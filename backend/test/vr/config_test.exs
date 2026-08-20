defmodule VR.ConfigTest do
  use VR.DataCase, async: false

  alias VR.Config

  # 실제 키가 아닌 테스트 전용 값만 사용한다.
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

  describe "해석 순서" do
    test "아무 데도 없으면 nil" do
      assert {nil, :none} = Config.fetch_with_source(@key)
      refute Config.configured?(@key)
    end

    test "환경변수만 있으면 환경변수에서 읽는다" do
      System.put_env(@env, "from-env")
      assert {"from-env", :env} = Config.fetch_with_source(@key)
    end

    test "DB 값이 환경변수보다 우선한다" do
      System.put_env(@env, "from-env")
      {:ok, _} = Config.put(@key, "from-db")
      assert {"from-db", :db} = Config.fetch_with_source(@key)
    end

    test "DB 값을 지우면 환경변수로 되돌아간다" do
      System.put_env(@env, "from-env")
      {:ok, _} = Config.put(@key, "from-db")
      :ok = Config.delete(@key)
      assert {"from-env", :env} = Config.fetch_with_source(@key)
    end
  end

  describe "빈 값 저장 (어드민 폼 안전장치)" do
    test "빈 문자열은 기존 값을 지우지 않는다" do
      {:ok, _} = Config.put(@key, "keep-me")
      {:ok, :unchanged} = Config.put(@key, "")
      assert Config.fetch(@key) == "keep-me"
    end

    test "nil도 기존 값을 지우지 않는다" do
      {:ok, _} = Config.put(@key, "keep-me")
      {:ok, :unchanged} = Config.put(@key, nil)
      assert Config.fetch(@key) == "keep-me"
    end
  end

  describe "저장 시 암호화" do
    test "DB에 평문으로 남지 않는다" do
      {:ok, _} = Config.put(@key, "super-secret-value")

      %{rows: [[raw]]} =
        VR.Repo.query!("SELECT value_encrypted FROM system_configs WHERE key = $1", [@key])

      refute String.contains?(raw, "super-secret-value")
      assert String.contains?(raw, "AES.GCM.V1")
      assert Config.fetch(@key) == "super-secret-value"
    end
  end

  describe "타입 변환" do
    test "boolean" do
      {:ok, _} = Config.put("stt.dev_mode", "true")
      assert Config.fetch("stt.dev_mode") == true

      {:ok, _} = Config.put("stt.dev_mode", "false")
      assert Config.fetch("stt.dev_mode") == false
    end
  end

  describe "알 수 없는 키" do
    test "레지스트리에 없는 키는 저장을 거부한다" do
      assert {:error, changeset} = Config.put("evil.backdoor", "x")
      assert %{key: ["알 수 없는 설정 키입니다"]} = errors_on(changeset)
    end
  end

  describe "기능 준비 상태" do
    test "필수 값이 빠지면 준비되지 않은 것으로 본다" do
      refute Config.feature_ready?(:transcription)

      statuses = Config.feature_status()
      stt = Enum.find(statuses, &(&1.feature == :transcription))
      refute stt.ready
      assert length(stt.missing) > 0
    end
  end
end
