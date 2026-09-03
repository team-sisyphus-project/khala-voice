defmodule VR.Transcription do
  @moduledoc """
  Transcription entry point — queueing and usage metering.

  The actual STT calls are made by `VR.Transcription.GoogleSTT`, and audio
  processing by `VR.Transcription.Audio`. This module wires those two into the
  domain.
  """

  alias VR.Billing.Credits
  alias VR.Config
  alias VR.Meetings
  alias VR.Meetings.RecordingSession
  alias VR.Transcription.{Audio, GoogleSTT}
  alias VR.Workers.{AudioSplitWorker, TranscriptionWorker}

  require Logger

  @doc """
  Enqueues a session for transcription.

  Over 20 minutes goes to the split worker; otherwise to the transcription worker.
  The decision is made here exactly once — deciding per worker would let the
  rules diverge.
  """
  def enqueue(%RecordingSession{} = session) do
    cond do
      is_nil(session.audio_url) ->
        {:error, :no_audio}

      Audio.needs_splitting?(session.duration_seconds) ->
        {:ok, _} = Meetings.set_session_status(session, "splitting")

        %{session_id: session.id}
        |> AudioSplitWorker.new()
        |> Oban.insert()

      true ->
        %{session_id: session.id}
        |> TranscriptionWorker.new()
        |> Oban.insert()
    end
  end

  @doc "Is transcription possible in this environment? Used by the admin dashboard."
  def ready? do
    GoogleSTT.ready?() and (GoogleSTT.dev_mode?() or Audio.available?())
  end

  @doc """
  Meters transcription usage.

  If no rate is configured, **metering is skipped** —
  transcription is not failed just because pricing setup is incomplete.
  """
  def charge(%RecordingSession{} = session, account_id) do
    with {:ok, cost} <- usage_cost(session) do
      Credits.charge_usage(account_id, cost,
        charge_domain: "stt",
        reason: "Transcription #{minutes(session)} min",
        # Not recorded twice even if the worker retries
        idempotency_key: "stt:#{session.id}",
        pricing_snapshot: %{
          "duration_seconds" => session.duration_seconds,
          "minutes" => minutes(session),
          "cost_per_minute_usd" => Config.fetch("stt.cost_per_minute_usd")
        }
      )
    else
      {:error, :no_pricing} ->
        Logger.info("[Transcription] no STT rate configured; skipping metering: #{session.id}")
        {:ok, :not_metered}

      error ->
        error
    end
  end

  defp usage_cost(session) do
    case Config.fetch("stt.cost_per_minute_usd") do
      nil ->
        {:error, :no_pricing}

      "" ->
        {:error, :no_pricing}

      rate ->
        case Decimal.parse(rate) do
          {decimal, _} -> {:ok, Decimal.mult(decimal, minutes(session))}
          :error -> {:error, :no_pricing}
        end
    end
  end

  # Rounded up to the minute. Using 30 seconds still counts as 1 minute — the
  # provider bills that way too.
  defp minutes(%RecordingSession{duration_seconds: seconds}) when is_integer(seconds),
    do: max(ceil(seconds / 60), 1)

  defp minutes(_), do: 1
end
