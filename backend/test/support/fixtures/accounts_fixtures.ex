defmodule VR.AccountsFixtures do
  @moduledoc "Helpers for creating test accounts."

  alias VR.Accounts

  def unique_email, do: "user#{System.unique_integer([:positive])}@example.test"
  def valid_password, do: "correct-horse-battery"

  def account_fixture(attrs \\ %{}) do
    {:ok, account} =
      attrs
      |> Enum.into(%{
        email: unique_email(),
        password: valid_password(),
        name: "Test User"
      })
      |> Accounts.register_account()

    account
  end

  def confirmed_account_fixture(attrs \\ %{}) do
    account = account_fixture(attrs)
    {:ok, token} = Accounts.create_email_token(account, "confirm")
    {:ok, account} = Accounts.confirm_account(token)
    account
  end
end
