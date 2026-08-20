defmodule VRWeb.API.FallbackController do
  @moduledoc """
  API 공통 오류 응답.

  **권한 없음은 404로 낸다.** 403을 주면 "그 리소스는 있는데 네가 못 볼 뿐"이라는
  정보가 새어 나간다.
  """

  use VRWeb, :controller

  def call(conn, {:error, :not_found}), do: error(conn, 404, "not_found", "찾을 수 없습니다")

  def call(conn, {:error, :unauthorized}),
    do: error(conn, 401, "unauthorized", "로그인이 필요합니다")

  def call(conn, {:error, :gone}), do: error(conn, 410, "gone", "만료되었습니다")

  def call(conn, {:error, {:missing_config, key}}) do
    error(conn, 503, "not_configured", "서버 설정이 완료되지 않았습니다 (#{key})")
  end

  def call(conn, {:error, :presign_failed}),
    do: error(conn, 503, "storage_unavailable", "업로드 URL을 만들지 못했습니다")

  def call(conn, {:error, :summarize_unavailable}),
    do: error(conn, 503, "summarize_unavailable", "AI 요약이 설정되지 않았습니다")

  def call(conn, {:error, :no_transcript}),
    do: error(conn, 422, "no_transcript", "요약할 전사가 없습니다")

  def call(conn, {:error, :meeting_archived}),
    do: error(conn, 422, "meeting_archived", "아카이브된 회의는 수정할 수 없습니다")

  def call(conn, {:error, :invalid_pincode}),
    do: error(conn, 401, "invalid_pincode", "PIN이 올바르지 않습니다")

  def call(conn, {:error, :locked}),
    do: error(conn, 429, "too_many_attempts", "시도가 너무 많습니다. 잠시 후 다시 해주세요")

  def call(conn, {:error, :invalid_request}),
    do: error(conn, 422, "invalid_request", "요청 형식이 올바르지 않습니다")

  def call(conn, {:error, :khala_not_connected}),
    do: error(conn, 409, "khala_not_connected", "칼라에 연결되어 있지 않습니다")

  def call(conn, {:error, :khala_reconnect_required}),
    do: error(conn, 409, "khala_reconnect_required", "칼라 연결이 만료되었습니다. 다시 연결해 주세요")

  def call(conn, {:error, :bad_request}),
    do: error(conn, 400, "bad_request", "요청 형식이 올바르지 않습니다")

  def call(conn, {:error, :already_uploaded}),
    do: error(conn, 422, "already_uploaded", "이미 업로드가 끝난 세션입니다")

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(422)
    |> json(%{
      status: "error",
      code: "validation_failed",
      errors: translate_errors(changeset)
    })
  end

  def call(conn, {:error, reason}) when is_atom(reason),
    do: error(conn, 422, to_string(reason), "요청을 처리하지 못했습니다")

  def call(conn, nil), do: error(conn, 404, "not_found", "찾을 수 없습니다")

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{status: "error", code: code, message: message})
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
