defmodule VR.Transcription.Audio do
  @moduledoc """
  FFmpeg 로 오디오를 다루는 것들 — 길이 확인 · 분할 · MP3 변환.

  **출처: sisyphus** `lib/sisyphus/meetings/audio_splitter.ex` — 거의 그대로.

  ## 왜 19분인가

  Google STT `batchRecognize` 에 길이 제한이 있어 20분을 넘기면 실패한다.
  19분으로 자르는 것은 **여유를 두기 위해서**다. 정확히 20분으로 자르면
  인코딩 오차나 컨테이너 헤더 때문에 경계에서 걸린다.

  ## 왜 MP3 로 바꾸는가

  webm/opus 를 그대로 넘기면 STT 가 간헐적으로 디코딩에 실패한다.
  MP3 는 어느 경로에서도 안정적이고, 브라우저 재생 호환성도 가장 넓다.
  """

  require Logger

  # 20분 제한에 여유를 둔다
  @chunk_seconds 19 * 60
  # 이보다 길면 분할한다
  @split_threshold_seconds 20 * 60

  def chunk_seconds, do: @chunk_seconds
  def split_threshold_seconds, do: @split_threshold_seconds

  @doc "FFmpeg 이 설치돼 있는가. 없으면 전사 경로 전체가 실패한다."
  def available? do
    not is_nil(System.find_executable("ffmpeg")) and
      not is_nil(System.find_executable("ffprobe"))
  end

  @doc "오디오 길이(초). `duration_seconds` 를 못 믿을 때 실측한다."
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
        Logger.error("[Audio] ffprobe 실패: #{error}")
        {:error, {:ffprobe_failed, error}}
    end
  end

  @doc "이 길이면 분할이 필요한가."
  def needs_splitting?(duration_seconds) when is_integer(duration_seconds),
    do: duration_seconds > @split_threshold_seconds

  def needs_splitting?(_), do: false

  @doc "이미 MP3 인가. 맞으면 변환을 건너뛴다."
  def mp3?(mime_type) when is_binary(mime_type),
    do:
      String.starts_with?(mime_type, "audio/mpeg") or String.starts_with?(mime_type, "audio/mp3")

  def mp3?(_), do: false

  @doc """
  MP3 로 변환한다. **모노 · 48kHz** 로 맞춘다 —
  화자 분리가 단일 채널만 지원하기 때문이다.
  """
  @spec to_mp3(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def to_mp3(input, output, opts \\ []) do
    args = [
      "-y",
      "-i",
      input,
      # 비디오 스트림이 섞여 있으면 버린다
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
        Logger.error("[Audio] MP3 변환 실패(#{code}): #{String.slice(error, -800, 800)}")
        {:error, {:transcode_failed, code}}
    end
  end

  @doc """
  19분 단위로 자른다. `{시작초, 길이초, 경로}` 목록을 돌려준다.

  **재인코딩하지 않는다** (`-c copy`). 자르기만 하는데 다시 인코딩하면
  1시간짜리에서 몇 분씩 걸리고 음질도 떨어진다.
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
        # 하나라도 실패하면 전부 버린다. 반쪽짜리 분할은 더 나쁘다.
        cleanup(chunks)
        {:error, reason}
    end
  end

  @doc "분할 파일을 지운다."
  def cleanup(chunks) do
    Enum.each(chunks, fn chunk -> File.rm(chunk.path) end)
    :ok
  end

  @doc "구간을 사람이 읽을 수 있는 라벨로. 세션 목록에 표시한다."
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
      # 재인코딩 없이 복사
      "-c",
      "copy",
      # 잘린 지점의 타임스탬프를 0부터 다시 센다
      "-avoid_negative_ts",
      "make_zero",
      output
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {error, code} ->
        Logger.error("[Audio] 분할 실패(#{code}): #{String.slice(error, -800, 800)}")
        {:error, {:split_failed, code}}
    end
  end
end
