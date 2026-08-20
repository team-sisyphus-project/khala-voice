defmodule VR.Repo.Migrations.AddStorageKeyToSessions do
  use Ecto.Migration

  @moduledoc """
  업로드 대상 키를 **서버가** 정하고 기록한다.

  지금까지는 클라이언트가 업로드를 마친 뒤 `audio_url` 을 보내오면 그대로 믿었다.
  그 값이 워커의 `Req.get/2` 로 들어가므로, 인증된 사용자가 사설망 주소를 넣어
  서버를 대신 요청하게 만들 수 있었다 (SSRF).

  이제 presign 단계에서 서버가 키를 정해 여기 남기고, 재생·전사 모두
  이 키로만 접근한다. 클라이언트가 보낸 주소는 쓰지 않는다.
  """

  def change do
    alter table(:recording_sessions) do
      add :storage_key, :string
    end
  end
end
