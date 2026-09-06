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

# ── Port resolution ───────────────────────────────────────────────
#
#  PORT / HTTPS_PORT are **optional** environment variables. When missing or
#  empty, the default is used. Unlike DATABASE_URL / SECRET_KEY_BASE — values
#  that make the app behave wrongly when absent — these are values where a
#  default is perfectly fine.
#
#  However, a value that is **present but malformed** (PORT=8080a, PORT=0, …)
#  halts boot as-is. Silently swallowing it into the default produces
#  "the app is up but only the healthcheck fails", which is expensive to trace.
#  Empty means "not decided"; malformed means "decided wrongly" — they are
#  treated differently.
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
              raise """
              The value of environment variable #{name} is not a valid port number: #{inspect(raw)}
              It must be an integer between 1 and 65535.
              Leave it empty to use the default, #{default}.
              """
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
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
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

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST", "localhost")

  # PORT is optional — a platform-injected value wins; otherwise 4000.
  port = port_from_env.("PORT", 4000)

  config :vr, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :vr, VRWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

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
# VR.Vault verifies this again at boot, but warning here first makes the cause easier to spot.
if config_env() != :test and System.get_env("CLOAK_KEY") in [nil, ""] do
  IO.warn("""
  CLOAK_KEY is not set. The app will not boot.

      openssl rand -base64 32

  Put the generated value into CLOAK_KEY in .env.
  """)
end
