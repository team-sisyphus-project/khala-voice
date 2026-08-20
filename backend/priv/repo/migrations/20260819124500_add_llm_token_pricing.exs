defmodule VR.Repo.Migrations.AddLlmTokenPricing do
  use Ecto.Migration

  @moduledoc """
  LLM 토큰 단가.

  **출처: devkanban** `MS.Meters.UsageRecorder.price_tokens/3` —
  `input_price_usd_per_1m` · `output_price_usd_per_1m` · `margin_rate` 구성과
  계산식(백만 토큰당 단가 → 마진 가산)을 그대로 따른다.

  단가를 비워 두면 계량하지 않는다. STT 와 같은 규칙이다
  (요금 설정이 덜 됐다고 요약을 실패시키지 않는다).
  """

  def change do
    alter table(:llm_providers) do
      add :input_price_usd_per_1m, :decimal
      add :output_price_usd_per_1m, :decimal
      add :margin_rate, :decimal, null: false, default: 0
    end
  end
end
