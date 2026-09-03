defmodule VR.Summarize.LLM.HTTP do
  @moduledoc """
  HTTP handling shared by the adapters.

  ## Why it lives separately

  If the three providers each called `Req.post` themselves, timeout, error
  classification, and retry policy would fork three ways. The fallback
  decision (`LLM.retryable?/1`) depends on exact error shapes, so they are
  produced in one place.

  **Retries are not left to Req.** Summaries are expensive, and the Oban
  worker already manages retries. Retrying here as well would silently
  multiply a single request.
  """

  require Logger

  # Long meetings take a while to answer. Unlike STT polling this finishes in
  # one shot, so be generous.
  @receive_timeout 180_000

  @doc """
  POSTs JSON and returns the parsed body.

  Error shapes are fixed — `{:http, status, body}` and `{:transport, reason}`.
  """
  def post_json(url, headers, payload) do
    Req.post(url,
      json: payload,
      headers: headers,
      receive_timeout: @receive_timeout,
      retry: false
    )
    |> handle()
  end

  defp handle({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp handle({:ok, %Req.Response{status: status, body: body}}) do
    {:error, {:http, status, summarize_body(body)}}
  end

  defp handle({:error, %Req.TransportError{reason: :timeout}}), do: {:error, :timeout}
  defp handle({:error, %{reason: reason}}), do: {:error, {:transport, reason}}
  defp handle({:error, reason}), do: {:error, {:transport, reason}}

  # A full error body in logs or the DB would be a problem. Keep only the head.
  defp summarize_body(body) when is_binary(body), do: String.slice(body, 0, 500)

  defp summarize_body(body) when is_map(body) do
    body |> Jason.encode!() |> String.slice(0, 500)
  rescue
    _ -> inspect(body, limit: 20)
  end

  defp summarize_body(body), do: inspect(body, limit: 20)
end
