defmodule Mix.Tasks.Vr.SeedPreviewAuth do
  @moduledoc """
  Sets up accounts for preview admin verification along with a recent MFA session.

      PREVIEW_ENV=true PREVIEW_TEST_ACCOUNT_PASSWORD=... mix vr.seed_preview_auth

  Neither passwords nor session tokens are printed. The task refuses to run
  unless `PREVIEW_ENV=true`, so test accounts cannot be created in production
  by accident.
  """
  @shortdoc "Idempotently seeds preview auth test data"

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    unless System.get_env("PREVIEW_ENV") == "true" do
      Mix.raise("Only runs in a preview environment with PREVIEW_ENV=true")
    end

    password = System.get_env("PREVIEW_TEST_ACCOUNT_PASSWORD")

    case VR.PreviewAuth.ensure(password: password) do
      {:ok, result} ->
        Mix.shell().info(
          "Preview auth test data ready: 3 accounts, admin permission active, MFA TTL #{result.mfa_ttl_seconds}s"
        )

      {:error, :password_required} ->
        Mix.raise("PREVIEW_TEST_ACCOUNT_PASSWORD must be set")

      {:error, :password_too_short} ->
        Mix.raise("PREVIEW_TEST_ACCOUNT_PASSWORD must be at least 10 characters")
    end
  end
end
