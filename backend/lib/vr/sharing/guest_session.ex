defmodule VR.Sharing.GuestSession do
  @moduledoc """
  One visitor who entered through a shared link = one row.

  **No source — this concept is new in this app.**

  sisyphus had no guest sessions at all. The guest API received the share token
  in the URL on every call and looked it up again, and the guest's identity
  (name, id) lived in browser JS memory variables
  (`assets/webapp/video-call-guest.js`). So the server never knew "which guests
  are inside right now", and revoking a link could not cut off someone who had
  already entered.

  ## Bound to exactly one meeting

  `meeting_id` is fixed on this row. Which meeting a guest can view is decided
  by **the session**, not the request URL. Since the URL carries no meeting id,
  there is no way to point at a different meeting at all.

  ## `granted_role` is copied from the link and frozen

  Kept as a reference, an already-entered guest's permissions would shift
  whenever the link's role changed. The promise made at entry time is preserved
  as-is.

  Token handling matches `VR.Accounts.AccountSession` — the original goes only
  to the client, the DB stores only a sha256 hash.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias VR.IdGenerator
  alias VR.Sharing.SharedLink

  @rand_size 32
  @token_prefix "gst_"
  @validity_hours 12

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "guest_sessions" do
    field :shared_link_id, :string
    field :meeting_id, :string
    field :account_id, :string

    field :token_hash, :binary, redact: true
    field :granted_role, :string
    field :display_name, :string
    field :email, :string
    field :user_agent, :string
    field :ip_address, :string

    field :last_activity_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def validity_hours, do: @validity_hours
  def token_prefix, do: @token_prefix

  @doc """
  Builds a guest session. Returns `{plaintext_token, changeset}`.

  Expiry is **the earlier of 12 hours and the link's expiry**. If the link dies
  tomorrow but the guest session lives until the day after, revocation would
  only be half effective.
  """
  def build(%SharedLink{} = link, attrs \\ %{}) do
    raw = :crypto.strong_rand_bytes(@rand_size)
    now = DateTime.utc_now(:second)
    expires_at = earliest(DateTime.add(now, @validity_hours, :hour), link.expires_at)

    changeset =
      %__MODULE__{}
      |> cast(attrs, [:display_name, :email])
      |> put_change(:id, IdGenerator.generate(:guest_session))
      |> put_change(:shared_link_id, link.id)
      |> put_change(:meeting_id, link.meeting_id)
      |> put_change(:token_hash, :crypto.hash(:sha256, raw))
      # Copied from the link and frozen. If the link changes later, this session stays.
      |> put_change(:granted_role, link.granted_role)
      |> put_change(:account_id, attrs[:account_id] || attrs["account_id"])
      |> put_change(:user_agent, truncate(attrs[:user_agent], 300))
      |> put_change(:ip_address, truncate(attrs[:ip_address], 45))
      |> put_change(:last_activity_at, now)
      |> put_change(:expires_at, expires_at)
      |> validate_required([:id, :shared_link_id, :meeting_id, :token_hash, :granted_role])
      |> validate_inclusion(:granted_role, SharedLink.roles())
      |> validate_identity(link)
      |> check_constraint(:granted_role, name: :guest_sessions_granted_role_check)

    {@token_prefix <> Base.url_encode64(raw, padding: false), changeset}
  end

  @doc "Converts the token from the request header into the hash used for DB lookup."
  def hash_token(@token_prefix <> encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} -> {:ok, :crypto.hash(:sha256, raw)}
      :error -> :error
    end
  end

  def hash_token(_), do: :error

  @doc "Is it still valid?"
  def live?(session, now \\ nil) do
    now = now || DateTime.utc_now(:second)
    is_nil(session.revoked_at) and DateTime.compare(session.expires_at, now) == :gt
  end

  # ── Internal ─────────────────────────────────────────────

  defp validate_identity(changeset, %SharedLink{} = link) do
    changeset
    |> maybe_require(:display_name, link.require_name)
    |> maybe_require(:email, link.require_email)
    |> validate_length(:display_name, min: 1, max: 60)
    |> validate_email(link.require_email)
  end

  defp maybe_require(changeset, _field, false), do: changeset
  defp maybe_require(changeset, field, true), do: validate_required(changeset, [field])

  defp validate_email(changeset, false), do: changeset

  defp validate_email(changeset, true) do
    validate_format(changeset, :email, ~r/^[^\s@]+@[^\s@]+$/, message: "has an invalid format")
  end

  defp earliest(a, nil), do: a
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp truncate(nil, _max), do: nil
  defp truncate(value, max), do: String.slice(to_string(value), 0, max)
end
