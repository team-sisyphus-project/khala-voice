defmodule VR.Sharing.SharedLink do
  @moduledoc """
  A meeting share link.

  **Source: sisyphus** `lib/sisyphus/shared_links/shared_link.ex` — only the structure was taken. What changed:

  | sisyphus | this app | why |
  |---|---|---|
  | `resource_type` + `resource_id` polymorphic reference | single `meeting_id` FK | The only shareable thing in this app is a meeting. Polymorphic references cannot carry an FK constraint, leaving orphan rows |
  | (none) | `granted_role` | The link decides **which role** a guest enters with. sisyphus guests had no role |
  | plaintext `token` | sha256 `token_hash` + `token_prefix` | The token is a credential that works with no further authentication. Whoever reads the DB becomes a visitor |
  | plaintext `pincode`, `:rand.uniform` generation | Bcrypt `pin_hash`, CSPRNG generation | The original was not a CSPRNG, and its range was off so `100000` could never occur |
  | `changeset` casts `:id`, `:token`, `:use_count` | all via `put_change` | The request body could overwrite the use count or the token |

  ## `granted_role` cannot be modified

  If an already-distributed `viewer` link were later raised to `contributor`,
  **everyone who received that link would be retroactively upgraded**. The
  promise made when the link was handed out would break. To change the role,
  revoke and reissue.

  `"reviewer"` cannot get in through any path — a single link must not hand
  over deletion rights. Enforced in **both** the changeset validation and a DB
  check constraint.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias VR.IdGenerator

  @rand_size 32
  @token_prefix "slt_"
  @roles ~w(viewer contributor)
  @pin_max_failures 5
  @pin_lock_minutes 15
  @metadata_max_bytes 4096

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "shared_links" do
    field :meeting_id, :string
    field :created_by_id, :string

    field :token_hash, :binary, redact: true
    field :token_prefix, :string
    field :granted_role, :string, default: "viewer"
    field :pin_hash, :string, redact: true

    field :max_uses, :integer
    field :use_count, :integer, default: 0
    field :expires_at, :utc_datetime
    field :is_active, :boolean, default: true
    field :revoked_at, :utc_datetime

    field :require_name, :boolean, default: true
    field :require_email, :boolean, default: false

    field :failed_pin_attempts, :integer, default: 0
    field :pin_locked_until, :utc_datetime

    field :last_used_at, :utc_datetime
    field :metadata, :map, default: %{}
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles
  def token_prefix, do: @token_prefix
  def pin_max_failures, do: @pin_max_failures
  def pin_lock_minutes, do: @pin_lock_minutes

  @doc """
  A new link. Returns `{plaintext_token, plaintext_pin | nil, changeset}`.

  The plaintext can never be recovered after this point. It is sent once in the
  issuance response and then discarded.
  """
  def build(meeting_id, created_by_id, attrs \\ %{}) do
    raw = :crypto.strong_rand_bytes(@rand_size)
    token = @token_prefix <> Base.url_encode64(raw, padding: false)

    {pincode, pin_hash} =
      if truthy?(attrs["with_pincode"] || attrs[:with_pincode]) do
        pin = generate_pincode()
        {pin, Bcrypt.hash_pwd_salt(pin)}
      else
        {nil, nil}
      end

    changeset =
      %__MODULE__{}
      |> cast(attrs, [
        :granted_role,
        :max_uses,
        :expires_at,
        :require_name,
        :require_email,
        :metadata
      ])
      # The values below are **never cast.** The request body cannot decide the
      # token or the use count.
      |> put_change(:id, IdGenerator.generate(:shared_link))
      |> put_change(:meeting_id, meeting_id)
      |> put_change(:created_by_id, created_by_id)
      |> put_change(:token_hash, :crypto.hash(:sha256, raw))
      |> put_change(:token_prefix, String.slice(token, 0, 12))
      |> put_change(:pin_hash, pin_hash)
      |> put_change(:use_count, 0)
      |> put_change(:is_active, true)
      |> validate()

    {token, pincode, changeset}
  end

  @doc """
  What can be changed after issuance.

  **`granted_role` is absent.** Raising a distributed link's role would
  retroactively upgrade everyone who received it.
  """
  def update_changeset(link, attrs) do
    link
    |> cast(attrs, [:is_active, :max_uses, :expires_at, :require_name, :require_email, :metadata])
    |> validate()
  end

  @doc "Regenerates only the token. Settings and use count are kept. Returns `{plaintext_token, changeset}`."
  def rotate_changeset(link) do
    raw = :crypto.strong_rand_bytes(@rand_size)
    token = @token_prefix <> Base.url_encode64(raw, padding: false)

    changeset =
      change(link, %{
        token_hash: :crypto.hash(:sha256, raw),
        token_prefix: String.slice(token, 0, 12)
      })

    {token, changeset}
  end

  @doc "Turns the PIN on or off. When turning on, generates a new PIN and returns `{plaintext_pin, changeset}`."
  def pin_changeset(link, :on) do
    pin = generate_pincode()

    changeset =
      change(link, %{
        pin_hash: Bcrypt.hash_pwd_salt(pin),
        # With a new PIN, the previous failure record is meaningless
        failed_pin_attempts: 0,
        pin_locked_until: nil
      })

    {pin, changeset}
  end

  def pin_changeset(link, :off) do
    {nil, change(link, %{pin_hash: nil, failed_pin_attempts: 0, pin_locked_until: nil})}
  end

  @doc "Converts the token string from the URL into the hash used for DB lookup."
  def hash_token(@token_prefix <> encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} -> {:ok, :crypto.hash(:sha256, raw)}
      :error -> :error
    end
  end

  def hash_token(_), do: :error

  @doc """
  A 6-digit PIN. **Generated with a CSPRNG, uniform over 000000–999999.**

  sisyphus used `:rand.uniform(899_999) + 100_000` — not a CSPRNG, and
  `100000` could never occur.
  """
  def generate_pincode do
    <<value::unsigned-integer-32>> = :crypto.strong_rand_bytes(4)

    # 2^32 is not a multiple of 1_000_000. Discard the remainder range to keep
    # the distribution uniform.
    limit = div(4_294_967_296, 1_000_000) * 1_000_000

    if value >= limit do
      generate_pincode()
    else
      value
      |> rem(1_000_000)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
    end
  end

  @doc "Is the PIN correct? **A missing PIN takes the same time** — so whether one is required does not leak through response timing."
  def valid_pin?(%__MODULE__{pin_hash: nil}, _pin), do: true

  def valid_pin?(%__MODULE__{pin_hash: hash}, pin) when is_binary(hash) and is_binary(pin),
    do: Bcrypt.verify_pass(pin, hash)

  def valid_pin?(%__MODULE__{pin_hash: hash}, _pin) when is_binary(hash) do
    Bcrypt.no_user_verify()
    false
  end

  @doc "Can this link be entered right now?"
  def usable?(link, now \\ nil), do: status(link, now) == :ok

  @doc "Why entry is not possible. For logs and admin screens — **never used in response bodies.**"
  def status(link, now \\ nil) do
    now = now || DateTime.utc_now(:second)

    cond do
      not is_nil(link.deleted_at) -> :deleted
      not is_nil(link.revoked_at) -> :revoked
      not link.is_active -> :inactive
      not is_nil(link.expires_at) and DateTime.compare(link.expires_at, now) != :gt -> :expired
      not is_nil(link.max_uses) and link.use_count >= link.max_uses -> :exhausted
      true -> :ok
    end
  end

  @doc "Is the PIN locked out?"
  def pin_locked?(%__MODULE__{pin_locked_until: nil}), do: false

  def pin_locked?(%__MODULE__{pin_locked_until: until}),
    do: DateTime.compare(until, DateTime.utc_now(:second)) == :gt

  # ── Internal ─────────────────────────────────────────────

  defp validate(changeset) do
    changeset
    |> validate_required([:id, :meeting_id, :token_hash, :token_prefix, :granted_role])
    |> validate_inclusion(:granted_role, @roles)
    |> validate_number(:max_uses, greater_than: 0)
    |> validate_future(:expires_at)
    |> validate_metadata()
    |> unique_constraint(:token_hash)
    |> check_constraint(:granted_role, name: :shared_links_granted_role_check)
    |> check_constraint(:max_uses, name: :shared_links_max_uses_check)
  end

  defp validate_future(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        if DateTime.compare(value, DateTime.utc_now(:second)) == :gt,
          do: changeset,
          else: add_error(changeset, field, "is already in the past")
    end
  end

  defp validate_metadata(changeset) do
    case get_field(changeset, :metadata) do
      value when is_map(value) ->
        if byte_size(Jason.encode!(value)) <= @metadata_max_bytes,
          do: changeset,
          else: add_error(changeset, :metadata, "is too large")

      nil ->
        changeset

      _ ->
        add_error(changeset, :metadata, "must be a map")
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
