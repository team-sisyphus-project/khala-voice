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
    # spike-recorder.ts bundles the TypeScript sources in packages/core directly.
    # No separate build artifact is produced, so source maps always point at the originals.
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

# Parameters that must never appear in logs.
# Adds this app's parameters to the Phoenix defaults (password, token, etc.).
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

# ── Oban job queues ─────────────────────────────────────────
config :vr, Oban,
  repo: VR.Repo,
  queues: [
    # transcription & audio splitting (kept low for external API load)
    transcription: 2,
    # AI summary
    summarize: 2,
    # credit grants & expiry
    billing: 1,
    # scheduled deletion, etc.
    maintenance: 1
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       # every hour on the hour — process expired deletion schedules
       {"0 * * * *", VR.Workers.DeletionWorker},
       # daily 03:10 — clean up expired friend invitations
       {"10 3 * * *", VR.Workers.InvitationCleanupWorker},
       # daily 00:20 — renew subscription periods + grant credits
       {"20 0 * * *", VR.Workers.MonthlyGrantWorker},
       # daily 00:30 — clean up expired credits (runs after grants)
       {"30 0 * * *", VR.Workers.CreditExpiryWorker},
       # daily 02:40 — permanently delete admin-account audit events older than 365 days
       {"40 2 * * *", VR.Workers.AdminAuditRetentionWorker}
     ]}
  ]

# ── Cloak ───────────────────────────────────────────────────
# The key is read at runtime from the CLOAK_KEY environment variable (see VR.Vault).
config :vr, VR.Vault, json_library: Jason

# ── ExAws (S3 presign) ──────────────────────────────────────
# Credentials are injected at request time via VR.Config.
# No keys live here.
config :ex_aws,
  json_codec: Jason,
  http_client: ExAws.Request.Req
