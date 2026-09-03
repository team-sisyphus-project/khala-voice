defmodule VR.Access.AccessLevel do
  @moduledoc """
  **Source: sisyphus** `lib/sisyphus/access/access_level.ex`

  Permission calculation.

  ## Two distinct concepts

  - **View Scope** — the visibility range the user **chooses** in the meeting settings
  - **Access Level** — the permission **automatically calculated** from the role

  ## Roles

  Role names are kept in English even in the Korean UI (`docs/05-auth-sharing.md`).

  | Role | Code | Permission |
  |---|---|---|
  | Reviewer | `:lv0` | Full control — edit, delete, archive, change permissions, share links |
  | Contributor | `:lv1` | Record, play back, edit speakers/transcription. Cannot delete or change permissions |
  | Viewer | `:lv2` | Read only. Audio URL is masked |
  | — | `:lv3` | No access. **Responds with 404** (does not reveal whether the resource exists) |
  """

  @view_scopes ~w(me_only assignees_only selected_friends all_friends)

  @type level :: :lv0 | :lv1 | :lv2 | :lv3

  def view_scopes, do: @view_scopes
  def default_view_scope, do: "assignees_only"

  @doc """
  Calculates the access level.

  ## Options
  - `:is_admin` — system admin
  - `:friends?` — `fn reviewer_id, account_id -> boolean end`. Injected to avoid a circular dependency
  - `:guest_role` — the role granted to a guest arriving via a share link (`"viewer"` | `"contributor"`)
  - `:guest_resource_id` — **must always accompany `:guest_role`.** The meeting id the
    guest session is bound to. If this value differs from the `entity` id, no guest permission is granted

  ## A guest role is only valid when bound to its meeting

  If we granted permission based on `guest_role` alone, a caller passing the wrong
  meeting id would **open any meeting.** A guest token must be valid for exactly one
  meeting, so we re-check the binding here. The normal path
  (`VR.Sharing.guest_authorize/2`) already checks it, but this double check makes a
  missed call site fail closed.
  """
  @spec resolve(map(), String.t() | nil, keyword()) :: level()
  def resolve(entity, account_id, opts \\ [])

  # Guest — a share link grants a role even without an account.
  # But only **for the meeting the guest session is bound to.**
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
      # The clauses below apply only to people who are not Reviewer/Contributor
      scope == "me_only" -> guest_or(opts, :lv3, entity)
      scope == "assignees_only" -> guest_or(opts, :lv3, entity)
      scope == "selected_friends" and account_id in selected -> :lv2
      scope == "all_friends" and friends?(opts, reviewer_id, account_id) -> :lv2
      true -> guest_or(opts, :lv3, entity)
    end
  end

  # Even without account permission, a share link admits the guest with its role.
  #
  # **Check the binding.** If `guest_resource_id` is missing or is not this meeting,
  # grant nothing — this is the last line of defense preventing one guest token from
  # opening a different meeting.
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

  @doc "Is the level at or above the minimum required level? `at_least?(:lv1, :lv1)` → true"
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

  @doc "Normalizes legacy/invalid values."
  def normalize_view_scope(nil), do: default_view_scope()
  def normalize_view_scope(scope) when scope in @view_scopes, do: scope
  # sisyphus value mapping
  def normalize_view_scope("selected_members"), do: "selected_friends"
  def normalize_view_scope("project_members"), do: "all_friends"
  def normalize_view_scope("all_users"), do: "all_friends"
  def normalize_view_scope("private"), do: "me_only"
  def normalize_view_scope(_), do: default_view_scope()

  # ── Extracting values from the entity (supports structs, maps, and string keys) ──

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
