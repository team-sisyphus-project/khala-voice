defmodule VR.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  @moduledoc """
  웹 푸시 구독. 기기 하나당 한 행.

  `endpoint` 가 사실상의 기기 식별자다 — 브라우저가 발급하고 재설치하면 바뀐다.
  같은 계정이 여러 기기를 쓰므로 계정당 여러 행이다.

  ## 실패를 세는 이유

  구독은 조용히 죽는다 (브라우저 재설치 · 알림 권한 철회 · 푸시 서비스 정리).
  410/404 를 받으면 즉시 지우지만, 그 외 실패가 쌓이는 구독도 결국 쓸모없다.
  세어 두고 일정 횟수를 넘으면 정리한다.
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

    # 같은 기기가 두 번 등록되지 않게 한다. 브라우저가 같은 endpoint 를 다시 준다.
    create unique_index(:push_subscriptions, [:endpoint])
    create index(:push_subscriptions, [:account_id])
  end
end
