defmodule Mix.Tasks.Vr.Doctor do
  @moduledoc """
  Checks the development environment and configuration.

      mix vr.doctor

  ## Why this exists

  This app has many external dependencies (FFmpeg, S3, Google STT, LLM). When
  any one is missing, only that feature dies quietly. This shows what is not
  working, and why, on a single screen.

  In production, the admin dashboard (`/_admin`) shows the same information.

  ## What it reports, in the order an installation answers it

    * the external tools;
    * the database — reachable, migrated, and whether the required extensions
      are usable by this role;
    * **required config, by entry point** — `migrate`, `seed` and `app boot`
      require different values, and each needs everything the one before it
      needs. A flat list of the three variables is what told operators that a
      migration needs `SECRET_KEY_BASE` (`docs/17-runtime-entry-points.md`);
    * **seed data** — the rows `VR.Release.seed/1` leaves behind, read back
      with the reads the seed itself opens with, and the command that creates
      each one when it is not there;
    * each feature that can be configured separately.

  A migrated database with none of the seed rows is a working install nobody
  can sign in to, which is why the seed section exists next to the config one.
  """
  @shortdoc "Checks the development environment and configuration"

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    # Show only the check results. SQL debug logs mixed in make them unreadable.
    Logger.configure(level: :warning)

    Mix.shell().info("\n━━━ System tools ━━━")
    binaries = check_binaries()

    Mix.shell().info("\n━━━ Database ━━━")
    schema = check_database()

    Mix.shell().info("\n━━━ Required config, by entry point ━━━")
    config = print_rows(config_rows())

    Mix.shell().info("\n━━━ Seed data ━━━")
    seed = print_rows(seed_rows(seed_facts(schema)))

    Mix.shell().info("\n━━━ Feature readiness ━━━")
    features = check_features()

    Mix.shell().info("\n━━━ Summary ━━━")
    summarize(binaries, features, config, seed)
  end

  # ── System tools ─────────────────────────────────────────

  defp check_binaries do
    tools = [
      {"ffmpeg", "audio splitting, MP3 conversion", :required, "brew install ffmpeg"},
      {"ffprobe", "audio duration checks", :required, "brew install ffmpeg"},
      {"gitleaks", "blocks secrets at commit time", :recommended, "brew install gitleaks"}
    ]

    Enum.map(tools, fn {bin, purpose, level, install} ->
      found = System.find_executable(bin)

      cond do
        found ->
          line(:ok, bin, purpose)
          {bin, true}

        level == :required ->
          line(:error, bin, "#{purpose} — transcription fails without it")
          Mix.shell().info("       install: #{install}")
          {bin, false}

        true ->
          line(:warn, bin, "#{purpose} — installation recommended")
          Mix.shell().info("       install: #{install}")
          {bin, false}
      end
    end)
  end

  # ── DB ───────────────────────────────────────────────────

  # Returns what the *next* section can ask of this database. The seed rows are
  # reads against tables the migrations create, so asking them on a green-field
  # database is asking for `relation "plans" does not exist` where a check
  # result should be.
  @spec check_database() :: :ready | :pending | :unreachable
  defp check_database do
    case VR.DBPreflight.check_connection() do
      :ok ->
        line(:ok, "connection", "ok")
        schema = check_migrations()
        check_extensions()
        schema

      {:error, message} ->
        line(:error, "connection", message)
        :unreachable
    end
  end

  defp check_migrations do
    pending = Ecto.Migrator.migrations(VR.Repo) |> Enum.filter(&(elem(&1, 0) == :down))

    if pending == [] do
      line(:ok, "migrations", "all applied")
      :ready
    else
      line(:error, "migrations", "#{length(pending)} pending — mix ecto.migrate")
      :pending
    end
  end

  defp check_extensions do
    for {ext, status} <- VR.DBPreflight.check_extensions() do
      case status do
        :installed ->
          line(:ok, ext, "installed")

        :creatable ->
          line(:warn, ext, "not installed — migrations will create it (mix ecto.migrate)")

        {:unreachable, message} ->
          line(:error, ext, message)

        {:not_creatable, message} ->
          line(:error, ext, message)

        {:unavailable, message} ->
          line(:error, ext, message)

        {:error, message} ->
          line(:error, ext, message)
      end
    end
  end

  # ── Required config, by entry point ──────────────────────

  # The three commands that bring an installation up do not need the same
  # things, and each one needs everything the one before it needs:
  #
  #     migrate    DATABASE_URL
  #     seed       + CLOAK_KEY
  #     app boot   + SECRET_KEY_BASE
  #
  # Listing the three values flat said the opposite — that a migration is
  # missing SECRET_KEY_BASE — which is the belief that turned a missing app
  # secret into `migration_failed`. `config/runtime.exs` and `VR.Release` now
  # split by entry point (`docs/17-runtime-entry-points.md`); this is the same
  # split, read out. A row is the command, and its mark answers the only
  # question worth asking about a command: can it run right now.
  @entry_points [
    {"migrate", "DATABASE_URL"},
    {"seed", "CLOAK_KEY"},
    {"app boot", "SECRET_KEY_BASE"}
  ]

  @doc false
  @spec config_rows(keyword()) :: [row()]
  def config_rows(opts \\ []) do
    repo_configured? = Keyword.get_lazy(opts, :repo_configured, &repo_configured?/0)

    {rows, _} =
      Enum.map_reduce(@entry_points, [], fn {label, var}, blocked ->
        row = config_row(label, var, value_state(var, repo_configured?), blocked)
        {row, blocked ++ Enum.map(row.missing, fn {name, _label} -> name end)}
      end)

    rows
  end

  # `DATABASE_URL` is the one value a checkout can do without: `config/dev.exs`
  # carries a working local connection, and `mix ecto.migrate` uses it. Calling
  # that missing would be this section's own version of the defect it removes —
  # a red mark on a command that runs. In a release there is no such file and
  # the variable is the only source, so the release answer is unchanged.
  defp value_state("DATABASE_URL" = var, repo_configured?) do
    cond do
      env_set?(var) -> :set
      repo_configured? -> :from_mix_config
      true -> :missing
    end
  end

  defp value_state(var, _repo_configured?) do
    if env_set?(var), do: :set, else: :missing
  end

  defp config_row(label, var, :missing, _blocked) do
    row(:error, label, "#{var} missing", missing: [{var, label}])
  end

  defp config_row(label, var, state, blocked) do
    detail = state_detail(var, state)

    # Its own value is there, and an earlier command's is not. The row above
    # already names it; repeating the name here is what makes this row's mark
    # readable without scrolling back up.
    case blocked do
      [] -> row(:ok, label, detail)
      names -> row(:error, label, detail <> " — waiting on #{Enum.join(names, ", ")}")
    end
  end

  defp state_detail(var, :set), do: "#{var} set"

  defp state_detail(var, :from_mix_config),
    do: "#{var} not set — using config/#{Mix.env()}.exs"

  defp env_set?(var), do: System.get_env(var) not in [nil, ""]

  defp repo_configured? do
    config = VR.Repo.config()
    Enum.any?([:url, :hostname, :socket, :socket_dir], &present?(config[&1]))
  rescue
    _ -> false
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_), do: true

  # ── Seed data ────────────────────────────────────────────

  # A migrated database is not yet a usable one. These are the three rows
  # `VR.Release.seed/1` creates, read back with the same reads the seed itself
  # opens with, so that "already there" means here what it means there.
  @seed_command "mix run priv/repo/seeds.exs"
  @admin_command "mix vr.bootstrap_admin --email you@example.com"

  @doc false
  @spec seed_facts(:ready | :pending | :unreachable) :: map() | :pending | :unreachable
  def seed_facts(:ready) do
    %{
      conversion: VR.Billing.Credits.conversion_setting(),
      free_plan: VR.Billing.get_plan_by_key(VR.Billing.free_plan_key()),
      admins: VR.Accounts.Admin.count_admins()
    }
  end

  def seed_facts(not_ready), do: not_ready

  @doc false
  @spec seed_rows(map() | :pending | :unreachable) :: [row()]
  def seed_rows(:pending),
    do: [row(:info, "seed data", "not checked — the migrations above have not run")]

  def seed_rows(:unreachable),
    do: [row(:info, "seed data", "not checked — the database cannot be reached")]

  def seed_rows(%{} = facts) do
    [conversion_row(facts.conversion), free_plan_row(facts.free_plan), admin_row(facts.admins)]
  end

  defp conversion_row(nil) do
    row(:error, "credit conversion", "missing — recorded usage cannot be priced",
      hint: "create: #{@seed_command}",
      missing: ["credit conversion"]
    )
  end

  defp conversion_row(setting) do
    row(:ok, "credit conversion", "1 credit = $#{setting.credit_value_usd}")
  end

  defp free_plan_row(nil) do
    row(:error, "free plan", "missing — new signups have no plan to join",
      hint: "create: #{@seed_command}",
      missing: ["free plan"]
    )
  end

  defp free_plan_row(plan) do
    case VR.Billing.current_revision(plan) do
      nil ->
        # The seed publishes revision 1 with the plan it creates, so a plan
        # without one was not left by the seed and re-running it will not add
        # one — it skips a plan that exists. Only the admin screen can.
        row(:warn, "free plan", "no revision — signups get no included credits",
          hint: "publish one: /_admin → Plans",
          missing: ["free plan revision"]
        )

      revision ->
        row(:ok, "free plan", "#{revision.included_credits} credits/month")
    end
  end

  # The same read `VR.Release.BootstrapAdmin` uses to decide whether there is
  # anyone to let in. The consequence is printed with it: a row saying "0" is
  # skipped over in a terminal, and "nobody can open /_admin" is not.
  defp admin_row(0) do
    row(:error, "admin sign-in", "no admin — /_admin cannot be opened by anyone",
      hint: "create: #{@admin_command}",
      missing: ["admin account"]
    )
  end

  defp admin_row(count) do
    row(:ok, "admin sign-in", "#{count} #{admins(count)} can open /_admin")
  end

  defp admins(1), do: "admin"
  defp admins(_), do: "admins"

  # ── Per feature ──────────────────────────────────────────

  defp check_features do
    statuses = VR.Config.feature_status()

    # Uses the real check for the same reason as transcription — in dev mode
    # it works even without keys.
    summary_ready = VR.Summarize.ready?()

    # For transcription, override with the real check that also considers
    # FFmpeg and dev mode, not just config. Even with every key present it
    # fails without FFmpeg, and in dev mode it works without keys.
    statuses =
      statuses
      |> Enum.map(fn
        %{feature: :transcription} = status ->
          cond do
            VR.Transcription.ready?() ->
              %{status | ready: true, missing: []}

            not VR.Transcription.Audio.available?() ->
              %{status | missing: status.missing ++ [%{label: "FFmpeg"}]}

            true ->
              status
          end

        status ->
          status
      end)
      |> Kernel.++([
        %{feature: :summary, ready: summary_ready, missing: llm_missing(summary_ready)}
      ])

    Enum.each(statuses, fn s ->
      label = feature_label(s.feature)

      if s.ready do
        line(:ok, label, "working")
      else
        names = s.missing |> Enum.map(& &1.label) |> Enum.join(", ")
        line(:warn, label, "not configured — needs: #{names}")
      end
    end)

    social = VR.Auth.Providers.list_active()

    if social == [] do
      line(:info, "social sign-in", "none (email+password only)")
    else
      line(:ok, "social sign-in", social |> Enum.map(& &1.display_name) |> Enum.join(", "))
    end

    statuses
  end

  defp llm_missing(true), do: []
  defp llm_missing(false), do: [%{label: "LLM API key"}]

  defp feature_label(:storage), do: "recording upload"
  defp feature_label(:transcription), do: "transcription"
  defp feature_label(:summary), do: "AI summary"
  defp feature_label(:mail), do: "mail delivery"
  defp feature_label(:push), do: "web push"
  defp feature_label(other), do: to_string(other)

  # ── Summary ──────────────────────────────────────────────

  defp summarize(binaries, features, config, seed) do
    missing_bins = binaries |> Enum.reject(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
    blocked = Enum.reject(features, & &1.ready)
    missing_config = Enum.flat_map(config, & &1.missing)
    missing_seed = Enum.flat_map(seed, & &1.missing)
    unchecked_seed? = Enum.any?(seed, &(&1.status == :info))

    cond do
      missing_bins == [] and blocked == [] and missing_config == [] and missing_seed == [] and
          not unchecked_seed? ->
        Mix.shell().info("  ✅ Everything is ready.\n")

      true ->
        if missing_bins != [] do
          Mix.shell().info("  Missing tools: #{Enum.join(missing_bins, ", ")}")
        end

        # Which command each value stops is the point of the section above, so
        # the summary carries it too: an operator who reads only this block
        # still learns that a missing CLOAK_KEY leaves the migration alone.
        if missing_config != [] do
          missing_config
          |> Enum.map(fn {var, label} -> "#{var} (#{label})" end)
          |> summary_list("Missing config")
          |> Enum.each(&Mix.shell().info/1)
        end

        if missing_seed != [] do
          missing_seed
          |> summary_list("Missing seed data")
          |> Enum.each(&Mix.shell().info/1)
        end

        if unchecked_seed? do
          Mix.shell().info("  Seed data: not checked — see Database above")
        end

        if blocked != [] do
          names = blocked |> Enum.map(&feature_label(&1.feature)) |> Enum.join(", ")
          Mix.shell().info("  Unconfigured features: #{names}")
        end

        Mix.shell().info("""

          Where to put configuration:
            local  .env                    (see docs/00-setup-checklist.md)
            prod   /_admin admin screens   (stored encrypted in the DB, takes precedence over .env)
        """)
    end
  end

  # Three entry points, each with a variable and a name, do not fit on one
  # line. The rows above already carry the same list one per line, so this is
  # a recap and can wrap — under the label, where the next name is expected.
  @summary_width 80

  defp summary_list(items, label) do
    indent = String.duplicate(" ", String.length(label) + 4)

    Enum.reduce(items, [], fn item, lines ->
      case lines do
        [] ->
          ["  #{label}: #{item}"]

        [current | rest] ->
          candidate = current <> ", " <> item

          if String.length(candidate) <= @summary_width,
            do: [candidate | rest],
            else: [indent <> item, current <> "," | rest]
      end
    end)
    |> Enum.reverse()
  end

  # ── Output ───────────────────────────────────────────────

  @typedoc """
  One printed check.

    * `:hint` — the second line, for a command to copy. Same shape as the
      `install:` line under a missing binary.
    * `:missing` — what the summary repeats. Config rows carry
      `{variable, entry point}`; seed rows carry the name of the row.
  """
  @type row :: %{
          status: :ok | :warn | :error | :info,
          label: String.t(),
          detail: String.t(),
          hint: String.t() | nil,
          missing: [String.t() | {String.t(), String.t()}]
        }

  defp row(status, label, detail, opts \\ []) do
    %{
      status: status,
      label: label,
      detail: detail,
      hint: opts[:hint],
      missing: opts[:missing] || []
    }
  end

  defp print_rows(rows) do
    Enum.each(rows, fn row ->
      Enum.each(render(row), &Mix.shell().info/1)
    end)

    rows
  end

  @doc false
  @spec render(row()) :: [String.t()]
  def render(row) do
    [line_text(row.status, row.label, row.detail)] ++ List.wrap(row.hint && "       #{row.hint}")
  end

  defp line(status, label, detail) do
    Mix.shell().info(line_text(status, label, detail))
  end

  defp line_text(status, label, detail) do
    mark =
      case status do
        :ok -> "  ✅"
        :warn -> "  ⚠️ "
        :error -> "  ❌"
        :info -> "  ·  "
      end

    "#{mark} #{String.pad_trailing(label, 18)} #{detail}"
  end
end
