defmodule VR.RuntimeConfigTest do
  @moduledoc """
  Regression tests for the port-resolution rules in `config/runtime.exs`.

  These tests do not boot the app. They evaluate the config file with
  `Config.Reader` and inspect the resulting keyword tree. That is, they verify
  "does the config resolve to that value", not "does the Endpoint actually
  listen on that port".

  `async: false` because env vars are temporarily overridden process-wide.
  """
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../config/runtime.exs", __DIR__)

  # Values the production branch requires. Always filled, regardless of port.
  @prod_required %{
    "DATABASE_URL" => "ecto://user:pass@localhost/vr_test",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "CLOAK_KEY" => Base.encode64(String.duplicate("k", 32))
  }

  # Variables affecting the port are explicitly cleared at the start of each case.
  @port_vars ~w(PORT HTTPS_PORT DEV_BIND_ALL PHX_SERVER)

  # RELEASE_COMMAND selects the entry point (see "migration-only entry point"
  # below). Cleared like the port vars so every other case reads as what it has
  # always been: the app-boot entry point.
  @entry_vars ~w(RELEASE_COMMAND)

  defp with_env(overrides, fun) do
    vars = Map.keys(@prod_required) ++ @port_vars ++ @entry_vars ++ Map.keys(overrides)
    original = Map.new(vars, &{&1, System.get_env(&1)})

    try do
      Enum.each(@port_vars ++ @entry_vars, &System.delete_env/1)
      Enum.each(@prod_required, fn {k, v} -> System.put_env(k, v) end)

      Enum.each(overrides, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      fun.()
    after
      Enum.each(original, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp read!(env), do: Config.Reader.read!(@runtime_exs, env: env)

  defp endpoint(env) do
    read!(env)
    |> Keyword.fetch!(:vr)
    |> Keyword.fetch!(VRWeb.Endpoint)
  end

  defp prod_http_port, do: endpoint(:prod) |> Keyword.fetch!(:http) |> Keyword.fetch!(:port)

  describe "prod / when PORT is missing or empty" do
    test "resolves to 4000 without raising even when PORT is absent (M1, M2)" do
      with_env(%{"PORT" => nil}, fn ->
        assert prod_http_port() == 4000
      end)
    end

    test "PORT='' resolves to 4000 (M3)" do
      with_env(%{"PORT" => ""}, fn ->
        assert prod_http_port() == 4000
      end)
    end

    test "PORT='   ' resolves to 4000 (M3)" do
      with_env(%{"PORT" => "   "}, fn ->
        assert prod_http_port() == 4000
      end)
    end
  end

  describe "prod / when PORT has a value" do
    test "the injected value beats the default (M4)" do
      with_env(%{"PORT" => "8080"}, fn ->
        assert prod_http_port() == 8080
      end)
    end

    test "leading/trailing whitespace and newlines are ignored (M5)" do
      with_env(%{"PORT" => " 8080\n"}, fn ->
        assert prod_http_port() == 8080
      end)
    end

    test "the 0.0.0.0 binding is preserved" do
      with_env(%{"PORT" => "8080"}, fn ->
        assert endpoint(:prod) |> Keyword.fetch!(:http) |> Keyword.fetch!(:ip) == {0, 0, 0, 0}
      end)
    end
  end

  describe "prod / when PORT is malformed" do
    # Empty means "not set"; malformed means "set wrong".
    # Swallowing the latter as 4000 makes the deploy look up while only the health check fails.
    for bad <- ["abc", "8080a", "0", "99999", "-1", "tcp://host:8080", "80.5"] do
      test "PORT=#{inspect(bad)} halts, naming PORT (M10)" do
        with_env(%{"PORT" => unquote(bad)}, fn ->
          err = assert_raise RuntimeError, fn -> prod_http_port() end
          assert err.message =~ "PORT"
          assert err.message =~ unquote(bad)
        end)
      end
    end
  end

  describe "prod / genuinely required values" do
    test "still halts when SECRET_KEY_BASE is missing (M11)" do
      with_env(%{"SECRET_KEY_BASE" => nil, "PORT" => "8080"}, fn ->
        assert_raise RuntimeError, ~r/SECRET_KEY_BASE/, fn -> prod_http_port() end
      end)
    end

    test "still halts when DATABASE_URL is missing (M11)" do
      with_env(%{"DATABASE_URL" => nil, "PORT" => "8080"}, fn ->
        assert_raise RuntimeError, ~r/DATABASE_URL/, fn -> prod_http_port() end
      end)
    end
  end

  # ── Entry points ────────────────────────────────────────────────
  #
  # A release evaluates runtime.exs for every command, including the migration
  # step `bin/vr eval 'VR.Release.migrate()'`. That entry point boots nothing,
  # so it must not be stopped by secrets only a running app reads — while the
  # app-boot entry point must keep stopping on exactly the same values as before.

  describe "prod / migration-only entry point (RELEASE_COMMAND=eval)" do
    defp eval_endpoint(overrides) do
      overrides = Map.put(overrides, "RELEASE_COMMAND", "eval")
      with_env(overrides, fn -> endpoint(:prod) end)
    end

    test "resolves without SECRET_KEY_BASE" do
      config = eval_endpoint(%{"SECRET_KEY_BASE" => nil})

      assert Keyword.fetch!(config, :http) |> Keyword.fetch!(:port) == 4000
    end

    test "sets no placeholder secret_key_base when the value is absent" do
      # A stand-in value here would be a known signing key in a public repo.
      config = eval_endpoint(%{"SECRET_KEY_BASE" => nil})

      refute Keyword.has_key?(config, :secret_key_base)
    end

    test "resolves without CLOAK_KEY" do
      config = eval_endpoint(%{"CLOAK_KEY" => nil})

      assert Keyword.fetch!(config, :http) |> Keyword.fetch!(:port) == 4000
    end

    test "uses SECRET_KEY_BASE when it is set, exactly as the app does" do
      config = eval_endpoint(%{})

      assert Keyword.fetch!(config, :secret_key_base) == @prod_required["SECRET_KEY_BASE"]
    end

    test "the database URL is still required, and the message names this entry point" do
      error =
        assert_raise RuntimeError, fn ->
          eval_endpoint(%{"DATABASE_URL" => nil, "SECRET_KEY_BASE" => nil})
        end

      assert error.message =~ "DATABASE_URL"
      assert error.message =~ "bin/vr eval 'VR.Release.migrate()'"
    end

    test "a malformed PORT still halts — relaxing secrets relaxes nothing else" do
      assert_raise RuntimeError, ~r/PORT/, fn ->
        eval_endpoint(%{"PORT" => "8080a", "SECRET_KEY_BASE" => nil})
      end
    end

    test "the platform-injected PORT is still honored" do
      config = eval_endpoint(%{"PORT" => "8080", "SECRET_KEY_BASE" => nil})

      assert Keyword.fetch!(config, :http) |> Keyword.fetch!(:port) == 8080
    end
  end

  describe "prod / app-boot entry point" do
    # `bin/vr start`, `bin/vr daemon` and every Mix task (RELEASE_COMMAND unset)
    # must keep failing on the app secrets.
    for command <- [nil, "start", "daemon", "rpc", "remote"] do
      test "RELEASE_COMMAND=#{inspect(command)} still halts without SECRET_KEY_BASE" do
        with_env(%{"RELEASE_COMMAND" => unquote(command), "SECRET_KEY_BASE" => nil}, fn ->
          assert_raise RuntimeError, ~r/SECRET_KEY_BASE/, fn -> prod_http_port() end
        end)
      end
    end

    test "the SECRET_KEY_BASE message names the app, and says migrations do not need it" do
      error =
        with_env(%{"SECRET_KEY_BASE" => nil}, fn ->
          assert_raise RuntimeError, fn -> prod_http_port() end
        end)

      assert error.message =~ "mix phx.gen.secret"
      assert error.message =~ "bin/vr start"
      assert error.message =~ "bin/vr eval 'VR.Release.migrate()'"
    end

    test "the DATABASE_URL message names the app entry point, not the migration one" do
      error =
        with_env(%{"DATABASE_URL" => nil}, fn ->
          assert_raise RuntimeError, fn -> prod_http_port() end
        end)

      assert error.message =~ "DATABASE_URL"
      assert error.message =~ "bin/vr start"
    end
  end

  describe "dev" do
    defp dev_port(kind) do
      endpoint(:dev) |> Keyword.fetch!(kind) |> Keyword.fetch!(:port)
    end

    test "4000 when PORT is absent (M6)" do
      with_env(%{"PORT" => nil}, fn -> assert dev_port(:http) == 4000 end)
    end

    test "PORT='' resolves to 4000 without an ArgumentError (M6)" do
      # Copying .env.example verbatim yields PORT= with an empty string.
      with_env(%{"PORT" => ""}, fn -> assert dev_port(:http) == 4000 end)
    end

    test "uses the given value when PORT is set (M6)" do
      with_env(%{"PORT" => "4100"}, fn -> assert dev_port(:http) == 4100 end)
    end

    test "4001 when DEV_BIND_ALL=true and HTTPS_PORT is empty (M7)" do
      with_env(%{"DEV_BIND_ALL" => "true", "HTTPS_PORT" => ""}, fn ->
        assert dev_port(:https) == 4001
      end)
    end

    test "DEV_BIND_ALL=true + explicit HTTPS_PORT (M7)" do
      with_env(%{"DEV_BIND_ALL" => "true", "HTTPS_PORT" => "4443"}, fn ->
        assert dev_port(:https) == 4443
      end)
    end

    test "does not enable https when DEV_BIND_ALL is off" do
      with_env(%{"DEV_BIND_ALL" => nil, "HTTPS_PORT" => "4443"}, fn ->
        refute Keyword.has_key?(endpoint(:dev), :https)
      end)
    end
  end

  describe "regression guard — do the rules live in one place" do
    @backend_root Path.expand("../..", __DIR__)
    @repo_root Path.expand("../../..", __DIR__)

    test "'environment variable PORT is missing' no longer appears (M8)" do
      hits =
        Path.wildcard(Path.join(@backend_root, "config/*.exs"))
        |> Enum.filter(&(File.read!(&1) =~ "environment variable PORT is missing"))

      assert hits == []
    end

    test "runtime.exs is the only config file mentioning PORT / HTTPS_PORT (M12)" do
      referencing =
        Path.wildcard(Path.join(@backend_root, "config/*.exs"))
        |> Enum.filter(&(File.read!(&1) =~ ~r/"(PORT|HTTPS_PORT)"/))
        |> Enum.map(&Path.basename/1)

      assert referencing == ["runtime.exs"]
    end

    test "the port-parsing function is defined exactly once in runtime.exs (M12)" do
      source = File.read!(Path.join(@backend_root, "config/runtime.exs"))
      assert length(Regex.scan(~r/port_from_env\s*=\s*fn/, source)) == 1
    end

    # Boot variables runtime.exs reads via a literal env-var name. Pinned as an
    # explicit list — unlike `VR.EnvExampleTest`, which derives the set from the
    # runtime.exs source — so that dropping one of these from .env.example fails
    # here even if the runtime.exs read disappears in the same change.
    @boot_env_vars ~w(DATABASE_URL SECRET_KEY_BASE CLOAK_KEY PHX_HOST PORT HTTPS_PORT
                      PHX_SERVER RELEASE_COMMAND ECTO_IPV6 POOL_SIZE DNS_CLUSTER_QUERY
                      DEV_BIND_ALL)

    test "every boot env var runtime.exs reads is listed in .env.example (M13)" do
      runtime = File.read!(Path.join(@backend_root, "config/runtime.exs"))

      # Keep the pinned list honest: each entry must still be read by name.
      not_read = Enum.reject(@boot_env_vars, &(runtime =~ ~s("#{&1}")))

      assert not_read == [],
             "pinned boot vars no longer read by runtime.exs " <>
               "(update @boot_env_vars): #{Enum.join(not_read, ", ")}"

      listed =
        Path.join(@repo_root, ".env.example")
        |> File.read!()
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/^([A-Z][A-Z0-9_]*)=/, line, capture: :all_but_first) do
            [name] -> [name]
            nil -> []
          end
        end)

      missing = Enum.reject(@boot_env_vars, &(&1 in listed))

      assert missing == [],
             "boot env vars read by runtime.exs but missing from .env.example: " <>
               Enum.join(missing, ", ")
    end

    test "the Dockerfile COPYs every config file runtime.exs needs (M9)" do
      # Rules moved into a separate config file would not ship in the release and would blow up at boot.
      # If runtime.exs starts reading other files, this test warns first.
      refute File.read!(Path.join(@backend_root, "config/runtime.exs")) =~
               ~r/Code\.(eval|require)_file/

      assert File.read!(Path.join(@repo_root, "Dockerfile")) =~ "config/runtime.exs config/"
    end
  end
end
