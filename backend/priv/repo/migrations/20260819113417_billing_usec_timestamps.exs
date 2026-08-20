defmodule VR.Repo.Migrations.BillingUsecTimestamps do
  use Ecto.Migration

  @moduledoc """
  크레딧 묶음·원장의 시각을 마이크로초로 올린다.

  초 단위로는 같은 초에 들어간 항목들의 순서를 가릴 수 없다.
  원장은 "무슨 일이 어떤 순서로 있었나"가 전부라 순서가 흔들리면 안 된다.

  **출처: devkanban** — `credit_lot.ex` 도 `utc_datetime_usec` 를 쓴다.
  """

  def up do
    alter table(:credit_lots) do
      modify :inserted_at, :utc_datetime_usec
      modify :updated_at, :utc_datetime_usec
      modify :expires_at, :utc_datetime_usec
      modify :expired_at, :utc_datetime_usec
    end

    alter table(:credit_ledger_entries) do
      modify :inserted_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:credit_lots) do
      modify :inserted_at, :utc_datetime
      modify :updated_at, :utc_datetime
      modify :expires_at, :utc_datetime
      modify :expired_at, :utc_datetime
    end

    alter table(:credit_ledger_entries) do
      modify :inserted_at, :utc_datetime
    end
  end
end
