defmodule VR.Repo.Migrations.AddLlmTokenPricing do
  use Ecto.Migration

  @moduledoc """
  LLM token pricing.

  **Source: devkanban** `MS.Meters.UsageRecorder.price_tokens/3` —
  follows its `input_price_usd_per_1m` · `output_price_usd_per_1m` · `margin_rate`
  fields and formula (per-million-token rate → add margin) as-is.

  If the rates are left blank, usage is not metered. Same rule as STT
  (an unfinished pricing setup must not fail summarization).
  """

  def change do
    alter table(:llm_providers) do
      add :input_price_usd_per_1m, :decimal
      add :output_price_usd_per_1m, :decimal
      add :margin_rate, :decimal, null: false, default: 0
    end
  end
end
