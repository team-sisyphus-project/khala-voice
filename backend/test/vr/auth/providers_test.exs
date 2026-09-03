defmodule VR.Auth.ProvidersTest do
  use VR.DataCase, async: false

  alias VR.Auth.Providers

  describe "activation decision" do
    test "not exposed without credentials" do
      google = Providers.get("google")
      refute google.credentials_present
      refute google.active
      assert Providers.list_active() == []
      refute Providers.active?("google")
    end

    test "cannot be enabled without credentials" do
      assert {:error, :credentials_missing} = Providers.set_enabled("google", true)
    end

    test "not exposed when disabled even with credentials" do
      {:ok, _} = Providers.upsert("google", %{"client_id" => "cid", "client_secret" => "sec"})

      google = Providers.get("google")
      assert google.credentials_present
      refute google.enabled
      refute google.active
    end

    test "exposed when credentials exist and it is enabled" do
      {:ok, _} = Providers.upsert("google", %{"client_id" => "cid", "client_secret" => "sec"})
      {:ok, _} = Providers.set_enabled("google", true)

      assert Providers.active?("google")
      assert ["google"] = Enum.map(Providers.list_active(), & &1.provider)
    end
  end

  describe "secret preservation" do
    test "saving with an empty client_secret keeps the existing value" do
      {:ok, _} = Providers.upsert("google", %{"client_id" => "cid", "client_secret" => "sec"})
      {:ok, _} = Providers.upsert("google", %{"client_secret" => ""})

      assert Providers.get("google").credentials_present
    end

    test "client_secret is not stored in the DB as plaintext" do
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

  describe "env var fallback" do
    test "credentials come from env vars but enabled only flips in the DB" do
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
