defmodule VR.LogRedactorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias VR.LogRedactor

  describe "redact/1" do
    test "공유 토큰을 가린다" do
      redacted = LogRedactor.redact("GET /api/public/share/slt_abcdefghijklmnop1234")

      refute redacted =~ "abcdefghijkl"
      assert redacted =~ "slt_…"
      # 뒤 4자는 남긴다 — 지원할 때 "같은 토큰인가"는 볼 수 있어야 한다
      assert redacted =~ "1234"
    end

    test "게스트 토큰도 가린다" do
      assert LogRedactor.redact("x-guest-token: gst_QRSTUVWXYZ012345") =~ "gst_…"
    end

    test "한 줄에 여러 개가 있어도 전부 가린다" do
      redacted = LogRedactor.redact("slt_aaaaaaaaaaaa1111 과 gst_bbbbbbbbbbbb2222")

      refute redacted =~ "aaaaaaaaaaaa"
      refute redacted =~ "bbbbbbbbbbbb"
    end

    test "토큰이 아닌 것은 건드리지 않는다" do
      assert LogRedactor.redact("정상 로그 메시지") == "정상 로그 메시지"
      assert LogRedactor.redact("slt_짧음") == "slt_짧음"
    end

    test "문자열이 아니면 그대로 둔다" do
      assert LogRedactor.redact(%{a: 1}) == %{a: 1}
      assert LogRedactor.redact(nil) == nil
    end
  end

  describe "로거에 실제로 붙어 있다" do
    test "Logger 를 통과하면 토큰이 지워진다" do
      # 애플리케이션 시작 시 install/0 이 붙인 필터가 동작하는지 본다.
      # 이게 깨지면 요청 경로의 토큰이 그대로 로그에 남는다.
      captured =
        capture_log(fn ->
          require Logger
          Logger.error("요청 실패: /share/slt_ZZZZZZZZZZZZ9999")
        end)

      refute captured =~ "ZZZZZZZZZZZZ"
      assert captured =~ "slt_…"
    end
  end
end
