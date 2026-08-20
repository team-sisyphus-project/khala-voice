defmodule VR.Push do
  @moduledoc """
  웹 푸시 알림.

  전사·요약은 몇 분씩 걸린다. 사용자가 화면을 닫아도 끝났다는 것을 알려야
  다시 돌아와 확인한다.

  ## 알림은 부가 기능이다

  실패해도 **작업을 실패시키지 않는다.** 전사가 끝났는데 알림을 못 보냈다고
  전사를 롤백하면 그게 더 큰 손해다. 모든 실패는 로그로만 남긴다.

  ## 본문에 회의 내용을 담지 않는다

  푸시 페이로드는 암호화되지만 잠금화면에 그대로 뜬다. 제목 정도는 몰라도
  전사 본문이나 요약이 화면에 뜨면 곤란하다. "전사가 끝났습니다" 까지만 보낸다.
  """

  import Ecto.Query, warn: false

  alias VR.Config
  alias VR.Push.Subscription
  alias VR.Repo

  require Logger

  # 이만큼 연달아 실패하면 죽은 구독으로 본다
  @max_failures 5

  @doc "이 환경에서 푸시를 보낼 수 있는가. 어드민 대시보드가 쓴다."
  def ready?, do: not is_nil(public_key()) and not is_nil(private_key())

  @doc "브라우저가 구독할 때 필요한 공개키."
  def public_key, do: present(Config.fetch("push.vapid_public_key"))

  @doc "계정의 구독 목록."
  def list_subscriptions(account_id) do
    Repo.all(from s in Subscription, where: s.account_id == ^account_id)
  end

  @doc """
  구독을 등록한다. 같은 기기가 다시 등록하면 갱신한다.

  브라우저는 같은 `endpoint` 를 다시 주므로 새 행을 만들면 중복 알림이 간다.
  """
  def subscribe(account_id, attrs) do
    endpoint = attrs["endpoint"] || attrs[:endpoint]

    existing = endpoint && Repo.get_by(Subscription, endpoint: endpoint)

    (existing || %Subscription{})
    |> Subscription.changeset(account_id, attrs)
    |> Ecto.Changeset.put_change(:failed_count, 0)
    |> Repo.insert_or_update()
  end

  @doc "구독을 지운다. 브라우저가 구독을 해제했을 때."
  def unsubscribe(account_id, endpoint) do
    {count, _} =
      Repo.delete_all(
        from s in Subscription,
          where: s.account_id == ^account_id and s.endpoint == ^endpoint
      )

    {:ok, count}
  end

  @doc """
  계정의 모든 기기에 알린다.

  ## 옵션
  - `:url` — 알림을 눌렀을 때 갈 곳
  - `:tag` — 같은 태그의 알림은 서로를 대체한다 (같은 회의 알림이 쌓이지 않게)
  """
  def notify(account_id, title, body, opts \\ []) do
    if ready?() do
      payload =
        Jason.encode!(%{
          "title" => title,
          "body" => body,
          "url" => opts[:url] || "/go/meetings",
          "tag" => opts[:tag] || "vr"
        })

      account_id
      |> list_subscriptions()
      |> Enum.each(&deliver(&1, payload))
    end

    :ok
  end

  # ── 내부 ─────────────────────────────────────────────────

  defp deliver(%Subscription{} = subscription, payload) do
    configure_vapid()

    case WebPushElixir.send_notification(Subscription.to_push_json(subscription), payload) do
      {:ok, _} ->
        touch(subscription)

      # 브라우저가 구독을 버렸다. 다시 보낼 이유가 없다.
      {:error, :expired} ->
        Repo.delete(subscription)

      {:error, reason} ->
        Logger.warning("[Push] 전송 실패: #{inspect(reason)}")
        bump_failure(subscription)
    end
  rescue
    error ->
      # 알림 때문에 부르는 쪽이 죽으면 안 된다
      Logger.warning("[Push] 전송 중 예외: #{inspect(error)}")
      bump_failure(subscription)
  end

  # 라이브러리가 애플리케이션 환경에서 키를 읽는다. 우리 설정은 DB→ENV 순이라
  # 보내기 직전에 옮겨 담는다. 키는 사실상 고정이라 경합 문제가 되지 않는다.
  defp configure_vapid do
    Application.put_env(:web_push_elixir, :vapid_public_key, public_key())
    Application.put_env(:web_push_elixir, :vapid_private_key, private_key())
    Application.put_env(:web_push_elixir, :vapid_subject, subject())
  end

  defp touch(%Subscription{} = subscription) do
    Repo.update_all(
      from(s in Subscription, where: s.id == ^subscription.id),
      set: [last_used_at: DateTime.utc_now(:second), failed_count: 0]
    )
  end

  defp bump_failure(%Subscription{} = subscription) do
    if subscription.failed_count + 1 >= @max_failures do
      Repo.delete(subscription)
    else
      Repo.update_all(from(s in Subscription, where: s.id == ^subscription.id),
        inc: [failed_count: 1]
      )
    end
  end

  defp private_key, do: present(Config.fetch("push.vapid_private_key"))

  defp subject do
    present(Config.fetch("push.vapid_subject")) || "mailto:admin@example.com"
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
