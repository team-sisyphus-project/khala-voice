defmodule VR.Storage.S3 do
  @moduledoc """
  AWS S3 presigned URL 발급.

  sisyphus는 이 발급을 n8n 웹훅에 위임했다. 이 앱은 직접 서명한다.
  SigV4 구현은 `ExAws`가 한다 — 직접 짜지 않는다.

  자격증명은 `VR.Config`에서 요청 시점에 읽는다.
  어드민에서 키를 바꾸면 재배포 없이 즉시 반영된다.
  """

  alias VR.Config

  require Logger

  # presign 만료. 업로드가 느린 회선에서도 끝날 만큼은 주되,
  # 유출됐을 때의 창은 좁게.
  @expires_in 1800

  # 다운로드 서명 만료. 재생을 시작하기엔 충분하고 링크가 새어도 곧 죽는다.
  @download_expires_in 300

  @doc """
  PUT 용 presigned URL.

  ## 옵션
  - `:key` — S3 오브젝트 키 (필수)
  - `:content_type` — 업로드 시 보낼 Content-Type (서명에 포함된다)
  - `:expires_in` — 초 (기본 1800)
  """
  def presign_upload(opts) do
    key = Keyword.fetch!(opts, :key)
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    expires_in = Keyword.get(opts, :expires_in, @expires_in)

    with {:ok, config} <- aws_config(),
         {:ok, bucket} <- fetch_required("storage.bucket") do
      # Content-Type 을 서명에 넣는다. 클라이언트가 다른 타입으로 올리면 S3가 거부한다.
      result =
        ExAws.Config.new(:s3, config)
        |> ExAws.S3.presigned_url(:put, bucket, key,
          expires_in: expires_in,
          query_params: [],
          headers: [{"content-type", content_type}]
        )

      case result do
        {:ok, url} ->
          {:ok,
           %{
             upload_url: url,
             download_url: public_url(key),
             key: key,
             expires_in: expires_in,
             content_type: content_type
           }}

        {:error, reason} ->
          Logger.error("[Storage] presign 실패: #{inspect(reason)}")
          {:error, :presign_failed}
      end
    end
  end

  @doc """
  GET 용 presigned URL.

  ## 왜 서명 없는 URL 을 쓰지 않는가

  `recording_key/4` 는 `meeting_id` · `session_id` · `started_at_unix` · 확장자로
  **완전히 결정된다.** 이 값들은 회의를 볼 수 있는 사람이면 API 응답으로 다 받는다.
  그래서 응답에서 `audio_url` 필드만 지우는 것으로는 Viewer 마스킹이 되지 않는다 —
  키를 손으로 조립하면 그만이다. 서명을 붙이고 **버킷을 비공개로 두어야** 닫힌다.

  ## 옵션
  - `:expires_in` — 초. 없으면 `storage.download_url_ttl_seconds` 설정, 그것도 없으면 300
  """
  def presign_download(key, opts \\ [])

  def presign_download(nil, _opts), do: {:error, :no_storage_key}
  def presign_download("", _opts), do: {:error, :no_storage_key}

  def presign_download(key, opts) when is_binary(key) do
    # 운영자가 설정한 값이 있으면 그것이 최종이다. 없을 때만 호출부 판단을 쓴다.
    expires_in =
      configured_download_ttl() || Keyword.get(opts, :expires_in) || @download_expires_in

    with {:ok, config} <- aws_config(),
         {:ok, bucket} <- fetch_required("storage.bucket") do
      ExAws.Config.new(:s3, config)
      |> ExAws.S3.presigned_url(:get, bucket, key, expires_in: expires_in)
      |> case do
        {:ok, url} ->
          {:ok, url}

        {:error, reason} ->
          Logger.error("[Storage] 다운로드 presign 실패: #{inspect(reason)}")
          {:error, :presign_failed}
      end
    end
  end

  defp configured_download_ttl do
    case Config.fetch("storage.download_url_ttl_seconds") do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parse_ttl(value)
      _ -> nil
    end
  end

  defp parse_ttl(value) do
    case Integer.parse(value) do
      {seconds, _} when seconds > 0 -> seconds
      _ -> nil
    end
  end

  @doc """
  우리 버킷이나 CDN 의 오브젝트를 가리키는 URL 인가.

  워커가 오디오를 내려받기 전에 확인한다. 클라이언트가 준 주소를 그대로
  따라가면 사설망·클라우드 메타데이터 엔드포인트로 서버를 보낼 수 있다.
  """
  def own_object_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host = String.downcase(host)
        host != "" and (host == bucket_host() or host in cdn_hosts())

      _ ->
        false
    end
  end

  def own_object_url?(_), do: false

  defp bucket_host do
    with bucket when is_binary(bucket) <- Config.fetch("storage.bucket"),
         region when is_binary(region) <- Config.fetch("storage.region") do
      String.downcase("#{bucket}.s3.#{region}.amazonaws.com")
    else
      _ -> nil
    end
  end

  defp cdn_hosts do
    case Config.fetch("storage.cdn_base_url") do
      base when is_binary(base) and base != "" ->
        case URI.parse(base) do
          %URI{host: host} when is_binary(host) -> [String.downcase(host)]
          _ -> []
        end

      _ ->
        []
    end
  end

  @doc "서버에서 직접 올린다. 분할 청크 등 서버가 만든 파일용."
  def put_object(key, body, content_type) do
    with {:ok, config} <- aws_config(),
         {:ok, bucket} <- fetch_required("storage.bucket") do
      bucket
      |> ExAws.S3.put_object(key, body, content_type: content_type)
      |> ExAws.request(config)
      |> case do
        {:ok, _} ->
          {:ok, %{key: key, download_url: public_url(key)}}

        {:error, reason} ->
          Logger.error("[Storage] 업로드 실패: #{inspect(reason)}")
          {:error, :upload_failed}
      end
    end
  end

  @doc "다운로드 URL. CDN 도메인이 있으면 그쪽으로."
  def public_url(key) do
    case Config.fetch("storage.cdn_base_url") do
      nil -> s3_url(key)
      "" -> s3_url(key)
      base -> String.trim_trailing(base, "/") <> "/" <> key
    end
  end

  defp s3_url(key) do
    bucket = Config.fetch("storage.bucket")
    region = Config.fetch("storage.region")
    "https://#{bucket}.s3.#{region}.amazonaws.com/#{key}"
  end

  @doc "필수 설정이 모두 있는가."
  def configured? do
    Enum.all?(
      ~w(storage.bucket storage.region storage.access_key_id storage.secret_access_key),
      &Config.configured?/1
    )
  end

  # ── 내부 ─────────────────────────────────────────────────

  defp aws_config do
    with {:ok, access_key_id} <- fetch_required("storage.access_key_id"),
         {:ok, secret_access_key} <- fetch_required("storage.secret_access_key"),
         {:ok, region} <- fetch_required("storage.region") do
      {:ok,
       [
         access_key_id: access_key_id,
         secret_access_key: secret_access_key,
         region: region
       ]}
    end
  end

  defp fetch_required(key) do
    case Config.fetch(key) do
      nil -> {:error, {:missing_config, key}}
      "" -> {:error, {:missing_config, key}}
      value -> {:ok, value}
    end
  end
end
