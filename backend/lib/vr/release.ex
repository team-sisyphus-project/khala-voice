defmodule VR.Release do
  @moduledoc """
  Release entry points — the commands that run against a *built* release,
  where Mix does not exist.

      bin/vr eval 'VR.Release.migrate()'

  This is the migration step in `deploy.toml`, and the one an operator types
  by hand during a manual deploy.

  ## Why it checks before it migrates

  `eval` evaluates `config/runtime.exs` and then runs one expression on a
  non-booted system. `config/runtime.exs` now distinguishes migration-only
  requirements (`DATABASE_URL`) from app-boot requirements
  (`SECRET_KEY_BASE`, `CLOAK_KEY`), so a missing app secret no longer stops a
  migration that never reads it.

  That split removes an accidental gate, which is exactly why the checks below
  exist: this module states its *own* requirement, and names itself when the
  requirement is not met. `VR.DBPreflight` then answers the two questions a
  bare `Ecto.Migrator.run/3` answers only by failing halfway — can we reach
  the database, and can the required extensions exist — while nothing has been
  changed yet. See `docs/16-postgres-extension-privileges.md`.
  """

  @app :vr

  # Named in every failure message. An operator reading a deploy log needs to
  # know which command to fix and re-run, not only what went wrong.
  @entry_point "bin/vr eval 'VR.Release.migrate()'"

  @doc """
  Runs every pending migration for every configured repo.

  Raises before touching the database when `DATABASE_URL` is absent, when the
  database cannot be reached, or when a required PostgreSQL extension is
  missing and the current role cannot create it. Each message names the
  missing value or the administrator action, and this entry point.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      ensure_configured!(repo)

      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          preflight!(repo)
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  @doc """
  Raises unless `repo` has somewhere to connect to.

  In a release `config/runtime.exs` raises first, so this is the guard for
  every other way here — a release built from a modified config, or a call
  from `mix run -e`. Either way the operator gets the variable name and the
  entry point instead of a `DBConnection` timeout.
  """
  def ensure_configured!(repo) do
    if configured?(repo_config(repo)) do
      :ok
    else
      raise """
      environment variable DATABASE_URL is missing.

      It is required by the database migration entry point:

          #{@entry_point}

      For example: ecto://USER:PASS@HOST/DATABASE

      Only DATABASE_URL is needed here. SECRET_KEY_BASE and CLOAK_KEY are read
      when the application itself boots, not when migrations run.
      """
    end
  end

  @doc """
  Raises unless the database is ready to be migrated.

  `opts` are passed to `VR.DBPreflight.check_connection/2`.
  """
  def preflight!(repo, opts \\ []) do
    case VR.DBPreflight.check_connection(repo, opts) do
      :ok -> :ok
      {:error, message} -> raise not_ready_message([message])
    end

    case blocking_extensions(repo) do
      [] -> :ok
      problems -> raise not_ready_message(problems)
    end
  end

  # `:installed` and `:creatable` need no action — the migrations create what
  # they can. `{:error, _}` is reported but does **not** block: the check
  # failing is not proof that the migration would, and a preflight must never
  # be the reason a working deploy stops.
  defp blocking_extensions(repo) do
    repo
    |> VR.DBPreflight.check_extensions()
    |> Enum.flat_map(fn
      {_ext, status} when status in [:installed, :creatable] ->
        []

      {ext, {:error, message}} ->
        warn(~s(could not check the PostgreSQL extension "#{ext}": #{message}))
        warn("continuing — the migration will report the extension itself if it is missing.")
        []

      {ext, {_blocked, message}} ->
        [~s(the PostgreSQL extension "#{ext}" is #{message})]
    end)
  end

  defp not_ready_message(problems) do
    """
    the database is not ready for migration.

    #{Enum.map_join(problems, "\n\n", &("    " <> &1))}

    Nothing has been migrated. Fix the above, then re-run:

        #{@entry_point}
    """
  end

  defp configured?(config) do
    Enum.any?([:url, :hostname, :socket, :socket_dir], &present?(config[&1]))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_), do: true

  # `Ecto.Repo.config/0` resolves without the repo running (`with_repo` reads
  # it the same way), but a release assembled without any repo config at all
  # raises here — and that is precisely the case whose own message we want.
  defp repo_config(repo) do
    repo.config()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Logger is not necessarily started at this point in an `eval`; stderr is.
  defp warn(message), do: IO.puts(:stderr, "[VR.Release] " <> message)

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
  end
end
