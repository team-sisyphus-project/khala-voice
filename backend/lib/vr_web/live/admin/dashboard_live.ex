defmodule VRWeb.Admin.DashboardLive do
  @moduledoc "어드민 대시보드 — 무엇이 설정됐고 무엇이 빠졌는지 한눈에."

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
      missing: if(LlmProviders.ready?(), do: [], else: [%{label: "LLM API 키"}])
    }

    # 설정만이 아니라 FFmpeg 유무까지 본 실제 판정으로 덮는다.
    # 키가 다 있어도 FFmpeg 이 없으면 전사는 실패한다.
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
      title="대시보드"
      subtitle="배포 후 여기서 API 키를 넣으면 각 기능이 켜집니다."
    >
      <.readiness_banner statuses={@statuses} />

      <.notice
        :if={not @ffmpeg.ok}
        kind={:error}
        icon="error"
        title={"FFmpeg이 없습니다: " <> Enum.join(@ffmpeg.missing, ", ")}
        class="mb-4"
      >
        20분을 넘는 녹음은 분할이 필요하고, 모든 오디오는 STT로 보내기 전 MP3로 변환됩니다.
        FFmpeg이 없으면 전사 경로 전체가 실패합니다.
      </.notice>

      <div class="grid grid-cols-2 gap-3">
        <div :for={s <- @statuses} class="vr-card">
          <div class="vr-card__body">
            <div class="flex items-center justify-between gap-2 mb-1.5">
              <h3 class="font-semibold" style="color: var(--text-primary);">
                {feature_label(s.feature)}
              </h3>
              <span class={["vr-chip", if(s.ready, do: "vr-chip--ok", else: "vr-chip--warn")]}>
                {if s.ready, do: "동작 중", else: "미설정"}
              </span>
            </div>
            <p :if={not s.ready} class="vr-hint">
              필요: {s.missing |> Enum.map(& &1.label) |> Enum.join(", ")}
            </p>
            <p :if={s.ready} class="vr-hint">필요한 설정이 모두 채워졌습니다.</p>
          </div>
        </div>
      </div>

      <div class="vr-card mt-3">
        <div class="vr-card__body">
          <h3 class="font-semibold mb-2" style="color: var(--text-primary);">로그인 수단</h3>
          <div class="flex flex-wrap gap-1.5">
            <span class="vr-chip vr-chip--ok">이메일 + 비밀번호 (항상 켜짐)</span>
            <span :for={p <- @social} class="vr-chip vr-chip--ok">{p.display_name}</span>
            <span :if={@social == []} class="vr-hint">활성화된 소셜 로그인이 없습니다.</span>
          </div>
        </div>
      </div>
    </.shell>
    """
  end
end
