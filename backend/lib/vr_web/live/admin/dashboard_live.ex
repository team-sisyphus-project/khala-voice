defmodule VRWeb.Admin.DashboardLive do
  @moduledoc "Admin dashboard — what is configured and what is missing, at a glance."

  use VRWeb, :live_view

  import VRWeb.Admin.Components

  alias VR.Auth.Providers
  alias VR.Config
  alias VR.Summarize.LlmProviders

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  defp load(socket) do
    statuses = Config.feature_status()

    summary_status = %{
      feature: :summary,
      ready: LlmProviders.ready?(),
      missing: if(LlmProviders.ready?(), do: [], else: [%{label: "LLM API key"}])
    }

    # Override with the real verdict, which also checks for FFmpeg, not just config.
    # Even with all keys present, transcription fails without FFmpeg.
    statuses =
      Enum.map(statuses, fn
        %{feature: :transcription} = status ->
          if VR.Transcription.ready?() do
            %{status | ready: true, missing: []}
          else
            missing =
              if VR.Transcription.Audio.available?(),
                do: status.missing,
                else: status.missing ++ [%{label: "FFmpeg"}]

            %{status | ready: false, missing: missing}
          end

        status ->
          status
      end)

    assign(socket,
      statuses: statuses ++ [summary_status],
      social: Providers.list_active(),
      ffmpeg: ffmpeg_status()
    )
  end

  defp ffmpeg_status do
    missing = Enum.reject(~w(ffmpeg ffprobe), &System.find_executable/1)
    %{ok: missing == [], missing: missing}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      active={:dashboard}
      title="Dashboard"
      subtitle="After deploying, enter API keys here to turn on each feature."
    >
      <.readiness_banner statuses={@statuses} />

      <.notice
        :if={not @ffmpeg.ok}
        kind={:error}
        icon="error"
        title={"FFmpeg is missing: " <> Enum.join(@ffmpeg.missing, ", ")}
        class="mb-4"
      >
        Recordings longer than 20 minutes need to be split, and all audio is converted to MP3 before being sent to STT.
        Without FFmpeg, the entire transcription path fails.
      </.notice>

      <div class="grid grid-cols-2 gap-3">
        <div :for={s <- @statuses} class="vr-card">
          <div class="vr-card__body">
            <div class="flex items-center justify-between gap-2 mb-1.5">
              <h3 class="font-semibold" style="color: var(--text-primary);">
                {feature_label(s.feature)}
              </h3>
              <span class={["vr-chip", if(s.ready, do: "vr-chip--ok", else: "vr-chip--warn")]}>
                {if s.ready, do: "Running", else: "Not set"}
              </span>
            </div>
            <p :if={not s.ready} class="vr-hint">
              Requires: {s.missing |> Enum.map(& &1.label) |> Enum.join(", ")}
            </p>
            <p :if={s.ready} class="vr-hint">All required settings are in place.</p>
          </div>
        </div>
      </div>

      <div class="vr-card mt-3">
        <div class="vr-card__body">
          <h3 class="font-semibold mb-2" style="color: var(--text-primary);">Sign-in methods</h3>
          <div class="flex flex-wrap gap-1.5">
            <span class="vr-chip vr-chip--ok">Email + password (always on)</span>
            <span :for={p <- @social} class="vr-chip vr-chip--ok">{p.display_name}</span>
            <span :if={@social == []} class="vr-hint">No social sign-in providers are enabled.</span>
          </div>
        </div>
      </div>
    </.shell>
    """
  end
end
