defmodule VR.Storage do
  @moduledoc """
  Storage for audio and transcripts.

  Kept behind an adapter. It is just S3 for now, but since STT requires GCS,
  we leave room to consolidate on GCS later (`docs/01-overview.md` A2).
  """

  @adapter VR.Storage.S3

  @doc """
  Issues a presigned PUT URL for the browser to upload directly.

  Why it does not go through the server: an hour-long recording runs to tens of
  MB, and piping that through the app server wastes memory and bandwidth outright.
  """
  defdelegate presign_upload(opts), to: @adapter

  @doc """
  Download URL. Uses the CDN if one is configured.

  **Unsigned.** Do not hand this to users directly — use `presign_download/2`.
  Storage keys are deterministic, so an unsigned URL is effectively a permanent
  public link.
  """
  defdelegate public_url(key), to: @adapter

  @doc "Signed download URL. Always use this when giving audio to a user."
  defdelegate presign_download(key, opts), to: @adapter

  @doc """
  Is this an object in our bucket/CDN? Decides whether a worker may follow the URL.

  GETting a client-supplied address as-is can send the server to private
  networks or metadata endpoints (SSRF).
  """
  defdelegate own_object_url?(url), to: @adapter

  @doc """
  Uploads directly from the server. Only for **server-generated files**, such as
  split chunks.

  User uploads go straight from the browser via presign — piping large files
  through the app server wastes memory and bandwidth.
  """
  defdelegate put_object(key, body, content_type), to: @adapter

  @doc "Is the configuration complete?"
  defdelegate configured?(), to: @adapter

  @doc "Storage path for a recording file."
  def recording_key(meeting_id, session_id, started_at_unix, ext) do
    "data/meetings/#{meeting_id}/sessions/#{session_id}/#{started_at_unix}.#{ext}"
  end

  @doc "Storage path for a transcript."
  def transcript_key(meeting_id, session_id, started_at_unix) do
    "data/meetings/#{meeting_id}/sessions/#{session_id}/#{started_at_unix}.json"
  end

  @doc """
  Gets the file extension from a MIME type.

  Browsers report different values. Chrome/Firefox use webm, Safari uses mp4.
  """
  def extension_for("audio/webm" <> _), do: "webm"
  def extension_for("audio/ogg" <> _), do: "ogg"
  def extension_for("audio/mp4" <> _), do: "m4a"
  def extension_for("audio/mpeg"), do: "mp3"
  def extension_for("audio/wav"), do: "wav"
  def extension_for("audio/x-wav"), do: "wav"
  def extension_for(_), do: "bin"

  @doc "Audio MIME types allowed for upload."
  def allowed_mime?(mime) when is_binary(mime) do
    base = mime |> String.split(";") |> List.first() |> String.trim()
    base in ~w(audio/webm audio/ogg audio/mp4 audio/mpeg audio/wav audio/x-wav)
  end

  def allowed_mime?(_), do: false
end
