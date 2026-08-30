import Config

# ══════════════════════════════════════════════════════════════════
#  런타임 설정
#
#  이 앱의 외부 자격증명은 **전부 VR.Config를 통해서만** 읽는다.
#  (해석 순서: DB → 환경변수 → 없음)
#
#  따라서 여기에는 API 키를 두지 않는다. 여기서 다루는 것은
#  앱이 부팅하는 데 필요한 것(DB 접속, 시크릿 베이스, 호스트)뿐이다.
#
#  새 자격증명이 필요하면 config/runtime.exs가 아니라
#  VR.Config.Registry에 항목을 추가한다.
# ══════════════════════════════════════════════════════════════════

# 개발/테스트에서는 .env 파일을 읽어 환경변수로 올린다.
# 릴리즈(prod)에서는 실제 환경변수를 쓰므로 건너뛴다.
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

          # 이미 셸에 있는 값이 우선한다 (CI·배포에서 .env를 덮어쓰지 않도록)
          if System.get_env(key) in [nil, ""], do: System.put_env(key, value)

        _ ->
          :ok
      end
    end)
  end
end

# ── 포트 해석 ─────────────────────────────────────────────────────
#
#  PORT / HTTPS_PORT 는 **선택** 환경변수다. 없거나 비어 있으면 기본값을 쓴다.
#  DATABASE_URL · SECRET_KEY_BASE 처럼 "없으면 동작이 틀리는" 값이 아니라
#  "없으면 기본값이면 되는" 값이기 때문이다.
#
#  다만 값이 **있는데 형식이 틀린** 경우(PORT=8080a, PORT=0 …)는 그대로 멈춘다.
#  기본값으로 조용히 삼키면 "떴는데 헬스체크만 실패" 가 되어 원인 추적이 비싸진다.
#  비어 있는 것은 "안 정했다", 형식이 틀린 것은 "잘못 정했다" — 다르게 대한다.
#
#  이 규칙은 여기 한 곳에만 있다. config/dev.exs 는 포트를 직접 읽지 않고,
#  아래 :dev 분기가 dev.exs 의 Endpoint 설정 위에 포트만 덮어쓴다.
#  (릴리즈에는 config.exs / prod.exs / runtime.exs 만 실려 가므로 규칙을
#   별도 파일로 빼면 부팅 시점에 파일을 찾지 못한다. 그래서 파일 분리 대신
#   "한 파일 안의 한 함수" 로 단일 출처를 지킨다.)
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
              환경변수 #{name} 의 값이 올바른 포트 번호가 아닙니다: #{inspect(raw)}
              1~65535 사이의 정수여야 합니다.
              값을 비워 두면 기본값 #{default} 을 사용합니다.
              """
          end
      end
  end
end

# 개발 환경의 포트도 같은 규칙을 탄다.
# dev.exs 가 이미 잡아 둔 ip/certfile 등은 유지되고 port 만 병합된다.
if config_env() == :dev do
  config :vr, VRWeb.Endpoint, http: [port: port_from_env.("PORT", 4000)]

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

  # PORT 는 선택값이다 — 플랫폼이 주입하면 그 값이 이기고, 없으면 4000.
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

# ── Cloak 키 존재 확인 ────────────────────────────────────────────
# VR.Vault가 부팅 시 다시 검증하지만, 여기서 먼저 알려주면 원인 파악이 빠르다.
if config_env() != :test and System.get_env("CLOAK_KEY") in [nil, ""] do
  IO.warn("""
  CLOAK_KEY가 설정되지 않았습니다. 앱이 부팅되지 않습니다.

      openssl rand -base64 32

  생성한 값을 .env 의 CLOAK_KEY 에 넣으세요.
  """)
end
