defmodule VR.ConfigTest do
  use VR.DataCase, async: false

  alias VR.Config

  # Uses test-only values, never real keys.
  @key "stt.project_id"
  @env "STT_PROJECT_ID"

  setup do
    original = System.get_env(@env)
    System.delete_env(@env)
    Config.delete(@key)

    on_exit(fn ->
      if original, do: System.put_env(@env, original), else: System.delete_env(@env)
    end)

    :ok
  end

  describe "resolution order" do
    test "nil when set nowhere" do
      assert {nil, :none} = Config.fetch_with_source(@key)
      refute Config.configured?(@key)
    end

    test "reads from the env var when only it exists" do
      System.put_env(@env, "from-env")
      assert {"from-env", :env} = Config.fetch_with_source(@key)
    end

    test "the DB value takes precedence over the env var" do
      System.put_env(@env, "from-env")
      {:ok, _} = Config.put(@key, "from-db")
      assert {"from-db", :db} = Config.fetch_with_source(@key)
    end

    test "deleting the DB value falls back to the env var" do
      System.put_env(@env, "from-env")
      {:ok, _} = Config.put(@key, "from-db")
      :ok = Config.delete(@key)
      assert {"from-env", :env} = Config.fetch_with_source(@key)
    end
  end

  describe "saving empty values (admin form safeguard)" do
    test "an empty string does not erase the existing value" do
      {:ok, _} = Config.put(@key, "keep-me")
      {:ok, :unchanged} = Config.put(@key, "")
      assert Config.fetch(@key) == "keep-me"
    end

    test "nil does not erase the existing value either" do
      {:ok, _} = Config.put(@key, "keep-me")
      {:ok, :unchanged} = Config.put(@key, nil)
      assert Config.fetch(@key) == "keep-me"
    end
  end

  describe "encryption at rest" do
    test "not stored in the DB as plaintext" do
      {:ok, _} = Config.put(@key, "super-secret-value")

      %{rows: [[raw]]} =
        VR.Repo.query!("SELECT value_encrypted FROM system_configs WHERE key = $1", [@key])

      refute String.contains?(raw, "super-secret-value")
      assert String.contains?(raw, "AES.GCM.V1")
      assert Config.fetch(@key) == "super-secret-value"
    end
  end

  describe "type casting" do
    test "boolean" do
      {:ok, _} = Config.put("stt.dev_mode", "true")
      assert Config.fetch("stt.dev_mode") == true

      {:ok, _} = Config.put("stt.dev_mode", "false")
      assert Config.fetch("stt.dev_mode") == false
    end
  end

  describe "unknown keys" do
    test "refuses to save keys not in the registry" do
      assert {:error, changeset} = Config.put("evil.backdoor", "x")
      assert %{key: ["is not a known configuration key"]} = errors_on(changeset)
    end
  end

  describe "feature readiness" do
    test "considered not ready when required values are missing" do
      refute Config.feature_ready?(:transcription)

      statuses = Config.feature_status()
      stt = Enum.find(statuses, &(&1.feature == :transcription))
      refute stt.ready
      assert length(stt.missing) > 0
    end
  end
end
