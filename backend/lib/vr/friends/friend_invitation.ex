defmodule VR.Friends.FriendInvitation do
  @moduledoc """
  Friend invitation.

  Two modes handled by the same schema.

  | Mode | `email` | Flow |
  |---|---|---|
  | Email invitation | present | Send mail → click link → (sign up if needed) → accept |
  | Link invitation | absent | Generate link → deliver by any channel → whoever opens it accepts |

  Like session and email tokens, **only the hash** of the token is stored.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.IdGenerator

  @rand_size 24
  @validity_days 14
  @statuses ~w(pending accepted declined expired cancelled)

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "friend_invitations" do
    field :invited_by_id, :string
    field :email, :string
    field :token_hash, :binary, redact: true
    field :status, :string, default: "pending"
    field :message, :string
    field :expires_at, :utc_datetime
    field :accepted_by_id, :string
    field :responded_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def validity_days, do: @validity_days

  @doc "Returns `{raw_token, changeset}`. The raw token is used only in the link."
  def build(invited_by_id, attrs \\ %{}) do
    token = :crypto.strong_rand_bytes(@rand_size)
    now = DateTime.utc_now(:second)

    email =
      case attrs[:email] || attrs["email"] do
        nil -> nil
        "" -> nil
        value -> value |> to_string() |> String.trim() |> String.downcase()
      end

    changeset =
      %__MODULE__{}
      |> change(%{
        id: IdGenerator.generate(:friend_invitation),
        invited_by_id: invited_by_id,
        email: email,
        token_hash: :crypto.hash(:sha256, token),
        status: "pending",
        message: attrs[:message] || attrs["message"],
        expires_at: DateTime.add(now, @validity_days, :day)
      })
      |> validate_length(:message, max: 300)
      |> validate_email_format()

    {Base.url_encode64(token, padding: false), changeset}
  end

  def hash_token(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} -> {:ok, :crypto.hash(:sha256, raw)}
      :error -> :error
    end
  end

  def hash_token(_), do: :error

  def respond_changeset(invitation, status, accepted_by_id \\ nil) when status in @statuses do
    change(invitation, %{
      status: status,
      accepted_by_id: accepted_by_id,
      responded_at: DateTime.utc_now(:second)
    })
  end

  defp validate_email_format(changeset) do
    case get_field(changeset, :email) do
      nil ->
        changeset

      _ ->
        validate_format(changeset, :email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
          message: "is not a valid email address"
        )
    end
  end
end
