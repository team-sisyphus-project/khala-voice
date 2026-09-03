defmodule VR.Summarize.LlmProvidersTest do
  use VR.DataCase, async: false

  alias VR.Summarize.LlmProviders

  setup do
    for name <- ~w(LLM_PROVIDER LLM_API_KEY LLM_MODEL), do: System.delete_env(name)
    :ok
  end

  test "summarization is inactive with nothing configured" do
    refute LlmProviders.ready?()
    assert LlmProviders.primary() == nil
  end

  test "available when a key exists and it is enabled" do
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

  test "lower-priority-number providers are used first" do
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

  test "saving with an empty api_key keeps the existing key" do
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

  test "api_key is not stored in the DB as plaintext" do
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
