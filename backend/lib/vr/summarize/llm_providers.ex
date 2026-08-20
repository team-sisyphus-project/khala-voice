defmodule VR.Summarize.LlmProviders do
  @moduledoc """
  LLM 제공자 조회/관리.

  ## 선택 순서

      enabled = true  AND  api_key 있음  →  priority 오름차순  →  첫 번째

  호출이 실패하면 다음 우선순위로 폴백한다. 전부 실패하면 요약이 실패로 기록된다.
  """

  import Ecto.Query, warn: false

  alias VR.Repo
  alias VR.Summarize.LlmProvider

  @env_key "LLM_API_KEY"
  @env_provider "LLM_PROVIDER"
  @env_model "LLM_MODEL"

  @doc "어드민용 — 등록된 제공자 전부"
  def list_all do
    Repo.all(from p in LlmProvider, order_by: [asc: :priority, asc: :provider])
    |> Enum.map(&decorate/1)
    |> maybe_append_env_fallback()
  end

  @doc "실제로 호출 가능한 제공자만, 우선순위 순"
  def list_usable do
    list_all()
    |> Enum.filter(& &1.usable)
    |> Enum.sort_by(& &1.priority)
  end

  @doc "가장 우선순위가 높은 사용 가능 제공자"
  def primary, do: List.first(list_usable())

  @doc "요약 기능이 동작 가능한가"
  def ready?, do: list_usable() != []

  def get(id) when is_binary(id), do: Repo.get(LlmProvider, id)

  def upsert(attrs, opts \\ []) do
    attrs = Map.put(attrs, "updated_by_id", opts[:actor_id])
    name = attrs["provider"]

    existing = (name && Repo.get_by(LlmProvider, provider: name)) || %LlmProvider{}

    existing
    |> LlmProvider.admin_changeset(attrs)
    |> Repo.insert_or_update()
  end

  def delete(%LlmProvider{} = provider), do: Repo.delete(provider)

  # ── 내부 ─────────────────────────────────────────────────

  defp decorate(%LlmProvider{} = p) do
    key = present(p.api_key) || env_key_for(p.provider)

    Map.merge(p, %{
      key_present: not is_nil(key),
      key_source: if(present(p.api_key), do: :db, else: if(key, do: :env, else: :none)),
      resolved_api_key: key,
      usable: p.enabled and not is_nil(key) and present(p.model) != nil
    })
  end

  # 환경변수로만 설정된 경우에도 요약이 동작하도록, DB에 행이 없으면 가상 항목을 붙인다.
  defp maybe_append_env_fallback(providers) do
    env_provider = present(System.get_env(@env_provider))
    env_key = present(System.get_env(@env_key))
    env_model = present(System.get_env(@env_model))

    already? = Enum.any?(providers, &(&1.provider == env_provider))

    if env_provider && env_key && env_model && not already? do
      fallback =
        %LlmProvider{
          provider: env_provider,
          display_name: "#{String.capitalize(env_provider)} (환경변수)",
          model: env_model,
          enabled: true,
          priority: 1000
        }
        |> Map.merge(%{
          key_present: true,
          key_source: :env,
          resolved_api_key: env_key,
          usable: true
        })

      providers ++ [fallback]
    else
      providers
    end
  end

  defp env_key_for(provider) do
    if present(System.get_env(@env_provider)) == provider,
      do: present(System.get_env(@env_key)),
      else: nil
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
