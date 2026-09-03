defmodule VR.StorageTest do
  use VR.DataCase, async: false

  alias VR.{Config, Storage}

  setup do
    Config.put("storage.bucket", "vr-test-bucket", nil)
    Config.put("storage.region", "ap-northeast-2", nil)
    Config.put("storage.cdn_base_url", "", nil)
    :ok
  end

  describe "own_object_url?/1 — SSRF guard" do
    test "our bucket passes" do
      key = Storage.recording_key("meet_a", "mrss_b", 1_700_000_000, "webm")
      assert Storage.own_object_url?(Storage.public_url(key))
    end

    test "blocks cloud metadata addresses" do
      # This is why the guard exists — an authenticated user could point the server at private networks
      refute Storage.own_object_url?("http://169.254.169.254/latest/meta-data/")
      refute Storage.own_object_url?("http://localhost:4000/_admin")
      refute Storage.own_object_url?("http://127.0.0.1/")
      refute Storage.own_object_url?("http://[::1]/")
    end

    test "blocks other buckets" do
      refute Storage.own_object_url?("https://evil-bucket.s3.ap-northeast-2.amazonaws.com/x.mp3")
    end

    test "blocks host-impersonating addresses" do
      refute Storage.own_object_url?(
               "https://vr-test-bucket.s3.ap-northeast-2.amazonaws.com.evil.com/x"
             )

      refute Storage.own_object_url?(
               "https://evil.com/vr-test-bucket.s3.ap-northeast-2.amazonaws.com"
             )
    end

    test "blocks non-http/https schemes" do
      refute Storage.own_object_url?("file:///etc/passwd")
      refute Storage.own_object_url?("gopher://internal/")
      refute Storage.own_object_url?("data:text/plain,hello")
    end

    test "blocks non-URLs" do
      refute Storage.own_object_url?("")
      refute Storage.own_object_url?("just text")
      refute Storage.own_object_url?(nil)
      refute Storage.own_object_url?(123)
    end

    test "the CDN host also passes when configured" do
      Config.put("storage.cdn_base_url", "https://files.example.com", nil)

      assert Storage.own_object_url?("https://files.example.com/data/meetings/x.webm")
      refute Storage.own_object_url?("https://files.example.com.evil.com/x")
    end

    test "case differences still match our host" do
      assert Storage.own_object_url?("https://VR-TEST-BUCKET.S3.AP-NORTHEAST-2.AMAZONAWS.COM/x")
    end
  end

  describe "presign_download/2" do
    test "does not presign without a key" do
      assert {:error, :no_storage_key} = Storage.presign_download(nil, [])
      assert {:error, :no_storage_key} = Storage.presign_download("", [])
    end
  end

  describe "recording_key/4" do
    test "is fully deterministic" do
      # This property is why unsigned URLs cannot mask Viewers.
      # Changing the value would orphan existing objects, so lock it as a regression.
      assert Storage.recording_key("meet_a", "mrss_b", 1_700_000_000, "webm") ==
               "data/meetings/meet_a/sessions/mrss_b/1700000000.webm"
    end
  end
end
