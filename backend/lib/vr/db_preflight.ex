defmodule VR.DBPreflight do
  @moduledoc """
  Database preflight checks: can we connect, and are the required PostgreSQL
  extensions (`citext`, `pg_trgm`) either installed or creatable by the
  current role?

  Lives in the application core (no Mix dependency) so both `mix vr.doctor`
  and any runtime health surface can use it. All functions return plain data —
  the caller decides how to print it.

  ## Why the probe

  Migrations run `CREATE EXTENSION IF NOT EXISTS`, which requires either
  superuser or an extension-creation grant. On managed databases the app role
  often lacks it, and the failure only surfaces mid-migration with a cryptic
  `insufficient_privilege`. The probe here runs the same statement inside a
  transaction that is always rolled back, so the answer — "a DBA must create
  this first" — arrives *before* migration, with no side effect either way.
  """

  @extensions ~w(citext pg_trgm)

  @typedoc """
  Status of one required extension.

    * `:installed` — present in `pg_extension`, nothing to do.
    * `:creatable` — missing, but the current role can create it; migrations
      will do so.
    * `{:not_creatable, message}` — missing and the role lacks the privilege;
      a database administrator must create it before migration.
    * `{:unavailable, message}` — missing from `pg_available_extensions`;
      the server's contrib package is not installed.
    * `{:error, message}` — the check itself failed (e.g. connection lost).
  """
  @type extension_status ::
          :installed
          | :creatable
          | {:not_creatable, String.t()}
          | {:unavailable, String.t()}
          | {:error, String.t()}

  @doc "The PostgreSQL extensions the schema depends on."
  @spec extensions() :: [String.t()]
  def extensions, do: @extensions

  @doc """
  Checks that the database answers a trivial query.

  Returns `:ok`, or `{:error, message}` where the message names the host,
  port, and database and hints at the likely cause — never a raw `inspect`
  of the exception struct.

  Options:

    * `:probe` (default `true`) — when the pool reports a generic
      `DBConnection.ConnectionError` (which hides *why* the pool cannot
      connect: wrong password and missing database look identical), open one
      direct short-lived connection to recover the underlying Postgres error.
  """
  @spec check_connection(module(), keyword()) :: :ok | {:error, String.t()}
  def check_connection(repo \\ VR.Repo, opts \\ []) do
    case repo.query("SELECT 1", []) do
      {:ok, _} ->
        :ok

      {:error, %DBConnection.ConnectionError{} = error} ->
        config = safe_config(repo)

        error =
          if Keyword.get(opts, :probe, true) do
            probe_connect(config) || error
          else
            error
          end

        {:error, connection_failure_message(error, config)}

      {:error, error} ->
        {:error, connection_failure_message(error, safe_config(repo))}
    end
  rescue
    error -> {:error, connection_failure_message(error, safe_config(repo))}
  catch
    :exit, reason -> {:error, connection_failure_message({:exit, reason}, safe_config(repo))}
  end

  @doc """
  Checks each required extension: installed → creatable by the current role →
  otherwise who has to act. Returns `[{extension_name, status}]` in
  `extensions()` order.

  The creatability probe runs `CREATE EXTENSION IF NOT EXISTS` inside a
  transaction that is always rolled back, so a successful probe leaves the
  database untouched.
  """
  @spec check_extensions(module()) :: [{String.t(), extension_status()}]
  def check_extensions(repo \\ VR.Repo) do
    Enum.map(@extensions, fn ext -> {ext, extension_check(repo, ext)} end)
  end

  @doc """
  Builds a human-readable cause for a failed connection attempt.

  `config` is the repo's config keyword list; host/port/database/username are
  read from the explicit keys or, failing that, parsed out of `:url`. The
  password is never included.
  """
  @spec connection_failure_message(term(), Keyword.t()) :: String.t()
  def connection_failure_message(error, config) do
    info = conn_info(config)

    at =
      ~s(PostgreSQL at #{info.host}:#{info.port} ) <>
        ~s{(database "#{info.database}", user "#{info.username}")}

    case error do
      %DBConnection.ConnectionError{} ->
        "cannot connect to #{at} — is the server running and reachable? " <>
          "Check DATABASE_URL (or the dev config) for the right host and port."

      %Postgrex.Error{postgres: %{code: code}}
      when code in [:invalid_password, :invalid_authorization_specification] ->
        ~s(authentication failed for user "#{info.username}" on #{info.host}:#{info.port} — ) <>
          "check the username/password in DATABASE_URL."

      %Postgrex.Error{postgres: %{code: :invalid_catalog_name}} ->
        ~s(database "#{info.database}" does not exist on #{info.host}:#{info.port} — ) <>
          "run `mix ecto.create`, or ask an administrator to create it."

      other ->
        "cannot connect to #{at} — #{describe_error(other)}"
    end
  end

  # ── Direct connection probe ───────────────────────────────

  # The pool reports connection loss as a generic DBConnection.ConnectionError;
  # the underlying Postgres error (bad password? missing database?) is lost —
  # the pool turns every connect failure into "connection not available"
  # (verified against db_connection 2.10: even `backoff_type: :stop` +
  # `max_restarts: 0` surfaces only `:killed`). So we perform one handshake
  # directly through Postgrex.Protocol — Postgrex's DBConnection callback
  # module — which returns the server's actual error. It is an internal API,
  # so the whole probe degrades to `nil` (generic message) on any surprise.
  # Returns the underlying %Postgrex.Error{} or nil.
  defp probe_connect(config) do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    opts =
      config
      |> Keyword.merge(parse_url_opts(config))
      |> Keyword.drop([:pool, :pool_size, :name, :log, :url, :priv, :telemetry_prefix])
      |> Keyword.put_new(:show_sensitive_data_on_connection_error, false)

    task =
      Task.Supervisor.async_nolink(Ecto.Adapters.SQL.StorageSupervisor, fn ->
        case opts |> Postgrex.Utils.default_opts() |> Postgrex.Protocol.connect() do
          {:ok, state} ->
            Postgrex.Protocol.disconnect(
              %DBConnection.ConnectionError{message: "preflight probe finished"},
              state
            )

            :ok

          {:error, error} ->
            {:error, error}
        end
      end)

    case Task.yield(task, 5_000) || Task.shutdown(task) do
      {:ok, {:error, %Postgrex.Error{} = error}} -> error
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp parse_url_opts(config) do
    case config[:url] do
      url when is_binary(url) and url != "" -> Ecto.Repo.Supervisor.parse_url(url)
      _ -> []
    end
  end

  # ── Extension check internals ─────────────────────────────

  defp extension_check(repo, ext) do
    with {:installed?, {:ok, false}} <- {:installed?, extension_installed?(repo, ext)},
         {:available?, {:ok, true}} <- {:available?, extension_available?(repo, ext)} do
      probe_create(repo, ext)
    else
      {:installed?, {:ok, true}} -> :installed
      {:available?, {:ok, false}} -> {:unavailable, unavailable_message(ext)}
      {_step, {:error, error}} -> {:error, check_failure_message(error, repo)}
    end
  rescue
    error -> {:error, check_failure_message(error, repo)}
  catch
    :exit, reason -> {:error, check_failure_message({:exit, reason}, repo)}
  end

  defp extension_installed?(repo, ext) do
    case repo.query("SELECT 1 FROM pg_extension WHERE extname = $1", [ext]) do
      {:ok, %{num_rows: n}} -> {:ok, n > 0}
      {:error, error} -> {:error, error}
    end
  end

  defp extension_available?(repo, ext) do
    case repo.query("SELECT 1 FROM pg_available_extensions WHERE name = $1", [ext]) do
      {:ok, %{num_rows: n}} -> {:ok, n > 0}
      {:error, error} -> {:error, error}
    end
  end

  # Runs `CREATE EXTENSION IF NOT EXISTS` and rolls back regardless of the
  # outcome: a check must not mutate the database. The rollback value carries
  # the classification out of the transaction.
  defp probe_create(repo, ext) do
    result =
      repo.transaction(fn ->
        case repo.query(~s(CREATE EXTENSION IF NOT EXISTS "#{ext}"), []) do
          {:ok, _} -> repo.rollback(:creatable)
          {:error, error} -> repo.rollback({:create_failed, error})
        end
      end)

    case result do
      {:error, :creatable} -> :creatable
      {:error, {:create_failed, error}} -> {:not_creatable, not_creatable_message(ext, error)}
      {:error, error} -> {:error, check_failure_message(error, repo)}
      {:ok, other} -> {:error, "unexpected probe result: #{describe_error(other)}"}
    end
  end

  defp not_creatable_message(ext, error) do
    "not installed, and the current database role cannot create it " <>
      "(#{describe_error(error)}) — a database administrator must run " <>
      ~s(`CREATE EXTENSION IF NOT EXISTS "#{ext}"` before migration.)
  end

  defp unavailable_message(ext) do
    "not available on this PostgreSQL server (missing from pg_available_extensions) — " <>
      "install the postgresql-contrib package, then a database administrator must run " <>
      ~s(`CREATE EXTENSION IF NOT EXISTS "#{ext}"` before migration.)
  end

  defp check_failure_message(error, repo) do
    info = conn_info(safe_config(repo))
    "check failed against #{info.host}:#{info.port} — #{describe_error(error)}"
  end

  # ── Error / config plumbing ───────────────────────────────

  defp describe_error(%{__exception__: true} = error),
    do: error |> Exception.message() |> squeeze()

  defp describe_error({:exit, reason}), do: "the database process exited (#{brief(reason)})"
  defp describe_error(other), do: brief(other)

  # Last-resort rendering for terms that carry no message of their own.
  # Kept short so an exotic failure never dumps a struct across the screen.
  defp brief(term), do: term |> inspect() |> String.slice(0, 120) |> squeeze()

  # Doctor-style reports print one line per check; Postgres errors arrive with
  # embedded newlines and hint indentation.
  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp safe_config(repo) do
    repo.config()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp conn_info(config) do
    uri =
      case config[:url] do
        url when is_binary(url) -> URI.parse(url)
        _ -> %URI{}
      end

    %{
      host: config[:hostname] || uri.host || "localhost",
      port: config[:port] || uri.port || 5432,
      database: config[:database] || uri_database(uri) || "?",
      username: config[:username] || uri_username(uri) || "?"
    }
  end

  defp uri_database(%URI{path: "/" <> db}) when db != "", do: db
  defp uri_database(_), do: nil

  # Only the username — the password half of userinfo must never surface.
  defp uri_username(%URI{userinfo: info}) when is_binary(info),
    do: info |> String.split(":", parts: 2) |> hd()

  defp uri_username(_), do: nil
end
