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

    # Boot variables runtime.exs reads via a literal env-var name. Pinned as an
    # explicit list — unlike `VR.EnvExampleTest`, which derives the set from the
    # runtime.exs source — so that dropping one of these from .env.example fails
    # here even if the runtime.exs read disappears in the same change.
    @boot_env_vars ~w(DATABASE_URL SECRET_KEY_BASE CLOAK_KEY PHX_HOST PORT HTTPS_PORT
                      PHX_SERVER ECTO_IPV6 POOL_SIZE DNS_CLUSTER_QUERY DEV_BIND_ALL)

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

  describe "documentation — the boot-parameter spec" do
    # The Story's M8/M9. Numbered independently of the M-markers above, which
    # belong to the earlier runtime Story.
    @config_doc Path.expand("../../../docs/07-config-admin.md", __DIR__)

    defp config_doc, do: File.read!(@config_doc)

    defp documented_default(var) do
      row = ~r/^\|\s*`#{var}`\s*\|\s*`(\d+)`/m

      case Regex.run(row, config_doc(), capture: :all_but_first) do
        [n] -> String.to_integer(n)
        nil -> nil
      end
    end

    test "a normative boot-parameter default table exists, exactly once (Story M8)" do
      headings = Regex.scan(~r/^#+ Boot parameter defaults\s*$/m, config_doc())

      assert length(headings) == 1,
             "docs/07-config-admin.md must carry exactly one normative " <>
               "'Boot parameter defaults' section, found #{length(headings)}"
    end

    # The reason for pinning the table to the code: prose defaults drift silently.
    # If someone changes the default in runtime.exs, this fails until the Spec follows.
    test "the documented PORT default equals the one runtime.exs resolves (Story M8)" do
      with_env(%{"PORT" => nil}, fn ->
        assert documented_default("PORT") == prod_http_port()
      end)
    end

    test "the documented HTTPS_PORT default equals the one runtime.exs resolves (Story M8)" do
      with_env(%{"DEV_BIND_ALL" => "true", "HTTPS_PORT" => nil}, fn ->
        assert documented_default("HTTPS_PORT") ==
                 endpoint(:dev) |> Keyword.fetch!(:https) |> Keyword.fetch!(:port)
      end)
    end

    # grain-3: the satellite docs must not carry a second copy of the numbers.
    # They may mention PORT all they like, as long as they send the reader to the
    # one normative table instead of restating what it says.
    @satellite_docs [
      Path.expand("../../../README.md", __DIR__),
      Path.expand("../../../.env.example", __DIR__),
      Path.expand("../../../docs/00-setup-checklist.md", __DIR__)
    ]

    test "every doc that mentions PORT points at the normative table (Story M8)" do
      for path <- @satellite_docs, body = File.read!(path), body =~ "PORT" do
        assert body =~ "Boot parameter defaults",
               "#{Path.basename(path)} mentions PORT but never points at " <>
                 "docs/07-config-admin.md > Boot parameter defaults"
      end
    end

    test "no satellite doc restates the PORT default as a number (Story M8)" do
      restated = ~r/\bPORT\b\s*(?:=|defaults to|default:|→)\s*`?\d{2,5}/i

      for path <- @satellite_docs do
        offenders =
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.filter(&Regex.match?(restated, &1))

        assert offenders == [],
               "#{Path.basename(path)} restates a port default; the number belongs " <>
                 "only in docs/07-config-admin.md: #{inspect(offenders)}"
      end
    end

    test "rule R6 states the empty-vs-malformed rule (Story M9)" do
      [row] = Regex.run(~r/^\| R6 \|.*$/m, config_doc())

      assert row =~ ~r/malformed/i
      assert row =~ ~r/default/i
      assert row =~ ~r/halt/i
    end

    # R6 is a port-only rule. runtime.exs defaults these four only when the variable
    # is *absent*: an empty `NAME=` reaches String.to_integer/1, becomes an empty host,
    # reads as truthy, or is handed to DNSCluster as "". Since .env.example ships every
    # key as `NAME=`, a table that promised "empty → default" would misdescribe exactly
    # the case a reader hits. This pins the disclaimer so it cannot be dropped.
    test "non-port rows are marked as not applying R6 (Story M9)" do
      for var <- ~w(POOL_SIZE PHX_HOST PHX_SERVER DNS_CLUSTER_QUERY) do
        [row] = Regex.run(~r/^\|\s*`?#{var}`?.*$/m, config_doc())

        assert row =~ "R6 not applied",
               "#{var}'s row must say R6 is not applied to it — runtime.exs " <>
                 "defaults it only when the variable is absent, not when empty"
      end
    end
  end
end
