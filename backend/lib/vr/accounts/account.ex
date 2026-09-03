defmodule VR.Accounts.Account do
  @moduledoc """
  사용자 계정.

  ## 로그인 수단

  - 이메일 + 비밀번호 (항상 사용 가능)
  - 소셜 로그인 (어드민에서 제공자를 켰을 때만)

  소셜로 가입한 계정은 `hashed_password`가 없을 수 있다. 이 경우 그 제공자를
  끄면 로그인할 수 없게 되므로, 어드민이 끄기 전에 확인 절차를 거친다.

  ## 삭제

  즉시 지우지 않고 `scheduled_deletion_at`을 세워 유예를 준다.
  유예 기간 안에 로그인하면 취소되고, 지나면 `DeletionWorker`가 처리한다.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.IdGenerator

  @locales ~w(ko en ja es zh_CN zh_TW)

  @doc """
  고를 수 있는 전사 언어.

  **프런트(`apps/web/src/lib/prefs.ts`)의 목록과 같아야 한다.** 한쪽에만 있는 값이
  저장되면 전사가 통째로 실패하고 크레딧만 나간다.

  중국어는 `zh-*` 가 아니라 `cmn-*` 다 — Google STT v2 의 코드가 그렇다.
  """
  @transcribe_languages ~w(
    ko-KR en-US en-GB ja-JP cmn-Hans-CN cmn-Hant-TW es-ES fr-FR de-DE vi-VN
  )
  # 사용자가 고르는 테마. 시스템 어드민 설정이 아니다.
  @themes ~w(light dark pencil-warm game)
  @deletion_grace_days 14

  @derive {Jason.Encoder,
           only: [
             :id,
             :email,
             :name,
             :locale,
             :transcribe_language,
             :country,
             :time_zone,
             :confirmed_at,
             :is_admin,
             :theme,
             :inserted_at
           ]}

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "accounts" do
    field :email, :string
    field :hashed_password, :string, redact: true
    field :name, :string
    field :confirmed_at, :utc_datetime

    # 앱 UI 표시 언어. **전사 언어(`transcribe_language`)와 다른 값이다.**
    # 신규 계정 기본값은 영어다 — 앱은 영어를 우선 언어로 낸다.
    field :locale, :string, default: "en"
    field :country, :string
    field :time_zone, :string

    # 소셜 로그인
    field :is_social, :boolean, default: false
    field :social_provider, :string
    field :social_id, :string

    field :is_admin, :boolean, default: false

    # 설치 시 자동 생성된 임시 어드민. 실사용자 승격 후 삭제하는 것이 정상 절차다.
    field :is_bootstrap, :boolean, default: false

    # 사용자별 화면 테마. 시스템 어드민 설정이 아니다.
    field :theme, :string, default: "light"
    # 기본 전사 언어. **nil = 자동**(브라우저 언어를 따라간다).
    # UI 언어(`locale`)와 다른 값이다 — 전사는 STT 코드(`cmn-Hans-CN` 등)를 쓴다.
    field :transcribe_language, :string

    # 2단계 인증 — 시스템 어드민 전용. 일반 사용자에게는 노출하지 않는다.
    field :mfa_secret, VR.Encrypted.Binary, source: :mfa_secret_encrypted, redact: true
    field :mfa_enabled, :boolean, default: false
    field :mfa_enabled_at, :utc_datetime
    field :mfa_backup_hashes, {:array, :string}, default: [], redact: true

    # 삭제 예약
    field :deleted_at, :utc_datetime
    field :scheduled_deletion_at, :utc_datetime

    # 가상 필드
    field :password, :string, virtual: true, redact: true
    field :invite_code, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  def locales, do: @locales

  def transcribe_languages, do: @transcribe_languages
  def themes, do: @themes
  def deletion_grace_days, do: @deletion_grace_days

  @doc """
  이메일 + 비밀번호 가입.

  ## 옵션
  - `:hash_password` — false면 해싱을 건너뛴다 (검증만 할 때)
  """
  def registration_changeset(account, attrs, opts \\ []) do
    account
    |> cast(attrs, [:email, :password, :name, :locale, :country, :time_zone, :invite_code])
    |> put_id()
    |> validate_email()
    |> validate_password(opts)
    |> validate_name()
    |> validate_locale()
  end

  @doc "소셜 로그인 가입. 비밀번호가 없다."
  def social_registration_changeset(account, attrs) do
    account
    |> cast(attrs, [:email, :name, :social_provider, :social_id, :locale, :country, :time_zone])
    |> put_id()
    |> put_change(:is_social, true)
    |> validate_required([:social_provider, :social_id])
    |> validate_email()
    |> validate_name()
    |> validate_locale()
    # 소셜 제공자가 이미 이메일을 검증했다
    |> put_change(:confirmed_at, DateTime.utc_now(:second))
  end

  @doc "프로필 수정."
  def profile_changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :locale, :country, :time_zone, :theme, :transcribe_language])
    |> validate_inclusion(:transcribe_language, @transcribe_languages, message: "지원하지 않는 언어입니다")
    |> validate_name()
    |> validate_locale()
    |> validate_inclusion(:theme, @themes, message: "알 수 없는 테마입니다")
  end

  @doc """
  기본 전사 언어를 바꾼다.

  `nil` 은 **자동** 이다 — 브라우저 언어를 따라간다. 빈 문자열도 자동으로 본다
  (폼이 빈 값을 보내는 경우).
  """
  def transcribe_language_changeset(account, language) do
    normalized = if language in [nil, ""], do: nil, else: language

    account
    |> cast(%{transcribe_language: normalized}, [:transcribe_language])
    |> validate_inclusion(:transcribe_language, @transcribe_languages, message: "지원하지 않는 언어입니다")
  end

  @doc "테마만 바꾼다. 프로필 폼을 거치지 않고 즉시 저장할 때 쓴다."
  def theme_changeset(account, theme) do
    account
    |> cast(%{theme: theme}, [:theme])
    |> validate_inclusion(:theme, @themes, message: "알 수 없는 테마입니다")
  end

  @doc """
  UI 표시 언어만 바꾼다. 프로필 폼을 거치지 않고 즉시 저장할 때 쓴다.

  **전사 언어(`transcribe_language`)와 다른 값이다** — UI 언어는 `locale`
  코드(`ko` · `en` 등)를 쓴다.
  """
  def locale_changeset(account, locale) do
    account
    # empty_values: [] 로 빈 문자열도 그대로 받는다 — API 경계에서 빈 값은
    # 무시(no-op)가 아니라 명시적으로 거부한다.
    |> cast(%{locale: locale}, [:locale], empty_values: [])
    |> validate_required([:locale])
    |> validate_locale()
  end

  @doc "MFA 설정. 시스템 어드민에게만 쓴다."
  def mfa_changeset(account, attrs) do
    cast(account, attrs, [:mfa_secret, :mfa_enabled, :mfa_enabled_at, :mfa_backup_hashes])
  end

  @doc "비밀번호 변경 또는 최초 설정 (소셜 전용 계정이 비밀번호를 추가하는 경우 포함)."
  def password_changeset(account, attrs, opts \\ []) do
    account
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "비밀번호가 일치하지 않습니다")
    |> validate_password(opts)
  end

  @doc "이메일 변경."
  def email_changeset(account, attrs) do
    account
    |> cast(attrs, [:email])
    |> validate_email()
    |> case do
      %{changes: %{email: _}} = changeset -> changeset
      changeset -> add_error(changeset, :email, "이전과 동일합니다")
    end
  end

  @doc "이메일 확인 완료 표시."
  def confirm_changeset(account) do
    change(account, confirmed_at: DateTime.utc_now(:second))
  end

  # ── 검증 ─────────────────────────────────────────────────

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, IdGenerator.generate(:account))
      "" -> put_change(changeset, :id, IdGenerator.generate(:account))
      _ -> changeset
    end
  end

  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/, message: "이메일 형식이 올바르지 않습니다")
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, VR.Repo)
    |> unique_constraint(:email)
  end

  defp validate_name(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 80)
  end

  defp validate_locale(changeset) do
    validate_inclusion(changeset, :locale, @locales)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 10, max: 72, message: "10자 이상이어야 합니다")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash? && password && changeset.valid? do
      changeset
      # bcrypt는 72바이트를 넘으면 잘라버린다. 미리 막는다.
      |> validate_length(:password, max: 72, count: :bytes)
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  비밀번호 검증. 계정이 없거나 비밀번호가 없어도 **같은 시간이 걸리도록** 한다.
  응답 시간 차이로 계정 존재 여부가 새는 것을 막는다.
  """
  def valid_password?(%__MODULE__{hashed_password: hashed}, password)
      when is_binary(hashed) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed)
  end

  def valid_password?(_account, _password) do
    Bcrypt.no_user_verify()
    false
  end

  @doc "이 계정이 비밀번호로 로그인할 수 있는가. 소셜 전용 계정이면 false."
  def password_login?(%__MODULE__{hashed_password: hashed}), do: is_binary(hashed)
end
