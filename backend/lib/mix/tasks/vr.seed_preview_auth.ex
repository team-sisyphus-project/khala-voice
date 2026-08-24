defmodule Mix.Tasks.Vr.SeedPreviewAuth do
  @moduledoc """
  Preview 관리자 검증용 계정과 최근 MFA 세션을 구성한다.

      PREVIEW_ENV=true PREVIEW_TEST_ACCOUNT_PASSWORD=... mix vr.seed_preview_auth

  비밀번호나 세션 토큰은 출력하지 않는다. `PREVIEW_ENV=true`가 아니면 실행을
  거부하므로 운영 환경에서 실수로 테스트 계정을 만들지 않는다.
  """
  @shortdoc "Preview 인증 테스트 데이터를 멱등 구성한다"

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    unless System.get_env("PREVIEW_ENV") == "true" do
      Mix.raise("PREVIEW_ENV=true인 Preview 환경에서만 실행할 수 있습니다")
    end

    password = System.get_env("PREVIEW_TEST_ACCOUNT_PASSWORD")

    case VR.PreviewAuth.ensure(password: password) do
      {:ok, result} ->
        Mix.shell().info(
          "Preview 인증 테스트 데이터 준비 완료: 계정 3개, 관리자 권한 활성, MFA TTL #{result.mfa_ttl_seconds}초"
        )

      {:error, :password_required} ->
        Mix.raise("PREVIEW_TEST_ACCOUNT_PASSWORD를 설정해야 합니다")

      {:error, :password_too_short} ->
        Mix.raise("PREVIEW_TEST_ACCOUNT_PASSWORD는 10자 이상이어야 합니다")
    end
  end
end
