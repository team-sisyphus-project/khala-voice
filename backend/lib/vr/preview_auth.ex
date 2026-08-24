defmodule VR.PreviewAuth do
  @moduledoc """
  Preview 환경에서 관리자 기능을 확인하기 위한 인증 테스트 데이터를 구성한다.

  호출할 때마다 세 계정의 비밀번호와 역할을 요구 상태로 맞추고, 관리자에게
  최근 MFA 확인 시각이 기록된 단일 세션을 보장한다. 운영 시작 경로에서는 이
  모듈을 호출하지 않으며, 실행 진입점은 명시적인 preview 환경 확인을 요구한다.
  """

  import Ecto.Query, warn: false

  alias VR.Accounts
  alias VR.Accounts.{Account, AccountSession, Admin}
  alias VR.Repo

  @session_marker "khala-preview-auth-fixture"
  @accounts [
    admin: {"admin@khala.voice", "Preview 관리자", true},
    user1: {"user1@khala.voice", "Preview 사용자 1", false},
    user2: {"user2@khala.voice", "Preview 사용자 2", false}
  ]

  def mfa_ttl_seconds, do: Admin.recent_mfa_seconds()

  @doc "테스트 계정 세 개와 관리자의 최근 MFA 세션을 멱등 구성한다."
  def ensure(opts) do
    with {:ok, password} <- validate_password(opts[:password]) do
      Repo.transaction(fn ->
        accounts = Map.new(@accounts, &ensure_account(&1, password))
        session = ensure_mfa_session(accounts.admin)

        %{
          accounts: accounts,
          mfa_session: session,
          mfa_ttl_seconds: mfa_ttl_seconds()
        }
      end)
    end
  end

  defp validate_password(password) when password in [nil, ""], do: {:error, :password_required}

  defp validate_password(password) when is_binary(password) and byte_size(password) < 10,
    do: {:error, :password_too_short}

  defp validate_password(password) when is_binary(password), do: {:ok, password}
  defp validate_password(_password), do: {:error, :password_required}

  defp ensure_account({role, {email, name, admin?}}, password) do
    account = Repo.get_by(Account, email: email)

    account =
      case account do
        nil ->
          %Account{}
          |> Account.registration_changeset(%{email: email, name: name, password: password})
          |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
          |> Ecto.Changeset.put_change(:is_admin, admin?)
          |> Repo.insert!()

        account ->
          account
          |> Account.password_changeset(%{password: password})
          |> Ecto.Changeset.put_change(
            :confirmed_at,
            account.confirmed_at || DateTime.utc_now(:second)
          )
          |> Ecto.Changeset.put_change(:is_admin, admin?)
          |> Repo.update!()
      end

    {role, account}
  end

  defp ensure_mfa_session(admin) do
    now = DateTime.utc_now(:second)

    Repo.update_all(
      from(s in AccountSession,
        where: s.account_id == ^admin.id and s.is_active == true and s.expires_at > ^now
      ),
      set: [mfa_verified_at: now]
    )

    case Repo.one(
           from s in AccountSession,
             where: s.account_id == ^admin.id and s.user_agent == ^@session_marker,
             limit: 1
         ) do
      nil ->
        {:ok, _token, session} =
          Accounts.create_session(admin,
            user_agent: @session_marker,
            mfa_verified_at: now
          )

        session

      session ->
        session
        |> Ecto.Changeset.change(%{
          is_active: true,
          mfa_verified_at: now,
          last_activity_at: now,
          expires_at: DateTime.add(now, AccountSession.validity_days(), :day)
        })
        |> Repo.update!()
    end
  end
end
