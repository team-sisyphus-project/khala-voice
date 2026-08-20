defmodule VR.PushTest do
  use VR.DataCase, async: false

  import VR.AccountsFixtures

  alias VR.{Config, Push}
  alias VR.Push.Subscription

  setup do
    # `Config.put(key, "")` 는 no-op 이다 (어드민 폼에서 빈 칸 = 유지).
    # 지우려면 delete/1 을 써야 한다.
    Config.delete("push.vapid_public_key")
    Config.delete("push.vapid_private_key")

    %{account: account_fixture()}
  end

  defp attrs(endpoint \\ "https://fcm.googleapis.com/fcm/send/abc") do
    %{
      "endpoint" => endpoint,
      "p256dh" => "BKxQ_fake_public_key",
      "auth" => "fake_auth"
    }
  end

  describe "구독" do
    test "등록하고 목록에 나온다", %{account: account} do
      assert {:ok, sub} = Push.subscribe(account.id, attrs())

      assert String.starts_with?(sub.id, "push_")
      assert [_] = Push.list_subscriptions(account.id)
    end

    test "같은 기기가 다시 등록하면 갱신한다", %{account: account} do
      # 브라우저는 같은 endpoint 를 다시 준다. 새 행을 만들면 알림이 두 번 간다.
      {:ok, first} = Push.subscribe(account.id, attrs())
      {:ok, second} = Push.subscribe(account.id, attrs())

      assert first.id == second.id
      assert length(Push.list_subscriptions(account.id)) == 1
    end

    test "https 가 아닌 endpoint 는 거부한다", %{account: account} do
      # 이 주소로 우리 서버가 요청을 보낸다. 검증하지 않으면 SSRF 다.
      assert {:error, _} = Push.subscribe(account.id, attrs("http://evil.test/push"))
      assert {:error, _} = Push.subscribe(account.id, attrs("file:///etc/passwd"))
      assert {:error, _} = Push.subscribe(account.id, attrs("not a url"))
    end

    test "다른 계정이 같은 기기를 등록하면 소유자가 넘어간다", %{account: account} do
      # 기기를 넘겨준 경우다. 옛 주인에게 계속 알림이 가면 안 된다.
      other = account_fixture()

      {:ok, _} = Push.subscribe(account.id, attrs())
      {:ok, _} = Push.subscribe(other.id, attrs())

      assert Push.list_subscriptions(account.id) == []
      assert [_] = Push.list_subscriptions(other.id)
    end

    test "해지하면 사라진다", %{account: account} do
      {:ok, sub} = Push.subscribe(account.id, attrs())

      assert {:ok, 1} = Push.unsubscribe(account.id, sub.endpoint)
      assert Push.list_subscriptions(account.id) == []
    end

    test "남의 구독은 해지할 수 없다", %{account: account} do
      other = account_fixture()
      {:ok, sub} = Push.subscribe(other.id, attrs())

      assert {:ok, 0} = Push.unsubscribe(account.id, sub.endpoint)
      assert [_] = Push.list_subscriptions(other.id)
    end
  end

  describe "발송 준비 상태" do
    setup do
      # 개발 `.env` 에 VAPID 키가 있으면 Config 가 그걸로 폴백한다.
      # 이 블록은 "키가 아예 없는" 상태를 봐야 하므로 환경변수도 잠시 걷어낸다.
      saved =
        for key <- ~w(VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY), into: %{} do
          value = System.get_env(key)
          System.delete_env(key)
          {key, value}
        end

      on_exit(fn ->
        Enum.each(saved, fn
          {_key, nil} -> :ok
          {key, value} -> System.put_env(key, value)
        end)
      end)

      :ok
    end

    test "키가 없으면 보내지 않는다", %{account: account} do
      {:ok, _} = Push.subscribe(account.id, attrs())

      refute Push.ready?()
      # 키가 없어도 부르는 쪽이 죽지 않는다 — 알림은 부가 기능이다
      assert :ok = Push.notify(account.id, "제목", "본문")
    end

    test "DB 값이 환경변수보다 우선한다", _ctx do
      System.put_env("VAPID_PUBLIC_KEY", "env-public")
      Config.put("push.vapid_public_key", "db-public", nil)
      Config.put("push.vapid_private_key", "db-private", nil)

      assert Push.ready?()
      assert Push.public_key() == "db-public"
    end

    test "DB 값이 없으면 환경변수로 폴백한다", _ctx do
      System.put_env("VAPID_PUBLIC_KEY", "env-public")
      System.put_env("VAPID_PRIVATE_KEY", "env-private")

      assert Push.ready?()
      assert Push.public_key() == "env-public"
    end
  end

  describe "비밀 취급" do
    test "구독 키가 inspect 에 노출되지 않는다", %{account: account} do
      {:ok, sub} = Push.subscribe(account.id, attrs())
      dumped = inspect(sub)

      refute dumped =~ "BKxQ_fake_public_key"
      refute dumped =~ "fake_auth"
    end
  end

  describe "to_push_json/1" do
    test "브라우저가 준 모양 그대로 만든다", %{account: account} do
      {:ok, sub} = Push.subscribe(account.id, attrs())

      decoded = Jason.decode!(Subscription.to_push_json(sub))

      assert decoded["endpoint"] == sub.endpoint
      assert decoded["keys"]["p256dh"] == sub.p256dh
      assert decoded["keys"]["auth"] == sub.auth
    end
  end
end
