defmodule VR.MigrationExtensionGuardTest do
  @moduledoc """
  The extension guards in the two green-field migrations.

  These are the only two migrations that need a PostgreSQL extension
  (`citext`, `pg_trgm`), and they carry their own copies of the guard — a
  migration must stay self-contained. Both copies are exercised here so the
  duplicates cannot drift apart.

  The guards take the repo as an argument and only ever call `query/1,2` and
  `query!/2`, so they can be driven against a plain Postgrex connection with no
  migration runner in play. That is what makes the interesting case testable:
  a *second* connection, as a role that holds no CREATE privilege and owns
  neither extension — the preview/platform situation this hardening exists for.
  """

  use ExUnit.Case, async: false

  # Both migration copies of the guard. Loaded from disk: migration files are
  # not on the compile path.
  @migrations_dir Path.expand("../../priv/repo/migrations", __DIR__)

  @modules [
    {VR.Repo.Migrations.CreateAccounts, "20260819073219_create_accounts.exs", "citext"},
    {VR.Repo.Migrations.CreateMeetings, "20260819082228_create_meetings.exs", "pg_trgm"}
  ]

  for {module, file, _ext} <- @modules do
    unless Code.ensure_loaded?(module) do
      Code.require_file(Path.join(@migrations_dir, file))
    end
  end

  @guards Enum.map(@modules, fn {module, _file, _ext} -> module end)
  @required_extensions Enum.map(@modules, fn {_module, _file, ext} -> ext end)

  # A name no server will ever offer, for the "not available here" branch.
  @absent_extension "vr_no_such_extension"

  # Scratch extension for the ownership-positive drop case: contrib, no
  # dependants, safe to create and drop inside a test.
  @scratch_candidates ~w(btree_gin btree_gist unaccent fuzzystrmatch)

  @limited_role "vr_ext_guard_limited"

  # Schema deliberately kept off the search_path, for the "installed but
  # unreachable" branch.
  @hidden_schema "vr_ext_guard_hidden"

  defmodule AdminConn do
    @moduledoc false
    # Minimal repo stand-in over a Postgrex connection: the guards call nothing
    # else. The pid is held module-side so the *module* can be handed to the
    # guard, which dispatches on a module the way Ecto does.
    def bind(pid), do: :persistent_term.put({__MODULE__, :pid}, pid)
    def pid, do: :persistent_term.get({__MODULE__, :pid}, nil)
    def query(sql, params \\ [], opts \\ []), do: Postgrex.query(pid(), sql, params, opts)
    def query!(sql, params \\ [], opts \\ []), do: Postgrex.query!(pid(), sql, params, opts)
  end

  defmodule LimitedConn do
    @moduledoc false
    def bind(pid), do: :persistent_term.put({__MODULE__, :pid}, pid)
    def pid, do: :persistent_term.get({__MODULE__, :pid}, nil)
    def query(sql, params \\ [], opts \\ []), do: Postgrex.query(pid(), sql, params, opts)
    def query!(sql, params \\ [], opts \\ []), do: Postgrex.query!(pid(), sql, params, opts)
  end

  setup do
    admin = connect!(conn_opts())
    AdminConn.bind(admin)

    limited = start_limited_role(admin)
    if limited, do: LimitedConn.bind(limited)

    # The connections above are linked to the test process and die with it, so
    # the cleanup opens its own.
    on_exit(fn ->
      case Postgrex.start_link(conn_opts()) do
        {:ok, pid} ->
          remove_limited_role(pid)
          GenServer.stop(pid)

        _ ->
          :ok
      end
    end)

    %{limited: limited}
  end

  describe "ensure_extension!/2 — extension already present" do
    test "succeeds for every required extension, in both migration copies" do
      for guard <- @guards, ext <- @required_extensions do
        assert :ok = guard.ensure_extension!(AdminConn, ext),
               "#{inspect(guard)} rejected the already-installed extension #{ext}"
      end
    end
  end

  describe "ensure_extension!/2 — extension missing" do
    test "names the administrator action when the server does not offer it" do
      for guard <- @guards do
        error =
          assert_raise RuntimeError, fn ->
            guard.ensure_extension!(AdminConn, @absent_extension)
          end

        assert error.message =~ ~s(extension "#{@absent_extension}" is not available)
        assert error.message =~ "A database administrator must install"
        assert error.message =~ ~s(CREATE EXTENSION IF NOT EXISTS "#{@absent_extension}";)
      end
    end
  end

  describe "ensure_extension!/2 — extension present but out of reach" do
    test "names the administrator action when it sits in an unsearched schema" do
      case scratch_extension() do
        nil ->
          skipped()

        ext ->
          AdminConn.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{@hidden_schema}"), [])

          try do
            AdminConn.query!(
              ~s(CREATE EXTENSION IF NOT EXISTS "#{ext}" SCHEMA "#{@hidden_schema}"),
              []
            )

            for guard <- @guards do
              error =
                assert_raise RuntimeError, fn -> guard.ensure_extension!(AdminConn, ext) end

              assert error.message =~ ~s(extension "#{ext}" is installed, but not where)
              assert error.message =~ ~s(in schema     "#{@hidden_schema}")
              assert error.message =~ ~s(ALTER EXTENSION "#{ext}" SET SCHEMA public;)
              assert error.message =~ "SET search_path ="
            end
          after
            AdminConn.query!(~s(DROP SCHEMA IF EXISTS "#{@hidden_schema}" CASCADE), [])
          end
      end
    end
  end

  describe "ensure_extension!/2 — role without CREATE privilege" do
    @tag :limited_role
    test "succeeds when the extension is pre-provisioned and owned by somebody else",
         %{limited: limited} do
      if limited do
        for ext <- @required_extensions do
          # The premise: this role did not create the extension and does not
          # own it. Without that, the assertion below proves nothing.
          refute VR.Repo.Migrations.CreateAccounts.extension_owned?(LimitedConn, ext),
                 "#{@limited_role} unexpectedly owns #{ext}; the test premise is broken"
        end

        for guard <- @guards, ext <- @required_extensions do
          assert :ok = guard.ensure_extension!(LimitedConn, ext)
        end
      else
        skipped()
      end
    end

    @tag :limited_role
    test "names the administrator action when it cannot create a missing extension",
         %{limited: limited} do
      creatable = limited && uninstalled_extension()

      if creatable do
        error =
          assert_raise RuntimeError, fn ->
            VR.Repo.Migrations.CreateAccounts.ensure_extension!(LimitedConn, creatable)
          end

        assert error.message =~ ~s(cannot create the PostgreSQL extension "#{creatable}")
        assert error.message =~ "insufficient privilege"
        assert error.message =~ "A database administrator must create it"
        assert error.message =~ ~s(CREATE EXTENSION IF NOT EXISTS "#{creatable}";)

        # The failed attempt must not have left the extension behind.
        refute installed?(creatable)
      else
        skipped()
      end
    end
  end

  describe "drop_extension_if_owned!/2" do
    test "drops an extension this role owns" do
      case scratch_extension() do
        nil ->
          skipped()

        ext ->
          AdminConn.query!(~s(CREATE EXTENSION IF NOT EXISTS "#{ext}"), [])
          assert installed?(ext)
          assert VR.Repo.Migrations.CreateAccounts.extension_owned?(AdminConn, ext)

          try do
            assert :ok =
                     VR.Repo.Migrations.CreateAccounts.drop_extension_if_owned!(AdminConn, ext)

            refute installed?(ext)
          after
            AdminConn.query!(~s(DROP EXTENSION IF EXISTS "#{ext}"), [])
          end
      end
    end

    @tag :limited_role
    test "leaves an extension this role does not own alone", %{limited: limited} do
      if limited do
        for guard <- @guards, ext <- @required_extensions do
          assert :skipped = guard.drop_extension_if_owned!(LimitedConn, ext)
          assert installed?(ext), "rolling back removed the pre-provisioned #{ext}"
        end
      else
        skipped()
      end
    end

    test "is a no-op when the extension is not installed at all" do
      for guard <- @guards do
        assert :skipped = guard.drop_extension_if_owned!(AdminConn, @absent_extension)
      end
    end
  end

  # ── Helpers ───────────────────────────────────────────────

  defp conn_opts(overrides \\ []) do
    VR.Repo.config()
    |> Keyword.take([:hostname, :port, :socket_dir, :username, :password, :database])
    |> Keyword.merge(overrides)
  end

  defp connect!(opts) do
    {:ok, pid} = Postgrex.start_link(opts)
    %{rows: [[1]]} = Postgrex.query!(pid, "SELECT 1", [])
    pid
  end

  # Creates a login role with no CREATE privilege anywhere, and connects as it.
  # Returns nil when the test database's own account cannot create roles — the
  # suite still runs everywhere, it just cannot prove the limited-role cases.
  defp start_limited_role(admin) do
    password = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    database = Keyword.fetch!(conn_opts(), :database)

    remove_limited_role(admin)

    Postgrex.query!(
      admin,
      ~s(CREATE ROLE "#{@limited_role}" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE ) <>
        ~s(PASSWORD '#{password}'),
      []
    )

    Postgrex.query!(admin, ~s(GRANT CONNECT ON DATABASE "#{database}" TO "#{@limited_role}"), [])
    Postgrex.query!(admin, ~s(GRANT USAGE ON SCHEMA public TO "#{@limited_role}"), [])

    connect!(conn_opts(username: @limited_role, password: password))
  rescue
    _ -> nil
  end

  # A role holding granted privileges cannot be dropped, so revoke first. Every
  # statement is best-effort: the usual case is that the role is not there.
  defp remove_limited_role(admin) do
    database = Keyword.fetch!(conn_opts(), :database)

    Postgrex.query(admin, ~s(REVOKE ALL ON SCHEMA public FROM "#{@limited_role}"), [])
    Postgrex.query(admin, ~s(REVOKE ALL ON DATABASE "#{database}" FROM "#{@limited_role}"), [])
    Postgrex.query(admin, ~s(DROP ROLE IF EXISTS "#{@limited_role}"), [])
    :ok
  end

  defp installed?(ext) do
    %{rows: rows} = AdminConn.query!("SELECT 1 FROM pg_extension WHERE extname = $1", [ext])
    rows != []
  end

  defp scratch_extension do
    Enum.find(@scratch_candidates, fn ext -> available?(ext) and not installed?(ext) end)
  end

  defp uninstalled_extension do
    scratch_extension() ||
      (
        %{rows: rows} =
          AdminConn.query!(
            """
            SELECT a.name
              FROM pg_available_extensions a
             WHERE a.name NOT IN (SELECT extname FROM pg_extension)
             ORDER BY a.name
             LIMIT 1
            """,
            []
          )

        case rows do
          [[name] | _] -> name
          _ -> nil
        end
      )
  end

  defp available?(ext) do
    %{rows: rows} =
      AdminConn.query!("SELECT 1 FROM pg_available_extensions WHERE name = $1", [ext])

    rows != []
  end

  # Loud on purpose: an environment that cannot run one of these cases should
  # say so rather than report a silent pass.
  defp skipped do
    IO.warn(
      "skipped: this case needs a test database account that can create roles " <>
        "and a spare contrib extension",
      []
    )
  end
end
