defmodule VR.Transcription.Audio do
  @moduledoc """
  Audio handling via FFmpeg — duration checks, splitting, MP3 conversion.

  **Source: sisyphus** `lib/sisyphus/meetings/audio_splitter.ex` — almost verbatim.

  ## Why 19 minutes

  Google STT `batchRecognize` has a length limit and fails past 20 minutes.
  Cutting at 19 minutes is **to leave headroom**. Cutting at exactly 20 minutes
  trips the boundary due to encoding drift or container headers.

  ## Why convert to MP3

  Passing webm/opus straight through makes STT fail decoding intermittently.
  MP3 is stable on every path and has the widest browser playback compatibility.
  """

  require Logger

  # Headroom under the 20-minute limit
  @chunk_seconds 19 * 60
  # Split anything longer than this
  @split_threshold_seconds 20 * 60

  def chunk_seconds, do: @chunk_seconds
  def split_threshold_seconds, do: @split_threshold_seconds

  @doc "Is FFmpeg installed? Without it the entire transcription path fails."
  def available? do
    not is_nil(System.find_executable("ffmpeg")) and
      not is_nil(System.find_executable("ffprobe"))
  end

  @doc "Audio duration in seconds. Measured directly when `duration_seconds` cannot be trusted."
  @spec duration(String.t()) :: {:ok, integer()} | {:error, term()}
  def duration(path) do
    args = [
      "-v",
      "error",
      "-show_entries",
      "format=duration",
      "-of",
      "default=noprint_wrappers=1:nokey=1",
      path
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Float.parse(String.trim(output)) do
          {seconds, _} -> {:ok, trunc(seconds)}
          :error -> {:error, :invalid_duration}
        end

      {error, _} ->
        Logger.error("[Audio] ffprobe failed: #{error}")
        {:error, {:ffprobe_failed, error}}
    end
  end

  @doc "Does this duration require splitting?"
  def needs_splitting?(duration_seconds) when is_integer(duration_seconds),
    do: duration_seconds > @split_threshold_seconds

  def needs_splitting?(_), do: false

  @doc "Is it already MP3? If so, conversion is skipped."
  def mp3?(mime_type) when is_binary(mime_type),
    do:
      String.starts_with?(mime_type, "audio/mpeg") or String.starts_with?(mime_type, "audio/mp3")

  def mp3?(_), do: false

  @doc """
  Converts to MP3. Normalized to **mono, 48kHz** —
  because speaker diarization supports only a single channel.
  """
  @spec to_mp3(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def to_mp3(input, output, opts \\ []) do
    args = [
      "-y",
      "-i",
      input,
      # Drop any video stream mixed in
      "-vn",
      "-acodec",
      "libmp3lame",
      "-ab",
      Keyword.get(opts, :bitrate, "128k"),
      "-ar",
      to_string(Keyword.get(opts, :sample_rate, 48_000)),
      "-ac",
      "1",
      output
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, output}

      {error, code} ->
        Logger.error("[Audio] MP3 conversion failed (#{code}): #{String.slice(error, -800, 800)}")
        {:error, {:transcode_failed, code}}
    end
  end

  @doc """
  Cuts into 19-minute chunks. Returns a list of `{start_seconds, duration_seconds, path}`.

  **No re-encoding** (`-c copy`). Re-encoding just to cut takes minutes on an
  hour-long file and degrades audio quality.
  """
  @spec split(String.t(), String.t(), integer()) ::
          {:ok,
           [
             %{
               index: integer(),
               start_seconds: integer(),
               duration_seconds: integer(),
               path: String.t()
             }
           ]}
          | {:error, term()}
  def split(input, output_dir, total_seconds) do
    File.mkdir_p!(output_dir)
    ext = Path.extname(input)
    count = ceil(total_seconds / @chunk_seconds)

    chunks =
      Enum.map(0..(count - 1), fn index ->
        start = index * @chunk_seconds
        finish = min((index + 1) * @chunk_seconds, total_seconds)

        %{
          index: index,
          start_seconds: start,
          duration_seconds: finish - start,
          path: Path.join(output_dir, "chunk_#{index}#{ext}")
        }
      end)

    results = Enum.map(chunks, &cut(input, &1))

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        {:ok, chunks}

      {:error, reason} ->
        # If even one fails, discard them all. A half-done split is worse.
        cleanup(chunks)
        {:error, reason}
    end
  end

  @doc "Deletes the split files."
  def cleanup(chunks) do
    Enum.each(chunks, fn chunk -> File.rm(chunk.path) end)
    :ok
  end

  @doc "The range as a human-readable label. Shown in the session list."
  def range_label(start_seconds, duration_seconds) do
    "#{clock(start_seconds)}~#{clock(start_seconds + duration_seconds)}"
  end

  defp clock(seconds) do
    minutes = div(seconds, 60)
    "#{minutes}:#{String.pad_leading(to_string(rem(seconds, 60)), 2, "0")}"
  end

  defp cut(input, %{start_seconds: start, duration_seconds: duration, path: output}) do
    args = [
      "-y",
      "-i",
      input,
      "-ss",
      to_string(start),
      "-t",
      to_string(duration),
      # Copy without re-encoding
      "-c",
      "copy",
      # Restart timestamps from 0 at the cut point
      "-avoid_negative_ts",
      "make_zero",
      output
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {error, code} ->
        Logger.error("[Audio] split failed (#{code}): #{String.slice(error, -800, 800)}")
        {:error, {:split_failed, code}}
    end
  end
end
