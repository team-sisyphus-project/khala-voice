defmodule VR.Summarize.LLM.HTTP do
  @moduledoc """
  어댑터들이 공유하는 HTTP 처리.

  ## 왜 따로 두나

  제공자 셋이 각자 `Req.post` 를 부르면 타임아웃·에러 분류·재시도 정책이
  세 갈래로 갈라진다. 폴백 판단(`LLM.retryable?/1`)이 정확한 에러 모양에
  기대므로 한 곳에서 만든다.

  **재시도는 Req 에 맡기지 않는다.** 요약은 비싸고, Oban 워커가 이미
  재시도를 관리한다. 여기서 또 재시도하면 한 번의 요청이 조용히 몇 배가 된다.
  """

  require Logger

  # 긴 회의는 응답이 오래 걸린다. STT 폴링과 달리 한 방에 끝나므로 넉넉히.
  @receive_timeout 180_000

  @doc """
  JSON 을 POST 하고 파싱된 본문을 돌려준다.

  에러 모양을 고정한다 — `{:http, status, body}` · `{:transport, reason}`.
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

  # 에러 본문이 통째로 로그·DB 에 남으면 곤란하다. 앞부분만 남긴다.
  defp summarize_body(body) when is_binary(body), do: String.slice(body, 0, 500)

  defp summarize_body(body) when is_map(body) do
    body |> Jason.encode!() |> String.slice(0, 500)
  rescue
    _ -> inspect(body, limit: 20)
  end

  defp summarize_body(body), do: inspect(body, limit: 20)
end
