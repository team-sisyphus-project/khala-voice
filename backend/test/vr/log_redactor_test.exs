defmodule VR.LogRedactorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias VR.LogRedactor

  describe "redact/1" do
    test "redacts share tokens" do
      redacted = LogRedactor.redact("GET /api/public/share/slt_abcdefghijklmnop1234")

      refute redacted =~ "abcdefghijkl"
      assert redacted =~ "slt_…"
      # Keep the last 4 chars — support needs to tell "is this the same token"
      assert redacted =~ "1234"
    end

    test "redacts guest tokens too" do
      assert LogRedactor.redact("x-guest-token: gst_QRSTUVWXYZ012345") =~ "gst_…"
    end

    test "redacts every occurrence on a single line" do
      redacted = LogRedactor.redact("slt_aaaaaaaaaaaa1111 and gst_bbbbbbbbbbbb2222")

      refute redacted =~ "aaaaaaaaaaaa"
      refute redacted =~ "bbbbbbbbbbbb"
    end

    test "leaves non-tokens untouched" do
      assert LogRedactor.redact("normal log message") == "normal log message"
      assert LogRedactor.redact("slt_short") == "slt_short"
    end

    test "returns non-strings as-is" do
      assert LogRedactor.redact(%{a: 1}) == %{a: 1}
      assert LogRedactor.redact(nil) == nil
    end
  end

  describe "actually attached to the logger" do
    test "tokens are scrubbed when passing through Logger" do
      # Verifies the filter attached by install/0 at application start works.
      # If this breaks, tokens in request paths land in logs verbatim.
      captured =
        capture_log(fn ->
          require Logger
          Logger.error("request failed: /share/slt_ZZZZZZZZZZZZ9999")
        end)

      refute captured =~ "ZZZZZZZZZZZZ"
      assert captured =~ "slt_…"
    end
  end
end
