defmodule VR.DBPreflightTest do
  use VR.DataCase, async: true

  alias VR.DBPreflight

  # ── Stub repos ─────────────────────────────────────────────
  #
  # `VR.DBPreflight` only calls `query/2`, `transaction/1`, `rollback/1`, and
  # `config/0` on the repo it is given, so a plain module can stand in for a
  # repo whose failure modes (connection refused, missing privilege, …) we
  # cannot reproduce against the real test database.

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

  defmodule RaisingRepo do
    def config, do: [hostname: "db.internal", database: "vr_prod"]
    def query(_sql, _params), do: raise(RuntimeError, "repo VR.Repo is not started")
  end

  defmodule NoPrivilegeRepo do
    # Extensions not installed, listed as available, but CREATE fails: the
    # probe must classify this as "a DBA has to create them".
    def config, do: [hostname: "db.internal", database: "vr_prod", username: "vr_app"]

    def query("SELECT 1 FROM pg_extension" <> _, [_ext]), do: {:ok, %{num_rows: 0}}
    def query("SELECT 1 FROM pg_available_extensions" <> _, [_ext]), do: {:ok, %{num_rows: 1}}

    def query("CREATE EXTENSION IF NOT EXISTS" <> _, []) do
      {:error,
       %Postgrex.Error{
         postgres: %{
           code: :insufficient_privilege,
           message: "permission denied to create extension \"citext\""
         }
       }}
    end

    def transaction(fun) do
      {:ok, fun.()}
    catch
      {:vr_test_rollback, value} -> {:error, value}
    end

    def rollback(value), do: throw({:vr_test_rollback, value})
  end

  defmodule UnavailableExtensionsRepo do
    # Server without the contrib package: nothing installed, nothing available.
    def config, do: [hostname: "db.internal", database: "vr_prod"]

    def query("SELECT 1 FROM pg_extension" <> _, [_ext]), do: {:ok, %{num_rows: 0}}
    def query("SELECT 1 FROM pg_available_extensions" <> _, [_ext]), do: {:ok, %{num_rows: 0}}
  end

  defmodule CreatableRepo do
    # Extensions available and the role may create them; the probe must roll
    # back — a committed CREATE EXTENSION would be a side effect of a check.
    def config, do: [hostname: "db.internal", database: "vr_prod"]

    def query("SELECT 1 FROM pg_extension" <> _, [_ext]), do: {:ok, %{num_rows: 0}}
    def query("SELECT 1 FROM pg_available_extensions" <> _, [_ext]), do: {:ok, %{num_rows: 1}}

    def query("CREATE EXTENSION IF NOT EXISTS" <> _, []) do
      send(self(), :extension_created)
      {:ok, %{num_rows: 0}}
    end

    def transaction(fun) do
      {:ok, fun.()}
    catch
      {:vr_test_rollback, value} ->
        send(self(), :probe_rolled_back)
        {:error, value}
    end

    def rollback(value), do: throw({:vr_test_rollback, value})
  end

  # ── Connection ─────────────────────────────────────────────

  describe "check_connection/1" do
    test "succeeds against the real test database" do
      assert :ok = DBPreflight.check_connection(VR.Repo)
    end

    test "reports host, port, and database when the server is unreachable" do
      assert {:error, message} = DBPreflight.check_connection(DownRepo, probe: false)

      assert message =~ "db.internal:6543"
      assert message =~ "vr_prod"
      assert message =~ "running"
      assert message =~ "DATABASE_URL"
      # A clear cause, not a raw inspect of the exception struct.
      refute message =~ "%DBConnection.ConnectionError"
    end

    test "survives a repo that raises instead of returning an error tuple" do
      assert {:error, message} = DBPreflight.check_connection(RaisingRepo)
      assert message =~ "db.internal"
      refute message =~ "%RuntimeError"
    end

    test "pool-level failure is probed down to the real cause (missing database)" do
      # The pool only says "connection not available"; the probe opens a direct
      # connection to the real server and recovers invalid_catalog_name.
      defmodule MissingDbRepo do
        def config do
          VR.Repo.config()
          |> Keyword.put(:database, "vr_preflight_no_such_db")
          |> Keyword.drop([:pool])
        end

        def query(_sql, _params),
          do: {:error, %DBConnection.ConnectionError{message: "connection not available"}}
      end

      assert {:error, message} = DBPreflight.check_connection(MissingDbRepo)
      assert message =~ ~s(database "vr_preflight_no_such_db" does not exist)
      assert message =~ "mix ecto.create"
    end
  end

  describe "connection_failure_message/2" do
    @config [hostname: "db.internal", port: 6543, database: "vr_prod", username: "vr_app"]

    test "connection refused hints that the server may not be running" do
      error = %DBConnection.ConnectionError{message: "tcp connect: :econnrefused"}
      message = DBPreflight.connection_failure_message(error, @config)

      assert message =~ "db.internal:6543"
      assert message =~ ~s(database "vr_prod")
      assert message =~ "running"
    end

    test "invalid password points at the credentials, not the server" do
      error = %Postgrex.Error{
        postgres: %{code: :invalid_password, message: "password authentication failed"}
      }

      message = DBPreflight.connection_failure_message(error, @config)

      assert message =~ ~s(user "vr_app")
      assert message =~ "password"
      assert message =~ "DATABASE_URL"
    end

    test "missing database recommends creating it" do
      error = %Postgrex.Error{
        postgres: %{code: :invalid_catalog_name, message: ~s(database "vr_prod" does not exist)}
      }

      message = DBPreflight.connection_failure_message(error, @config)

      assert message =~ ~s(database "vr_prod" does not exist)
      assert message =~ "mix ecto.create"
    end

    test "reads host and database from a url-only config, without leaking the password" do
      error = %DBConnection.ConnectionError{message: "tcp connect: :econnrefused"}

      message =
        DBPreflight.connection_failure_message(
          error,
          url: "ecto://vr_app:s3cret@db.example.com:6543/vr_prod"
        )

      assert message =~ "db.example.com:6543"
      assert message =~ ~s(database "vr_prod")
      refute message =~ "s3cret"
    end
  end

  # ── Extensions ─────────────────────────────────────────────

  describe "check_extensions/1" do
    test "reports citext and pg_trgm as installed on the migrated test database" do
      assert [{"citext", :installed}, {"pg_trgm", :installed}] =
               DBPreflight.check_extensions(VR.Repo)
    end

    test "role without privilege → states the DBA prerequisite explicitly" do
      results = DBPreflight.check_extensions(NoPrivilegeRepo)

      for ext <- ~w(citext pg_trgm) do
        assert {:not_creatable, message} = :proplists.get_value(ext, results)
        assert message =~ "database administrator"
        assert message =~ ~s(CREATE EXTENSION IF NOT EXISTS "#{ext}")
        assert message =~ "before migration"
      end
    end

    test "extension missing from the server → says the package must be installed and a DBA must create it" do
      results = DBPreflight.check_extensions(UnavailableExtensionsRepo)

      for ext <- ~w(citext pg_trgm) do
        assert {:unavailable, message} = :proplists.get_value(ext, results)
        assert message =~ "pg_available_extensions"
        assert message =~ "database administrator"
        assert message =~ ~s(CREATE EXTENSION IF NOT EXISTS "#{ext}")
      end
    end

    test "creatable extension → probe succeeds but is rolled back" do
      results = DBPreflight.check_extensions(CreatableRepo)

      assert [{"citext", :creatable}, {"pg_trgm", :creatable}] = results
      # One CREATE per extension, each inside a rolled-back transaction.
      assert_received :extension_created
      assert_received :probe_rolled_back
      assert_received :extension_created
      assert_received :probe_rolled_back
      refute_received :extension_created
    end

    test "connection loss mid-check degrades to an error, not a crash" do
      assert [{"citext", {:error, message}} | _] = DBPreflight.check_extensions(DownRepo)
      assert message =~ "db.internal"
      refute message =~ "%DBConnection.ConnectionError"
    end
  end
end
