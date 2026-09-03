defmodule VR.Config do
  @moduledoc """
  The **single path** for configuration resolution.

      VR.Config.fetch("storage.access_key_id")
      VR.Config.fetch(:storage, :access_key_id)

  Resolution order:

      1. DB (system_configs, Cloak-encrypted)
      2. Environment variable (the Registry's :env name)
      3. nil  →  the corresponding feature turns off

  ## Rules

  - **No literal defaults in code.** When a value is missing, the feature simply
    stops. This repo is public, so a hardcoded default is itself a leak.
  - Other modules never call `System.get_env/1` directly. Everything goes through here.
  - Adding a new config value is just adding an entry to `VR.Config.Registry`.
    The admin screen, validation, masking, and env-var fallback follow automatically.
  """

  import Ecto.Query, warn: false

  alias VR.Config.Registry
  alias VR.Repo
  alias VR.System.SystemConfig

  @type source :: :db | :env | :none

  # ── Reads ────────────────────────────────────────────────

  @doc "Returns the config value cast to its type. nil when absent."
  @spec fetch(String.t()) :: term() | nil
  def fetch(key) when is_binary(key) do
    case fetch_with_source(key) do
      {value, _source} -> value
    end
  end

  @spec fetch(atom(), atom()) :: term() | nil
  def fetch(group, name) when is_atom(group) and is_atom(name),
    do: fetch("#{group}.#{name}")

  @doc "Returns the value together with its source. Used by the admin UI to show where a value came from."
  @spec fetch_with_source(String.t()) :: {term() | nil, source()}
  def fetch_with_source(key) when is_binary(key) do
    entry = Registry.entry(key)

    cond do
      is_nil(entry) ->
        {nil, :none}

      value = db_value(key) ->
        {cast(value, entry.type), :db}

      value = env_value(entry) ->
        {cast(value, entry.type), :env}

      true ->
        {nil, :none}
    end
  end

  @doc "Whether the value is configured (in the DB or an environment variable)."
  @spec configured?(String.t()) :: boolean()
  def configured?(key) do
    case fetch_with_source(key) do
      {nil, _} -> false
      {"", _} -> false
      _ -> true
    end
  end

  @doc """
  Whether a feature can operate. Every required entry must be filled in.

      VR.Config.feature_ready?(:transcription)
  """
  @spec feature_ready?(atom()) :: boolean()
  def feature_ready?(feature) do
    feature |> Registry.required_for() |> Enum.all?(&configured?(&1.key))
  end

  @doc "Per-feature readiness and missing entries. For the admin dashboard warning banner."
  @spec feature_status() :: [%{feature: atom(), ready: boolean(), missing: [map()]}]
  def feature_status do
    Enum.map(Registry.features(), fn feature ->
      missing = feature |> Registry.required_for() |> Enum.reject(&configured?(&1.key))
      %{feature: feature, ready: missing == [], missing: missing}
    end)
  end

  # ── Writes ───────────────────────────────────────────────

  @doc """
  Saves a config value to the DB.

  **Does nothing for an empty string.** Saving the admin form with a secret
  field left blank is normal behavior (= keep the existing value).
  Use `delete/1` to clear a value.
  """
  @spec put(String.t(), term(), keyword()) :: {:ok, SystemConfig.t()} | {:error, term()}
  def put(key, value, opts \\ [])
  def put(_key, nil, _opts), do: {:ok, :unchanged}
  def put(_key, "", _opts), do: {:ok, :unchanged}

  def put(key, value, opts) do
    attrs = %{key: key, value: to_string(value), updated_by_id: opts[:actor_id]}

    case Repo.get_by(SystemConfig, key: key) do
      nil -> %SystemConfig{} |> SystemConfig.changeset(attrs) |> Repo.insert()
      existing -> existing |> SystemConfig.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Deletes the value stored in the DB. The env-var fallback applies afterward."
  @spec delete(String.t()) :: :ok
  def delete(key) do
    Repo.delete_all(from c in SystemConfig, where: c.key == ^key)
    :ok
  end

  @doc "Saves a whole group at once. Shape: `%{\"storage.bucket\" => \"...\"}`."
  @spec put_many(map(), keyword()) :: :ok
  def put_many(params, opts \\ []) do
    Enum.each(params, fn {key, value} ->
      if Registry.entry(key), do: put(key, value, opts)
    end)

    :ok
  end

  # ── Admin display ────────────────────────────────────────

  @doc """
  Group data to render on the admin screen. **Never includes the actual contents of secrets.**
  """
  @spec admin_view(atom()) :: [map()]
  def admin_view(group) do
    Enum.map(Registry.entries_for(group), fn entry ->
      {value, source} = fetch_with_source(entry.key)
      present = value not in [nil, ""]

      Map.merge(entry, %{
        source: source,
        present: present,
        # Secrets are never returned. Non-secrets get the actual value for editing.
        display_value: if(entry.secret, do: nil, else: value),
        updated_at: updated_at(entry.key)
      })
    end)
  end

  defp updated_at(key) do
    case Repo.get_by(SystemConfig, key: key) do
      nil -> nil
      config -> config.updated_at
    end
  end

  # ── Internal ─────────────────────────────────────────────

  defp db_value(key) do
    case Repo.get_by(SystemConfig, key: key) do
      nil -> nil
      %{value: ""} -> nil
      %{value: value} -> value
    end
  rescue
    # Tolerates pre-migration state and booting without a DB (e.g. at build time)
    _ -> nil
  end

  defp env_value(%{env: nil}), do: nil

  defp env_value(%{env: name}) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp cast(nil, _type), do: nil
  defp cast(value, :boolean), do: String.downcase(to_string(value)) in ~w(true 1 yes on)

  defp cast(value, :integer) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp cast(value, :json) do
    case Jason.decode(to_string(value)) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end

  defp cast(value, _type), do: to_string(value)
end
