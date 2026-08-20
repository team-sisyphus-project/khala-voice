defmodule VR.Auth.ProvidersTest do
  use VR.DataCase, async: false

  alias VR.Auth.Providers

  describe "활성화 판정" do
    test "키가 없으면 노출되지 않는다" do
      google = Providers.get("google")
      refute google.credentials_present
      refute google.active
      assert Providers.list_active() == []
      refute Providers.active?("google")
    end

    test "키가 없으면 켤 수 없다" do
      assert {:error, :credentials_missing} = Providers.set_enabled("google", true)
    end

    test "키가 있어도 꺼져 있으면 노출되지 않는다" do
      {:ok, _} = Providers.upsert("google", %{"client_id" => "cid", "client_secret" => "sec"})

      google = Providers.get("google")
      assert google.credentials_present
      refute google.enabled
      refute google.active
    end

    test "키가 있고 켜면 노출된다" do
      {:ok, _} = Providers.upsert("google", %{"client_id" => "cid", "client_secret" => "sec"})
      {:ok, _} = Providers.set_enabled("google", true)

      assert Providers.active?("google")
      assert ["google"] = Enum.map(Providers.list_active(), & &1.provider)
    end
  end

  describe "비밀값 보존" do
    test "빈 client_secret으로 저장해도 기존 값이 유지된다" do
      {:ok, _} = Providers.upsert("google", %{"client_id" => "cid", "client_secret" => "sec"})
      {:ok, _} = Providers.upsert("google", %{"client_secret" => ""})

      assert Providers.get("google").credentials_present
    end

    test "client_secret은 DB에 평문으로 남지 않는다" do
      {:ok, _} =
        Providers.upsert("google", %{"client_id" => "cid", "client_secret" => "plaintext-secret"})

      %{rows: [[raw]]} =
        VR.Repo.query!("SELECT client_secret_encrypted FROM auth_providers WHERE provider = $1", [
          "google"
        ])

      refute String.contains?(raw, "plaintext-secret")
      assert String.contains?(raw, "AES.GCM.V1")
    end
  end

  describe "환경변수 폴백" do
    test "키는 환경변수에서 읽지만 enabled는 DB에서만 켜진다" do
      System.put_env("GOOGLE_OAUTH_CLIENT_ID", "env-cid")
      System.put_env("GOOGLE_OAUTH_CLIENT_SECRET", "env-sec")

      on_exit(fn ->
        System.delete_env("GOOGLE_OAUTH_CLIENT_ID")
        System.delete_env("GOOGLE_OAUTH_CLIENT_SECRET")
      end)

      google = Providers.get("google")
      assert google.credentials_present
      assert google.credentials_source == :env
      refute google.active
    end
  end
end
