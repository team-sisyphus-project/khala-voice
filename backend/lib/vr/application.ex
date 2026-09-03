defmodule VR.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Before the logger. Share tokens appear in request paths — left as-is, the logs become credentials.
    VR.LogRedactor.install()

    ensure_ffmpeg!()

    children = [
      VRWeb.Telemetry,
      # Vault must start before Repo. It is needed to read and write encrypted fields.
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

  # Without FFmpeg, splitting and transcoding of recordings over 20 minutes all fail.
  # Do not block boot (developer convenience), but warn loudly at startup.
  # The same status is shown on the admin dashboard.
  defp ensure_ffmpeg! do
    missing = Enum.reject(~w(ffmpeg ffprobe), &System.find_executable/1)

    if missing != [] do
      require Logger

      Logger.warning("""
      [VR] FFmpeg not found: #{Enum.join(missing, ", ")}

      Recordings over 20 minutes require splitting, and all audio is converted
      to MP3 before being handed to STT. Without FFmpeg, this entire path fails.

          macOS:  brew install ffmpeg
          Docker: the image must include the ffmpeg package
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
