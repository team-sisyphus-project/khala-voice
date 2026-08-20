defmodule VR.Config do
  @moduledoc """
  설정 해석의 **유일한 경로**.

      VR.Config.fetch("storage.access_key_id")
      VR.Config.fetch(:storage, :access_key_id)

  해석 순서:

      1. DB (system_configs, Cloak 암호화)
      2. 환경변수 (Registry의 :env 이름)
      3. nil  →  해당 기능이 꺼진다

  ## 규칙

  - **코드에 리터럴 기본값을 두지 않는다.** 값이 없으면 없는 대로 기능이 멈춘다.
    이 리포는 공개되므로, 하드코딩된 기본값은 그 자체로 유출이다.
  - 다른 모듈이 `System.get_env/1`을 직접 부르지 않는다. 전부 여기를 거친다.
  - 새 설정값은 `VR.Config.Registry`에 항목을 추가하는 것으로 끝난다.
    어드민 화면·검증·마스킹·환경변수 폴백이 자동으로 따라온다.
  """

  import Ecto.Query, warn: false

  alias VR.Config.Registry
  alias VR.Repo
  alias VR.System.SystemConfig

  @type source :: :db | :env | :none

  # ── 읽기 ─────────────────────────────────────────────────

  @doc "설정값을 타입에 맞게 변환해 반환한다. 없으면 nil."
  @spec fetch(String.t()) :: term() | nil
  def fetch(key) when is_binary(key) do
    case fetch_with_source(key) do
      {value, _source} -> value
    end
  end

  @spec fetch(atom(), atom()) :: term() | nil
  def fetch(group, name) when is_atom(group) and is_atom(name),
    do: fetch("#{group}.#{name}")

  @doc "값과 출처를 함께 반환한다. 어드민에서 '어디서 온 값인지' 보여줄 때 쓴다."
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

  @doc "값이 설정되어 있는지 (DB든 환경변수든)."
  @spec configured?(String.t()) :: boolean()
  def configured?(key) do
    case fetch_with_source(key) do
      {nil, _} -> false
      {"", _} -> false
      _ -> true
    end
  end

  @doc """
  기능이 동작 가능한지. 필수 항목이 전부 채워져 있어야 한다.

      VR.Config.feature_ready?(:transcription)
  """
  @spec feature_ready?(atom()) :: boolean()
  def feature_ready?(feature) do
    feature |> Registry.required_for() |> Enum.all?(&configured?(&1.key))
  end

  @doc "기능별 준비 상태와 빠진 항목. 어드민 대시보드 경고 배너용."
  @spec feature_status() :: [%{feature: atom(), ready: boolean(), missing: [map()]}]
  def feature_status do
    Enum.map(Registry.features(), fn feature ->
      missing = feature |> Registry.required_for() |> Enum.reject(&configured?(&1.key))
      %{feature: feature, ready: missing == [], missing: missing}
    end)
  end

  # ── 쓰기 ─────────────────────────────────────────────────

  @doc """
  설정값을 DB에 저장한다.

  **빈 문자열이면 아무것도 하지 않는다.** 어드민 폼에서 비밀값 필드를
  비운 채 저장하는 것이 정상 동작(= 기존 값 유지)이기 때문이다.
  값을 지우려면 `delete/1`을 쓴다.
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

  @doc "DB에 저장된 값을 지운다. 이후에는 환경변수 폴백이 적용된다."
  @spec delete(String.t()) :: :ok
  def delete(key) do
    Repo.delete_all(from c in SystemConfig, where: c.key == ^key)
    :ok
  end

  @doc "그룹 하나를 한 번에 저장한다. `%{\"storage.bucket\" => \"...\"}` 형태."
  @spec put_many(map(), keyword()) :: :ok
  def put_many(params, opts \\ []) do
    Enum.each(params, fn {key, value} ->
      if Registry.entry(key), do: put(key, value, opts)
    end)

    :ok
  end

  # ── 어드민 표시용 ────────────────────────────────────────

  @doc """
  어드민 화면에 뿌릴 그룹 데이터. **비밀값의 실제 내용은 포함하지 않는다.**
  """
  @spec admin_view(atom()) :: [map()]
  def admin_view(group) do
    Enum.map(Registry.entries_for(group), fn entry ->
      {value, source} = fetch_with_source(entry.key)
      present = value not in [nil, ""]

      Map.merge(entry, %{
        source: source,
        present: present,
        # 비밀값은 절대 되돌려주지 않는다. 비밀이 아니면 편집용으로 실제 값을 준다.
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

  # ── 내부 ─────────────────────────────────────────────────

  defp db_value(key) do
    case Repo.get_by(SystemConfig, key: key) do
      nil -> nil
      %{value: ""} -> nil
      %{value: value} -> value
    end
  rescue
    # 마이그레이션 전이나 DB 없이 부팅하는 경우(빌드 타임 등)를 견딘다
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
