import Config

# ══════════════════════════════════════════════════════════════════
#  Runtime configuration
#
#  Every external credential in this app is read **only through VR.Config**.
#  (Resolution order: DB → environment variable → absent)
#
#  Therefore no API keys live here. This file only handles what the app
#  needs to boot: DB connection, secret key base, host.
#
#  If you need a new credential, add an entry to VR.Config.Registry,
#  not to config/runtime.exs.
# ══════════════════════════════════════════════════════════════════

# In dev/test, the .env file is read and lifted into environment variables.
# Releases (prod) use real environment variables, so this is skipped.
if config_env() in [:dev, :test] do
  env_file = Path.expand("../../.env", __DIR__)

  if File.exists?(env_file) do
    env_file
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
    |> Enum.each(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          key = String.trim(key)
          value = value |> String.trim() |> String.trim("\"") |> String.trim("'")

          # Values already in the shell win (so CI/deploys are not overwritten by .env)
          if System.get_env(key) in [nil, ""], do: System.put_env(key, value)

        _ ->
          :ok
      end
    end)
  end
end

# ── Entry point: booting the app vs preparing the database ────────
#
#  A release evaluates this file for **every** command it is given — including
#  `bin/vr eval 'VR.Release.migrate()'`, the migration step in `deploy.toml`.
#  `eval` runs a single expression on a *non-booted* system: no Endpoint, no
#  Vault, no supervision tree. Yet the requirements below used to be one
#  undifferentiated set, so a missing SECRET_KEY_BASE — a value no migration
#  reads — stopped the migration with a message about cookies. Channel A of the
#  configuration spec therefore splits in two:
#
#    * migration-only requirements — DATABASE_URL. Needed at both entry points.
#    * app-boot requirements — SECRET_KEY_BASE, CLOAK_KEY. Needed only where
#      something is actually started.
#
#  The same line decides what a *malformed* value stops, not only a missing one
#  — see `halt_or_warn` immediately below.
#
#  RELEASE_COMMAND is exported by the release's own launcher script (`start`,
#  `daemon`, `eval`, `rpc`, `remote`). It is **unset** for Mix, so
#  `mix ecto.migrate`, `mix setup` and `mix phx.server` keep exactly today's
#  behavior; only the non-booted `eval` entry point relaxes. Any other `eval`
#  expression is treated the same way, which is correct for the same reason:
#  `eval` starts no application, so nothing can consume the app secrets.
release_command = System.get_env("RELEASE_COMMAND")
migration_entry? = release_command == "eval"

entry_point_label =
  if migration_entry? do
    "the database migration entry point (`bin/vr eval 'VR.Release.migrate()'`)"
  else
    "the application (`bin/vr start`, `mix phx.server`)"
  end

# ── A malformed value: halt, or warn and carry on ─────────────────
#
#  PORT / HTTPS_PORT / PHX_SCHEME / PHX_URL_PORT all describe how the outside
#  world reaches a **running** app. The migration entry point runs none of that
#  — no Endpoint is started, no link is generated — so halting a migration on
#  one of these values reproduces, one variable further along, the exact defect
#  the split above exists to remove: a database preparation step that dies on a
#  value it never reads, and reaches the operator as `migration_failed`.
#
#  So the same wrong value now has two outcomes:
#
#    * app boot (`bin/vr start`, `mix phx.server`, every Mix task) — raises,
#      unchanged. "Up, but every generated link points at an origin that does
#      not answer" is the expensive failure, and a default quietly standing in
#      for a value somebody deliberately set is how you arrive at it.
#    * migration entry point — one stderr warning naming the variable and the
#      value this run continues with. The migration then proceeds.
#
#  The value is still wrong either way; the warning names the command that will
#  stop tolerating it. DATABASE_URL is untouched by this — the migration
#  genuinely reads it, so it stays a hard failure at both entry points.
halt_or_warn = fn name, message, fallback ->
  if migration_entry? do
    IO.puts(:stderr, """
    [VR.Runtime] ignoring #{name} and continuing with the default, #{fallback}.

    #{String.trim_trailing(message)}

    The database preparation entry point serves no requests and generates no
    links, so this run does not read it. `bin/vr start` does, and halts on
    this value until it is fixed.
    """)

    fallback
  else
    raise message
  end
end

# ── Port resolution ───────────────────────────────────────────────
#
#  PORT / HTTPS_PORT are **optional** environment variables. When missing or
#  empty, the default is used. Unlike DATABASE_URL / SECRET_KEY_BASE — values
#  that make the app behave wrongly when absent — these are values where a
#  default is perfectly fine.
#
#  However, a value that is **present but malformed** (PORT=8080a, PORT=0, …)
#  halts the app as-is. Silently swallowing it into the default produces
#  "the app is up but only the healthcheck fails", which is expensive to trace.
#  Empty means "not decided"; malformed means "decided wrongly" — they are
#  treated differently. At the migration entry point the same malformed value
#  is a warning instead (see halt_or_warn above): nothing there listens on a
#  port, so nothing there can be reached on the wrong one.
#
#  This rule lives here and nowhere else. config/dev.exs does not read the
#  port itself; the :dev branch below overwrites only the port on top of the
#  Endpoint config from dev.exs.
#  (Releases ship only config.exs / prod.exs / runtime.exs, so extracting the
#   rule into a separate file would fail to find it at boot. Instead of a
#   separate file, the single source of truth is "one function in one file".)
port_from_env = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    raw ->
      case String.trim(raw) do
        "" ->
          default

        trimmed ->
          case Integer.parse(trimmed) do
            {n, ""} when n > 0 and n <= 65_535 ->
              n

            _ ->
              message = """
              environment variable #{name} is not a valid port number: #{inspect(raw)}

              It must be an integer between 1 and 65535.
              Leave it empty to use the default, #{default}.
              """

              halt_or_warn.(name, message, default)
          end
      end
  end
end

# The dev environment's port follows the same rule.
# The ip/certfile etc. already set by dev.exs are kept; only the port is merged.
if config_env() == :dev do
  config :vr, VRWeb.Endpoint, http: [port: port_from_env.("PORT", 4000)]

  # DATABASE_URL is honored in dev too (.env.example documents it as the way to
  # point at a non-default Postgres). When it is set and non-empty, its parsed
  # values (user/pass/host/db) take precedence over the localhost defaults in
  # config/dev.exs — Ecto merges `url` over keyword options. When absent or
  # empty, dev.exs's vr_dev defaults stay in effect unchanged.
  # Like PORT above, a blank value means "not decided" — fall back to defaults.
  case String.trim(System.get_env("DATABASE_URL") || "") do
    "" -> :ok
    database_url -> config :vr, VR.Repo, url: database_url
  end

  if System.get_env("DEV_BIND_ALL") == "true" do
    config :vr, VRWeb.Endpoint, https: [port: port_from_env.("HTTPS_PORT", 4001)]
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/vr start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :vr, VRWeb.Endpoint, server: true
end

if config_env() == :prod do
  # Migration-only requirement: needed by the migration entry point *and* by
  # the app. Missing here, both are dead, so both raise the same way — with the
  # entry point named, because "DATABASE_URL is missing" during a deploy is
  # otherwise attributed to whichever step the operator happens to be watching.
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.

      It is required by #{entry_point_label}.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :vr, VR.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # App-boot requirement: signs and encrypts cookies. A default value is used in
  # config/dev.exs and config/test.exs but you want a different value for prod,
  # and you most likely don't want to check it into version control, so we use
  # an environment variable instead.
  #
  # Absent at the migration entry point it is simply left unset: no Endpoint is
  # started there, and inventing a placeholder would bake a known signing key
  # into an open-source repo.
  secret_key_base =
    case System.get_env("SECRET_KEY_BASE") do
      nil when migration_entry? ->
        nil

      nil ->
        raise """
        environment variable SECRET_KEY_BASE is missing.

        It is required by #{entry_point_label}, which uses it to sign and
        encrypt cookies. You can generate one by calling: mix phx.gen.secret

        Database migrations do not read it — `bin/vr eval 'VR.Release.migrate()'`
        runs without it.
        """

      value ->
        value
    end

  host = System.get_env("PHX_HOST", "localhost")

  # PORT is optional — a platform-injected value wins; otherwise 4000.
  port = port_from_env.("PORT", 4000)

  # ── Public URL: how the outside world reaches this app ──────────
  #
  #  `http:` below is what the app *listens* on. `url:` is what it *claims to
  #  be* — the scheme/host/port Phoenix stamps onto every absolute URL it
  #  generates (`VRWeb.Endpoint.url/0`, `url(~p"/…")`, LiveView's socket URL,
  #  the OAuth `redirect_uri`, invite links, OAuth/MCP discovery metadata).
  #  The two are deliberately different: behind a TLS terminator the app
  #  listens on plain HTTP port 4000 while the world reaches it at
  #  https://host:443.
  #
  #  This used to be hardcoded to https/443 — correct for exactly one topology.
  #  A preview reachable only over plain HTTP got absolute links pointing at an
  #  https origin that does not answer, so the callback and every generated link
  #  broke while the app itself looked healthy.
  #
  #  Both halves now come from the environment, and the default is the old
  #  hardcoded pair, so an existing https deployment that sets neither variable
  #  resolves to exactly what it resolved to before:
  #
  #    PHX_SCHEME    http | https        default https
  #    PHX_URL_PORT  1..65535            default 443 for https, 80 for http
  #
  #  PHX_URL_PORT follows the same rule as PORT (see port_from_env): empty
  #  means "not decided" and takes the default; malformed halts boot. It only
  #  needs setting when the public port is neither the scheme's default nor
  #  hidden behind a proxy — e.g. a preview served directly on http://host:4000.
  url_scheme =
    case System.get_env("PHX_SCHEME") do
      nil ->
        "https"

      raw ->
        case raw |> String.trim() |> String.downcase() do
          "" ->
            "https"

          scheme when scheme in ["http", "https"] ->
            scheme

          _ ->
            message = """
            environment variable PHX_SCHEME is not a valid URL scheme: #{inspect(raw)}

            It must be one of:

                https   (default) the app is reached over TLS — directly or
                        through a terminating proxy
                http    the app is reached over plain HTTP, as in a preview
                        environment with no TLS in front of it

            It sets the scheme of the links this app generates, not the one it
            listens on. Leave it empty to use the default, https.
            """

            halt_or_warn.("PHX_SCHEME", message, "https")
        end
    end

  # 443 and 80 are the ports each scheme omits from a URL. Deriving the default
  # from the scheme means the common cases — https behind a terminator, http in
  # a preview — both need no second variable.
  url_port = port_from_env.("PHX_URL_PORT", if(url_scheme == "https", do: 443, else: 80))

  config :vr, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  endpoint_config = [
    url: [host: host, port: url_port, scheme: url_scheme],
    http: [
      ip: {0, 0, 0, 0},
      port: port
    ]
  ]

  # Set only when we have one (see above). Phoenix raises on its own if an
  # Endpoint is ever started without it, which is the correct failure for a
  # path that has no business starting one.
  endpoint_config =
    if secret_key_base do
      Keyword.put(endpoint_config, :secret_key_base, secret_key_base)
    else
      endpoint_config
    end

  config :vr, VRWeb.Endpoint, endpoint_config

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :vr, VRWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :vr, VRWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :vr, VR.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end

# ── Cloak key presence check ──────────────────────────────────────
# App-boot requirement. VR.Vault verifies this again at boot, but warning here
# first makes the cause easier to spot. Skipped at the migration entry point:
# no Vault is started there, and "the app will not boot" is a false alarm in
# the middle of a migration log.
if config_env() != :test and not migration_entry? and System.get_env("CLOAK_KEY") in [nil, ""] do
  IO.warn("""
  [VR.Runtime] CLOAK_KEY is not set. The app will not boot.

      openssl rand -base64 32

  Put the generated value into CLOAK_KEY in .env.
  """)
end
