defmodule VR.Accounts do
  @moduledoc """
  계정 · 세션 · 이메일 토큰.

  ## 보안 원칙

  1. **토큰은 해시로 저장한다.** 원본은 쿠키와 메일 링크에만 존재한다.
  2. **계정 존재 여부를 흘리지 않는다.** 로그인 실패와 비밀번호 재설정 요청은
     계정이 있든 없든 같은 응답과 비슷한 소요 시간을 갖는다.
  3. **비밀번호 변경은 다른 세션을 전부 끊는다.** 탈취된 세션을 확실히 무효화한다.
  4. **로그인 시도를 센다.** 이메일별·IP별로 각각 제한한다.
  """

  import Ecto.Query, warn: false

  alias VR.Accounts.{Account, AccountSession, AccountToken, InviteCode, LoginAttempt}
  alias VR.Config
  alias VR.Repo

  # 최근 15분 안의 실패 횟수가 이 값을 넘으면 잠근다
  @max_failures_per_email 10
  @max_failures_per_ip 30
  @failure_window_minutes 15

  # ── 조회 ─────────────────────────────────────────────────

  def get_account(id), do: Repo.one(active_query() |> where([a], a.id == ^id))

  def get_account!(id), do: Repo.one!(active_query() |> where([a], a.id == ^id))

  def get_account_by_email(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()
    Repo.one(active_query() |> where([a], a.email == ^normalized))
  end

  def get_account_by_email(_), do: nil

  def get_account_by_social(provider, social_id) do
    Repo.one(
      active_query()
      |> where([a], a.social_provider == ^provider and a.social_id == ^social_id)
    )
  end

  defp active_query, do: from(a in Account, where: is_nil(a.deleted_at))

  @doc """
  이메일 + 비밀번호로 계정을 찾는다.

  계정이 없어도 bcrypt 더미 검증을 수행해 응답 시간을 맞춘다.
  """
  def get_account_by_email_and_password(email, password) do
    account = get_account_by_email(email)

    if Account.valid_password?(account || %Account{}, password), do: account
  end

  # ── 가입 ─────────────────────────────────────────────────

  @doc """
  가입.

  `policy.invite_code_required`가 켜져 있으면 유효한 초대 코드가 있어야 한다.
  코드 확인과 계정 생성, 코드 소진을 **한 트랜잭션**으로 묶어
  같은 코드로 두 계정이 만들어지는 것을 막는다.
  """
  def register_account(attrs) do
    result =
      if invite_required?() do
        register_with_invite(attrs)
      else
        %Account{} |> Account.registration_changeset(attrs) |> Repo.insert()
      end

    # 무료 플랜에 자동 구독시킨다. 실패해도 가입은 성립한다 —
    # 요금 설정이 덜 됐다고 사용자가 못 들어오면 안 된다.
    with {:ok, account} <- result do
      VR.Billing.ensure_default_subscription(account.id)
      {:ok, account}
    end
  end

  defp invite_required?, do: Config.fetch("policy.invite_code_required") == true

  defp register_with_invite(attrs) do
    code = attrs[:invite_code] || attrs["invite_code"]

    Ecto.Multi.new()
    |> Ecto.Multi.run(:invite, fn _repo, _ ->
      case claimable_invite(code) do
        nil -> {:error, :invalid_invite_code}
        invite -> {:ok, invite}
      end
    end)
    |> Ecto.Multi.insert(:account, Account.registration_changeset(%Account{}, attrs))
    |> Ecto.Multi.run(:consume, fn repo, %{invite: invite, account: account} ->
      # status를 다시 조건에 넣어 동시 요청이 같은 코드를 쓰지 못하게 한다
      case repo.update_all(
             from(i in InviteCode, where: i.id == ^invite.id and i.status == "available"),
             set: [
               status: "used",
               used_by_account_id: account.id,
               used_at: DateTime.utc_now(:second)
             ]
           ) do
        {1, _} -> {:ok, :consumed}
        {0, _} -> {:error, :invite_code_taken}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account}} ->
        {:ok, account}

      {:error, :invite, reason, _} ->
        {:error,
         %Account{}
         |> Account.registration_changeset(attrs, hash_password: false)
         |> Ecto.Changeset.add_error(:invite_code, invite_error_message(reason))}

      {:error, :consume, _reason, _} ->
        {:error,
         %Account{}
         |> Account.registration_changeset(attrs, hash_password: false)
         |> Ecto.Changeset.add_error(:invite_code, "방금 다른 분이 사용했습니다. 다른 코드를 입력해 주세요.")}

      {:error, :account, changeset, _} ->
        {:error, changeset}
    end
  end

  defp invite_error_message(:invalid_invite_code), do: "유효하지 않은 초대 코드입니다"
  defp invite_error_message(_), do: "초대 코드를 확인해 주세요"

  defp claimable_invite(nil), do: nil
  defp claimable_invite(""), do: nil

  defp claimable_invite(code) do
    normalized = code |> to_string() |> String.trim() |> String.upcase()
    now = DateTime.utc_now(:second)

    Repo.one(
      from i in InviteCode,
        where:
          i.code == ^normalized and i.status == "available" and
            (is_nil(i.expires_at) or i.expires_at > ^now)
    )
  end

  @doc "초대 코드를 발급한다."
  def create_invite_code(attrs \\ %{}) do
    attrs |> InviteCode.build() |> Repo.insert()
  end

  def list_invite_codes(opts \\ []) do
    query = from i in InviteCode, order_by: [desc: i.inserted_at]
    query = if opts[:status], do: where(query, [i], i.status == ^opts[:status]), else: query
    Repo.all(query)
  end

  def change_account_registration(account \\ %Account{}, attrs \\ %{}) do
    Account.registration_changeset(account, attrs, hash_password: false)
  end

  @doc """
  소셜 로그인으로 들어온 사용자를 찾거나 만든다.

  1. `(제공자, 소셜ID)`로 찾는다
  2. 없으면 이메일로 기존 계정을 찾아 **연결**한다
     (같은 사람이 비밀번호로 먼저 가입했을 수 있다)
  3. 그것도 없으면 새로 만든다
  """
  def find_or_create_social_account(provider, social_id, attrs) do
    cond do
      account = get_account_by_social(provider, social_id) ->
        {:ok, account}

      account = attrs[:email] && get_account_by_email(attrs[:email]) ->
        account
        |> Ecto.Changeset.change(%{social_provider: provider, social_id: social_id})
        |> Repo.update()

      true ->
        result =
          %Account{}
          |> Account.social_registration_changeset(
            Map.merge(attrs, %{social_provider: provider, social_id: social_id})
          )
          |> Repo.insert()

        with {:ok, account} <- result do
          VR.Billing.ensure_default_subscription(account.id)
          {:ok, account}
        end
    end
  end

  # ── 프로필 · 비밀번호 ────────────────────────────────────

  def update_profile(%Account{} = account, attrs) do
    account |> Account.profile_changeset(attrs) |> Repo.update()
  end

  @doc "테마만 바꾼다. 설정 화면을 거치지 않고 즉시 저장할 때 쓴다."
  def update_theme(%Account{} = account, theme) do
    account |> Account.theme_changeset(theme) |> Repo.update()
  end

  @doc """
  UI 표시 언어(`locale`)만 바꾼다. 설정 화면을 거치지 않고 즉시 저장할 때 쓴다.

  **전사 언어(`transcribe_language`)와 다른 값이다.** 영어로 앱을 쓰면서
  한국어 회의를 녹음하는 것이 흔하다 — 둘을 묶으면 그때마다 함께 바꿔야 한다.
  """
  def update_locale(%Account{} = account, locale) do
    account |> Account.locale_changeset(locale) |> Repo.update()
  end

  @doc """
  기본 전사 언어를 바꾼다. `nil` 이면 자동(브라우저 언어)으로 되돌린다.

  **대화(UI) 언어(`locale`)와 다른 값이다.** 한국어로 앱을 쓰면서 영어 회의를
  녹음하는 것이 흔하다 — 둘을 묶으면 그때마다 UI 언어까지 바꿔야 한다.
  """
  def update_transcribe_language(%Account{} = account, language) do
    account |> Account.transcribe_language_changeset(language) |> Repo.update()
  end

  @doc """
  비밀번호를 바꾸고 **다른 모든 세션을 끊는다.**

  `keep_session_id`로 지정한 세션만 남는다 (지금 쓰고 있는 브라우저).
  """
  def update_password(%Account{} = account, attrs, opts \\ []) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:account, Account.password_changeset(account, attrs))
    |> Ecto.Multi.run(:sessions, fn _repo, _changes ->
      {count, _} = revoke_other_sessions(account.id, opts[:keep_session_id])
      {:ok, count}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account}} -> {:ok, account}
      {:error, :account, changeset, _} -> {:error, changeset}
    end
  end

  # ── 세션 ─────────────────────────────────────────────────

  @doc "로그인. `{원본_토큰, 세션}`을 돌려준다. 원본은 쿠키에만 심는다."
  def create_session(%Account{} = account, attrs \\ %{}) do
    {token, changeset} = AccountSession.build(account.id, attrs)

    case Repo.insert(changeset) do
      {:ok, session} -> {:ok, token, session}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "서버가 확인한 MFA 성공 시각을 현재 로그인 세션에 기록한다."
  def mark_session_mfa_verified(%AccountSession{account_id: account_id} = session, account_id) do
    session
    |> Ecto.Changeset.change(%{mfa_verified_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  def mark_session_mfa_verified(%AccountSession{}, _account_id), do: {:error, :session_mismatch}

  @doc """
  세션 토큰으로 계정을 찾는다. 유효하면 마지막 활동 시각을 갱신한다.

  삭제 예약된 계정이 로그인하면 예약이 **취소된다.**
  """
  def get_account_by_session_token(token) when is_binary(token) do
    with {:ok, hash} <- AccountSession.hash_token(token),
         %AccountSession{} = session <- find_live_session(hash),
         %Account{} = account <- get_account(session.account_id) do
      touch_session(session)
      {:ok, account, session}
    else
      _ -> :error
    end
  end

  def get_account_by_session_token(_), do: :error

  defp find_live_session(hash) do
    now = DateTime.utc_now(:second)

    Repo.one(
      from s in AccountSession,
        where: s.token_hash == ^hash and s.is_active == true and s.expires_at > ^now
    )
  end

  defp touch_session(session) do
    now = DateTime.utc_now(:second)

    # 1분 안에 이미 갱신했으면 쓰기를 건너뛴다 (요청마다 UPDATE 하지 않기)
    if DateTime.diff(now, session.last_activity_at || now, :second) >= 60 do
      Repo.update_all(
        from(s in AccountSession, where: s.id == ^session.id),
        set: [last_activity_at: now]
      )
    end
  end

  def list_sessions(account_id) do
    now = DateTime.utc_now(:second)

    Repo.all(
      from s in AccountSession,
        where: s.account_id == ^account_id and s.is_active == true and s.expires_at > ^now,
        order_by: [desc: s.last_activity_at]
    )
  end

  def revoke_session(token) when is_binary(token) do
    case AccountSession.hash_token(token) do
      {:ok, hash} ->
        Repo.update_all(
          from(s in AccountSession, where: s.token_hash == ^hash),
          set: [is_active: false]
        )

        :ok

      :error ->
        :ok
    end
  end

  def revoke_session_by_id(account_id, session_id) do
    Repo.update_all(
      from(s in AccountSession, where: s.account_id == ^account_id and s.id == ^session_id),
      set: [is_active: false]
    )

    :ok
  end

  def revoke_other_sessions(account_id, keep_session_id) do
    query =
      from s in AccountSession,
        where: s.account_id == ^account_id and s.is_active == true

    query =
      if keep_session_id, do: where(query, [s], s.id != ^keep_session_id), else: query

    Repo.update_all(query, set: [is_active: false])
  end

  def revoke_all_sessions(account_id), do: revoke_other_sessions(account_id, nil)

  # ── 이메일 토큰 ──────────────────────────────────────────

  @doc "일회성 토큰을 만든다. 원본 문자열을 돌려준다 — 메일 링크에만 쓴다."
  def create_email_token(%Account{} = account, context, sent_to \\ nil) do
    {token, changeset} = AccountToken.build(account.id, context, sent_to || account.email)

    case Repo.insert(changeset) do
      {:ok, _} -> {:ok, token}
      error -> error
    end
  end

  @doc "토큰을 확인하고 **즉시 소진 처리한다.** 같은 토큰은 두 번 쓸 수 없다."
  def consume_email_token(token, context) when is_binary(token) do
    now = DateTime.utc_now(:second)

    with {:ok, hash} <- AccountToken.hash_token(token),
         %AccountToken{} = record <-
           Repo.one(
             from t in AccountToken,
               where:
                 t.token_hash == ^hash and t.context == ^context and
                   t.expires_at > ^now and is_nil(t.used_at)
           ),
         {1, _} <-
           Repo.update_all(
             from(t in AccountToken, where: t.id == ^record.id and is_nil(t.used_at)),
             set: [used_at: now]
           ),
         %Account{} = account <- get_account(record.account_id) do
      {:ok, account, record}
    else
      _ -> :error
    end
  end

  def consume_email_token(_token, _context), do: :error

  @doc "이메일 확인 완료 처리."
  def confirm_account(token) do
    case consume_email_token(token, "confirm") do
      {:ok, account, _} ->
        account |> Account.confirm_changeset() |> Repo.update()

      :error ->
        :error
    end
  end

  @doc "재설정 토큰으로 비밀번호를 바꾸고 모든 세션을 끊는다."
  def reset_password(token, attrs) do
    case consume_email_token(token, "reset_password") do
      {:ok, account, _} ->
        update_password(account, attrs, keep_session_id: nil)

      :error ->
        :error
    end
  end

  # ── 로그인 시도 제한 ─────────────────────────────────────

  def record_login_attempt(email, ip, success?) do
    %LoginAttempt{}
    |> LoginAttempt.changeset(%{email: email, ip_address: ip, success: success?})
    |> Repo.insert()
  end

  @doc """
  지금 로그인을 시도해도 되는지.

  이메일별·IP별로 최근 실패를 각각 센다.
  """
  def login_allowed?(email, ip) do
    since = DateTime.add(DateTime.utc_now(:second), -@failure_window_minutes, :minute)

    email_failures = count_failures(:email, email, since)
    ip_failures = count_failures(:ip_address, ip, since)

    cond do
      email_failures >= @max_failures_per_email -> {:error, :too_many_attempts}
      ip_failures >= @max_failures_per_ip -> {:error, :too_many_attempts}
      true -> :ok
    end
  end

  defp count_failures(_field, nil, _since), do: 0

  defp count_failures(:email, value, since) do
    normalized = value |> to_string() |> String.trim() |> String.downcase()

    Repo.aggregate(
      from(a in LoginAttempt,
        where: a.email == ^normalized and a.success == false and a.attempted_at > ^since
      ),
      :count
    )
  end

  defp count_failures(:ip_address, value, since) do
    Repo.aggregate(
      from(a in LoginAttempt,
        where: a.ip_address == ^value and a.success == false and a.attempted_at > ^since
      ),
      :count
    )
  end

  @doc "로그인 성공 시 그 이메일의 실패 기록을 지운다."
  def clear_failures(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()
    Repo.delete_all(from a in LoginAttempt, where: a.email == ^normalized and a.success == false)
    :ok
  end

  # ── 삭제 예약 ────────────────────────────────────────────

  @doc "계정 삭제를 예약한다. 유예 기간이 지나면 DeletionWorker가 처리한다."
  def schedule_deletion(%Account{} = account) do
    at = DateTime.add(DateTime.utc_now(:second), Account.deletion_grace_days(), :day)

    result =
      account
      |> Ecto.Changeset.change(%{scheduled_deletion_at: at})
      |> Repo.update()

    # 예약과 동시에 모든 세션을 끊는다
    with {:ok, _} <- result, do: revoke_all_sessions(account.id)

    result
  end

  @doc "삭제 예약 취소. 유예 기간 안에 로그인하면 자동으로 호출된다."
  def cancel_deletion(%Account{scheduled_deletion_at: nil} = account), do: {:ok, account}

  def cancel_deletion(%Account{} = account) do
    account
    |> Ecto.Changeset.change(%{scheduled_deletion_at: nil})
    |> Repo.update()
  end
end
