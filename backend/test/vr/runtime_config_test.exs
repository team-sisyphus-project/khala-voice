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

  import ExUnit.CaptureIO

  @runtime_exs Path.expand("../../config/runtime.exs", __DIR__)
  @backend_root_for_url Path.expand("../..", __DIR__)

  # Values the production branch requires. Always filled, regardless of port.
  @prod_required %{
    "DATABASE_URL" => "ecto://user:pass@localhost/vr_test",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "CLOAK_KEY" => Base.encode64(String.duplicate("k", 32))
  }

  # Variables affecting the port are explicitly cleared at the start of each case.
  @port_vars ~w(PORT HTTPS_PORT DEV_BIND_ALL PHX_SERVER)

  # Variables describing the *public* URL (what the app claims to be), as
  # opposed to @port_vars (what it listens on). Cleared the same way, so every
  # case that does not name them reads as the default https deployment.
  @url_vars ~w(PHX_SCHEME PHX_URL_PORT PHX_HOST)

  # RELEASE_COMMAND selects the entry point (see "migration-only entry point"
  # below). Cleared like the port vars so every other case reads as what it has
  # always been: the app-boot entry point.
  @entry_vars ~w(RELEASE_COMMAND)

  defp with_env(overrides, fun) do
    vars =
      Map.keys(@prod_required) ++ @port_vars ++ @url_vars ++ @entry_vars ++ Map.keys(overrides)

    original = Map.new(vars, &{&1, System.get_env(&1)})

    try do
      Enum.each(@port_vars ++ @url_vars ++ @entry_vars, &System.delete_env/1)
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

  # ── Public URL ──────────────────────────────────────────────────
  #
  # `http:` is what the app listens on; `url:` is what it claims to be. Phoenix
  # stamps `url:` onto every absolute URL it generates — `VRWeb.Endpoint.url/0`
  # (MCP metadata, the Khala app link), `url(~p"/khala/callback")` (the OAuth
  # redirect_uri) and `url(~p"/invite/…")` (invite links). It was pinned to
  # https/443, so a plain-HTTP preview handed out links to an origin that does
  # not answer.

  defp prod_url(overrides \\ %{}) do
    with_env(overrides, fn -> endpoint(:prod) |> Keyword.fetch!(:url) end)
  end

  describe "prod / public URL scheme" do
    test "defaults to https — an existing deployment that sets nothing is unchanged" do
      assert prod_url()[:scheme] == "https"
      assert prod_url()[:port] == 443
    end

    test "PHX_SCHEME=http switches the generated links to http" do
      url = prod_url(%{"PHX_SCHEME" => "http"})

      assert url[:scheme] == "http"
    end

    test "PHX_SCHEME='' is 'not decided' and takes the https default" do
      assert prod_url(%{"PHX_SCHEME" => ""})[:scheme] == "https"
    end

    test "surrounding whitespace and casing are ignored" do
      assert prod_url(%{"PHX_SCHEME" => " HTTP\n"})[:scheme] == "http"
      assert prod_url(%{"PHX_SCHEME" => "  Https  "})[:scheme] == "https"
    end

    for bad <- ["ftp", "https://", "htp", "http:", "1", "wss"] do
      test "PHX_SCHEME=#{inspect(bad)} halts, naming the variable and the value" do
        error =
          assert_raise RuntimeError, fn -> prod_url(%{"PHX_SCHEME" => unquote(bad)}) end

        assert error.message =~ "PHX_SCHEME"
        assert error.message =~ unquote(bad)
        assert error.message =~ "http"
        assert error.message =~ "https"
      end
    end
  end

  describe "prod / public URL port" do
    test "https implies 443 and http implies 80 — neither needs a second variable" do
      assert prod_url(%{"PHX_SCHEME" => "https"})[:port] == 443
      assert prod_url(%{"PHX_SCHEME" => "http"})[:port] == 80
    end

    test "PHX_URL_PORT overrides the scheme's default" do
      assert prod_url(%{"PHX_SCHEME" => "http", "PHX_URL_PORT" => "4000"})[:port] == 4000
      assert prod_url(%{"PHX_URL_PORT" => "8443"})[:port] == 8443
    end

    test "PHX_URL_PORT='' takes the scheme's default" do
      assert prod_url(%{"PHX_SCHEME" => "http", "PHX_URL_PORT" => ""})[:port] == 80
    end

    test "a malformed PHX_URL_PORT halts, naming the variable" do
      error =
        assert_raise RuntimeError, fn -> prod_url(%{"PHX_URL_PORT" => "8443a"}) end

      assert error.message =~ "PHX_URL_PORT"
      assert error.message =~ "8443a"
    end

    test "the listen port and the public port stay independent" do
      config =
        with_env(%{"PORT" => "4000", "PHX_SCHEME" => "http", "PHX_URL_PORT" => "80"}, fn ->
          endpoint(:prod)
        end)

      # Behind a proxy: listening on 4000, reachable on 80.
      assert Keyword.fetch!(config, :http) |> Keyword.fetch!(:port) == 4000
      assert Keyword.fetch!(config, :url) |> Keyword.fetch!(:port) == 80
    end

    test "PORT alone never moves the public port" do
      assert prod_url(%{"PORT" => "4000"})[:port] == 443
    end
  end

  describe "prod / public URL host" do
    test "defaults to localhost and follows PHX_HOST" do
      assert prod_url()[:host] == "localhost"
      assert prod_url(%{"PHX_HOST" => "preview.example.test"})[:host] == "preview.example.test"
    end

    # `check_origin` is left at its Phoenix default (`true`), which compares the
    # request's Origin **host** against `url[:host]` — not the scheme, not the
    # port (deps/phoenix/lib/phoenix/socket/transport.ex, `origin_allowed?/4`).
    # So a plain-HTTP preview's LiveView socket is accepted on the same terms as
    # an https one, provided PHX_HOST names the host it is actually served from.
    test "no config file pins check_origin for prod — the url host stays the single source" do
      pinning =
        Path.wildcard(Path.join(@backend_root_for_url, "config/*.exs"))
        |> Enum.filter(&(File.read!(&1) =~ ~r/check_origin:/))
        |> Enum.map(&Path.basename/1)

      assert pinning == ["dev.exs"]
    end
  end

  describe "prod / regression guard — the public URL is not hardcoded" do
    test "no config file pins the endpoint's url scheme or port to a literal" do
      offenders =
        Path.wildcard(Path.join(@backend_root_for_url, "config/*.exs"))
        |> Enum.filter(fn file ->
          source = File.read!(file)

          source =~ ~r/scheme:\s*"https"/ or source =~ ~r/url:\s*\[[^\]]*port:\s*\d/
        end)
        |> Enum.map(&Path.basename/1)

      assert offenders == []
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

    # ── Malformed values ──────────────────────────────────────────
    #
    # These three used to halt here as well, on the rationale that "the same
    # file resolves them, so a malformed value must fail the same way at both
    # entry points". That reasoning described the implementation (one file),
    # not the entry point (what it reads). A migration starts no Endpoint and
    # generates no link, so it reads none of PORT / PHX_SCHEME / PHX_URL_PORT
    # — and halting on one reproduced, under a different variable name, the
    # very defect this split was made to remove: a database preparation step
    # dying on a value it never reads, reaching the operator as
    # `migration_failed`. See docs/17-runtime-entry-points.md.
    #
    # The value is still wrong. It is reported as a warning naming the
    # variable, the default this run continues with, and the command that does
    # halt on it.

    defp eval_with_stderr(overrides) do
      parent = self()

      output =
        capture_io(:stderr, fn -> send(parent, {:endpoint, eval_endpoint(overrides)}) end)

      assert_receive {:endpoint, config}
      {config, output}
    end

    test "a malformed PORT warns and continues on the default" do
      {config, warning} = eval_with_stderr(%{"PORT" => "8080a", "SECRET_KEY_BASE" => nil})

      assert Keyword.fetch!(config, :http) |> Keyword.fetch!(:port) == 4000

      assert warning =~ "[VR.Runtime]"
      assert warning =~ "PORT"
      assert warning =~ "8080a"
      # What it continues with, and what will not tolerate it.
      assert warning =~ "continuing with the default, 4000"
      assert warning =~ "bin/vr start"
    end

    test "a malformed PHX_URL_PORT warns and the public port stays the default" do
      {config, warning} =
        eval_with_stderr(%{"PHX_URL_PORT" => "8443a", "SECRET_KEY_BASE" => nil})

      assert Keyword.fetch!(config, :url) |> Keyword.fetch!(:port) == 443

      assert warning =~ "PHX_URL_PORT"
      assert warning =~ "8443a"
    end

    test "the warning keeps the message the app halts with, word for word" do
      {_config, warning} = eval_with_stderr(%{"PORT" => "8080a"})

      halt =
        with_env(%{"PORT" => "8080a"}, fn ->
          assert_raise RuntimeError, fn -> prod_http_port() end
        end)

      # Two operators comparing a deploy log against a boot log must be able to
      # match them. The warning quotes the raise message; it does not paraphrase.
      assert String.contains?(warning, String.trim_trailing(halt.message))
    end

    test "every line the warning writes fits in 80 columns" do
      {_config, warning} = eval_with_stderr(%{"PHX_SCHEME" => "ftp"})

      too_wide = warning |> String.split("\n") |> Enum.filter(&(String.length(&1) > 80))

      assert too_wide == []
    end

    test "a well-formed value is not warned about" do
      {config, warning} = eval_with_stderr(%{"PORT" => "8080", "PHX_SCHEME" => "http"})

      assert Keyword.fetch!(config, :http) |> Keyword.fetch!(:port) == 8080
      assert warning == ""
    end

    test "DATABASE_URL is still fatal here, malformed neighbours or not" do
      capture_io(:stderr, fn ->
        error =
          assert_raise RuntimeError, fn ->
            eval_endpoint(%{"DATABASE_URL" => nil, "PORT" => "8080a"})
          end

        assert error.message =~ "DATABASE_URL"
      end)
    end

    test "the platform-injected PORT is still honored" do
      config = eval_endpoint(%{"PORT" => "8080", "SECRET_KEY_BASE" => nil})

      assert Keyword.fetch!(config, :http) |> Keyword.fetch!(:port) == 8080
    end

    # A well-formed public URL is still resolved here — the deploy step that
    # migrates and the one that starts the app read the same file, and a value
    # that works at one must work at the other.
    test "PHX_SCHEME is resolved here too" do
      config = eval_endpoint(%{"PHX_SCHEME" => "http", "SECRET_KEY_BASE" => nil})

      assert Keyword.fetch!(config, :url) |> Keyword.fetch!(:scheme) == "http"
    end

    test "a malformed PHX_SCHEME warns and continues on https" do
      {config, warning} = eval_with_stderr(%{"PHX_SCHEME" => "ftp", "SECRET_KEY_BASE" => nil})

      assert Keyword.fetch!(config, :url) |> Keyword.fetch!(:scheme) == "https"
      # The scheme decides the public port's default, and the fallback decides
      # it here too — a warned scheme must not leave a half-applied URL.
      assert Keyword.fetch!(config, :url) |> Keyword.fetch!(:port) == 443

      assert warning =~ "PHX_SCHEME"
      assert warning =~ "ftp"
      assert warning =~ "continuing with the default, https"
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

    for {var, bad} <- [{"PORT", "8080a"}, {"PHX_SCHEME", "ftp"}, {"PHX_URL_PORT", "8443a"}] do
      test "#{var}=#{inspect(bad)} still halts the app — only the migration relaxes" do
        error =
          with_env(%{unquote(var) => unquote(bad)}, fn ->
            assert_raise RuntimeError, fn -> endpoint(:prod) end
          end)

        assert error.message =~ unquote(var)
        assert error.message =~ unquote(bad)
        # A halt is not a warning wearing a different hat: it says nothing
        # about carrying on, because it does not carry on.
        refute error.message =~ "continuing with the default"
      end
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
    @boot_env_vars ~w(DATABASE_URL SECRET_KEY_BASE CLOAK_KEY PHX_HOST PHX_SCHEME
                      PHX_URL_PORT PORT HTTPS_PORT PHX_SERVER RELEASE_COMMAND ECTO_IPV6
                      POOL_SIZE DNS_CLUSTER_QUERY DEV_BIND_ALL)

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
