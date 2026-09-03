defmodule VR.Storage.S3 do
  @moduledoc """
  AWS S3 presigned URL issuance.

  sisyphus delegated this issuance to an n8n webhook. This app signs directly.
  The SigV4 implementation is `ExAws`'s — we do not hand-roll it.

  Credentials are read from `VR.Config` at request time.
  Changing keys in the admin takes effect immediately without a redeploy.
  """

  alias VR.Config

  require Logger

  # Presign expiry. Long enough for an upload to finish on a slow connection,
  # but a narrow window if it leaks.
  @expires_in 1800

  # Download signature expiry. Enough to start playback, and the link dies soon
  # even if it leaks.
  @download_expires_in 300

  @doc """
  Presigned URL for PUT.

  ## Options
  - `:key` — S3 object key (required)
  - `:content_type` — the Content-Type to send on upload (included in the signature)
  - `:expires_in` — seconds (default 1800)
  """
  def presign_upload(opts) do
    key = Keyword.fetch!(opts, :key)
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    expires_in = Keyword.get(opts, :expires_in, @expires_in)

    with {:ok, config} <- aws_config(),
         {:ok, bucket} <- fetch_required("storage.bucket") do
      # Content-Type goes into the signature. If the client uploads with a
      # different type, S3 rejects it.
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
          Logger.error("[Storage] presign failed: #{inspect(reason)}")
          {:error, :presign_failed}
      end
    end
  end

  @doc """
  Presigned URL for GET.

  ## Why we do not use unsigned URLs

  `recording_key/4` is **fully determined** by `meeting_id`, `session_id`,
  `started_at_unix`, and the extension. Anyone who can view the meeting receives
  all of these in API responses. So merely removing the `audio_url` field from a
  response does not mask it from Viewers — they can assemble the key by hand.
  Only signing plus **keeping the bucket private** closes this.

  ## Options
  - `:expires_in` — seconds. Falls back to the `storage.download_url_ttl_seconds`
    setting, then to 300
  """
  def presign_download(key, opts \\ [])

  def presign_download(nil, _opts), do: {:error, :no_storage_key}
  def presign_download("", _opts), do: {:error, :no_storage_key}

  def presign_download(key, opts) when is_binary(key) do
    # An operator-configured value is final. The caller's choice is used only
    # when there is none.
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
          Logger.error("[Storage] download presign failed: #{inspect(reason)}")
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
  Does this URL point to an object in our bucket or CDN?

  Checked before a worker downloads audio. Following a client-supplied address
  as-is can send the server to private networks or cloud metadata endpoints.
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

  @doc "Uploads directly from the server. For server-generated files such as split chunks."
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
          Logger.error("[Storage] upload failed: #{inspect(reason)}")
          {:error, :upload_failed}
      end
    end
  end

  @doc "Download URL. Uses the CDN domain when one is set."
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

  @doc "Are all required settings present?"
  def configured? do
    Enum.all?(
      ~w(storage.bucket storage.region storage.access_key_id storage.secret_access_key),
      &Config.configured?/1
    )
  end

  # ── Internal ─────────────────────────────────────────────

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
