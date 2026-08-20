defmodule VR.Push.Subscription do
  @moduledoc """
  웹 푸시 구독 하나. 기기 하나에 해당한다.

  브라우저의 `PushSubscription.toJSON()` 이 주는 세 값(`endpoint`, `keys.p256dh`,
  `keys.auth`)을 그대로 담는다. 이 셋이 있어야 그 기기에 암호화된 알림을 보낼 수 있다.
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
  구독을 만들거나 갱신한다.

  `account_id` 를 **인자로 받는다.** `attrs` 로 받으면 요청 본문이 소유자를
  정할 수 있고, 구조체에 직접 박으면 Ecto 가 변경으로 보지 않아 기기를
  넘겨줬을 때 옛 주인에게 알림이 계속 간다.
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

  @doc "푸시 서비스에 보낼 JSON. 라이브러리가 이 형태를 받는다."
  def to_push_json(%__MODULE__{} = subscription) do
    Jason.encode!(%{
      "endpoint" => subscription.endpoint,
      "keys" => %{"p256dh" => subscription.p256dh, "auth" => subscription.auth}
    })
  end

  # ── 내부 ─────────────────────────────────────────────────

  # endpoint 는 브라우저가 주지만 우리가 그 주소로 요청을 보낸다.
  # 검증 없이 받으면 임의 호스트로 서버를 보낼 수 있다 (SSRF).
  defp validate_endpoint(changeset) do
    case get_field(changeset, :endpoint) do
      nil ->
        changeset

      endpoint ->
        case URI.parse(endpoint) do
          %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
            changeset

          _ ->
            add_error(changeset, :endpoint, "https 주소여야 합니다")
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
