defmodule VR.Config.Registry do
  @moduledoc """
  Declarative definitions of system configuration keys.

  The admin settings screen is **generated from this registry.** To add a new
  config value, add a single entry here — the screen, validation, masking, and
  env-var fallback follow along.

  ## Entry fields

  | Field | Meaning |
  |---|---|
  | `key` | `"group.name"` format. DB `system_configs.key` |
  | `group` | Admin screen grouping |
  | `label` | Name shown on screen |
  | `env` | Environment variable fallback name (nil means DB-only) |
  | `type` | `:string` `:text` `:boolean` `:integer` `:json` |
  | `secret` | When true, the value is masked and never echoed back to the screen |
  | `required` | Value needed for the feature to operate |
  | `feature` | The feature this value belongs to. Unset means the feature turns off |
  | `help` | Input help text |
  """

  @groups [
    storage: %{label: "Storage (S3)", icon: "hero-cloud-arrow-up"},
    stt: %{label: "Transcription (Google STT)", icon: "hero-microphone"},
    llm: %{label: "AI summary", icon: "hero-sparkles"},
    mail: %{label: "Mail delivery", icon: "hero-envelope"},
    push: %{label: "Web push", icon: "hero-bell"},
    policy: %{label: "Policy", icon: "hero-adjustments-horizontal"},
    app: %{label: "App", icon: "hero-globe-alt"},
    khala: %{label: "Khala integration", icon: "hero-paper-airplane"}
  ]

  @entries [
    # ── Storage ─────────────────────────────────────────────
    %{
      key: "storage.bucket",
      group: :storage,
      label: "Bucket name",
      env: "STORAGE_BUCKET",
      type: :string,
      secret: false,
      required: true,
      feature: :storage,
      help: "S3 bucket where recording audio and transcripts are stored"
    },
    %{
      key: "storage.region",
      group: :storage,
      label: "Region",
      env: "STORAGE_REGION",
      type: :string,
      secret: false,
      required: true,
      feature: :storage,
      help: "e.g. ap-northeast-2"
    },
    %{
      key: "storage.access_key_id",
      group: :storage,
      label: "Access Key ID",
      env: "STORAGE_ACCESS_KEY_ID",
      type: :string,
      secret: true,
      required: true,
      feature: :storage,
      help: "IAM key with S3 PutObject permission"
    },
    %{
      key: "storage.secret_access_key",
      group: :storage,
      label: "Secret Access Key",
      env: "STORAGE_SECRET_ACCESS_KEY",
      type: :string,
      secret: true,
      required: true,
      feature: :storage,
      help: nil
    },
    %{
      key: "storage.cdn_base_url",
      group: :storage,
      label: "CDN base URL",
      env: "STORAGE_CDN_BASE_URL",
      type: :string,
      secret: false,
      required: false,
      feature: :storage,
      help: "Domain used for downloads. Leave empty to use S3 URLs directly"
    },
    %{
      key: "storage.download_url_ttl_seconds",
      group: :storage,
      label: "Audio download URL expiry (seconds)",
      env: "STORAGE_DOWNLOAD_URL_TTL_SECONDS",
      type: :integer,
      secret: false,
      required: false,
      feature: nil,
      help: "Lifetime of signed playback URLs. Defaults to 300 seconds when empty. A longer value means a leaked link stays valid that much longer"
    },

    # ── Transcription (Google Cloud STT v2) ─────────────────
    %{
      key: "stt.credentials_json",
      group: :stt,
      label: "Service account JSON",
      env: "STT_CREDENTIALS_JSON",
      type: :text,
      secret: true,
      required: true,
      feature: :transcription,
      help: "Paste the full contents of the GCP service account key file"
    },
    %{
      key: "stt.project_id",
      group: :stt,
      label: "GCP project ID",
      env: "STT_PROJECT_ID",
      type: :string,
      secret: false,
      required: true,
      feature: :transcription,
      help: nil
    },
    %{
      key: "stt.location",
      group: :stt,
      label: "Region",
      env: "STT_LOCATION",
      type: :string,
      secret: false,
      required: false,
      feature: :transcription,
      help: "Defaults to us"
    },
    %{
      key: "stt.recognizer",
      group: :stt,
      label: "Recognizer name",
      env: "STT_RECOGNIZER",
      type: :string,
      secret: false,
      required: false,
      feature: :transcription,
      help: "Defaults to meeting-transcriber"
    },
    %{
      key: "stt.gcs_bucket",
      group: :stt,
      label: "GCS staging bucket",
      env: "STT_GCS_BUCKET",
      type: :string,
      secret: false,
      required: true,
      feature: :transcription,
      help: "batchRecognize requires a gs:// path. A bucket where audio is briefly uploaded then deleted"
    },
    %{
      key: "stt.cost_per_minute_usd",
      group: :stt,
      label: "Cost per minute (USD)",
      env: "STT_COST_PER_MINUTE_USD",
      type: :string,
      secret: false,
      required: false,
      feature: nil,
      help: "Input to credit conversion. Enter Google STT's published rate (e.g. 0.016). Leave empty to skip metering"
    },
    %{
      key: "stt.dev_mode",
      group: :stt,
      label: "Dev mode",
      env: "STT_DEV_MODE",
      type: :boolean,
      secret: false,
      required: false,
      feature: nil,
      help: "When on, returns mock transcription results without calling the real API. For developing without GCP credentials"
    },

    # ── AI summary ──────────────────────────────────────────
    # Per-provider keys, models, and rates are managed in the `llm_providers`
    # table (Admin → LLM providers). Only global switches live here.
    %{
      key: "llm.dev_mode",
      group: :llm,
      label: "Dev mode",
      env: "LLM_DEV_MODE",
      type: :boolean,
      secret: false,
      required: false,
      feature: nil,
      help: "When on, generates mock summaries without calling the LLM. Quotes are pulled from the real transcription, so jump behavior is verified too"
    },
    %{
      key: "llm.auto_summarize",
      group: :llm,
      label: "Auto-summarize when transcription completes",
      env: "LLM_AUTO_SUMMARIZE",
      type: :boolean,
      secret: false,
      required: false,
      feature: nil,
      help: "When off, summaries are only generated when the user presses [Summarize]"
    },
    %{
      key: "app.trust_proxy_headers",
      group: :app,
      label: "Trust proxy headers",
      env: "APP_TRUST_PROXY_HEADERS",
      type: :boolean,
      secret: false,
      required: false,
      feature: nil,
      help:
        "Only turn on behind a reverse proxy. When on, X-Forwarded-For is used as the visitor IP. With no proxy in front, a single header line bypasses IP restrictions"
    },
    %{
      key: "app.timezone",
      group: :app,
      label: "Display timezone",
      env: "APP_TIMEZONE",
      type: :string,
      secret: false,
      required: false,
      feature: nil,
      help: "Timezone used for date/time display in meeting-notes exports. e.g. Asia/Seoul. Defaults to Asia/Seoul when empty"
    },

    # ── Mail ────────────────────────────────────────────────
    %{
      key: "mail.provider",
      group: :mail,
      label: "Provider",
      env: "MAIL_PROVIDER",
      type: :string,
      secret: false,
      required: true,
      feature: :mail,
      help: "local | mailgun | resend"
    },
    %{
      key: "mail.domain",
      group: :mail,
      label: "Sending domain",
      env: "MAIL_DOMAIN",
      type: :string,
      secret: false,
      required: false,
      feature: :mail,
      help: nil
    },
    %{
      key: "mail.api_key",
      group: :mail,
      label: "API key",
      env: "MAIL_API_KEY",
      type: :string,
      secret: true,
      required: false,
      feature: :mail,
      help: nil
    },

    # ── Web push ────────────────────────────────────────────
    %{
      key: "push.vapid_public_key",
      group: :push,
      label: "VAPID public key",
      env: "VAPID_PUBLIC_KEY",
      type: :string,
      secret: false,
      required: true,
      feature: :push,
      help: nil
    },
    %{
      key: "push.vapid_private_key",
      group: :push,
      label: "VAPID private key",
      env: "VAPID_PRIVATE_KEY",
      type: :string,
      secret: true,
      required: true,
      feature: :push,
      help: nil
    },
    %{
      key: "push.vapid_subject",
      group: :push,
      label: "VAPID Subject",
      env: "VAPID_SUBJECT",
      type: :string,
      secret: false,
      required: true,
      feature: :push,
      help: "Contact starting with mailto: or https:"
    },

    # ── Policy ──────────────────────────────────────────────
    %{
      key: "policy.invite_code_required",
      group: :policy,
      label: "Invite code required at signup",
      env: nil,
      type: :boolean,
      secret: false,
      required: false,
      feature: nil,
      help: "When on, an invite code is required to sign up"
    },
    %{
      key: "policy.hard_stop_on_zero_credits",
      group: :policy,
      label: "Block when credits run out",
      env: nil,
      type: :boolean,
      secret: false,
      required: false,
      feature: nil,
      help: "When on, new transcription and summary requests are rejected when the balance is at or below zero. Turn on when monetizing"
    },

    # ── App ─────────────────────────────────────────────────
    %{
      key: "app.base_url",
      group: :app,
      label: "Service base URL",
      env: "APP_BASE_URL",
      type: :string,
      secret: false,
      required: true,
      feature: :mail,
      help: "Base address for links included in emails. e.g. https://voice.example.com"
    },
    %{
      key: "app.bootstrap_admin_email",
      group: :app,
      label: "Initial admin email",
      env: "BOOTSTRAP_ADMIN_EMAIL",
      type: :string,
      secret: false,
      required: false,
      feature: nil,
      help: "Used only when creating the very first admin account"
    },
    %{
      key: "app.bootstrap_admin_password",
      group: :app,
      label: "Initial admin password",
      env: "BOOTSTRAP_ADMIN_PASSWORD",
      type: :string,
      secret: true,
      required: false,
      feature: nil,
      help: "Used only when creating the very first admin account. When empty, a secure random password is generated"
    },

    # ── Khala integration ───────────────────────────────────
    # No secrets here. Khala is a public client (PKCE), so no client_secret is
    # used, and the client_id comes from dynamic registration (`docs/15-mcp-khala.md`).
    %{
      key: "khala.enabled",
      group: :khala,
      label: "Enable Khala integration",
      env: "KHALA_ENABLED",
      type: :boolean,
      secret: false,
      required: false,
      feature: :khala,
      help: "When off, the Khala integration disappears entirely from the settings and meeting screens"
    },
    %{
      key: "khala.mcp_url",
      group: :khala,
      label: "Khala MCP address",
      env: "KHALA_MCP_URL",
      type: :string,
      secret: false,
      required: false,
      feature: :khala,
      help: "e.g. https://mcp.khala.to/mcp — OAuth endpoints are discovered automatically from this address"
    }
  ]

  @doc "All configuration entries"
  def entries, do: @entries

  @doc "Group definitions (ordered)"
  def groups, do: @groups

  @doc "Entries belonging to a group"
  def entries_for(group), do: Enum.filter(@entries, &(&1.group == group))

  @doc "Look up an entry by key"
  def entry(key), do: Enum.find(@entries, &(&1.key == key))

  @doc "List of known keys"
  def keys, do: Enum.map(@entries, & &1.key)

  @doc "Entries required for a feature to operate"
  def required_for(feature) do
    Enum.filter(@entries, &(&1.feature == feature and &1.required))
  end

  @doc "List of declared features"
  def features do
    @entries |> Enum.map(& &1.feature) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end
end
