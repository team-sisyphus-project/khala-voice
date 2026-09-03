defmodule VR.Khala.Connection do
  @moduledoc """
  A Khala account connection. **We hold someone else's tokens.**

  Automatic sending happens after summarization finishes (after the user's
  browser is closed), so the server must hold the tokens (`docs/15-mcp-khala.md`).

  That is why `access_token` and `refresh_token` are stored encrypted via
  `VR.Encrypted.Binary`. They are also hidden from inspect via `@derive`, so
  they never leak into logs or error output.

  Khala is a **public client** (`token_endpoint_auth_methods_supported: ["none"]`).
  There is no client_secret, so there is nothing to store — PKCE takes its place.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias VR.IdGenerator

  @derive {Inspect, except: [:access_token, :refresh_token]}

  @primary_key {:id, :string, autogenerate: false}
  schema "khala_connections" do
    field :account_id, :string
    field :client_id, :string

    field :access_token, VR.Encrypted.Binary, source: :access_token_encrypted
    field :refresh_token, VR.Encrypted.Binary, source: :refresh_token_encrypted
    field :expires_at, :utc_datetime

    field :inbox_code, :string
    field :inbox_name, :string

    field :connected_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def build(account_id, attrs) do
    %__MODULE__{}
    |> cast(attrs, [:client_id, :access_token, :refresh_token, :expires_at])
    |> put_change(:id, IdGenerator.generate(:khala_connection))
    |> put_change(:account_id, account_id)
    |> put_change(:connected_at, DateTime.utc_now(:second))
    |> validate_required([:client_id, :access_token])
  end

  @doc "Refresh the tokens. If Khala does not issue a new refresh_token, keep the current one."
  def refresh_changeset(connection, attrs) do
    connection
    |> cast(attrs, [:access_token, :refresh_token, :expires_at])
    |> validate_required([:access_token])
  end

  @doc "The inbox we created on Khala. It becomes the sender side."
  def inbox_changeset(connection, code, name) do
    change(connection, inbox_code: code, inbox_name: name)
  end

  @doc "Revoke the connection. The row is not deleted — when it was revoked must remain on record."
  def revoke_changeset(connection) do
    change(connection, revoked_at: DateTime.utc_now(:second))
  end
end
