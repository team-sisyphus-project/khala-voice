defmodule VR.Friends.FriendInvitation do
  @moduledoc """
  친구 초대.

  두 가지 방식을 같은 스키마로 처리한다.

  | 방식 | `email` | 흐름 |
  |---|---|---|
  | 이메일 초대 | 있음 | 메일 발송 → 링크 클릭 → (미가입이면 가입) → 수락 |
  | 링크 초대 | 없음 | 링크 생성 → 아무 경로로 전달 → 연 사람이 수락 |

  토큰은 세션·이메일 토큰과 마찬가지로 **해시만** 저장한다.
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

  @doc "`{원본_토큰, changeset}`을 돌려준다. 원본은 링크에만 쓴다."
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
          message: "이메일 형식이 올바르지 않습니다"
        )
    end
  end
end
