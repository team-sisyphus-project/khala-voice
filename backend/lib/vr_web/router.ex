defmodule VRWeb.Router do
  use VRWeb, :router

  get "/healthz", VRWeb.HealthController, :show

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {VRWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug VRWeb.UserAuth, :fetch_current_account
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug VRWeb.UserAuth, :fetch_current_account
  end

  # 게스트 세션을 붙이기만 한다. 거절은 각 액션이 한다.
  pipeline :guest do
    plug VRWeb.GuestAuth
  end

  pipeline :require_guest do
    plug VRWeb.GuestAuth, :require_guest
  end

  # `:api` 는 `accepts ["json"]` 이라 마크다운 요청이 406 을 맞는다.
  # 공용 파이프라인을 고치는 대신 내보내기 전용을 둔다.
  pipeline :api_export do
    plug :accepts, ["json", "md", "html"]
    plug :fetch_session
    plug VRWeb.UserAuth, :fetch_current_account
  end

  pipeline :api_auth do
    plug VRWeb.UserAuth, :require_authenticated_api
  end

  # ── 시스템 어드민 ──────────────────────────────────────────
  # M1에서 AdminAuth 플러그가 Account.is_admin 기반으로 교체된다.
  # 어드민은 로그인한 계정의 is_admin 으로 판정한다.
  # 권한이 없으면 404 — 어드민 화면의 존재 자체를 노출하지 않는다.
  # 첫 어드민은 `mix vr.make_admin <이메일>` 로 만든다.
  pipeline :admin do
    plug VRWeb.UserAuth, :require_admin
  end

  pipeline :redirect_if_authenticated do
    plug VRWeb.UserAuth, :redirect_if_authenticated
  end

  pipeline :require_auth do
    plug VRWeb.UserAuth, :require_authenticated
  end

  # ── 인증 ───────────────────────────────────────────────────
  scope "/", VRWeb do
    pipe_through [:browser, :redirect_if_authenticated]

    live_session :guest,
      on_mount: [{VRWeb.UserAuth, :mount_current_account}],
      layout: false do
      live "/login", AuthLive.LoginLive, :new
      live "/register", AuthLive.RegisterLive, :new
      live "/forgot-password", AuthLive.ForgotPasswordLive, :new
      live "/reset-password/:token", AuthLive.ResetPasswordLive, :edit
      live "/login/mfa", AuthLive.MFALive, :new

      # 2단계 인증 **등록**은 로그인 흐름 안에 있다. 어드민 구역 안에 두면
      # 켜야 들어갈 수 있는 문을 켜기 위해 들어가야 하는 데드락이 된다.
      live "/login/mfa/enroll", AuthLive.MFAEnrollLive, :new
    end

    post "/login", SessionController, :create
    post "/login/mfa", SessionController, :verify_mfa
    post "/login/mfa/enroll", SessionController, :enroll

    # 소셜 로그인 — 꺼진 제공자는 컨트롤러에서 404를 낸다
    get "/auth/:provider", OAuthController, :request
    get "/auth/:provider/callback", OAuthController, :callback
  end

  scope "/", VRWeb do
    pipe_through :browser

    delete "/logout", SessionController, :delete
    get "/confirm/:token", ConfirmationController, :confirm
  end

  # ── 우리 MCP 서버 (외부가 아카이브를 읽는다) ────────────────
  # 인증은 Bearer 토큰(`mcp_`). CSRF 가 없는 `:api` 파이프라인을 쓴다 —
  # 브라우저가 아니라 프로그램이 부른다.
  pipeline :mcp do
    plug :accepts, ["json"]
    plug VRWeb.MCPAuth
  end

  scope "/", VRWeb do
    pipe_through :mcp

    post "/mcp", MCPController, :handle
  end

  # 메타데이터는 인증 없이 읽을 수 있어야 한다 — 401 을 받은 클라이언트가
  # "어떻게 인증하나"를 알아내는 문서다.
  scope "/", VRWeb do
    pipe_through :api

    get "/.well-known/oauth-protected-resource", MCPMetadataController, :show
    get "/.well-known/oauth-protected-resource/mcp", MCPMetadataController, :show
  end

  # ── 칼라 연동 (로그인 필요) ────────────────────────────────
  # OAuth 왕복만 여기 있다. 토큰을 쓰는 일은 `VR.Khala` 가 한다.
  scope "/khala", VRWeb do
    pipe_through [:browser, :require_auth]

    get "/connect", KhalaController, :connect
    get "/callback", KhalaController, :callback
  end

  # ── 공유 링크 화면 (로그인 없이 열린다) ────────────────────
  # 같은 index.html 을 준다. 실제 판정은 `/api/public` 이 한다 —
  # 이 화면 자체에는 회의 내용이 없다.
  scope "/share", VRWeb do
    pipe_through :browser

    get "/:token", AppController, :index
  end

  # ── React SPA (로그인 필요) ───────────────────────────────
  # 세 접두어가 같은 index.html 을 받는다. 라우팅은 클라이언트가 한다.
  #
  #   /app  데스크톱 표면 (3단)
  #   /m    모바일 표면 (한 화면씩)
  #   /go   표면 중립 딥링크 — 푸시·메일이 만드는 링크. 여는 쪽이 표면을 고른다
  #
  # 표면을 나눈 이유와 공유 링크가 안 나뉘는 이유는 `apps/web/src/lib/surface.ts`.
  for prefix <- ["/app", "/m", "/go"] do
    scope prefix, VRWeb do
      pipe_through [:browser, :require_auth]

      get "/", AppController, :index
      get "/*path", AppController, :index
    end
  end

  # ── 앱 (로그인 필요) ──────────────────────────────────────
  scope "/", VRWeb do
    pipe_through [:browser, :require_auth]

    live_session :authenticated,
      on_mount: [{VRWeb.UserAuth, :require_authenticated}],
      layout: false do
      live "/friends", AppLive.FriendsLive, :index
      live "/settings", AppLive.SettingsLive, :edit
    end
  end

  # 초대 링크는 비로그인도 열 수 있다 — 누가 초대했는지 보여줘야 한다
  scope "/", VRWeb do
    pipe_through :browser

    live_session :invite,
      on_mount: [{VRWeb.UserAuth, :mount_current_account}],
      layout: false do
      live "/invite/:token", AppLive.InviteLive, :show
    end
  end

  # ── REST API ──────────────────────────────────────────────
  scope "/api", VRWeb.API do
    pipe_through [:api, :api_auth]

    get "/me", MeController, :show
    get "/friends", FriendController, :index
    patch "/me/theme", MeController, :update_theme
    patch "/me/transcribe-language", MeController, :update_transcribe_language
    get "/me/billing", BillingController, :show
    get "/me/push", PushController, :show
    post "/me/push", PushController, :subscribe
    delete "/me/push", PushController, :unsubscribe

    get "/mcp-tokens", MCPTokenController, :index
    post "/mcp-tokens", MCPTokenController, :create
    delete "/mcp-tokens/:id", MCPTokenController, :delete

    get "/khala", KhalaController, :show
    get "/khala/inboxes", KhalaController, :inboxes
    delete "/khala", KhalaController, :disconnect
    post "/meetings/:meeting_id/khala", KhalaController, :send_meeting

    get "/meetings", MeetingController, :index
    post "/meetings", MeetingController, :create
    get "/meetings/:id", MeetingController, :show
    patch "/meetings/:id", MeetingController, :update
    patch "/meetings/:id/permissions", MeetingController, :update_permissions
    patch "/meetings/:id/status", MeetingController, :update_status
    get "/meetings/:id/taxonomy", MeetingController, :taxonomy
    post "/meetings/:id/summarize", MeetingController, :summarize
    delete "/meetings/:id", MeetingController, :delete

    post "/meetings/:meeting_id/sessions", RecordingSessionController, :create
    post "/sessions/:id/upload", RecordingSessionController, :upload
    post "/sessions/:id/transcribe", RecordingSessionController, :transcribe
    get "/sessions/:id/audio", RecordingSessionController, :audio
    patch "/sessions/:id/speakers", RecordingSessionController, :update_speakers
    delete "/sessions/:id", RecordingSessionController, :delete

    get "/topics", TopicController, :index
    post "/topics", TopicController, :create

    # ⚠ "/topics/:id" 보다 위에 있어야 한다. Phoenix 는 선언 순서대로 매치하므로
    #    아래에 두면 id="reorder" 로 잡혀 404 가 난다.
    patch "/topics/reorder", TopicController, :reorder
    patch "/topics/:id", TopicController, :update
    delete "/topics/:id", TopicController, :delete

    get "/labels", LabelController, :index
    post "/labels", LabelController, :create
    patch "/labels/:id", LabelController, :update
    delete "/labels/:id", LabelController, :delete

    get "/meetings/:meeting_id/share-links", ShareLinkController, :index
    post "/meetings/:meeting_id/share-links", ShareLinkController, :create
    patch "/share-links/:id", ShareLinkController, :update
    post "/share-links/:id/rotate", ShareLinkController, :rotate
    post "/share-links/:id/pincode", ShareLinkController, :set_pincode
    delete "/share-links/:id", ShareLinkController, :delete

    post "/uploads/presign", UploadController, :presign
  end

  # `.md` 는 경로의 **리터럴 세그먼트**다. Phoenix 가 확장자로 포맷을 협상해 주지 않는다.
  scope "/api", VRWeb.API do
    pipe_through [:api_export, :api_auth]

    get "/meetings/:id/export.md", MeetingController, :export_markdown
  end

  # ── 공개 API (게스트 공유 링크) ────────────────────────────
  # **인증 없이 닿는 유일한 API 다.** 경로에 회의 id 가 없다는 점이 핵심이다 —
  # 게스트가 볼 회의는 게스트 세션이 정한다.
  # 세션 스코프 경로를 **다른 접두사**로 나눈다. `/share/:token` 아래에 두면
  # `/share/meeting` 이 token="meeting" 으로 잡힌다.
  scope "/api/public", VRWeb.API.Public do
    pipe_through [:api, :guest, :require_guest]

    get "/guest/meeting", ShareController, :meeting
    get "/guest/sessions/:id/audio", ShareController, :audio
    delete "/guest/session", ShareController, :leave
  end

  scope "/api/public", VRWeb.API.Public do
    pipe_through [:api, :guest]

    get "/share/:token", ShareController, :show
    post "/share/:token/enter", ShareController, :enter
  end

  scope "/_admin", VRWeb.Admin do
    pipe_through [:browser, :admin]

    live_session :admin,
      on_mount: [{VRWeb.UserAuth, :require_admin}],
      layout: false do
      live "/", DashboardLive, :index
      live "/accounts", AccountsLive, :index
      live "/security", SecurityLive, :index
      live "/billing", BillingLive, :index
      live "/settings/:group", SettingsLive, :edit
      live "/social", SocialLive, :index
      live "/llm", LlmLive, :index
    end
  end

  scope "/", VRWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", VRWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:vr, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/spike", VRWeb do
      pipe_through :browser

      get "/recorder", SpikeController, :recorder
    end

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: VRWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
