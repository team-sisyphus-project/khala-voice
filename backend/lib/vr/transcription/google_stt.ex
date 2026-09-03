defmodule VR.Transcription.GoogleSTT do
  @moduledoc """
  Google Cloud Speech-to-Text v2 (Chirp) client.

  **Source: sisyphus** `lib/sisyphus/meetings/google_stt.ex` (997 lines)
  — the configuration source was switched to `VR.Config`, and the Agora video
  recording path (HLS `.m3u8` download, MPEG-TS conversion) was removed.
  The rest is unchanged.

  ## Why batchRecognize

  The synchronous `recognize` accepts at most 60 seconds. Meetings run longer.
  Batch **only accepts GCS URIs**, so there is a round trip of uploading the
  audio to a temporary bucket and deleting it. That round trip is why a GCS
  bucket setting is mandatory.

  ## Flow

      1. Download audio (S3)
      2. Upload to temporary GCS bucket
      3. Submit batchRecognize → operation name
      4. Poll every 5 seconds (up to 30 minutes)
      5. Read the result GCS file → group words by speaker
      6. Clean up temporary files (on both success and failure)

  ## Dev mode

  With `stt.dev_mode` on, mock segments are returned without any real calls.
  The full UI flow can be verified without GCP credentials.
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
  Transcribes an audio URL.

  ## Options
  - `:language` — language code (default `"en-US"`)
  - `:mime_type` — audio format (default `"audio/mpeg"`)
  - `:min_speakers` / `:max_speakers` — speaker diarization range (default 1–6)
  """
  @spec transcribe(String.t(), keyword()) :: {:ok, [segment()]} | {:error, term()}
  def transcribe(audio_url, opts \\ []) do
    if dev_mode?() do
      Logger.info("[GoogleSTT] dev mode — returning mock transcription result: #{audio_url}")
      {:ok, mock_segments()}
    else
      with {:ok, config} <- fetch_config(),
           {:ok, token} <- access_token(config),
           {:ok, audio} <- download_audio(audio_url) do
        transcribe_batch(config, token, audio, opts)
      end
    end
  end

  @doc "Can transcription actually run in this environment?"
  def ready? do
    dev_mode?() or match?({:ok, _}, fetch_config())
  end

  def dev_mode?, do: Config.fetch("stt.dev_mode") == true

  # ── Configuration ────────────────────────────────────────

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

  # ── Auth: service account → access token ─────────────────

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
        # The response body may contain a token, so never log it whole
        Logger.error("[GoogleSTT] token exchange failed: status=#{status}")
        {:error, {:token_exchange_failed, status}}

      {:error, reason} ->
        {:error, {:token_request_failed, reason}}
    end
  end

  # ── Audio download ───────────────────────────────────────

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

  # ── Batch transcription ──────────────────────────────────

  defp transcribe_batch(config, token, audio, opts) do
    bucket = config.gcs_bucket
    batch_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    mime_type = Keyword.get(opts, :mime_type, "audio/mpeg")
    {ext, content_type} = file_info(mime_type)

    object = "stt-temp/#{batch_id}.#{ext}"
    result_prefix = "stt-results/#{batch_id}/"
    gcs_uri = "gs://#{bucket}/#{object}"
    language = Keyword.get(opts, :language, "en-US")

    Logger.info("[GoogleSTT] batch started: #{gcs_uri} language=#{language} mime=#{mime_type}")

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

    # Temporary files are deleted whether we succeed or fail. Otherwise GCS
    # costs keep piling up.
    delete_gcs_object(token, bucket, object)
    cleanup_results(token, bucket, result_prefix)

    result
  end

  # mime_type → extension, content-type
  defp file_info("audio/webm" <> _), do: {"webm", "audio/webm"}
  defp file_info("audio/mp4" <> _), do: {"mp4", "audio/mp4"}
  defp file_info("audio/m4a" <> _), do: {"m4a", "audio/mp4"}
  defp file_info("audio/ogg" <> _), do: {"ogg", "audio/ogg"}
  defp file_info("audio/wav" <> _), do: {"wav", "audio/wav"}
  defp file_info("audio/x-wav" <> _), do: {"wav", "audio/wav"}
  defp file_info("audio/mpeg" <> _), do: {"mp3", "audio/mpeg"}
  defp file_info("audio/mp3" <> _), do: {"mp3", "audio/mpeg"}
  defp file_info(_), do: {"mp3", "audio/mpeg"}

  # Decoding configuration.
  # Some combinations fail with autoDecodingConfig, so known ones are explicit.
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
        # Mono assumed. Speaker diarization supports only a single channel.
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
        Logger.error("[GoogleSTT] GCS upload failed: status=#{status} #{inspect(body)}")
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
        Logger.info("[GoogleSTT] batch operation started: #{operation}")
        {:ok, operation}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[GoogleSTT] batch submit failed: status=#{status} #{inspect(body)}")
        {:error, {:batch_submit_failed, status, body}}

      {:error, reason} ->
        {:error, {:batch_request_failed, reason}}
    end
  end

  # Per-region endpoints. Only global has no prefix.
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
        # Logged only once a minute. Logging every attempt fills the log with polling.
        if rem(attempt, 12) == 0 do
          Logger.info("[GoogleSTT] in progress: #{attempt * 5}s elapsed #{operation}")
        end

        poll(config, token, operation, attempt + 1)

      {:ok, %{status: status, body: body}} ->
        Logger.error("[GoogleSTT] polling failed: status=#{status} #{inspect(body)}")
        {:error, {:poll_failed, status}}

      {:error, reason} ->
        # A transient network error should not throw away the whole run
        if attempt < @max_poll_attempts - 1 do
          Logger.warning("[GoogleSTT] polling error (retrying): #{inspect(reason)}")
          poll(config, token, operation, attempt + 1)
        else
          {:error, {:poll_request_failed, reason}}
        end
    end
  end

  # ── Result parsing ───────────────────────────────────────

  defp parse_batch_result(response, token, bucket, prefix) do
    results = get_in(response, ["response", "results"]) || %{}

    {segments, errors} =
      Enum.reduce(results, {[], []}, fn {file_uri, file_result}, {segs, errs} ->
        cond do
          error = file_result["error"] ->
            message = error["message"] || "unknown error"
            Logger.error("[GoogleSTT] transcription error #{file_uri}: #{message}")
            {segs, [{file_uri, message} | errs]}

          output_uri = get_in(file_result, ["cloudStorageResult", "uri"]) || file_result["uri"] ->
            case read_gcs_json(token, output_uri) do
              {:ok, payload} -> {segs ++ parse_result(payload), errs}
              {:error, reason} -> {segs, [{output_uri, reason} | errs]}
            end

          true ->
            # Sometimes an inline result arrives
            inline = file_result["inlineResult"] || file_result
            {segs ++ parse_result(inline), errs}
        end
      end)

    _ = bucket
    _ = prefix

    cond do
      segments != [] -> {:ok, segments}
      errors != [] -> {:error, {:transcription_failed, errors}}
      # A result came back but with no segments = silence or recognition
      # failure. Not an error.
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

        # The operation may be done while the file has not been written yet
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

  # ── Building segments ────────────────────────────────────

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

  # Groups word-level results by speaker.
  # A new segment opens only when the speaker changes.
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

  # When a file arrives split into pieces, the same speaker is cut apart at the
  # boundaries. Stitch them back together.
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

  # ── Dev-mode mock data ───────────────────────────────────

  defp mock_segments do
    [
      %{
        speaker: "speaker_1",
        start_ms: 0,
        end_ms: 5_200,
        confidence: 0.95,
        text: "Hello everyone, let's start today's meeting. The first item is the project status."
      },
      %{
        speaker: "speaker_2",
        start_ms: 5_400,
        end_ms: 12_800,
        confidence: 0.93,
        text: "Sure, the recording feature we discussed last week should be wrapped up this week."
      },
      %{
        speaker: "speaker_1",
        start_ms: 13_000,
        end_ms: 19_500,
        confidence: 0.94,
        text: "Great. Then let's set the release for April 30th."
      },
      %{
        speaker: "speaker_3",
        start_ms: 19_800,
        end_ms: 26_100,
        confidence: 0.91,
        text: "The schedule is fine, but we are short on QA staff. We need about three more people."
      },
      %{
        speaker: "speaker_2",
        start_ms: 26_400,
        end_ms: 31_000,
        confidence: 0.92,
        text: "I will check on that and share an update by next Monday."
      }
    ]
  end
end
