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

  defp with_env(overrides, fun) do
    vars = Map.keys(@prod_required) ++ @port_vars ++ Map.keys(overrides)
    original = Map.new(vars, &{&1, System.get_env(&1)})

    try do
      Enum.each(@port_vars, &System.delete_env/1)
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

    test "the Dockerfile COPYs every config file runtime.exs needs (M9)" do
      # Rules moved into a separate config file would not ship in the release and would blow up at boot.
      # If runtime.exs starts reading other files, this test warns first.
      refute File.read!(Path.join(@backend_root, "config/runtime.exs")) =~
               ~r/Code\.(eval|require)_file/

      assert File.read!(Path.join(@repo_root, "Dockerfile")) =~ "config/runtime.exs config/"
    end
  end
end
