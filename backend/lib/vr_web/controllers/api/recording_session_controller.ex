defmodule VRWeb.API.RecordingSessionController do
  @moduledoc """
  녹음 세션 REST API.

  ## 흐름

      POST /api/meetings/:id/sessions      세션 생성 (녹음 시작)
      POST /api/uploads/presign            업로드 URL 발급
      (브라우저가 S3에 직접 PUT)
      POST /api/sessions/:id/upload        업로드 등록
      POST /api/sessions/:id/transcribe    전사 큐잉  ← M3
  """

  use VRWeb, :controller

  alias VR.{Meetings, Storage}
  alias VRWeb.API.JSONView

  action_fallback VRWeb.API.FallbackController

  def create(conn, %{"meeting_id" => meeting_id} = params) do
    account = conn.assigns.current_account

    with {:ok, meeting, level} <- Meetings.authorize(meeting_id, account, :lv1),
         :ok <- ensure_active(meeting),
         {:ok, session} <-
           Meetings.create_session(meeting, Map.take(params, ~w(started_at_unix metadata))) do
      conn
      |> put_status(:created)
      |> json(JSONView.session(session, level))
    end
  end

  @doc "S3 업로드가 끝난 뒤 서버에 알린다."
  def upload(conn, %{"id" => id} = params) do
    account = conn.assigns.current_account

    with {:ok, session} <- load_session(id),
         {:ok, meeting, level} <- Meetings.authorize(session.meeting_id, account, :lv1),
         :ok <- ensure_mutable(meeting),
         :ok <- validate_mime(params["mime_type"]),
         # audio_url 은 받지 않는다. 서버가 storage_key 에서 만든다.
         {:ok, updated} <-
           Meetings.register_upload(
             session,
             Map.take(params, ~w(duration_seconds file_size_bytes mime_type))
           ) do
      Meetings.recalculate_totals(meeting)
      json(conn, JSONView.session(updated, level))
    end
  end

  @doc "전사를 시작한다. 20분을 넘으면 분할 워커로 간다."
  def transcribe(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with {:ok, session} <- load_session(id),
         {:ok, meeting, level} <- Meetings.authorize(session.meeting_id, account, :lv1),
         :ok <- ensure_mutable(meeting),
         :ok <- ensure_transcribable(session),
         {:ok, _job} <- VR.Transcription.enqueue(session) do
      # 큐잉만 하고 바로 응답한다. 완료는 폴링·SSE 로 알린다.
      conn
      |> put_status(:accepted)
      |> json(JSONView.session(Meetings.get_session(session.id), level))
    end
  end

  defp ensure_transcribable(%{status: status}) when status in ~w(uploaded failed completed),
    do: :ok

  defp ensure_transcribable(_session), do: {:error, :not_transcribable}

  def delete(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with {:ok, session} <- load_session(id),
         {:ok, meeting, _level} <- Meetings.authorize(session.meeting_id, account, :lv0),
         {:ok, _} <- Meetings.delete_session(session) do
      Meetings.recalculate_totals(meeting)
      send_resp(conn, :no_content, "")
    end
  end

  @doc "화자 매핑 또는 전사 본문 갱신."
  def update_speakers(conn, %{"id" => id} = params) do
    account = conn.assigns.current_account

    with {:ok, session} <- load_session(id),
         {:ok, meeting, level} <- Meetings.authorize(session.meeting_id, account, :lv1),
         :ok <- ensure_mutable(meeting),
         {:ok, updated} <- apply_speaker_update(session, params) do
      json(conn, JSONView.session(updated, level))
    end
  end

  @doc """
  오디오를 준다. **서명된 URL 로 리다이렉트**한다.

  파일을 앱 서버로 흘려보내지 않는다 — 1시간 녹음이 수십 MB다.
  서명 만료가 짧으므로 링크가 새어도 곧 죽는다.

  Viewer(lv2)는 여기 도달하지 못한다. `authorize(:lv1)` 이 `{:error, :not_found}` 를
  주고 404 가 나간다 — 403 을 주면 회의의 존재가 드러난다.
  """
  def audio(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with {:ok, session} <- load_session(id),
         {:ok, _meeting, _level} <- Meetings.authorize(session.meeting_id, account, :lv1),
         {:ok, url} <- presign_audio(session) do
      redirect(conn, external: url)
    end
  end

  # 키가 없는 세션(개발 시드 등)은 줄 것이 없다
  defp presign_audio(%{storage_key: key} = session) when is_binary(key) and key != "" do
    VR.Storage.presign_download(key, expires_in: playback_ttl(session))
  end

  defp presign_audio(_session), do: {:error, :not_found}

  # 재생이 끝나기 전에 서명이 죽으면 안 된다.
  #
  # 브라우저는 리다이렉트로 받은 **서명된 주소**에 대고 Range 요청을 이어간다.
  # 고정 5분을 주면 한 시간짜리 회의는 5분 지점에서 재생이 끊긴다.
  # 그래서 길이에 비례해 주되, 새어 나갔을 때를 생각해 상한을 둔다.
  # 설정값이 있으면 그것을 그대로 따른다 (운영자가 판단한 값이 우선).
  @min_playback_ttl 900
  @max_playback_ttl 21_600

  defp playback_ttl(%{duration_seconds: seconds}) when is_integer(seconds) and seconds > 0 do
    (seconds * 3)
    |> max(@min_playback_ttl)
    |> min(@max_playback_ttl)
  end

  defp playback_ttl(_session), do: @min_playback_ttl

  # 아카이브된 회의는 읽기 전용이다. 지금까지는 create 에만 걸려 있어
  # 아카이브 후에도 전사본을 고칠 수 있었다.
  defp ensure_mutable(%{status: "archived"}), do: {:error, :meeting_archived}
  defp ensure_mutable(_meeting), do: :ok

  # ── 내부 ─────────────────────────────────────────────────

  defp apply_speaker_update(session, params) do
    attrs =
      %{}
      |> maybe_put(:speaker_map, params["speaker_map"])
      |> maybe_put(:transcript, params["transcript"])

    if attrs == %{} do
      {:error, :nothing_to_update}
    else
      Meetings.update_transcript(session, attrs)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp load_session(id) do
    case Meetings.get_session(id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  defp ensure_active(%{status: "active"}), do: :ok
  defp ensure_active(_meeting), do: {:error, :meeting_not_active}

  defp validate_mime(nil), do: :ok

  defp validate_mime(mime) do
    if Storage.allowed_mime?(mime), do: :ok, else: {:error, :unsupported_media_type}
  end
end
