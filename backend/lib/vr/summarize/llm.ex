defmodule VR.Summarize.LLM do
  @moduledoc """
  LLM call entry point.

  **Origin: sisyphus** — sisyphus delegated this to an n8n workflow.
  This app calls providers directly (user requirement: remove n8n).

  ## Fallback

  Providers are tried in `LlmProviders.list_usable/0` order.
  We move on to the next provider **only for failures worth retrying** —
  rate limits (429), server errors (5xx), timeouts.

  A bad key (401) or malformed request (400) would fail on the next provider
  for the same reason — or worse, **spend money twice.** Those failures stop
  immediately.
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
  Fetches structured JSON.

  On success: `{:ok, %{body:, model:, provider:, usage:}}`.
  If every provider fails: `{:error, reason}` with the last failure reason.
  """
  @spec complete(String.t(), String.t(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  def complete(system, user, schema, opts \\ []) do
    case LlmProviders.list_usable() do
      [] -> {:error, :no_provider}
      providers -> try_providers(providers, system, user, schema, opts, nil)
    end
  end

  @doc "Whether summarization is available in this environment."
  def ready?, do: LlmProviders.ready?()

  @doc "Provider name -> adapter module. Returns nil if unknown."
  def adapter(provider), do: Map.get(@adapters, provider)

  # ── Internal ─────────────────────────────────────────────

  defp try_providers([], _system, _user, _schema, _opts, last_error) do
    {:error, last_error || :no_provider}
  end

  defp try_providers([provider | rest], system, user, schema, opts, _last) do
    case adapter(provider.provider) do
      nil ->
        Logger.warning("[LLM] Unknown provider: #{provider.provider}")
        try_providers(rest, system, user, schema, opts, {:unknown_provider, provider.provider})

      module ->
        case module.complete(provider, system, user, schema, opts) do
          {:ok, result} ->
            {:ok, result}

          {:error, reason} ->
            if retryable?(reason) and rest != [] do
              Logger.warning("[LLM] #{provider.provider} failed (#{inspect(reason)}); falling back to the next provider")

              try_providers(rest, system, user, schema, opts, reason)
            else
              {:error, reason}
            end
        end
    end
  end

  # Is this a failure worth sending the same request to another provider?
  defp retryable?({:http, status, _}) when status == 429 or status >= 500, do: true
  defp retryable?({:transport, _}), do: true
  defp retryable?(:timeout), do: true
  defp retryable?(_), do: false
end
