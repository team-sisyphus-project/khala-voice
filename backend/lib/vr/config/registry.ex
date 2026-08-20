defmodule VR.Config.Registry do
  @moduledoc """
  시스템 설정 키의 선언적 정의.

  어드민 설정 화면은 **이 레지스트리에서 생성된다.** 새 설정값을 추가하려면
  여기에 항목 하나만 추가하면 되고, 화면·검증·마스킹·환경변수 폴백이 따라온다.

  ## 항목 필드

  | 필드 | 뜻 |
  |---|---|
  | `key` | `"그룹.이름"` 형식. DB `system_configs.key` |
  | `group` | 어드민 화면 묶음 |
  | `label` | 화면에 보이는 이름 |
  | `env` | 환경변수 폴백 이름 (nil이면 DB 전용) |
  | `type` | `:string` `:text` `:boolean` `:integer` `:json` |
  | `secret` | true면 값을 화면에 되돌려 보여주지 않고 마스킹 |
  | `required` | 해당 기능이 동작하려면 필요한 값 |
  | `feature` | 이 값이 속한 기능. 미설정 시 그 기능이 꺼진다 |
  | `help` | 입력 도움말 |
  """

  @groups [
    storage: %{label: "스토리지 (S3)", icon: "hero-cloud-arrow-up"},
    stt: %{label: "전사 (Google STT)", icon: "hero-microphone"},
    llm: %{label: "AI 요약", icon: "hero-sparkles"},
    mail: %{label: "메일 발송", icon: "hero-envelope"},
    push: %{label: "웹 푸시", icon: "hero-bell"},
    policy: %{label: "정책", icon: "hero-adjustments-horizontal"},
    app: %{label: "앱", icon: "hero-globe-alt"},
    khala: %{label: "칼라 연동", icon: "hero-paper-airplane"}
  ]

  @entries [
    # ── 스토리지 ────────────────────────────────────────────
    %{
      key: "storage.bucket",
      group: :storage,
      label: "버킷 이름",
      env: "STORAGE_BUCKET",
      type: :string,
      secret: false,
      required: true,
      feature: :storage,
      help: "녹음 오디오와 전사본이 저장되는 S3 버킷"
    },
    %{
      key: "storage.region",
      group: :storage,
      label: "리전",
      env: "STORAGE_REGION",
      type: :string,
      secret: false,
      required: true,
      feature: :storage,
      help: "예: ap-northeast-2"
    },
    %{
      key: "storage.access_key_id",
      group: :storage,
      label: "Access Key ID",
      env: "STORAGE_ACCESS_KEY_ID",
      type: :string,
      secret: true,
      required: true,
      feature: :storage,
      help: "S3 PutObject 권한이 있는 IAM 키"
    },
    %{
      key: "storage.secret_access_key",
      group: :storage,
      label: "Secret Access Key",
      env: "STORAGE_SECRET_ACCESS_KEY",
      type: :string,
      secret: true,
      required: true,
      feature: :storage,
      help: nil
    },
    %{
      key: "storage.cdn_base_url",
      group: :storage,
      label: "CDN 기본 URL",
      env: "STORAGE_CDN_BASE_URL",
      type: :string,
      secret: false,
      required: false,
      feature: :storage,
      help: "다운로드에 사용할 도메인. 비우면 S3 URL을 직접 쓴다"
    },
    %{
      key: "storage.download_url_ttl_seconds",
      group: :storage,
      label: "오디오 다운로드 URL 만료(초)",
      env: "STORAGE_DOWNLOAD_URL_TTL_SECONDS",
      type: :integer,
      secret: false,
      required: false,
      feature: nil,
      help: "재생용 서명 URL 의 유효 시간. 비우면 300초. 길게 잡으면 링크가 새어도 그만큼 오래 산다"
    },

    # ── 전사 (Google Cloud STT v2) ──────────────────────────
    %{
      key: "stt.credentials_json",
      group: :stt,
      label: "서비스 계정 JSON",
      env: "STT_CREDENTIALS_JSON",
      type: :text,
      secret: true,
      required: true,
      feature: :transcription,
      help: "GCP 서비스 계정 키 파일의 내용 전체를 붙여넣는다"
    },
    %{
      key: "stt.project_id",
      group: :stt,
      label: "GCP 프로젝트 ID",
      env: "STT_PROJECT_ID",
      type: :string,
      secret: false,
      required: true,
      feature: :transcription,
      help: nil
    },
    %{
      key: "stt.location",
      group: :stt,
      label: "리전",
      env: "STT_LOCATION",
      type: :string,
      secret: false,
      required: false,
      feature: :transcription,
      help: "기본값 us"
    },
    %{
      key: "stt.recognizer",
      group: :stt,
      label: "Recognizer 이름",
      env: "STT_RECOGNIZER",
      type: :string,
      secret: false,
      required: false,
      feature: :transcription,
      help: "기본값 meeting-transcriber"
    },
    %{
      key: "stt.gcs_bucket",
      group: :stt,
      label: "GCS 임시 버킷",
      env: "STT_GCS_BUCKET",
      type: :string,
      secret: false,
      required: true,
      feature: :transcription,
      help: "batchRecognize는 gs:// 경로를 요구한다. 오디오를 잠시 올렸다 지우는 버킷"
    },
    %{
      key: "stt.cost_per_minute_usd",
      group: :stt,
      label: "분당 원가 (USD)",
      env: "STT_COST_PER_MINUTE_USD",
      type: :string,
      secret: false,
      required: false,
      feature: nil,
      help: "크레딧 환산의 입력이다. Google STT 공시 단가를 넣는다 (예: 0.016). 비우면 계량하지 않는다"
    },
    %{
      key: "stt.dev_mode",
      group: :stt,
      label: "개발 모드",
      env: "STT_DEV_MODE",
      type: :boolean,
      secret: false,
      required: false,
      feature: nil,
      help: "켜면 실제 API를 호출하지 않고 목 전사 결과를 반환한다. GCP 자격증명 없이 개발할 때"
    },

    # ── AI 요약 ─────────────────────────────────────────────
    # 제공자별 키·모델·단가는 `llm_providers` 테이블에서 관리한다
    # (어드민 → LLM 제공자). 여기에는 전역 스위치만 둔다.
    %{
      key: "llm.dev_mode",
      group: :llm,
      label: "개발 모드",
      env: "LLM_DEV_MODE",
      type: :boolean,
      secret: false,
      required: false,
      feature: nil,
      help: "켜면 LLM을 호출하지 않고 목 요약을 만든다. 실제 전사에서 인용을 뽑으므로 점프 동작까지 확인된다"
    },
    %{
      key: "llm.auto_summarize",
      group: :llm,
      label: "전사 완료 시 자동 요약",
      env: "LLM_AUTO_SUMMARIZE",
      type: :boolean,
      secret: false,
      required: false,
      feature: nil,
      help: "끄면 사용자가 [요약] 을 눌렀을 때만 생성한다"
    },
    %{
      key: "app.trust_proxy_headers",
      group: :app,
      label: "프록시 헤더 신뢰",
      env: "APP_TRUST_PROXY_HEADERS",
      type: :boolean,
      secret: false,
      required: false,
      feature: nil,
      help:
        "리버스 프록시 뒤에 있을 때만 켠다. 켜면 X-Forwarded-For 를 방문자 IP 로 쓴다. 프록시가 없는데 켜면 헤더 한 줄로 IP 제한을 우회당한다"
    },
    %{
      key: "app.timezone",
      group: :app,
      label: "표기 기준 시간대",
      env: "APP_TIMEZONE",
      type: :string,
      secret: false,
      required: false,
      feature: nil,
      help: "회의록 내보내기의 날짜·시각 표기 기준. 예: Asia/Seoul. 비우면 Asia/Seoul"
    },

    # ── 메일 ────────────────────────────────────────────────
    %{
      key: "mail.provider",
      group: :mail,
      label: "제공자",
      env: "MAIL_PROVIDER",
      type: :string,
      secret: false,
      required: true,
      feature: :mail,
      help: "local | mailgun | resend"
    },
    %{
      key: "mail.domain",
      group: :mail,
      label: "발송 도메인",
      env: "MAIL_DOMAIN",
      type: :string,
      secret: false,
      required: false,
      feature: :mail,
      help: nil
    },
    %{
      key: "mail.api_key",
      group: :mail,
      label: "API 키",
      env: "MAIL_API_KEY",
      type: :string,
      secret: true,
      required: false,
      feature: :mail,
      help: nil
    },

    # ── 웹 푸시 ─────────────────────────────────────────────
    %{
      key: "push.vapid_public_key",
      group: :push,
      label: "VAPID 공개키",
      env: "VAPID_PUBLIC_KEY",
      type: :string,
      secret: false,
      required: true,
      feature: :push,
      help: nil
    },
    %{
      key: "push.vapid_private_key",
      group: :push,
      label: "VAPID 비밀키",
      env: "VAPID_PRIVATE_KEY",
      type: :string,
      secret: true,
      required: true,
      feature: :push,
      help: nil
    },
    %{
      key: "push.vapid_subject",
      group: :push,
      label: "VAPID Subject",
      env: "VAPID_SUBJECT",
      type: :string,
      secret: false,
      required: true,
      feature: :push,
      help: "mailto: 또는 https: 로 시작하는 연락처"
    },

    # ── 정책 ────────────────────────────────────────────────
    %{
      key: "policy.invite_code_required",
      group: :policy,
      label: "가입 시 초대코드 필요",
      env: nil,
      type: :boolean,
      secret: false,
      required: false,
      feature: nil,
      help: "켜면 초대코드가 있어야 가입할 수 있다"
    },
    %{
      key: "policy.hard_stop_on_zero_credits",
      group: :policy,
      label: "크레딧 소진 시 차단",
      env: nil,
      type: :boolean,
      secret: false,
      required: false,
      feature: nil,
      help: "켜면 잔액이 0 이하일 때 신규 전사·요약 요청을 거부한다. 유료화 시 켠다"
    },

    # ── 앱 ──────────────────────────────────────────────────
    %{
      key: "app.base_url",
      group: :app,
      label: "서비스 기본 URL",
      env: "APP_BASE_URL",
      type: :string,
      secret: false,
      required: true,
      feature: :mail,
      help: "메일에 들어가는 링크의 기준 주소. 예: https://voice.example.com"
    },

    # ── 칼라 연동 ───────────────────────────────────────────
    # 시크릿이 없다. 칼라는 공개 클라이언트라(PKCE) client_secret 을 쓰지 않고,
    # client_id 는 동적 등록으로 받는다 (`docs/15-mcp-khala.md`).
    %{
      key: "khala.enabled",
      group: :khala,
      label: "칼라 연동 사용",
      env: "KHALA_ENABLED",
      type: :boolean,
      secret: false,
      required: false,
      feature: :khala,
      help: "끄면 설정·회의 화면에서 칼라 연동이 아예 사라진다"
    },
    %{
      key: "khala.mcp_url",
      group: :khala,
      label: "칼라 MCP 주소",
      env: "KHALA_MCP_URL",
      type: :string,
      secret: false,
      required: false,
      feature: :khala,
      help: "예: https://mcp.khala.to/mcp — OAuth 엔드포인트는 이 주소에서 자동으로 찾는다"
    }
  ]

  @doc "모든 설정 항목"
  def entries, do: @entries

  @doc "그룹 정의 (순서 있음)"
  def groups, do: @groups

  @doc "그룹에 속한 항목들"
  def entries_for(group), do: Enum.filter(@entries, &(&1.group == group))

  @doc "키로 항목 조회"
  def entry(key), do: Enum.find(@entries, &(&1.key == key))

  @doc "알려진 키 목록"
  def keys, do: Enum.map(@entries, & &1.key)

  @doc "기능이 동작하는 데 필요한 항목들"
  def required_for(feature) do
    Enum.filter(@entries, &(&1.feature == feature and &1.required))
  end

  @doc "선언된 기능 목록"
  def features do
    @entries |> Enum.map(& &1.feature) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end
end
