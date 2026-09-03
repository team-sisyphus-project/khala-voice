defmodule VR.Summarize.LlmProvider do
  @moduledoc """
  LLM provider configuration used for AI summaries.

  Multiple providers can be registered and are tried in ascending `priority`
  order. When an earlier provider fails with a rate limit or 5xx, we move on
  to the next one.

  `tier` is joined with `billing_model_pricing` to convert token usage into credits.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(gemini anthropic openai)
  @tiers ~w(high mid low)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "llm_providers" do
    field :provider, :string
    field :display_name, :string
    field :api_key, VR.Encrypted.Binary, source: :api_key_encrypted
    field :base_url, :string
    field :model, :string
    field :tier, :string, default: "mid"
    field :temperature, :decimal, default: Decimal.new("0.2")
    field :max_output_tokens, :integer, default: 16_384

    # Token pricing — origin: devkanban `MS.Meters.UsageRecorder.price_tokens/3`
    field :input_price_usd_per_1m, :decimal
    field :output_price_usd_per_1m, :decimal
    field :margin_rate, :decimal, default: Decimal.new("0")
    field :enabled, :boolean, default: false
    field :priority, :integer, default: 100
    field :updated_by_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  def providers, do: @providers
  def tiers, do: @tiers

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :provider,
      :display_name,
      :api_key,
      :base_url,
      :model,
      :tier,
      :temperature,
      :max_output_tokens,
      :input_price_usd_per_1m,
      :output_price_usd_per_1m,
      :margin_rate,
      :enabled,
      :priority,
      :updated_by_id
    ])
    |> validate_required([:provider, :model])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:tier, @tiers)
    |> validate_number(:max_output_tokens, greater_than: 0)
    |> validate_number(:input_price_usd_per_1m, greater_than_or_equal_to: 0)
    |> validate_number(:output_price_usd_per_1m, greater_than_or_equal_to: 0)
    |> validate_number(:margin_rate, greater_than_or_equal_to: 0)
    |> unique_constraint(:provider)
  end

  @doc "An empty API key keeps the existing value (when the masked field in the admin form was left untouched)"
  def admin_changeset(provider, attrs) do
    attrs =
      Enum.reduce(["api_key", :api_key], attrs, fn key, acc ->
        case Map.get(acc, key) do
          v when v in [nil, ""] -> Map.delete(acc, key)
          _ -> acc
        end
      end)

    changeset(provider, attrs)
  end
end
