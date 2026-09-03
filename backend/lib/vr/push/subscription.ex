defmodule VR.Push.Subscription do
  @moduledoc """
  One web push subscription. Corresponds to one device.

  Holds, as is, the three values the browser's `PushSubscription.toJSON()`
  provides (`endpoint`, `keys.p256dh`, `keys.auth`). All three are needed to
  send an encrypted notification to that device.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias VR.IdGenerator

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "push_subscriptions" do
    field :account_id, :string
    field :endpoint, :string
    field :p256dh, :string, redact: true
    field :auth, :string, redact: true
    field :user_agent, :string
    field :last_used_at, :utc_datetime
    field :failed_count, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc """
  Create or update a subscription.

  `account_id` is **taken as an argument.** Accepting it via `attrs` would let
  the request body decide the owner, and setting it directly on the struct
  means Ecto does not see it as a change — so when a device is handed over,
  notifications keep going to the previous owner.
  """
  def changeset(subscription, account_id, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth, :user_agent])
    |> put_change(:account_id, account_id)
    |> put_id()
    |> validate_required([:id, :account_id, :endpoint, :p256dh, :auth])
    |> validate_endpoint()
    |> unique_constraint(:endpoint)
  end

  @doc "The JSON to send to the push service. The library accepts this shape."
  def to_push_json(%__MODULE__{} = subscription) do
    Jason.encode!(%{
      "endpoint" => subscription.endpoint,
      "keys" => %{"p256dh" => subscription.p256dh, "auth" => subscription.auth}
    })
  end

  # ── Internal ─────────────────────────────────────────────

  # The endpoint comes from the browser, but we are the ones sending requests to it.
  # Accepting it unvalidated lets the server be pointed at an arbitrary host (SSRF).
  defp validate_endpoint(changeset) do
    case get_field(changeset, :endpoint) do
      nil ->
        changeset

      endpoint ->
        case URI.parse(endpoint) do
          %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
            changeset

          _ ->
            add_error(changeset, :endpoint, "must be an https URL")
        end
    end
  end

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      value when value in [nil, ""] ->
        put_change(changeset, :id, IdGenerator.generate(:push_subscription))

      _ ->
        changeset
    end
  end
end
