defmodule VR.Access.AccessLevel do
  @moduledoc """
  **출처: sisyphus** `lib/sisyphus/access/access_level.ex`

  권한 계산.

  ## 두 개념을 구분한다

  - **View Scope** — 사용자가 회의 설정에서 **고르는** 공개 범위
  - **Access Level** — 역할에서 **자동으로 계산되는** 권한

  ## 역할

  명칭은 한국어 UI에서도 영문 그대로 쓴다 (`docs/05-auth-sharing.md`).

  | 역할 | 코드 | 권한 |
  |---|---|---|
  | Reviewer | `:lv0` | 전권 — 편집 · 삭제 · 아카이브 · 권한 변경 · 공유 링크 |
  | Contributor | `:lv1` | 녹음 · 재생 · 화자/전사 편집. 삭제 · 권한 변경 불가 |
  | Viewer | `:lv2` | 읽기 전용. 오디오 URL 마스킹 |
  | — | `:lv3` | 접근 불가. **404로 응답한다** (존재 여부를 노출하지 않는다) |
  """

  @view_scopes ~w(me_only assignees_only selected_friends all_friends)

  @type level :: :lv0 | :lv1 | :lv2 | :lv3

  def view_scopes, do: @view_scopes
  def default_view_scope, do: "assignees_only"

  @doc """
  권한 레벨을 계산한다.

  ## 옵션
  - `:is_admin` — 시스템 어드민
  - `:friends?` — `fn reviewer_id, account_id -> boolean end`. 순환 의존을 피해 주입받는다
  - `:guest_role` — 공유 링크로 들어온 게스트에게 부여된 역할 (`"viewer"` | `"contributor"`)
  - `:guest_resource_id` — **`:guest_role` 과 반드시 함께 온다.** 게스트 세션이 묶인
    회의 id. 이 값이 `entity` 의 id 와 다르면 게스트 권한을 주지 않는다

  ## 게스트 역할은 회의와 묶여야만 유효하다

  `guest_role` 만 보고 권한을 주면, 그 값을 넘기는 호출부가 회의 id 를 잘못 넘겼을 때
  **아무 회의나 열린다.** 게스트 토큰은 회의 하나에만 유효해야 하므로, 여기서 결합을
  다시 확인한다. 정상 경로(`VR.Sharing.guest_authorize/2`)가 이미 확인하지만
  호출부를 하나 빠뜨렸을 때 닫히는 쪽으로 실패하도록 이중으로 둔다.
  """
  @spec resolve(map(), String.t() | nil, keyword()) :: level()
  def resolve(entity, account_id, opts \\ [])

  # 게스트 — 계정이 없어도 공유 링크가 역할을 준다.
  # 단 **그 게스트 세션이 묶인 회의일 때만** 준다.
  def resolve(entity, nil, opts) do
    guest_or(opts, :lv3, entity)
  end

  def resolve(entity, account_id, opts) do
    reviewer_id = get(entity, :reviewer_id)
    contributor_ids = get(entity, :contributor_ids) || []
    scope = view_scope(entity)
    selected = selected_account_ids(entity)

    cond do
      opts[:is_admin] -> :lv0
      account_id == reviewer_id -> :lv0
      account_id in contributor_ids -> :lv1
      # 아래는 Reviewer/Contributor가 아닌 사람에게만 적용된다
      scope == "me_only" -> guest_or(opts, :lv3, entity)
      scope == "assignees_only" -> guest_or(opts, :lv3, entity)
      scope == "selected_friends" and account_id in selected -> :lv2
      scope == "all_friends" and friends?(opts, reviewer_id, account_id) -> :lv2
      true -> guest_or(opts, :lv3, entity)
    end
  end

  # 계정 권한이 없어도 공유 링크가 있으면 그 역할로 들어온다.
  #
  # **결합을 확인한다.** `guest_resource_id` 가 없거나 이 회의가 아니면 주지 않는다 —
  # 게스트 토큰 하나로 다른 회의가 열리는 것을 막는 마지막 방어선이다.
  defp guest_or(opts, fallback, entity) do
    with role when role in ["viewer", "contributor"] <- opts[:guest_role],
         resource_id when is_binary(resource_id) <- opts[:guest_resource_id],
         true <- bound_to?(entity, resource_id) do
      if role == "contributor", do: :lv1, else: :lv2
    else
      _ -> fallback
    end
  end

  defp bound_to?(entity, resource_id) when is_map(entity) do
    case get(entity, :id) do
      id when is_binary(id) -> id == resource_id
      _ -> false
    end
  end

  defp bound_to?(_entity, _resource_id), do: false

  defp friends?(opts, reviewer_id, account_id) do
    case opts[:friends?] do
      fun when is_function(fun, 2) -> fun.(reviewer_id, account_id)
      _ -> false
    end
  end

  @doc "level 이 최소 요구 수준 이상인가. `at_least?(:lv1, :lv1)` → true"
  def at_least?(level, required), do: rank(level) <= rank(required)

  defp rank(:lv0), do: 0
  defp rank(:lv1), do: 1
  defp rank(:lv2), do: 2
  defp rank(:lv3), do: 3

  def to_role(:lv0), do: "reviewer"
  def to_role(:lv1), do: "contributor"
  def to_role(:lv2), do: "viewer"
  def to_role(:lv3), do: "none"

  def to_string!(:lv0), do: "lv0"
  def to_string!(:lv1), do: "lv1"
  def to_string!(:lv2), do: "lv2"
  def to_string!(:lv3), do: "lv3"

  @doc "레거시/잘못된 값을 정규화한다."
  def normalize_view_scope(nil), do: default_view_scope()
  def normalize_view_scope(scope) when scope in @view_scopes, do: scope
  # sisyphus 값 매핑
  def normalize_view_scope("selected_members"), do: "selected_friends"
  def normalize_view_scope("project_members"), do: "all_friends"
  def normalize_view_scope("all_users"), do: "all_friends"
  def normalize_view_scope("private"), do: "me_only"
  def normalize_view_scope(_), do: default_view_scope()

  # ── entity 에서 값 꺼내기 (구조체·맵·문자열 키 모두 지원) ──

  defp get(entity, key) when is_map(entity) do
    Map.get(entity, key) || Map.get(entity, Atom.to_string(key))
  end

  defp view_scope(entity) do
    case get(entity, :permissions) do
      perms when is_map(perms) ->
        (get_in(perms, ["view", "mode"]) || get_in(perms, [:view, :mode]))
        |> normalize_view_scope()

      _ ->
        default_view_scope()
    end
  end

  defp selected_account_ids(entity) do
    case get(entity, :permissions) do
      perms when is_map(perms) ->
        get_in(perms, ["view", "accountIds"]) || get_in(perms, ["view", "account_ids"]) ||
          get_in(perms, [:view, :accountIds]) || []

      _ ->
        []
    end
  end
end
