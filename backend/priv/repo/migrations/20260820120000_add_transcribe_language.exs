defmodule VR.Repo.Migrations.AddTranscribeLanguage do
  use Ecto.Migration

  @moduledoc """
  기본 전사 언어를 계정에 둔다.

  `nil` 은 **자동** 이다 — 브라우저 언어를 따라간다. 기본값을 문자열로 박지 않는
  이유: 박는 순간 "사용자가 고른 것"과 "우리가 정해준 것"을 구분할 수 없고,
  나중에 자동 감지를 켜 줄 방법이 없다.

  마이크는 여기 두지 않는다 — 그건 사람이 아니라 **자리**에 딸린 설정이라
  기기(localStorage)에 남는다.
  """

  def change do
    alter table(:accounts) do
      add :transcribe_language, :string
    end
  end
end
