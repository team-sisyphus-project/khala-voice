defmodule VR.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  @moduledoc """
  Web push subscriptions. One row per device.

  `endpoint` is the de facto device identifier — issued by the browser,
  changed on reinstall. One account uses several devices, so several rows
  per account.

  ## Why failures are counted

  Subscriptions die silently (browser reinstall · notification permission
  revoked · push service cleanup). A 410/404 deletes the row immediately, but
  a subscription piling up other failures is useless too. We count them and
  clean up past a threshold.
  """

  def change do
    create table(:push_subscriptions, primary_key: false) do
      add :id, :string, primary_key: true
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all), null: false

      add :endpoint, :text, null: false
      add :p256dh, :string, null: false
      add :auth, :string, null: false

      add :user_agent, :string
      add :last_used_at, :utc_datetime
      add :failed_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    # Keeps the same device from registering twice. The browser hands back the same endpoint.
    create unique_index(:push_subscriptions, [:endpoint])
    create index(:push_subscriptions, [:account_id])
  end
end
