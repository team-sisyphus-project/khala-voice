defmodule VR.Billing.PlanRevision do
  @moduledoc """
  A plan's **immutable** commercial snapshot.

  **Source: devkanban** `lib/manualsquad/billing/plan_revision.ex`
  — removed runtime seconds, concurrency counts, and credit pack links.

  Once published, it is never edited. To change the price or included credits,
  **publish a new revision.** Subscriptions pin a specific revision, so existing
  contracts stay intact.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.Billing.Plan
  alias VR.IdGenerator

  @intervals ~w(month year)

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "plan_revisions" do
    field :revision, :integer
    # Prices per currency. %{"KRW" => %{"amount" => 0}} — minor unit (won, cents)
    field :prices, :map, default: %{}
    field :interval, :string, default: "month"
    # Credits granted each period
    field :included_credits, :integer, default: 0
    field :limits, :map, default: %{}
    field :purchasable, :boolean, default: true
    field :published_at, :utc_datetime

    belongs_to :plan, Plan

    timestamps(type: :utc_datetime)
  end

  def intervals, do: @intervals

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :plan_id,
      :revision,
      :prices,
      :interval,
      :included_credits,
      :limits,
      :purchasable,
      :published_at
    ])
    |> put_id()
    |> validate_required([:id, :plan_id, :revision])
    |> validate_inclusion(:interval, @intervals)
    |> validate_number(:included_credits, greater_than_or_equal_to: 0)
    |> validate_prices()
    |> unique_constraint([:plan_id, :revision])
    |> foreign_key_constraint(:plan_id)
  end

  @doc """
  The credits this revision grants.

  **Source: devkanban** `plan_revision.ex:102` `granted_credits/1`.
  devkanban also looked at credit pack links, but this app has no packs, so
  it is only `included_credits`.
  """
  def granted_credits(%__MODULE__{included_credits: credits}) when is_integer(credits),
    do: credits

  def granted_credits(_revision), do: 0

  @doc "The price in this currency (minor unit). nil when absent."
  def price(%__MODULE__{prices: prices}, currency) do
    case prices do
      %{^currency => %{"amount" => amount}} when is_integer(amount) -> amount
      _ -> nil
    end
  end

  @doc "Whether this is a free revision — zero in every currency."
  def free?(%__MODULE__{prices: prices}) when map_size(prices) == 0, do: true

  def free?(%__MODULE__{prices: prices}) do
    Enum.all?(prices, fn {_currency, entry} -> Map.get(entry, "amount", 0) == 0 end)
  end

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, IdGenerator.generate(:plan_revision))
      "" -> put_change(changeset, :id, IdGenerator.generate(:plan_revision))
      _ -> changeset
    end
  end

  # A malformed price map breaks the entire checkout screen. Block it before saving.
  defp validate_prices(changeset) do
    case get_field(changeset, :prices) do
      prices when is_map(prices) ->
        valid? =
          Enum.all?(prices, fn
            {currency, %{"amount" => amount}} when is_binary(currency) and is_integer(amount) ->
              amount >= 0

            _ ->
              false
          end)

        if valid?,
          do: changeset,
          else: add_error(changeset, :prices, ~s(must be in the form %{"KRW" => %{"amount" => 0}}))

      _ ->
        add_error(changeset, :prices, "must be a map")
    end
  end
end
