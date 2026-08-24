defmodule VR.Accounts.Admin do
  @moduledoc """
  시스템 어드민의 계정 관리.

  ## 잠금 방지가 이 모듈의 핵심이다

  어드민이 0명이 되면 **아무도 `/_admin` 에 들어갈 수 없다.**
  DB 를 직접 만지거나 `mix vr.make_admin` 을 서버에서 실행해야 복구된다.

  그래서 다음을 **거부**한다.

  - 마지막 어드민의 권한 회수
  - 마지막 어드민의 삭제
  - 자기 자신의 권한 회수 (실수로 나가는 것을 막는다)
  - 자기 자신의 삭제

  자기 계정을 지우려면 일반 설정 화면의 "계정 삭제 예약"을 쓴다.
  어드민 화면은 **남의 계정을 다루는 곳**이다.

  ## 부트스트랩 계정

  설치 직후에는 어드민이 없어 입구가 막혀 있다. 그래서 하나를 자동으로 만든다.
  실사용자를 승격한 뒤 이 계정을 지우면 입구가 닫힌다.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias VR.Accounts.{Account, AccountSession, AccountToken}
  alias VR.AdminAudit
  alias VR.Config
  alias VR.Friends.{FriendInvitation, Friendship}
  alias VR.Repo

  # ── 조회 ─────────────────────────────────────────────────

  @doc """
  계정 목록.

  ## 옵션
  - `:q` — 이메일·이름 부분 일치
  - `:only` — `:admins` | `:bootstrap` | `:deleted`
  - `:limit` — 기본 100
  """
  def list_accounts(opts \\ []) do
    query = from a in Account, order_by: [desc: a.is_admin, asc: a.email]

    query
    |> filter_deleted(opts[:only])
    |> filter_only(opts[:only])
    |> filter_query(opts[:q])
    |> limit(^(opts[:limit] || 100))
    |> Repo.all()
  end

  defp filter_deleted(query, :deleted), do: where(query, [a], not is_nil(a.deleted_at))
  defp filter_deleted(query, _), do: where(query, [a], is_nil(a.deleted_at))

  defp filter_only(query, :admins), do: where(query, [a], a.is_admin == true)
  defp filter_only(query, :bootstrap), do: where(query, [a], a.is_bootstrap == true)
  defp filter_only(query, _), do: query

  defp filter_query(query, nil), do: query
  defp filter_query(query, ""), do: query

  defp filter_query(query, q) do
    pattern = "%#{q}%"
    where(query, [a], ilike(a.email, ^pattern) or ilike(a.name, ^pattern))
  end

  @doc "살아있는 어드민 수. 잠금 방지 판단의 기준이다."
  def count_admins do
    Repo.aggregate(
      from(a in Account, where: a.is_admin == true and is_nil(a.deleted_at)),
      :count
    )
  end

  @doc "아직 남아있는 부트스트랩 계정. 있으면 어드민 화면이 삭제를 권한다."
  def bootstrap_account do
    Repo.one(from a in Account, where: a.is_bootstrap == true and is_nil(a.deleted_at), limit: 1)
  end

  @doc "계정 하나에 대해 어드민이 할 수 있는 일. UI 가 버튼을 그릴 때 쓴다."
  def capabilities(%Account{} = target, %Account{} = actor) do
    self? = target.id == actor.id
    last_admin? = target.is_admin and count_admins() <= 1

    %{
      can_promote: not target.is_admin,
      can_demote: target.is_admin and not self? and not last_admin?,
      can_delete: not self? and not last_admin?,
      is_self: self?,
      is_last_admin: last_admin?
    }
  end

  # ── 권한 변경 ────────────────────────────────────────────

  @doc "다른 계정을 어드민으로 승격한다."
  def promote(%Account{} = target, %Account{} = actor, session \\ nil) do
    cond do
      not actor.is_admin ->
        audited_result("admin.promote", target, actor, :unauthorized)

      not recent_mfa?(session, actor) ->
        audited_result("admin.promote", target, actor, :recent_mfa_required)

      target.deleted_at ->
        audited_result("admin.promote", target, actor, :account_deleted)

      target.is_admin ->
        audited_result("admin.promote", target, actor, :already_admin, {:ok, target})

      true ->
        set_admin(target, actor, true, "admin.promote")
    end
  end

  @doc """
  어드민 권한을 회수한다.

  마지막 어드민이거나 자기 자신이면 거부한다.
  """
  def demote(%Account{} = target, %Account{} = actor, session \\ nil) do
    cond do
      not actor.is_admin ->
        audited_result("admin.demote", target, actor, :unauthorized)

      not recent_mfa?(session, actor) ->
        audited_result("admin.demote", target, actor, :recent_mfa_required)

      not target.is_admin ->
        audited_result("admin.demote", target, actor, :not_admin, {:ok, target})

      target.id == actor.id ->
        audited_result("admin.demote", target, actor, :cannot_demote_self)

      count_admins() <= 1 ->
        audited_result("admin.demote", target, actor, :last_admin)

      true ->
        set_admin(target, actor, false, "admin.demote")
    end
  end

  defp set_admin(target, actor, value, action) do
    Multi.new()
    |> Multi.update(:account, Ecto.Changeset.change(target, %{is_admin: value}))
    |> Multi.insert(
      :audit_event,
      audit_changeset(action, target, actor, "succeeded", "completed")
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{account: updated}} -> {:ok, updated}
      {:error, :audit_event, _reason, _changes} -> {:error, :audit_write_failed}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # ── 삭제 ─────────────────────────────────────────────────

  @doc """
  계정을 즉시 삭제한다 (소프트 삭제 + 익명화).

  일반 사용자의 "삭제 예약"과 달리 유예 기간이 없다.
  어드민이 명시적으로 지우는 것이므로 바로 처리한다.

  `DeletionWorker` 와 같은 방식으로 익명화한다 — 이메일을 남기면
  삭제의 의미가 없고, 같은 주소로 재가입도 막힌다.
  """
  def delete_account(%Account{} = target, %Account{} = actor, session \\ nil) do
    cond do
      not actor.is_admin ->
        audited_result("account.delete", target, actor, :unauthorized)

      not recent_mfa?(session, actor) ->
        audited_result("account.delete", target, actor, :recent_mfa_required)

      target.id == actor.id ->
        audited_result("account.delete", target, actor, :cannot_delete_self)

      target.is_admin and count_admins() <= 1 ->
        audited_result("account.delete", target, actor, :last_admin)

      target.deleted_at ->
        audited_result("account.delete", target, actor, :already_deleted)

      true ->
        do_delete(target, actor)
    end
  end

  @recent_mfa_seconds 10 * 60

  @doc "고위험 관리자 작업에 인정되는 MFA 확인 유효기간(초)."
  def recent_mfa_seconds, do: @recent_mfa_seconds

  defp recent_mfa?(%AccountSession{id: session_id}, %Account{id: account_id}) do
    now = DateTime.utc_now(:second)
    cutoff = DateTime.add(now, -@recent_mfa_seconds, :second)

    Repo.exists?(
      from s in AccountSession,
        where:
          s.id == ^session_id and s.account_id == ^account_id and s.is_active == true and
            s.expires_at > ^now and s.mfa_verified_at >= ^cutoff and s.mfa_verified_at <= ^now
    )
  end

  defp recent_mfa?(_, _), do: false

  defp do_delete(target, actor) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.delete_all(:sessions, from(s in AccountSession, where: s.account_id == ^target.id))
    |> Multi.delete_all(:tokens, from(t in AccountToken, where: t.account_id == ^target.id))
    |> Multi.delete_all(
      :friendships,
      from(f in Friendship,
        where: f.account_a_id == ^target.id or f.account_b_id == ^target.id
      )
    )
    |> Multi.delete_all(
      :invitations,
      from(i in FriendInvitation, where: i.invited_by_id == ^target.id)
    )
    |> Multi.update(
      :account,
      Ecto.Changeset.change(target, %{
        deleted_at: now,
        email: "deleted+#{target.id}@deleted.invalid",
        name: nil,
        hashed_password: nil,
        social_provider: nil,
        social_id: nil,
        is_admin: false,
        is_bootstrap: false
      })
    )
    |> Multi.insert(
      :audit_event,
      audit_changeset("account.delete", target, actor, "succeeded", "completed")
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{account: deleted}} ->
        {:ok, deleted}

      {:error, :audit_event, _reason, _changes} ->
        {:error, :audit_write_failed}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  defp audited_result(action, target, actor, reason, result \\ nil) do
    outcome = if match?({:ok, _}, result), do: "succeeded", else: "denied"

    case AdminAudit.record(audit_attrs(action, target, actor, outcome, Atom.to_string(reason))) do
      {:ok, _event} -> result || {:error, reason}
      {:error, _changeset} -> {:error, :audit_write_failed}
    end
  end

  defp audit_changeset(action, target, actor, outcome, reason) do
    action
    |> audit_attrs(target, actor, outcome, reason)
    |> AdminAudit.changeset()
  end

  defp audit_attrs(action, target, actor, outcome, reason) do
    %{
      action: action,
      outcome: outcome,
      reason: reason,
      actor_account_id: actor.id,
      target_account_id: target.id,
      actor_email: actor.email,
      target_email: target.email
    }
  end

  # ── 부트스트랩 ───────────────────────────────────────────

  @doc """
  초기 어드민 계정을 만든다. 이미 어드민이 있으면 아무것도 하지 않는다.

  `{:ok, account, password}` — 비밀번호는 **이때 한 번만** 볼 수 있다.
  해시로만 저장하므로 나중에 조회할 수 없다.

  비밀번호는 공통 설정 계층의 `app.bootstrap_admin_password`에서 읽고,
  없으면 무작위로 만든다. **코드에 기본 비밀번호를 두지 않는다** —
  이 리포는 공개되므로 기본값이 있으면 모든 배포본이 같은 열쇠를 갖게 된다.
  """
  def ensure_bootstrap_admin(opts \\ []) do
    if count_admins() > 0 do
      {:error, :admin_exists}
    else
      # 이메일도 기본값을 두지 않는다. 모든 배포본이 같은 주소를 쓰면
      # 그 자체가 공격 대상이 된다.
      email = opts[:email] || Config.fetch("app.bootstrap_admin_email")

      password =
        opts[:password] || Config.fetch("app.bootstrap_admin_password") || random_password()

      if email in [nil, ""] do
        {:error, :email_required}
      else
        create_bootstrap(email, password)
      end
    end
  end

  defp create_bootstrap(email, password) do
    attrs = %{
      email: email,
      password: password,
      name: "초기 관리자"
    }

    changeset =
      %Account{}
      |> Account.registration_changeset(attrs)
      |> Ecto.Changeset.put_change(:is_admin, true)
      |> Ecto.Changeset.put_change(:is_bootstrap, true)
      # 로그인 직후 바로 쓸 수 있어야 한다. 메일 발송이 설정 안 됐을 수 있다.
      |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))

    case Repo.insert(changeset) do
      {:ok, account} -> {:ok, account, password}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # 사람이 옮겨적기 쉽도록 헷갈리는 글자(0/O/1/l/I)를 뺀다
  @alphabet ~c"abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  defp random_password do
    1..24
    |> Enum.map(fn _ -> Enum.random(@alphabet) end)
    |> List.to_string()
  end
end
