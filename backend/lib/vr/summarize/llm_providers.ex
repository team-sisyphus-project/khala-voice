defmodule VR.Summarize.LlmProviders do
  @moduledoc """
  LLM provider lookup and management.

  ## Selection order

      enabled = true  AND  api_key present  ->  priority ascending  ->  first

  If a call fails, we fall back to the next priority. If all fail, the summary
  is recorded as failed.
  """

  import Ecto.Query, warn: false

  alias VR.Repo
  alias VR.Summarize.LlmProvider

  @env_key "LLM_API_KEY"
  @env_provider "LLM_PROVIDER"
  @env_model "LLM_MODEL"

  @doc "For admin use — every registered provider"
  def list_all do
    Repo.all(from p in LlmProvider, order_by: [asc: :priority, asc: :provider])
    |> Enum.map(&decorate/1)
    |> maybe_append_env_fallback()
  end

  @doc "Only providers that can actually be called, in priority order"
  def list_usable do
    list_all()
    |> Enum.filter(& &1.usable)
    |> Enum.sort_by(& &1.priority)
  end

  @doc "The highest-priority usable provider"
  def primary, do: List.first(list_usable())

  @doc "Whether the summary feature is operational"
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

  # ── Internal ─────────────────────────────────────────────

  defp decorate(%LlmProvider{} = p) do
    key = present(p.api_key) || env_key_for(p.provider)

    Map.merge(p, %{
      key_present: not is_nil(key),
      key_source: if(present(p.api_key), do: :db, else: if(key, do: :env, else: :none)),
      resolved_api_key: key,
      usable: p.enabled and not is_nil(key) and present(p.model) != nil
    })
  end

  # So summaries also work when configured only via env vars, append a virtual
  # entry when there is no DB row.
  defp maybe_append_env_fallback(providers) do
    env_provider = present(System.get_env(@env_provider))
    env_key = present(System.get_env(@env_key))
    env_model = present(System.get_env(@env_model))

    already? = Enum.any?(providers, &(&1.provider == env_provider))

    if env_provider && env_key && env_model && not already? do
      fallback =
        %LlmProvider{
          provider: env_provider,
          display_name: "#{String.capitalize(env_provider)} (env var)",
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
