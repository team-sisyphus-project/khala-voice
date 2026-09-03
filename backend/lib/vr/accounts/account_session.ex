defmodule VR.Accounts.AccountSession do
  @moduledoc """
  Login session. One row per device.

  Tokens are kept in the DB so the settings screen can show "which devices are logged in"
  and support remote logout.

  ## Token handling

  The raw token exists **only in the cookie**; the DB stores only a SHA-256 hash.
  Even if the DB leaks, that alone cannot hijack a session.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.IdGenerator

  @rand_size 32
  @validity_days 60

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "account_sessions" do
    field :account_id, :string
    field :token_hash, :binary, redact: true
    field :user_agent, :string
    field :ip_address, :string
    field :last_activity_at, :utc_datetime
    field :mfa_verified_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def validity_days, do: @validity_days

  @doc """
  Creates a new session. Returns `{raw_token, changeset}`.

  The raw token cannot be recovered after this point. Plant it in the cookie and discard it.
  """
  def build(account_id, attrs \\ %{}) do
    token = :crypto.strong_rand_bytes(@rand_size)
    now = DateTime.utc_now(:second)

    changeset =
      %__MODULE__{}
      |> change(%{
        id: IdGenerator.generate(:account_session),
        account_id: account_id,
        token_hash: :crypto.hash(:sha256, token),
        user_agent: truncate(attrs[:user_agent], 300),
        ip_address: truncate(attrs[:ip_address], 45),
        last_activity_at: now,
        mfa_verified_at: attrs[:mfa_verified_at],
        expires_at: DateTime.add(now, @validity_days, :day),
        is_active: true
      })

    {Base.url_encode64(token, padding: false), changeset}
  end

  @doc "Converts the string token from the cookie into a hash for DB lookup."
  def hash_token(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} -> {:ok, :crypto.hash(:sha256, raw)}
      :error -> :error
    end
  end

  def hash_token(_), do: :error

  defp truncate(nil, _max), do: nil
  defp truncate(value, max), do: String.slice(to_string(value), 0, max)
end
