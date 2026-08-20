defmodule VR.Summarize.LlmProvider do
  @moduledoc """
  AI 요약에 쓰는 LLM 제공자 설정.

  여러 제공자를 등록해 두고 `priority` 오름차순으로 시도한다.
  앞선 제공자가 레이트리밋이나 5xx로 실패하면 다음으로 넘어간다.

  `tier`는 `billing_model_pricing`과 조인해 토큰 사용량을 크레딧으로 환산하는 데 쓴다.
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

    # 토큰 단가 — 출처: devkanban `MS.Meters.UsageRecorder.price_tokens/3`
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

  @doc "빈 API 키는 기존 값 유지 (어드민 폼에서 마스킹된 필드를 안 건드린 경우)"
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
