# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :vr,
  namespace: VR,
  ecto_repos: [VR.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :vr, VRWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: VRWeb.ErrorHTML, json: VRWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: VR.PubSub,
  live_view: [signing_salt: "gkzQhgY4"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :vr, VR.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  vr: [
    # spike-recorder.ts 는 packages/core 의 TypeScript 소스를 직접 번들한다.
    # 별도 빌드 산출물을 만들지 않아 소스맵이 항상 원본을 가리킨다.
    args:
      ~w(js/app.js js/spike-recorder.ts --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  vr: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# 로그에 남으면 안 되는 파라미터.
# Phoenix 기본값(password, token 등)에 이 앱의 것을 더한다.
config :phoenix, :filter_parameters, [
  "password",
  "token",
  "secret",
  "pincode",
  "api_key",
  "client_secret",
  "credentials_json"
]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# ── Oban 잡 큐 ──────────────────────────────────────────────
config :vr, Oban,
  repo: VR.Repo,
  queues: [
    # 전사 · 오디오 분할 (외부 API 부하 고려해 낮게)
    transcription: 2,
    # AI 요약
    summarize: 2,
    # 크레딧 지급 · 만료
    billing: 1,
    # 예약 삭제 등
    maintenance: 1
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       # 매시 정각 — 삭제 예약 만료 처리
       {"0 * * * *", VR.Workers.DeletionWorker},
       # 매일 03:10 — 만료된 친구 초대 정리
       {"10 3 * * *", VR.Workers.InvitationCleanupWorker},
       # 매일 00:20 — 구독 기간 갱신 + 크레딧 지급
       {"20 0 * * *", VR.Workers.MonthlyGrantWorker},
       # 매일 00:30 — 만료된 크레딧 정리 (지급 뒤에 돈다)
       {"30 0 * * *", VR.Workers.CreditExpiryWorker},
       # 매일 02:40 — 365일이 지난 관리자 계정 감사 이벤트 영구 삭제
       {"40 2 * * *", VR.Workers.AdminAuditRetentionWorker}
     ]}
  ]

# ── Cloak ───────────────────────────────────────────────────
# 키는 런타임에 CLOAK_KEY 환경변수에서 읽는다 (VR.Vault 참조).
config :vr, VR.Vault, json_library: Jason

# ── ExAws (S3 presign) ──────────────────────────────────────
# 자격증명은 VR.Config를 통해 요청 시점에 주입한다.
# 여기에 키를 두지 않는다.
config :ex_aws,
  json_codec: Jason,
  http_client: ExAws.Request.Req
