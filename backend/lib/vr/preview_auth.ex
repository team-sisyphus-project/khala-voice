defmodule VR.PreviewAuth do
  @moduledoc """
  Sets up authentication test data for verifying admin features in the preview environment.

  On every call it brings the three accounts' passwords and roles to the
  required state and guarantees the admin a single session with a recent MFA
  verification timestamp recorded. The production startup path never calls this
  module, and the execution entry point requires an explicit preview-environment check.
  """

  import Ecto.Query, warn: false

  alias VR.Accounts
  alias VR.Accounts.{Account, AccountSession, Admin}
  alias VR.Repo

  @session_marker "khala-preview-auth-fixture"
  @accounts [
    admin: {"admin@khala.voice", "Preview Admin", true},
    user1: {"user1@khala.voice", "Preview User 1", false},
    user2: {"user2@khala.voice", "Preview User 2", false}
  ]

  def mfa_ttl_seconds, do: Admin.recent_mfa_seconds()

  @doc "Idempotently sets up the three test accounts and the admin's recent MFA session."
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
