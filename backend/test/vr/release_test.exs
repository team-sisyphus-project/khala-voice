defmodule VR.ReleaseTest do
  @moduledoc """
  The release migration entry point — `bin/vr eval 'VR.Release.migrate()'`.

  These tests cover what that entry point must do *before* it migrates:
  state its own configuration requirement, and refuse to start on a database
  that cannot be reached or cannot hold the required extensions — while
  nothing has been changed yet.

  Stub repos stand in for failure modes we cannot reproduce against the real
  test database, in the same shape `VR.DBPreflightTest` uses: only `config/0`,
  `query/2`, `transaction/1` and `rollback/1` are ever called.
  """
  use VR.DataCase, async: true

  alias VR.Release

  @entry_point "bin/vr eval 'VR.Release.migrate()'"

  # ── Stub repos ─────────────────────────────────────────────

  defmodule UnconfiguredRepo do
    # A repo config with no url, hostname or socket: nowhere to connect to.
    def config, do: [pool_size: 2, log: false]
  end

  defmodule BlankUrlRepo do
    # `DATABASE_URL=` (present but empty) parses to a blank url — "not
    # decided", not "decided as the empty string".
    def config, do: [url: "   "]
  end

  defmodule SocketRepo do
    # Unix-socket connections carry no hostname. Still configured.
    def config, do: [socket_dir: "/var/run/postgresql", database: "vr_prod"]
  end

  defmodule NoConfigRepo do
    # `Ecto.Repo.config/0` raises when the app carries no config for the repo.
    def config, do: raise(ArgumentError, "configuration for VR.Repo not specified")
  end

  defmodule DownRepo do
    def config,
      do: [hostname: "db.internal", port: 6543, database: "vr_prod", username: "vr_app"]

    def query(_sql, _params),
      do:
        {:error,
         %DBConnection.ConnectionError{
           message: "tcp connect (db.internal:6543): connection refused - :econnrefused"
         }}
  end

  defmodule ExtensionRepo do
    @moduledoc false
    # Connects fine; extension classification is driven by the process
    # dictionary so one stub can play every case.
    def config, do: [hostname: "db.internal", database: "vr_prod", username: "vr_app"]

    def query("SELECT 1", []), do: {:ok, %{num_rows: 1}}
    def query("SELECT 1 FROM pg_extension" <> _, [_ext]), do: {:ok, %{num_rows: 0}}

    def query("SELECT 1 FROM pg_available_extensions" <> _, [_ext]) do
      case Process.get(:extension_mode) do
        :unavailable -> {:ok, %{num_rows: 0}}
        :catalog_error -> {:error, %Postgrex.Error{postgres: %{message: "catalog unreadable"}}}
        _ -> {:ok, %{num_rows: 1}}
      end
    end

    def query("CREATE EXTENSION IF NOT EXISTS" <> _, []) do
      case Process.get(:extension_mode) do
        :creatable ->
          {:ok, %{num_rows: 0}}

        _ ->
          {:error,
           %Postgrex.Error{
             postgres: %{
               code: :insufficient_privilege,
               message: "permission denied to create extension"
             }
           }}
      end
    end

    def transaction(fun) do
      {:ok, fun.()}
    catch
      {:vr_test_rollback, value} -> {:error, value}
    end

    def rollback(value), do: throw({:vr_test_rollback, value})
  end

  defp with_extension_mode(mode, fun) do
    Process.put(:extension_mode, mode)
    fun.()
  after
    Process.delete(:extension_mode)
  end

  # ── Migration-only configuration ───────────────────────────

  describe "ensure_configured!/1" do
    test "passes for the real, configured test repo" do
      assert :ok = Release.ensure_configured!(VR.Repo)
    end

    test "passes for a socket-only config, which has no hostname" do
      assert :ok = Release.ensure_configured!(SocketRepo)
    end

    test "names DATABASE_URL and this entry point when there is nowhere to connect" do
      message = assert_raise(RuntimeError, fn -> Release.ensure_configured!(UnconfiguredRepo) end)

      assert message.message =~ "DATABASE_URL"
      assert message.message =~ @entry_point
      assert message.message =~ "ecto://"
    end

    test "an empty DATABASE_URL is treated as missing, not as a value" do
      assert_raise RuntimeError, ~r/DATABASE_URL/, fn ->
        Release.ensure_configured!(BlankUrlRepo)
      end
    end

    test "a repo whose config/0 raises still produces the actionable message" do
      assert_raise RuntimeError, ~r/DATABASE_URL/, fn ->
        Release.ensure_configured!(NoConfigRepo)
      end
    end

    test "says the app-only secrets are not required here" do
      message = assert_raise(RuntimeError, fn -> Release.ensure_configured!(UnconfiguredRepo) end)

      # The whole point of the split: an operator hitting this must not go
      # hunting for SECRET_KEY_BASE / CLOAK_KEY.
      assert message.message =~ "SECRET_KEY_BASE"
      assert message.message =~ "CLOAK_KEY"
      assert message.message =~ "not"
    end
  end

  # ── Preflight ──────────────────────────────────────────────

  describe "preflight!/2" do
    test "passes against the migrated test database" do
      assert :ok = Release.preflight!(VR.Repo)
    end

    test "an unreachable database names the host and stops before migrating" do
      message =
        assert_raise(RuntimeError, fn -> Release.preflight!(DownRepo, probe: false) end)

      assert message.message =~ "db.internal:6543"
      assert message.message =~ "Nothing has been migrated"
      assert message.message =~ @entry_point
      refute message.message =~ "%DBConnection.ConnectionError"
    end

    test "a role that cannot create the extensions gets the administrator's SQL" do
      with_extension_mode(:not_creatable, fn ->
        message = assert_raise(RuntimeError, fn -> Release.preflight!(ExtensionRepo) end)

        for ext <- ~w(citext pg_trgm) do
          assert message.message =~ ~s(the PostgreSQL extension "#{ext}")
          assert message.message =~ ~s(CREATE EXTENSION IF NOT EXISTS "#{ext}")
        end

        assert message.message =~ "database administrator"
        assert message.message =~ "Nothing has been migrated"
      end)
    end

    # Found by running the real thing: the preflight message an operator hits
    # on a managed database came out as a single 363-character line. Every
    # required part was in it — the extension, the privilege, the DBA's SQL —
    # laid out so that none of them could be read in a terminal.
    test "the problem block wraps to a readable width" do
      # :catalog_error is absent on purpose — it warns and lets the migration
      # through, so it never reaches not_ready_message/1.
      messages =
        for mode <- [:not_creatable, :unavailable] do
          with_extension_mode(mode, fn ->
            {mode, assert_raise(RuntimeError, fn -> Release.preflight!(ExtensionRepo) end)}
          end)
        end

      unreachable =
        {:unreachable,
         assert_raise(RuntimeError, fn -> Release.preflight!(DownRepo, probe: false) end)}

      # Every path into not_ready_message/1, not just the one that was found long.
      for {mode, message} <- [unreachable | messages],
          line <- String.split(message.message, "\n") do
        assert String.length(line) <= 80,
               "#{mode}: #{String.length(line)} chars, over the 80-column budget:\n#{line}"
      end
    end

    # The SQL is there to be copied and pasted. A line break dropped into the
    # middle of it turns one action into two, and the second one is a typo.
    test "the administrator's SQL survives wrapping on one line" do
      with_extension_mode(:not_creatable, fn ->
        message = assert_raise(RuntimeError, fn -> Release.preflight!(ExtensionRepo) end)

        lines = String.split(message.message, "\n")

        for ext <- ~w(citext pg_trgm) do
          sql = ~s(CREATE EXTENSION IF NOT EXISTS "#{ext}")

          assert Enum.any?(lines, &String.contains?(&1, sql)),
                 "#{sql} was split across lines:\n#{message.message}"
        end
      end)
    end

    test "an extension the server does not ship names the package to install" do
      with_extension_mode(:unavailable, fn ->
        message = assert_raise(RuntimeError, fn -> Release.preflight!(ExtensionRepo) end)

        assert message.message =~ "pg_available_extensions"
        assert message.message =~ "contrib"
      end)
    end

    test "a creatable extension is not an obstacle — the migration creates it" do
      with_extension_mode(:creatable, fn ->
        assert :ok = Release.preflight!(ExtensionRepo)
      end)
    end

    test "a check that itself fails warns but does not block the migration" do
      with_extension_mode(:catalog_error, fn ->
        stderr =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            assert :ok = Release.preflight!(ExtensionRepo)
          end)

        assert stderr =~ "could not check"
        assert stderr =~ "citext"
      end)
    end
  end
end
