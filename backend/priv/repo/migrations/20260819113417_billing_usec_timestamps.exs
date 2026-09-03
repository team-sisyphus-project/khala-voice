defmodule VR.Repo.Migrations.BillingUsecTimestamps do
  use Ecto.Migration

  @moduledoc """
  Raises credit lot/ledger timestamps to microsecond precision.

  At second precision, entries inserted within the same second cannot be
  ordered. The ledger is entirely "what happened, in what order", so the
  ordering must not wobble.

  **Source: devkanban** — `credit_lot.ex` also uses `utc_datetime_usec`.
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
