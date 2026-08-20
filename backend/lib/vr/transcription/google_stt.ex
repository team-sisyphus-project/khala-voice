defmodule VR.Transcription.GoogleSTT do
  @moduledoc """
  Google Cloud Speech-to-Text v2 (Chirp) 클라이언트.

  **출처: sisyphus** `lib/sisyphus/meetings/google_stt.ex` (997줄)
  — 설정 소스를 `VR.Config` 로 바꾸고, Agora 화상 녹화 전용 경로
  (HLS `.m3u8` 다운로드 · MPEG-TS 변환)를 제거했다. 나머지는 그대로다.

  ## 왜 batchRecognize 인가

  동기 `recognize` 는 60초까지만 받는다. 회의는 그보다 길다.
  batch 는 **GCS URI 만 받으므로** 오디오를 임시 버킷에 올렸다가 지우는 왕복이 생긴다.
  이 왕복이 GCS 버킷 설정을 필수로 만드는 이유다.

  ## 흐름

      1. 오디오 다운로드 (S3)
      2. GCS 임시 버킷 업로드
      3. batchRecognize 제출 → operation name
      4. 5초 간격 폴링 (최대 30분)
      5. 결과 GCS 파일 읽기 → 단어를 화자별로 묶기
      6. 임시 파일 정리 (성공·실패 모두)

  ## 개발 모드

  `stt.dev_mode` 를 켜면 실제 호출 없이 목 세그먼트를 준다.
  GCP 자격증명 없이 전체 UI 흐름을 확인할 수 있다.
  """

  alias VR.Config

  require Logger

  @poll_interval_ms 5_000
  @max_poll_attempts 360

  @type segment :: %{
          speaker: String.t(),
          text: String.t(),
          start_ms: integer(),
          end_ms: integer(),
          confidence: float()
        }

  @doc """
  오디오 URL 을 전사한다.

  ## 옵션
  - `:language` — 언어 코드 (기본 `"en-US"`)
  - `:mime_type` — 오디오 형식 (기본 `"audio/mpeg"`)
  - `:min_speakers` / `:max_speakers` — 화자 분리 범위 (기본 1~6)
  """
  @spec transcribe(String.t(), keyword()) :: {:ok, [segment()]} | {:error, term()}
  def transcribe(audio_url, opts \\ []) do
    if dev_mode?() do
      Logger.info("[GoogleSTT] 개발 모드 — 목 전사 결과를 돌려줍니다: #{audio_url}")
      {:ok, mock_segments()}
    else
      with {:ok, config} <- fetch_config(),
           {:ok, token} <- access_token(config),
           {:ok, audio} <- download_audio(audio_url) do
        transcribe_batch(config, token, audio, opts)
      end
    end
  end

  @doc "이 환경에서 전사를 실제로 할 수 있는가."
  def ready? do
    dev_mode?() or match?({:ok, _}, fetch_config())
  end

  def dev_mode?, do: Config.fetch("stt.dev_mode") == true

  # ── 설정 ─────────────────────────────────────────────────

  defp fetch_config do
    credentials = Config.fetch("stt.credentials_json")
    project_id = Config.fetch("stt.project_id")
    gcs_bucket = Config.fetch("stt.gcs_bucket")

    cond do
      blank?(credentials) ->
        {:error, {:missing_config, "stt.credentials_json"}}

      blank?(project_id) ->
        {:error, {:missing_config, "stt.project_id"}}

      blank?(gcs_bucket) ->
        {:error, {:missing_config, "stt.gcs_bucket"}}

      true ->
        {:ok,
         %{
           credentials_json: credentials,
           project_id: project_id,
           location: Config.fetch("stt.location") || "us",
           gcs_bucket: gcs_bucket
         }}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # ── 인증: 서비스 계정 → 액세스 토큰 ─────────────────────

  defp access_token(%{credentials_json: json}) do
    case Jason.decode(json) do
      {:ok, creds} ->
        now = System.system_time(:second)

        claims = %{
          "iss" => creds["client_email"],
          "scope" => "https://www.googleapis.com/auth/cloud-platform",
          "aud" => "https://oauth2.googleapis.com/token",
          "iat" => now,
          "exp" => now + 3600
        }

        with {:ok, jwt} <- sign_jwt(claims, creds["private_key"]) do
          exchange_jwt(jwt)
        end

      {:error, _} ->
        {:error, :invalid_credentials_json}
    end
  end

  defp sign_jwt(claims, private_key) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    signing_input = header <> "." <> payload

    [entry] = :public_key.pem_decode(private_key)
    key = :public_key.pem_entry_decode(entry)
    signature = :public_key.sign(signing_input, :sha256, key)

    {:ok, signing_input <> "." <> Base.url_encode64(signature, padding: false)}
  rescue
    e -> {:error, {:jwt_sign_error, Exception.message(e)}}
  end

  defp exchange_jwt(jwt) do
    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    case Req.post("https://oauth2.googleapis.com/token",
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %{status: status}} ->
        # 응답 본문에 토큰이 섞일 수 있으니 통째로 로그에 남기지 않는다
        Logger.error("[GoogleSTT] 토큰 교환 실패: status=#{status}")
        {:error, {:token_exchange_failed, status}}

      {:error, reason} ->
        {:error, {:token_request_failed, reason}}
    end
  end

  # ── 오디오 다운로드 ──────────────────────────────────────

  defp download_audio(url) do
    case Req.get(url, receive_timeout: 120_000, max_redirects: 5) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:audio_download_failed, status}}

      {:error, reason} ->
        {:error, {:audio_download_error, reason}}
    end
  end

  # ── 배치 전사 ────────────────────────────────────────────

  defp transcribe_batch(config, token, audio, opts) do
    bucket = config.gcs_bucket
    batch_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    mime_type = Keyword.get(opts, :mime_type, "audio/mpeg")
    {ext, content_type} = file_info(mime_type)

    object = "stt-temp/#{batch_id}.#{ext}"
    result_prefix = "stt-results/#{batch_id}/"
    gcs_uri = "gs://#{bucket}/#{object}"
    language = Keyword.get(opts, :language, "en-US")

    Logger.info("[GoogleSTT] 배치 시작: #{gcs_uri} language=#{language} mime=#{mime_type}")

    result =
      with {:ok, _} <- upload_to_gcs(token, bucket, object, audio, content_type),
           {:ok, operation} <-
             submit_batch(
               config,
               token,
               gcs_uri,
               bucket,
               result_prefix,
               language,
               mime_type,
               opts
             ),
           {:ok, response} <- poll(config, token, operation, 0) do
        parse_batch_result(response, token, bucket, result_prefix)
      end

    # 성공하든 실패하든 임시 파일은 지운다. 안 지우면 GCS 비용이 계속 쌓인다.
    delete_gcs_object(token, bucket, object)
    cleanup_results(token, bucket, result_prefix)

    result
  end

  # mime_type → 확장자 · content-type
  defp file_info("audio/webm" <> _), do: {"webm", "audio/webm"}
  defp file_info("audio/mp4" <> _), do: {"mp4", "audio/mp4"}
  defp file_info("audio/m4a" <> _), do: {"m4a", "audio/mp4"}
  defp file_info("audio/ogg" <> _), do: {"ogg", "audio/ogg"}
  defp file_info("audio/wav" <> _), do: {"wav", "audio/wav"}
  defp file_info("audio/x-wav" <> _), do: {"wav", "audio/wav"}
  defp file_info("audio/mpeg" <> _), do: {"mp3", "audio/mpeg"}
  defp file_info("audio/mp3" <> _), do: {"mp3", "audio/mpeg"}
  defp file_info(_), do: {"mp3", "audio/mpeg"}

  # 디코딩 설정.
  # autoDecodingConfig 가 실패하는 조합이 있어 아는 것은 명시한다.
  # https://cloud.google.com/speech-to-text/v2/docs/encoding
  defp decoding_config("audio/webm;codecs=opus"),
    do: explicit("WEBM_OPUS", 48_000)

  defp decoding_config("audio/ogg" <> _), do: explicit("OGG_OPUS", 48_000)
  defp decoding_config("audio/wav" <> _), do: explicit("LINEAR16", 48_000)
  defp decoding_config("audio/x-wav" <> _), do: explicit("LINEAR16", 48_000)
  defp decoding_config("audio/mpeg" <> _), do: explicit("MP3", 16_000)
  defp decoding_config("audio/mp3" <> _), do: explicit("MP3", 16_000)
  defp decoding_config(_), do: %{"autoDecodingConfig" => %{}}

  defp explicit(encoding, sample_rate) do
    %{
      "explicitDecodingConfig" => %{
        "encoding" => encoding,
        "sampleRateHertz" => sample_rate,
        # 모노 전제. 화자 분리가 단일 채널만 지원한다.
        "audioChannelCount" => 1
      }
    }
  end

  defp upload_to_gcs(token, bucket, object, content, content_type) do
    url =
      "https://storage.googleapis.com/upload/storage/v1/b/#{URI.encode(bucket)}" <>
        "/o?uploadType=media&name=#{URI.encode(object)}"

    case Req.post(url,
           body: content,
           headers: [{"authorization", "Bearer #{token}"}, {"content-type", content_type}],
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200}} ->
        {:ok, :uploaded}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[GoogleSTT] GCS 업로드 실패: status=#{status} #{inspect(body)}")
        {:error, {:gcs_upload_failed, status}}

      {:error, reason} ->
        {:error, {:gcs_upload_error, reason}}
    end
  end

  defp submit_batch(config, token, gcs_uri, bucket, prefix, language, mime_type, opts) do
    url =
      "#{speech_endpoint(config)}/v2/projects/#{config.project_id}" <>
        "/locations/#{config.location}/recognizers/_:batchRecognize"

    body = %{
      "files" => [%{"uri" => gcs_uri}],
      "recognitionOutputConfig" => %{
        "gcsOutputConfig" => %{"uri" => "gs://#{bucket}/#{prefix}"}
      },
      "config" =>
        Map.merge(decoding_config(mime_type), %{
          "model" => "chirp_3",
          "languageCodes" => [language],
          "features" => %{
            "enableWordTimeOffsets" => true,
            "diarizationConfig" => %{
              "minSpeakerCount" => Keyword.get(opts, :min_speakers, 1),
              "maxSpeakerCount" => Keyword.get(opts, :max_speakers, 6)
            }
          }
        })
    }

    case Req.post(url,
           json: body,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"name" => operation}}} ->
        Logger.info("[GoogleSTT] 배치 작업 시작: #{operation}")
        {:ok, operation}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[GoogleSTT] 배치 제출 실패: status=#{status} #{inspect(body)}")
        {:error, {:batch_submit_failed, status, body}}

      {:error, reason} ->
        {:error, {:batch_request_failed, reason}}
    end
  end

  # 리전별 엔드포인트. global 만 접두사가 없다.
  defp speech_endpoint(%{location: "global"}), do: "https://speech.googleapis.com"
  defp speech_endpoint(%{location: region}), do: "https://#{region}-speech.googleapis.com"

  defp poll(_config, _token, _operation, attempt) when attempt >= @max_poll_attempts do
    {:error, :transcription_timeout}
  end

  defp poll(config, token, operation, attempt) do
    Process.sleep(@poll_interval_ms)

    url = "#{speech_endpoint(config)}/v2/#{operation}"

    case Req.get(url,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"done" => true} = body}} ->
        if body["error"],
          do: {:error, {:recognition_error, body["error"]}},
          else: {:ok, body}

      {:ok, %{status: 200}} ->
        # 1분마다 한 번만 남긴다. 매번 찍으면 로그가 폴링으로 가득 찬다.
        if rem(attempt, 12) == 0 do
          Logger.info("[GoogleSTT] 진행 중: #{attempt * 5}초 경과 #{operation}")
        end

        poll(config, token, operation, attempt + 1)

      {:ok, %{status: status, body: body}} ->
        Logger.error("[GoogleSTT] 폴링 실패: status=#{status} #{inspect(body)}")
        {:error, {:poll_failed, status}}

      {:error, reason} ->
        # 일시적 네트워크 오류로 전체를 버리지 않는다
        if attempt < @max_poll_attempts - 1 do
          Logger.warning("[GoogleSTT] 폴링 오류(재시도): #{inspect(reason)}")
          poll(config, token, operation, attempt + 1)
        else
          {:error, {:poll_request_failed, reason}}
        end
    end
  end

  # ── 결과 파싱 ────────────────────────────────────────────

  defp parse_batch_result(response, token, bucket, prefix) do
    results = get_in(response, ["response", "results"]) || %{}

    {segments, errors} =
      Enum.reduce(results, {[], []}, fn {file_uri, file_result}, {segs, errs} ->
        cond do
          error = file_result["error"] ->
            message = error["message"] || "알 수 없는 오류"
            Logger.error("[GoogleSTT] 전사 오류 #{file_uri}: #{message}")
            {segs, [{file_uri, message} | errs]}

          output_uri = get_in(file_result, ["cloudStorageResult", "uri"]) || file_result["uri"] ->
            case read_gcs_json(token, output_uri) do
              {:ok, payload} -> {segs ++ parse_result(payload), errs}
              {:error, reason} -> {segs, [{output_uri, reason} | errs]}
            end

          true ->
            # 인라인 결과가 올 때도 있다
            inline = file_result["inlineResult"] || file_result
            {segs ++ parse_result(inline), errs}
        end
      end)

    _ = bucket
    _ = prefix

    cond do
      segments != [] -> {:ok, segments}
      errors != [] -> {:error, {:transcription_failed, errors}}
      # 결과는 왔는데 세그먼트가 없다 = 무음이거나 인식 실패. 오류가 아니다.
      true -> {:ok, []}
    end
  end

  defp read_gcs_json(token, gcs_uri, retries \\ 3) do
    with {:ok, bucket, object} <- parse_gcs_uri(gcs_uri) do
      url =
        "https://storage.googleapis.com/storage/v1/b/#{URI.encode(bucket)}" <>
          "/o/#{URI.encode(object, &URI.char_unreserved?/1)}?alt=media"

      case Req.get(url,
             headers: [{"authorization", "Bearer #{token}"}],
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          {:ok, body}

        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          case Jason.decode(body) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, _} -> {:error, :invalid_json}
          end

        # 작업은 끝났는데 파일이 아직 안 쓰였을 수 있다
        {:ok, %{status: 404}} when retries > 0 ->
          Process.sleep(2_000)
          read_gcs_json(token, gcs_uri, retries - 1)

        {:ok, %{status: status}} ->
          {:error, {:gcs_read_failed, status}}

        {:error, reason} ->
          {:error, {:gcs_read_error, reason}}
      end
    end
  end

  defp parse_gcs_uri("gs://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket, object] -> {:ok, bucket, object}
      _ -> {:error, :invalid_gcs_uri}
    end
  end

  defp parse_gcs_uri(_), do: {:error, :invalid_gcs_uri}

  defp delete_gcs_object(token, bucket, object) do
    url =
      "https://storage.googleapis.com/storage/v1/b/#{URI.encode(bucket)}" <>
        "/o/#{URI.encode(object, &URI.char_unreserved?/1)}"

    Req.delete(url, headers: [{"authorization", "Bearer #{token}"}], receive_timeout: 10_000)
    :ok
  rescue
    _ -> :ok
  end

  defp cleanup_results(token, bucket, prefix) do
    url =
      "https://storage.googleapis.com/storage/v1/b/#{URI.encode(bucket)}" <>
        "/o?prefix=#{URI.encode(prefix)}"

    case Req.get(url, headers: [{"authorization", "Bearer #{token}"}], receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"items" => items}}} when is_list(items) ->
        Enum.each(items, fn item ->
          if name = item["name"], do: delete_gcs_object(token, bucket, name)
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # ── 세그먼트 만들기 ──────────────────────────────────────

  defp parse_result(payload) do
    response = payload["response"] || payload["result"] || payload
    results = response["results"] || payload["results"] || []

    results
    |> Enum.flat_map(fn item ->
      case item["alternatives"] do
        [best | _] -> group_by_speaker(best["words"] || [])
        _ -> []
      end
    end)
    |> merge_adjacent()
  end

  # 단어 단위 결과를 화자별로 묶는다.
  # 화자가 바뀔 때만 새 세그먼트를 연다.
  defp group_by_speaker([]), do: []

  defp group_by_speaker(words) do
    words
    |> Enum.reduce([], fn word, acc ->
      tag = word["speakerLabel"] || word["speakerTag"] || word["speaker_tag"] || 0
      speaker = "speaker_#{tag}"
      text = word["word"] || ""
      start_ms = to_ms(word["startOffset"] || word["start_offset"])
      end_ms = to_ms(word["endOffset"] || word["end_offset"])
      confidence = word["confidence"] || 0.0

      case acc do
        [%{speaker: ^speaker} = last | rest] ->
          [
            %{
              last
              | text: last.text <> " " <> text,
                end_ms: end_ms,
                confidence: (last.confidence + confidence) / 2
            }
            | rest
          ]

        _ ->
          [
            %{
              speaker: speaker,
              text: text,
              start_ms: start_ms,
              end_ms: end_ms,
              confidence: confidence
            }
            | acc
          ]
      end
    end)
    |> Enum.reverse()
  end

  # 파일이 여러 개로 나뉘어 오면 경계에서 같은 화자가 갈라진다. 다시 붙인다.
  defp merge_adjacent(segments) do
    segments
    |> Enum.reduce([], fn seg, acc ->
      case acc do
        [%{speaker: speaker} = prev | rest] when speaker == seg.speaker ->
          [
            %{
              prev
              | text: prev.text <> " " <> seg.text,
                end_ms: seg.end_ms,
                confidence: (prev.confidence + seg.confidence) / 2
            }
            | rest
          ]

        _ ->
          [seg | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp to_ms(nil), do: 0

  defp to_ms(value) when is_binary(value) do
    case Float.parse(String.trim_trailing(value, "s")) do
      {seconds, _} -> round(seconds * 1000)
      :error -> 0
    end
  end

  defp to_ms(value) when is_number(value), do: round(value * 1000)
  defp to_ms(_), do: 0

  # ── 개발 모드 목 데이터 ──────────────────────────────────

  defp mock_segments do
    [
      %{
        speaker: "speaker_1",
        start_ms: 0,
        end_ms: 5_200,
        confidence: 0.95,
        text: "안녕하세요, 오늘 회의를 시작하겠습니다. 첫 번째 안건은 프로젝트 진행 상황입니다."
      },
      %{
        speaker: "speaker_2",
        start_ms: 5_400,
        end_ms: 12_800,
        confidence: 0.93,
        text: "네, 지난주에 이야기한 녹음 기능은 이번 주에 마무리될 것 같습니다."
      },
      %{
        speaker: "speaker_1",
        start_ms: 13_000,
        end_ms: 19_500,
        confidence: 0.94,
        text: "좋습니다. 그러면 4월 30일까지 배포하는 걸로 정하겠습니다."
      },
      %{
        speaker: "speaker_3",
        start_ms: 19_800,
        end_ms: 26_100,
        confidence: 0.91,
        text: "일정은 괜찮은데 QA 인원이 부족합니다. 세 명 정도 더 필요합니다."
      },
      %{
        speaker: "speaker_2",
        start_ms: 26_400,
        end_ms: 31_000,
        confidence: 0.92,
        text: "그 부분은 제가 다음 주 월요일까지 확인해서 공유하겠습니다."
      }
    ]
  end
end
