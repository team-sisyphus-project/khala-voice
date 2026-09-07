defmodule VR.Release do
  @moduledoc """
  Release entry points — the commands that run against a *built* release,
  where Mix does not exist.

      bin/vr eval 'VR.Release.migrate()'
      bin/vr eval 'VR.Release.seed()'

  These are the database preparation steps in `deploy.toml`, and the ones an
  operator types by hand during a manual deploy.

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

  ## The two steps do not require the same things

  `migrate/0` writes schema; it reads no configuration beyond the connection.
  `seed/1` writes *application data*, and reads configuration the way the
  running app does — through `VR.Config`, which resolves DB before environment.
  Reading the DB layer means decrypting it, so seeding starts `VR.Vault` and
  therefore needs `CLOAK_KEY`. It still starts no Endpoint, so `SECRET_KEY_BASE`
  stays out of both steps.

      | value            | migrate | seed | app boot |
      | DATABASE_URL     |    ✓    |  ✓   |    ✓     |
      | CLOAK_KEY        |         |  ✓   |    ✓     |
      | SECRET_KEY_BASE  |         |      |    ✓     |
  """

  @app :vr

  # Named in every failure message. An operator reading a deploy log needs to
  # know which command to fix and re-run, not only what went wrong.
  @entry_point "bin/vr eval 'VR.Release.migrate()'"
  @seed_entry_point "bin/vr eval 'VR.Release.seed()'"

  # Seed data belongs to one database: `VR.Billing` and `VR.Accounts` name
  # `VR.Repo` directly. Looping over `:ecto_repos` the way `migrate/0` does
  # would run the same inserts once per repo, against the same repo.
  @seed_repo VR.Repo

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
  Creates the rows a fresh installation cannot run without. Safe to run again.

      bin/vr eval 'VR.Release.seed()'

  Three things, each created only when it is absent:

    * the credit conversion policy — without it, usage cannot be priced and
      transcription runs unmetered;
    * the free plan every signup is subscribed to;
    * the initial admin account, from `BOOTSTRAP_ADMIN_EMAIL` /
      `BOOTSTRAP_ADMIN_PASSWORD`, so that `/_admin` has someone who can open it.

  The admin is **skipped with a message** when no email is configured — there
  is no default address, because one shared address across every deployment
  would itself be the target. Everything else is still seeded.

  "Only when it is absent" is decided by a read, so two deploys running this
  at the same time can both read *absent* and both write. The one that loses
  the unique index reports the row as already there and carries on: the deploy
  step's job is to leave the row behind, not to be the one that wrote it.

  `:entry_point` overrides the command quoted in the messages. `priv/repo/seeds.exs`
  passes its own, so an operator running the Mix path is not told to run a
  release command that does not exist there.
  """
  def seed(opts \\ []) do
    load_app()
    entry_point = Keyword.get(opts, :entry_point, @seed_entry_point)

    ensure_configured!(@seed_repo, entry_point)
    ensure_vault!(entry_point)

    {:ok, :ok, _apps} =
      Ecto.Migrator.with_repo(@seed_repo, fn _repo -> seed_all(entry_point) end)

    :ok
  end

  @doc """
  Raises unless `repo` has somewhere to connect to.

  In a release `config/runtime.exs` raises first, so this is the guard for
  every other way here — a release built from a modified config, or a call
  from `mix run -e`. Either way the operator gets the variable name and the
  entry point instead of a `DBConnection` timeout.
  """
  def ensure_configured!(repo, entry_point \\ @entry_point) do
    if configured?(repo_config(repo)) do
      :ok
    else
      raise """
      environment variable DATABASE_URL is missing.

      It is required by the database preparation entry point:

          #{entry_point}

      For example: ecto://USER:PASS@HOST/DATABASE

      #{other_values_note(entry_point)}
      """
    end
  end

  # What an operator must *not* go hunting for. It differs by entry point, and
  # saying it wrongly is worse than not saying it: the seed does need CLOAK_KEY.
  defp other_values_note(@entry_point) do
    """
    Only DATABASE_URL is needed here. SECRET_KEY_BASE and CLOAK_KEY are read
    when the application itself boots, not when migrations run.
    """
    |> String.trim_trailing()
  end

  defp other_values_note(_seed_entry_point) do
    """
    Seeding also needs CLOAK_KEY — it reads configuration the way the app does,
    and stored values are encrypted. SECRET_KEY_BASE is not read by either step;
    it is read when the application itself boots.
    """
    |> String.trim_trailing()
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

  # ── Seeding ──────────────────────────────────────────────

  # The admin goes last. It is the only step whose input comes from the
  # operator, so it is the only one that can fail on a typo — and when it does,
  # the plan and the conversion policy are already in place. Re-running after
  # fixing the address skips them.
  defp seed_all(entry_point) do
    seed_credit_conversion(entry_point)
    seed_free_plan(entry_point)
    seed_bootstrap_admin(entry_point)
    :ok
  end

  # Every step below asks "is it there?" and then writes. Two deploys running
  # this at the same time — or one re-run after the other died mid-step — both
  # get a yes to that question and both write, and the second write loses on a
  # unique index. That loss is not a failure: it is the same answer the check
  # asked for, arriving a moment later. Said so, and only then.
  @concurrently " — created by a concurrent run."

  # 1 credit = $N. Changed from the admin UI afterwards.
  # The default follows devkanban's reference value (≈ $0.0015, Cookie Crate basis).
  # Without this value usage cannot be converted into credits, so transcription
  # and summarization would go unmetered.
  defp seed_credit_conversion(entry_point) do
    if is_nil(VR.Billing.Credits.conversion_setting()) do
      case VR.Billing.Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")}) do
        {:ok, setting} ->
          say(
            "[seeds] created credit conversion policy — 1 credit = $#{setting.credit_value_usd}"
          )

        {:error, changeset} ->
          duplicate!(changeset, "the credit conversion policy", entry_point)
          say("[seeds] credit conversion policy already exists" <> @concurrently)
      end
    else
      say("[seeds] credit conversion policy already exists.")
    end
  end

  # Every signup is subscribed to this automatically. Included credits are
  # changed from the admin UI (changing them publishes a new revision —
  # existing subscriptions are grandfathered).
  defp seed_free_plan(entry_point) do
    case VR.Billing.get_plan_by_key(VR.Billing.free_plan_key()) do
      nil -> create_free_plan(entry_point)
      _plan -> say("[seeds] free plan already exists.")
    end
  end

  defp create_free_plan(entry_point) do
    case VR.Billing.create_plan(%{
           key: VR.Billing.free_plan_key(),
           display_name: "Free",
           description: "Record meetings, then transcribe and summarize them.",
           status: "published",
           publicly_listed: true,
           sort_order: 0
         }) do
      {:ok, plan} ->
        publish_free_plan(plan, entry_point)

      {:error, changeset} ->
        duplicate!(changeset, "the free plan", entry_point)
        say("[seeds] free plan already exists" <> @concurrently)
    end
  end

  # Only the run that inserted the plan gets here, and it is the only one that
  # can insert revision 1 of it. So a failure here is never the race — it is
  # reported as what it is.
  defp publish_free_plan(plan, entry_point) do
    case VR.Billing.publish_revision(plan, %{
           prices: %{"KRW" => %{"amount" => 0}, "USD" => %{"amount" => 0}},
           interval: "month",
           included_credits: 3_000,
           limits: %{}
         }) do
      {:ok, revision} ->
        say("[seeds] created free plan — #{revision.included_credits} credits/month")

      {:error, changeset} ->
        raise seed_failed_message("the free plan's first revision", changeset, entry_point)
    end
  end

  defp seed_bootstrap_admin(entry_point) do
    # Asked *before* the account is created: afterwards the password is only a
    # hash, and "did the operator choose this, or did we generate it?" is the
    # difference between printing a secret into a deploy log and not.
    generated? = not VR.Config.configured?("app.bootstrap_admin_password")

    case VR.Accounts.Admin.ensure_bootstrap_admin() do
      {:ok, account, password} ->
        say(admin_created_message(account, if(generated?, do: password)))

      {:error, :admin_exists} ->
        say("[seeds] an admin already exists. Skipping.")

      {:error, :email_required} ->
        say(admin_skipped_message(entry_point))

      # The address is taken *and* an admin now exists: the other run created
      # it between the count above and this insert. Asking again is what tells
      # the two apart — if no admin exists, the address belongs to somebody
      # else's account, and that is a typo the operator has to see.
      {:error, %Ecto.Changeset{} = changeset} ->
        if already_there?(changeset) and VR.Accounts.Admin.count_admins() > 0 do
          say("[seeds] an admin already exists" <> @concurrently <> " Skipping.")
        else
          raise admin_failed_message(changeset, entry_point)
        end
    end
  end

  defp admin_failed_message(changeset, entry_point) do
    """
    the initial admin account could not be created.

        email     #{inspect(VR.Config.fetch("app.bootstrap_admin_email"))}
        rejected  #{changeset_errors(changeset)}

    Everything else has been seeded. Fix BOOTSTRAP_ADMIN_EMAIL (and
    BOOTSTRAP_ADMIN_PASSWORD, if it is the password that was rejected),
    then re-run:

        #{entry_point}
    """
  end

  # "That row is already there" is the one rejection that is not a failure.
  # Every other one is the seed being wrong, and stays loud.
  defp duplicate!(changeset, subject, entry_point) do
    if already_there?(changeset) do
      :ok
    else
      raise seed_failed_message(subject, changeset, entry_point)
    end
  end

  # It arrives in two shapes, and which one depends only on where the other
  # deploy's row landed. After the changeset's own lookup for the same index
  # (`unsafe_validate_unique/3`), the index rejects the write —
  # `constraint: :unique`. Before it, that lookup finds the row and says so
  # itself — `validation: :unsafe_unique`. One fact, two reporters.
  defp already_there?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique or opts[:validation] == :unsafe_unique
    end)
  end

  defp seed_failed_message(subject, changeset, entry_point) do
    """
    #{subject} could not be created.

        rejected  #{changeset_errors(changeset)}

    This is not a row that already exists, so re-running alone will not clear
    it. The steps before this one are seeded and will be skipped next time.
    Fix the cause, then re-run:

        #{entry_point}
    """
  end

  defp admin_created_message(account, password) do
    """

    ┌──────────────────────────────────────────────────────────┐
      Created the initial admin account

        Email     #{account.email}
        Password  #{password || "the value set in BOOTSTRAP_ADMIN_PASSWORD"}

    #{if password do
      "  This password is only shown right now. Save it somewhere."
    else
      "  It was not printed — it is already yours, and this output is a deploy log."
    end}
      Delete this account after promoting a real user to admin.
    └──────────────────────────────────────────────────────────┘
    """
  end

  # Not a failure: the rest of the seed is done and the app runs. It is,
  # however, the difference between a preview someone can sign in to and one
  # nobody can — so it says what to set and how to run it again from *both*
  # entry points, since either one may be the one that printed this.
  defp admin_skipped_message(entry_point) do
    """

    [seeds] no initial admin was created — BOOTSTRAP_ADMIN_EMAIL is not set.

        Nothing else was skipped. Until an admin exists, /_admin cannot be
        opened by anyone. Set the address and run the seed again:

            BOOTSTRAP_ADMIN_EMAIL=you@example.com #{entry_point}

        The password is optional — BOOTSTRAP_ADMIN_PASSWORD is used when set,
        and a random one is generated and printed once when it is not.
    """
  end

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field}: #{Enum.join(messages, ", ")}"
    end)
  end

  # ── Checks ───────────────────────────────────────────────

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

  # Seeding reads configuration through `VR.Config`, whose first source is the
  # DB — and `system_configs` values are Cloak-encrypted. Without the vault,
  # `VR.Config` rescues the decryption failure and quietly returns the
  # environment value instead, which is the worst of the three outcomes: an
  # operator's configured value ignored, with nothing said. So the vault is
  # started here, and its one requirement is stated up front.
  #
  # `CLOAK_KEY` is read from the environment rather than through `VR.Config`
  # for the same reason `VR.Vault` does: it is the key that makes the DB layer
  # of `VR.Config` readable at all, so it cannot live inside it.
  defp ensure_vault!(entry_point) do
    if System.get_env("CLOAK_KEY") in [nil, ""] do
      raise """
      environment variable CLOAK_KEY is missing.

      It is required by the seed entry point:

          #{entry_point}

      Seeding reads configuration the way the app does, and values stored in
      the database are encrypted with this key. Generate one with:

          openssl rand -base64 32

      It is the same key the app itself boots with — if the app runs, the value
      already exists. Migrations do not read it:
      `#{@entry_point}` runs without.
      """
    end

    case VR.Vault.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise vault_failed_message(reason, entry_point)
    end
  end

  defp vault_failed_message(reason, entry_point) do
    detail =
      case reason do
        {exception, _stacktrace} when is_exception(exception) -> Exception.message(exception)
        other -> inspect(other)
      end

    """
    the encryption vault could not be started, so nothing was seeded.

    #{indent(detail)}

    CLOAK_KEY must be a Base64-encoded 32-byte value. Fix it, then re-run:

        #{entry_point}
    """
  end

  defp not_ready_message(problems) do
    """
    the database is not ready for migration.

    #{Enum.map_join(problems, "\n\n", &wrap_problem/1)}

    Nothing has been migrated. Fix the above, then re-run:

        #{@entry_point}
    """
  end

  # `VR.DBPreflight` returns one line per check on purpose — `mix vr.doctor`
  # prints them in an aligned `label + value` column, and wrapping them there
  # would break that alignment. Here they land inside a multi-line message
  # instead, where a 363-character line is what an operator actually sees. So
  # the wrapping belongs to the side that builds the paragraph, not the side
  # that builds the sentence.
  @problem_width 76

  defp wrap_problem(problem) do
    problem
    |> break_outside_backticks()
    |> Enum.reduce([[]], fn word, [line | rest] ->
      # +1 for the space that would join this word to the current line.
      if line != [] and text_width(line) + 1 + String.length(word) > @problem_width do
        [[word], line | rest]
      else
        [[word | line] | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.map_join("\n", fn line -> "    " <> (line |> Enum.reverse() |> Enum.join(" ")) end)
  end

  defp text_width(reversed_words) do
    Enum.reduce(reversed_words, length(reversed_words) - 1, &(String.length(&1) + &2))
  end

  # Splits on whitespace, except inside a backticked span. The SQL an
  # administrator has to run is quoted that way, and it is there to be copied —
  # a line break dropped into the middle of it costs more than a long line.
  defp break_outside_backticks(text) do
    ~r/`[^`]*`|\S+/
    |> Regex.scan(text)
    |> Enum.map(fn [match] -> match end)
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "    " <> line
    end)
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

  # Seed progress is the operator's record of what a deploy did. stdout, not
  # Logger, for the same reason: in an `eval` the Logger may not be running.
  defp say(message), do: IO.puts(message)

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
  end
end
