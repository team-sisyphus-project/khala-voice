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

    # Sets the Gettext locale and `<html lang>` from the account's `locale`. Comes after the account is attached.
    plug VRWeb.Plugs.Locale
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug VRWeb.UserAuth, :fetch_current_account
  end

  # Only attaches the guest session. Rejection is each action's job.
  pipeline :guest do
    plug VRWeb.GuestAuth
  end

  pipeline :require_guest do
    plug VRWeb.GuestAuth, :require_guest
  end

  # `:api` declares `accepts ["json"]`, so a markdown request would hit a 406.
  # Rather than touching the shared pipeline, we keep an export-only one.
  pipeline :api_export do
    plug :accepts, ["json", "md", "html"]
    plug :fetch_session
    plug VRWeb.UserAuth, :fetch_current_account
  end

  pipeline :api_auth do
    plug VRWeb.UserAuth, :require_authenticated_api
  end

  # ── System admin ───────────────────────────────────────────
  # In M1 the AdminAuth plug is replaced with one based on Account.is_admin.
  # Admin status is determined by the signed-in account's is_admin.
  # Without permission the response is 404 — we never reveal that the admin
  # screens exist. Create the first admin with `mix vr.make_admin <email>`.
  pipeline :admin do
    plug VRWeb.UserAuth, :require_admin
  end

  pipeline :redirect_if_authenticated do
    plug VRWeb.UserAuth, :redirect_if_authenticated
  end

  pipeline :require_auth do
    plug VRWeb.UserAuth, :require_authenticated
  end

  # ── Authentication ─────────────────────────────────────────
  scope "/", VRWeb do
    pipe_through [:browser, :redirect_if_authenticated]

    live_session :guest,
      on_mount: [{VRWeb.UserAuth, :mount_current_account}, {VRWeb.UserAuth, :set_locale}],
      layout: false do
      live "/login", AuthLive.LoginLive, :new
      live "/register", AuthLive.RegisterLive, :new
      live "/forgot-password", AuthLive.ForgotPasswordLive, :new
      live "/reset-password/:token", AuthLive.ResetPasswordLive, :edit
      live "/login/mfa", AuthLive.MFALive, :new

      # Two-factor **enrollment** lives inside the sign-in flow. Placing it in
      # the admin area would deadlock: you would have to get through a door
      # that only opens once you have enabled the thing behind it.
      live "/login/mfa/enroll", AuthLive.MFAEnrollLive, :new
    end

    post "/login", SessionController, :create
    post "/login/mfa", SessionController, :verify_mfa
    post "/login/mfa/enroll", SessionController, :enroll

    # Social sign-in — the controller returns 404 for disabled providers
    get "/auth/:provider", OAuthController, :request
    get "/auth/:provider/callback", OAuthController, :callback
  end

  scope "/", VRWeb do
    pipe_through :browser

    delete "/logout", SessionController, :delete
    get "/confirm/:token", ConfirmationController, :confirm
  end

  # ── Our MCP server (external clients read the archive) ─────
  # Authenticated with Bearer tokens (`mcp_`). Uses the CSRF-free `:api`
  # pipeline — it is called by programs, not browsers.
  pipeline :mcp do
    plug :accepts, ["json"]
    plug VRWeb.MCPAuth
  end

  scope "/", VRWeb do
    pipe_through :mcp

    post "/mcp", MCPController, :handle
  end

  # The metadata must be readable without authentication — it is the document
  # a client that received a 401 uses to figure out how to authenticate.
  scope "/", VRWeb do
    pipe_through :api

    get "/.well-known/oauth-protected-resource", MCPMetadataController, :show
    get "/.well-known/oauth-protected-resource/mcp", MCPMetadataController, :show
  end

  # ── Khala integration (sign-in required) ───────────────────
  # Only the OAuth round trip lives here. Using the token is `VR.Khala`'s job.
  scope "/khala", VRWeb do
    pipe_through [:browser, :require_auth]

    get "/connect", KhalaController, :connect
    get "/callback", KhalaController, :callback
  end

  # ── Share link page (opens without sign-in) ────────────────
  # Serves the same index.html. The real access decision is made by
  # `/api/public` — this page itself contains no meeting content.
  scope "/share", VRWeb do
    pipe_through :browser

    get "/:token", AppController, :index
  end

  # ── React SPA (sign-in required) ──────────────────────────
  # Three prefixes receive the same index.html. Routing happens on the client.
  #
  #   /app  desktop surface (three panes)
  #   /m    mobile surface (one screen at a time)
  #   /go   surface-neutral deep links — the links push and mail generate.
  #         The opening side picks the surface.
  #
  # See `apps/web/src/lib/surface.ts` for why surfaces are split and why
  # share links are not.
  for prefix <- ["/app", "/m", "/go"] do
    scope prefix, VRWeb do
      pipe_through [:browser, :require_auth]

      get "/", AppController, :index
      get "/*path", AppController, :index
    end
  end

  # ── App (sign-in required) ─────────────────────────────────
  scope "/", VRWeb do
    pipe_through [:browser, :require_auth]

    live_session :authenticated,
      on_mount: [{VRWeb.UserAuth, :require_authenticated}, {VRWeb.UserAuth, :set_locale}],
      layout: false do
      live "/friends", AppLive.FriendsLive, :index
      live "/settings", AppLive.SettingsLive, :edit
    end
  end

  # Invite links open without sign-in too — we need to show who sent the invite
  scope "/", VRWeb do
    pipe_through :browser

    live_session :invite,
      on_mount: [{VRWeb.UserAuth, :mount_current_account}, {VRWeb.UserAuth, :set_locale}],
      layout: false do
      live "/invite/:token", AppLive.InviteLive, :show
    end
  end

  # ── REST API ──────────────────────────────────────────────
  scope "/api", VRWeb.API do
    pipe_through [:api, :api_auth]

    get "/me", MeController, :show
    get "/friends", FriendController, :index
    delete "/me/session", MeController, :logout
    patch "/me/theme", MeController, :update_theme
    patch "/me/locale", MeController, :update_locale
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

    # ⚠ Must come before "/topics/:id". Phoenix matches in declaration order,
    #    so placed below it would be captured as id="reorder" and 404.
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

  # `.md` is a **literal segment** of the path. Phoenix does not negotiate the format from the extension.
  scope "/api", VRWeb.API do
    pipe_through [:api_export, :api_auth]

    get "/meetings/:id/export.md", MeetingController, :export_markdown
  end

  # ── Public API (guest share links) ─────────────────────────
  # **The only API reachable without authentication.** The key point is that
  # there is no meeting id in the path — which meeting a guest can see is
  # determined by the guest session.
  # Session-scoped paths live under a **different prefix**: placed under
  # `/share/:token`, `/share/meeting` would be captured as token="meeting".
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
      live "/accounts/verify-mfa", MFAStepUpLive, :new
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
