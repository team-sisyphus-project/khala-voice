defmodule VR.StorageTest do
  use VR.DataCase, async: false

  alias VR.{Config, Storage}

  setup do
    Config.put("storage.bucket", "vr-test-bucket", nil)
    Config.put("storage.region", "ap-northeast-2", nil)
    Config.put("storage.cdn_base_url", "", nil)
    :ok
  end

  describe "own_object_url?/1 — SSRF 가드" do
    test "우리 버킷은 통과한다" do
      key = Storage.recording_key("meet_a", "mrss_b", 1_700_000_000, "webm")
      assert Storage.own_object_url?(Storage.public_url(key))
    end

    test "클라우드 메타데이터 주소는 막는다" do
      # 이것이 이 가드를 만든 이유다 — 인증된 사용자가 서버를 사설망으로 보낼 수 있었다
      refute Storage.own_object_url?("http://169.254.169.254/latest/meta-data/")
      refute Storage.own_object_url?("http://localhost:4000/_admin")
      refute Storage.own_object_url?("http://127.0.0.1/")
      refute Storage.own_object_url?("http://[::1]/")
    end

    test "남의 버킷은 막는다" do
      refute Storage.own_object_url?("https://evil-bucket.s3.ap-northeast-2.amazonaws.com/x.mp3")
    end

    test "호스트를 흉내 낸 주소는 막는다" do
      refute Storage.own_object_url?(
               "https://vr-test-bucket.s3.ap-northeast-2.amazonaws.com.evil.com/x"
             )

      refute Storage.own_object_url?(
               "https://evil.com/vr-test-bucket.s3.ap-northeast-2.amazonaws.com"
             )
    end

    test "http/https 가 아니면 막는다" do
      refute Storage.own_object_url?("file:///etc/passwd")
      refute Storage.own_object_url?("gopher://internal/")
      refute Storage.own_object_url?("data:text/plain,hello")
    end

    test "URL 이 아니면 막는다" do
      refute Storage.own_object_url?("")
      refute Storage.own_object_url?("그냥 글자")
      refute Storage.own_object_url?(nil)
      refute Storage.own_object_url?(123)
    end

    test "CDN 이 설정되면 그 호스트도 통과한다" do
      Config.put("storage.cdn_base_url", "https://files.example.com", nil)

      assert Storage.own_object_url?("https://files.example.com/data/meetings/x.webm")
      refute Storage.own_object_url?("https://files.example.com.evil.com/x")
    end

    test "대소문자가 달라도 우리 호스트로 본다" do
      assert Storage.own_object_url?("https://VR-TEST-BUCKET.S3.AP-NORTHEAST-2.AMAZONAWS.COM/x")
    end
  end

  describe "presign_download/2" do
    test "키가 없으면 발급하지 않는다" do
      assert {:error, :no_storage_key} = Storage.presign_download(nil, [])
      assert {:error, :no_storage_key} = Storage.presign_download("", [])
    end
  end

  describe "recording_key/4" do
    test "완전히 결정적이다" do
      # 이 성질 때문에 서명 없는 URL 로는 Viewer 마스킹이 되지 않는다.
      # 값이 바뀌면 기존 오브젝트를 못 찾으므로 회귀로 잠근다.
      assert Storage.recording_key("meet_a", "mrss_b", 1_700_000_000, "webm") ==
               "data/meetings/meet_a/sessions/mrss_b/1700000000.webm"
    end
  end
end
