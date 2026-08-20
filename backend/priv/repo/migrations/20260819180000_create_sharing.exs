defmodule VR.Repo.Migrations.CreateSharing do
  use Ecto.Migration

  @moduledoc """
  공유 링크 · 게스트 세션 · PIN 시도 기록.

  ## 토큰과 PIN 을 평문으로 두지 않는다

  공유 토큰은 **추가 인증 없이 즉시 통하는 자격증명**이다. DB 백업 · 리플리카 ·
  로그 · `SELECT *` 덤프 어디에서든 본 사람이 곧바로 그 회의에 들어온다.
  그래서 `AccountSession` 과 같이 sha256 해시만 저장하고, 원본은 발급 응답에서
  **한 번만** 내보낸다. 잃어버리면 재발급(`rotate`)한다.

  PIN 은 6자리(10^6)라 sha256 해시는 유출 시 몇 초 만에 역산된다. Bcrypt 를 쓴다.

  Cloak(AES-GCM)은 여기에 쓸 수 없다 — IV 가 매번 달라 `WHERE token_hash = ?` 조회가
  불가능하고, `CLOAK_KEY` 는 DB 자격증명 옆에 살아 함께 유출된다.

  ## sisyphus 와 다른 점

  sisyphus 는 `token` · `pincode` 를 평문 컬럼에 넣었고, PIN 생성에 `:rand.uniform`
  (CSPRNG 아님)을 쓰면서 범위도 어긋나 `100000` 이 나오지 않았다.
  게스트 세션 테이블은 아예 없었다 — 게스트 신원이 브라우저 JS 변수였다.
  """

  def change do
    create table(:shared_links, primary_key: false) do
      add :id, :string, primary_key: true
      add :meeting_id, references(:meetings, type: :string, on_delete: :delete_all), null: false
      add :created_by_id, references(:accounts, type: :string, on_delete: :nilify_all)

      add :token_hash, :binary, null: false

      # 앞 8자. 목록에서 어느 링크인지 알아보기만 한다. 이것만으로는 못 들어온다.
      add :token_prefix, :string, null: false
      add :granted_role, :string, null: false, default: "viewer"
      # Bcrypt. nil = PIN 없음
      add :pin_hash, :string

      add :max_uses, :integer
      add :use_count, :integer, null: false, default: 0
      add :expires_at, :utc_datetime
      add :is_active, :boolean, null: false, default: true
      add :revoked_at, :utc_datetime

      add :require_name, :boolean, null: false, default: true
      add :require_email, :boolean, null: false, default: false

      add :failed_pin_attempts, :integer, null: false, default: 0
      add :pin_locked_until, :utc_datetime

      add :last_used_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:shared_links, [:token_hash])
    create index(:shared_links, [:meeting_id])
    create index(:shared_links, [:created_by_id])
    create index(:shared_links, [:meeting_id, :is_active], where: "deleted_at IS NULL")

    # 애플리케이션 검증이 새어도 "reviewer" 링크가 만들어지지 않게 DB 에도 박는다
    create constraint(:shared_links, :shared_links_granted_role_check,
             check: "granted_role IN ('viewer','contributor')"
           )

    create constraint(:shared_links, :shared_links_max_uses_check,
             check: "max_uses IS NULL OR max_uses > 0"
           )

    create constraint(:shared_links, :shared_links_use_count_check, check: "use_count >= 0")

    create table(:guest_sessions, primary_key: false) do
      add :id, :string, primary_key: true

      add :shared_link_id, references(:shared_links, type: :string, on_delete: :delete_all),
        null: false

      # **회의 하나에만 접근한다**는 제약을 행에 박아 둔다.
      # 컨트롤러가 아니라 데이터가 범위를 들고 있어야 한다.
      add :meeting_id, references(:meetings, type: :string, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all)

      add :token_hash, :binary, null: false

      # 링크에서 복사해 굳힌다. 링크의 역할이 나중에 바뀌어도 이 세션은 그대로다.
      add :granted_role, :string, null: false
      add :display_name, :string
      add :email, :string
      add :user_agent, :string
      add :ip_address, :string

      add :last_activity_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:guest_sessions, [:token_hash])
    create index(:guest_sessions, [:shared_link_id])
    create index(:guest_sessions, [:meeting_id])
    create index(:guest_sessions, [:expires_at])

    create constraint(:guest_sessions, :guest_sessions_granted_role_check,
             check: "granted_role IN ('viewer','contributor')"
           )

    # PIN 대입 방어용 시도 기록.
    # `login_attempts` 를 재사용하지 않는다 — 그 테이블의 email 컬럼 의미가 흐려진다.
    create table(:share_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :binary
      add :ip_address, :string
      add :success, :boolean, null: false, default: false
      add :attempted_at, :utc_datetime, null: false
    end

    create index(:share_attempts, [:token_hash, :attempted_at])
    create index(:share_attempts, [:ip_address, :attempted_at])
  end
end
