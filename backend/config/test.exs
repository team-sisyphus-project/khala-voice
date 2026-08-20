import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :vr, VR.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "vr_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :vr, VRWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "vx3G8glyrMLOXOAEixR+88Q6d4JW+Do37Gh/JcNXh8l1MJ7q9juxpBph7Z1DFIn+",
  server: false

# In test we don't send emails
config :vr, VR.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# 테스트에서는 Oban 큐와 플러그인을 끈다.
# 켜두면 Peer 프로세스가 Ecto SQL 샌드박스 밖에서 DB를 잡아 테스트가 전부 깨진다.
config :vr, Oban, testing: :manual

# 테스트에서는 bcrypt 강도를 최소로 낮춘다. 보안이 아니라 속도가 목적이다.
# 운영 강도(12)로 돌리면 테스트 한 벌에 수십 초가 걸린다.
config :bcrypt_elixir, log_rounds: 1
