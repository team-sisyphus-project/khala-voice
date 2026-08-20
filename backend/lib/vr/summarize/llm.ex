defmodule VR.Summarize.LLM do
  @moduledoc """
  LLM 호출 진입점.

  **출처: sisyphus** — sisyphus 는 n8n 워크플로에 위임했다.
  이 앱은 직접 호출한다 (사용자 요구: n8n 제거).

  ## 폴백

  `LlmProviders.list_usable/0` 순서대로 시도한다.
  **재시도할 가치가 있는 실패에만** 다음 제공자로 넘어간다 —
  레이트리밋(429)·서버 오류(5xx)·타임아웃.

  키가 틀렸거나(401) 요청이 잘못됐으면(400) 다음 제공자도 같은 이유로 실패하거나,
  더 나쁘게는 **돈만 두 번 쓴다.** 그런 실패는 즉시 멈춘다.
  """

  alias VR.Summarize.LLM.{Anthropic, Gemini, OpenAI}
  alias VR.Summarize.LlmProviders

  require Logger

  @adapters %{
    "gemini" => Gemini,
    "anthropic" => Anthropic,
    "openai" => OpenAI
  }

  @type usage :: %{input_tokens: integer(), output_tokens: integer()}
  @type result :: %{body: String.t(), model: String.t(), provider: String.t(), usage: usage()}

  @doc """
  구조화 JSON 을 받아온다.

  성공하면 `{:ok, %{body:, model:, provider:, usage:}}`.
  전부 실패하면 마지막 이유를 담아 `{:error, reason}`.
  """
  @spec complete(String.t(), String.t(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  def complete(system, user, schema, opts \\ []) do
    case LlmProviders.list_usable() do
      [] -> {:error, :no_provider}
      providers -> try_providers(providers, system, user, schema, opts, nil)
    end
  end

  @doc "이 환경에서 요약이 가능한가."
  def ready?, do: LlmProviders.ready?()

  @doc "제공자 이름 → 어댑터 모듈. 없으면 nil."
  def adapter(provider), do: Map.get(@adapters, provider)

  # ── 내부 ─────────────────────────────────────────────────

  defp try_providers([], _system, _user, _schema, _opts, last_error) do
    {:error, last_error || :no_provider}
  end

  defp try_providers([provider | rest], system, user, schema, opts, _last) do
    case adapter(provider.provider) do
      nil ->
        Logger.warning("[LLM] 모르는 제공자: #{provider.provider}")
        try_providers(rest, system, user, schema, opts, {:unknown_provider, provider.provider})

      module ->
        case module.complete(provider, system, user, schema, opts) do
          {:ok, result} ->
            {:ok, result}

          {:error, reason} ->
            if retryable?(reason) and rest != [] do
              Logger.warning("[LLM] #{provider.provider} 실패(#{inspect(reason)}), 다음 제공자로 넘어갑니다")

              try_providers(rest, system, user, schema, opts, reason)
            else
              {:error, reason}
            end
        end
    end
  end

  # 같은 요청을 다른 제공자에 보내 볼 만한 실패인가
  defp retryable?({:http, status, _}) when status == 429 or status >= 500, do: true
  defp retryable?({:transport, _}), do: true
  defp retryable?(:timeout), do: true
  defp retryable?(_), do: false
end
