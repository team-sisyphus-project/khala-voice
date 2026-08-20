defmodule VR.Summarize.LlmProvidersTest do
  use VR.DataCase, async: false

  alias VR.Summarize.LlmProviders

  setup do
    for name <- ~w(LLM_PROVIDER LLM_API_KEY LLM_MODEL), do: System.delete_env(name)
    :ok
  end

  test "아무것도 없으면 요약이 비활성" do
    refute LlmProviders.ready?()
    assert LlmProviders.primary() == nil
  end

  test "키가 있고 켜면 사용 가능" do
    {:ok, _} =
      LlmProviders.upsert(%{
        "provider" => "gemini",
        "model" => "gemini-2.5-flash",
        "api_key" => "k",
        "enabled" => true
      })

    assert LlmProviders.ready?()
    assert LlmProviders.primary().provider == "gemini"
  end

  test "우선순위가 낮은 제공자를 먼저 쓴다" do
    {:ok, _} =
      LlmProviders.upsert(%{
        "provider" => "gemini",
        "model" => "m",
        "api_key" => "k",
        "enabled" => true,
        "priority" => 50
      })

    {:ok, _} =
      LlmProviders.upsert(%{
        "provider" => "anthropic",
        "model" => "m",
        "api_key" => "k",
        "enabled" => true,
        "priority" => 10
      })

    assert LlmProviders.primary().provider == "anthropic"
  end

  test "빈 api_key로 저장해도 기존 키가 유지된다" do
    {:ok, _} =
      LlmProviders.upsert(%{
        "provider" => "gemini",
        "model" => "m",
        "api_key" => "k",
        "enabled" => true
      })

    {:ok, _} = LlmProviders.upsert(%{"provider" => "gemini", "model" => "m", "api_key" => ""})
    assert LlmProviders.ready?()
  end

  test "api_key는 DB에 평문으로 남지 않는다" do
    {:ok, _} =
      LlmProviders.upsert(%{
        "provider" => "gemini",
        "model" => "m",
        "api_key" => "plaintext-llm-key",
        "enabled" => true
      })

    %{rows: [[raw]]} =
      VR.Repo.query!("SELECT api_key_encrypted FROM llm_providers WHERE provider = $1", ["gemini"])

    refute String.contains?(raw, "plaintext-llm-key")
    assert String.contains?(raw, "AES.GCM.V1")
  end
end
