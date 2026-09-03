defmodule VR.PushTest do
  use VR.DataCase, async: false

  import VR.AccountsFixtures

  alias VR.{Config, Push}
  alias VR.Push.Subscription

  setup do
    # `Config.put(key, "")` is a no-op (an empty admin-form field = keep).
    # Removal requires delete/1.
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

  describe "subscriptions" do
    test "registers and shows up in the list", %{account: account} do
      assert {:ok, sub} = Push.subscribe(account.id, attrs())

      assert String.starts_with?(sub.id, "push_")
      assert [_] = Push.list_subscriptions(account.id)
    end

    test "re-registering the same device updates it", %{account: account} do
      # The browser hands back the same endpoint. A new row would mean double notifications.
      {:ok, first} = Push.subscribe(account.id, attrs())
      {:ok, second} = Push.subscribe(account.id, attrs())

      assert first.id == second.id
      assert length(Push.list_subscriptions(account.id)) == 1
    end

    test "rejects non-https endpoints", %{account: account} do
      # Our server sends requests to this address. Without validation it is SSRF.
      assert {:error, _} = Push.subscribe(account.id, attrs("http://evil.test/push"))
      assert {:error, _} = Push.subscribe(account.id, attrs("file:///etc/passwd"))
      assert {:error, _} = Push.subscribe(account.id, attrs("not a url"))
    end

    test "ownership transfers when another account registers the same device", %{account: account} do
      # The device changed hands. The old owner must not keep receiving notifications.
      other = account_fixture()

      {:ok, _} = Push.subscribe(account.id, attrs())
      {:ok, _} = Push.subscribe(other.id, attrs())

      assert Push.list_subscriptions(account.id) == []
      assert [_] = Push.list_subscriptions(other.id)
    end

    test "unsubscribing removes it", %{account: account} do
      {:ok, sub} = Push.subscribe(account.id, attrs())

      assert {:ok, 1} = Push.unsubscribe(account.id, sub.endpoint)
      assert Push.list_subscriptions(account.id) == []
    end

    test "cannot unsubscribe someone else's subscription", %{account: account} do
      other = account_fixture()
      {:ok, sub} = Push.subscribe(other.id, attrs())

      assert {:ok, 0} = Push.unsubscribe(account.id, sub.endpoint)
      assert [_] = Push.list_subscriptions(other.id)
    end
  end

  describe "send readiness" do
    setup do
      # If the dev `.env` has VAPID keys, Config falls back to them.
      # This block needs the "no keys at all" state, so env vars are cleared for a moment too.
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

    test "does not send without keys", %{account: account} do
      {:ok, _} = Push.subscribe(account.id, attrs())

      refute Push.ready?()
      # Callers must not crash without keys — notifications are a nice-to-have
      assert :ok = Push.notify(account.id, "Title", "Body")
    end

    test "DB values take precedence over env vars", _ctx do
      System.put_env("VAPID_PUBLIC_KEY", "env-public")
      Config.put("push.vapid_public_key", "db-public", nil)
      Config.put("push.vapid_private_key", "db-private", nil)

      assert Push.ready?()
      assert Push.public_key() == "db-public"
    end

    test "falls back to env vars without DB values", _ctx do
      System.put_env("VAPID_PUBLIC_KEY", "env-public")
      System.put_env("VAPID_PRIVATE_KEY", "env-private")

      assert Push.ready?()
      assert Push.public_key() == "env-public"
    end
  end

  describe "secret handling" do
    test "subscription keys are not exposed via inspect", %{account: account} do
      {:ok, sub} = Push.subscribe(account.id, attrs())
      dumped = inspect(sub)

      refute dumped =~ "BKxQ_fake_public_key"
      refute dumped =~ "fake_auth"
    end
  end

  describe "to_push_json/1" do
    test "reproduces the exact shape the browser gave", %{account: account} do
      {:ok, sub} = Push.subscribe(account.id, attrs())

      decoded = Jason.decode!(Subscription.to_push_json(sub))

      assert decoded["endpoint"] == sub.endpoint
      assert decoded["keys"]["p256dh"] == sub.p256dh
      assert decoded["keys"]["auth"] == sub.auth
    end
  end
end
