defmodule VR.Storage do
  @moduledoc """
  오디오·전사본 저장소.

  어댑터 뒤에 둔다. 지금은 S3 하나지만, STT가 GCS를 요구하므로
  나중에 GCS 단일화로 바꿀 여지를 남겨둔다 (`docs/01-overview.md` A2).
  """

  @adapter VR.Storage.S3

  @doc """
  브라우저가 직접 올릴 presigned PUT URL을 발급한다.

  서버를 거치지 않는 이유: 1시간짜리 녹음이 수십 MB가 되는데
  그걸 앱 서버로 통과시키면 메모리와 대역폭이 그대로 낭비된다.
  """
  defdelegate presign_upload(opts), to: @adapter

  @doc """
  다운로드용 URL. CDN이 설정돼 있으면 그쪽을 쓴다.

  **서명이 없다.** 사용자에게 직접 내려보내지 말고 `presign_download/2` 를 써라 —
  저장 키가 결정적이라 서명 없는 URL 은 곧 영구 공개 링크다.
  """
  defdelegate public_url(key), to: @adapter

  @doc "서명된 다운로드 URL. 사용자에게 오디오를 줄 때는 항상 이것을 쓴다."
  defdelegate presign_download(key, opts), to: @adapter

  @doc """
  우리 버킷/CDN 의 오브젝트인가. 워커가 따라가도 되는 URL 인지 판정한다.

  클라이언트가 준 주소를 그대로 GET 하면 사설망·메타데이터 엔드포인트로
  서버를 보낼 수 있다 (SSRF).
  """
  defdelegate own_object_url?(url), to: @adapter

  @doc """
  서버에서 직접 올린다. 분할된 청크처럼 **서버가 만든 파일**에만 쓴다.

  사용자 업로드는 presign 으로 브라우저가 직접 올린다 — 큰 파일을
  앱 서버로 통과시키면 메모리와 대역폭이 낭비된다.
  """
  defdelegate put_object(key, body, content_type), to: @adapter

  @doc "설정이 갖춰졌는가."
  defdelegate configured?(), to: @adapter

  @doc "녹음 파일의 저장 경로."
  def recording_key(meeting_id, session_id, started_at_unix, ext) do
    "data/meetings/#{meeting_id}/sessions/#{session_id}/#{started_at_unix}.#{ext}"
  end

  @doc "전사본 저장 경로."
  def transcript_key(meeting_id, session_id, started_at_unix) do
    "data/meetings/#{meeting_id}/sessions/#{session_id}/#{started_at_unix}.json"
  end

  @doc """
  MIME 타입에서 확장자를 얻는다.

  브라우저마다 다른 값을 준다. Chrome/Firefox 는 webm, Safari 는 mp4.
  """
  def extension_for("audio/webm" <> _), do: "webm"
  def extension_for("audio/ogg" <> _), do: "ogg"
  def extension_for("audio/mp4" <> _), do: "m4a"
  def extension_for("audio/mpeg"), do: "mp3"
  def extension_for("audio/wav"), do: "wav"
  def extension_for("audio/x-wav"), do: "wav"
  def extension_for(_), do: "bin"

  @doc "업로드를 허용하는 오디오 MIME 목록."
  def allowed_mime?(mime) when is_binary(mime) do
    base = mime |> String.split(";") |> List.first() |> String.trim()
    base in ~w(audio/webm audio/ogg audio/mp4 audio/mpeg audio/wav audio/x-wav)
  end

  def allowed_mime?(_), do: false
end
