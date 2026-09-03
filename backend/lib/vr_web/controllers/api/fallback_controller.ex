defmodule VRWeb.API.FallbackController do
  @moduledoc """
  Common API error responses.

  **Missing permission is returned as 404.** Responding with 403 leaks the
  information that "the resource exists — you just can't see it."
  """

  use VRWeb, :controller

  def call(conn, {:error, :not_found}), do: error(conn, 404, "not_found", "Not found")

  def call(conn, {:error, :unauthorized}),
    do: error(conn, 401, "unauthorized", "Sign in required")

  def call(conn, {:error, :gone}), do: error(conn, 410, "gone", "This link has expired")

  def call(conn, {:error, {:missing_config, key}}) do
    error(conn, 503, "not_configured", "Server configuration is incomplete (#{key})")
  end

  def call(conn, {:error, :presign_failed}),
    do: error(conn, 503, "storage_unavailable", "Could not create an upload URL")

  def call(conn, {:error, :summarize_unavailable}),
    do: error(conn, 503, "summarize_unavailable", "AI summarization is not configured")

  def call(conn, {:error, :no_transcript}),
    do: error(conn, 422, "no_transcript", "There is no transcript to summarize")

  def call(conn, {:error, :meeting_archived}),
    do: error(conn, 422, "meeting_archived", "Archived meetings cannot be modified")

  def call(conn, {:error, :invalid_pincode}),
    do: error(conn, 401, "invalid_pincode", "Incorrect PIN")

  def call(conn, {:error, :locked}),
    do: error(conn, 429, "too_many_attempts", "Too many attempts. Please try again later")

  def call(conn, {:error, :invalid_request}),
    do: error(conn, 422, "invalid_request", "The request format is invalid")

  def call(conn, {:error, :khala_not_connected}),
    do: error(conn, 409, "khala_not_connected", "Not connected to Khala")

  def call(conn, {:error, :khala_reconnect_required}),
    do: error(conn, 409, "khala_reconnect_required", "The Khala connection has expired. Please reconnect")

  def call(conn, {:error, :bad_request}),
    do: error(conn, 400, "bad_request", "The request format is invalid")

  def call(conn, {:error, :already_uploaded}),
    do: error(conn, 422, "already_uploaded", "This session has already finished uploading")

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
    do: error(conn, 422, to_string(reason), "Could not process the request")

  def call(conn, nil), do: error(conn, 404, "not_found", "Not found")

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
