defmodule Mix.Tasks.Vr.Doctor do
  @moduledoc """
  Checks the development environment and configuration.

      mix vr.doctor

  ## Why this exists

  This app has many external dependencies (FFmpeg, S3, Google STT, LLM). When
  any one is missing, only that feature dies quietly. This shows what is not
  working, and why, on a single screen.

  In production, the admin dashboard (`/_admin`) shows the same information.
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
    check_database()

    Mix.shell().info("\n━━━ Required config ━━━")
    check_boot_config()

    Mix.shell().info("\n━━━ Feature readiness ━━━")
    features = check_features()

    Mix.shell().info("\n━━━ Summary ━━━")
    summarize(binaries, features)
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

  defp check_database do
    case VR.DBPreflight.check_connection() do
      :ok ->
        line(:ok, "connection", "ok")
        check_migrations()
        check_extensions()

      {:error, message} ->
        line(:error, "connection", message)
    end
  end

  defp check_migrations do
    pending = Ecto.Migrator.migrations(VR.Repo) |> Enum.filter(&(elem(&1, 0) == :down))

    if pending == [] do
      line(:ok, "migrations", "all applied")
    else
      line(:error, "migrations", "#{length(pending)} pending — mix ecto.migrate")
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

  # ── Boot-required config ─────────────────────────────────

  defp check_boot_config do
    for {name, env} <- [
          {"DATABASE_URL", "DATABASE_URL"},
          {"SECRET_KEY_BASE", "SECRET_KEY_BASE"},
          {"CLOAK_KEY", "CLOAK_KEY"}
        ] do
      if System.get_env(env) in [nil, ""] do
        line(:error, name, "missing")
      else
        line(:ok, name, "set")
      end
    end
  end

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

  defp summarize(binaries, features) do
    missing_bins = binaries |> Enum.reject(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
    blocked = Enum.reject(features, & &1.ready)

    cond do
      missing_bins == [] and blocked == [] ->
        Mix.shell().info("  ✅ Everything is ready.\n")

      true ->
        if missing_bins != [] do
          Mix.shell().info("  Missing tools: #{Enum.join(missing_bins, ", ")}")
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

  # ── Output ───────────────────────────────────────────────

  defp line(status, label, detail) do
    mark =
      case status do
        :ok -> "  ✅"
        :warn -> "  ⚠️ "
        :error -> "  ❌"
        :info -> "  ·  "
      end

    Mix.shell().info("#{mark} #{String.pad_trailing(label, 18)} #{detail}")
  end
end
