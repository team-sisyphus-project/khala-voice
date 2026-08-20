defmodule VR.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # 로거보다 먼저. 공유 토큰이 요청 경로에 있어 그대로 두면 로그가 자격증명이 된다.
    VR.LogRedactor.install()

    ensure_ffmpeg!()

    children = [
      VRWeb.Telemetry,
      # Vault는 Repo보다 먼저 뜨야 한다. 암호화 필드를 읽고 쓰려면 필요하다.
      VR.Vault,
      VR.Repo,
      {Oban, Application.fetch_env!(:vr, Oban)},
      {DNSCluster, query: Application.get_env(:vr, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: VR.PubSub},
      # Start a worker by calling: VR.Worker.start_link(arg)
      # {VR.Worker, arg},
      # Start to serve requests, typically the last entry
      VRWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: VR.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # FFmpeg이 없으면 20분 초과 녹음의 분할·트랜스코딩이 전부 실패한다.
  # 부팅을 막지는 않되(개발 편의), 시작 시점에 크게 경고한다.
  # 어드민 대시보드에도 같은 상태가 표시된다.
  defp ensure_ffmpeg! do
    missing = Enum.reject(~w(ffmpeg ffprobe), &System.find_executable/1)

    if missing != [] do
      require Logger

      Logger.warning("""
      [VR] FFmpeg을 찾을 수 없습니다: #{Enum.join(missing, ", ")}

      20분을 넘는 녹음은 분할이 필요하고, 모든 오디오는 STT에 넘기기 전
      MP3로 변환됩니다. FFmpeg이 없으면 이 경로가 전부 실패합니다.

          macOS:  brew install ffmpeg
          Docker: 이미지에 ffmpeg 패키지가 포함되어야 합니다
      """)
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    VRWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
