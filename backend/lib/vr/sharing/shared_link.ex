defmodule VR.Sharing.SharedLink do
  @moduledoc """
  회의 공유 링크.

  **출처: sisyphus** `lib/sisyphus/shared_links/shared_link.ex` — 구조만 가져왔다. 바꾼 것:

  | sisyphus | 이 앱 | 왜 |
  |---|---|---|
  | `resource_type` + `resource_id` 다형 참조 | `meeting_id` 단일 FK | 이 앱에는 공유할 것이 회의뿐이다. 다형 참조는 FK 제약을 못 걸어 고아 행이 남는다 |
  | (없음) | `granted_role` | 게스트가 **어떤 역할로** 들어올지를 링크가 정한다. sisyphus 게스트는 역할이 없었다 |
  | 평문 `token` | sha256 `token_hash` + `token_prefix` | 토큰은 추가 인증 없이 통하는 자격증명이다. DB 를 본 사람이 곧 방문자가 된다 |
  | 평문 `pincode`, `:rand.uniform` 생성 | Bcrypt `pin_hash`, CSPRNG 생성 | 원본은 CSPRNG 가 아니었고 범위도 어긋나 `100000` 이 나오지 않았다 |
  | `changeset` 이 `:id`·`:token`·`:use_count` 를 cast | 전부 `put_change` | 요청 본문으로 사용 횟수나 토큰을 덮어쓸 수 있었다 |

  ## `granted_role` 은 수정할 수 없다

  이미 배포된 `viewer` 링크를 나중에 `contributor` 로 올리면, **그 링크를 받은
  모든 사람의 권한이 소급 상승**한다. 링크를 나눠준 시점의 약속이 깨진다.
  역할을 바꾸려면 폐기하고 다시 발급해야 한다.

  `"reviewer"` 는 어떤 경로로도 들어갈 수 없다 — 링크 하나로 삭제 권한까지 넘길 수는 없다.
  changeset 검증과 DB check 제약 **양쪽**에 박아 둔다.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias VR.IdGenerator

  @rand_size 32
  @token_prefix "slt_"
  @roles ~w(viewer contributor)
  @pin_max_failures 5
  @pin_lock_minutes 15
  @metadata_max_bytes 4096

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "shared_links" do
    field :meeting_id, :string
    field :created_by_id, :string

    field :token_hash, :binary, redact: true
    field :token_prefix, :string
    field :granted_role, :string, default: "viewer"
    field :pin_hash, :string, redact: true

    field :max_uses, :integer
    field :use_count, :integer, default: 0
    field :expires_at, :utc_datetime
    field :is_active, :boolean, default: true
    field :revoked_at, :utc_datetime

    field :require_name, :boolean, default: true
    field :require_email, :boolean, default: false

    field :failed_pin_attempts, :integer, default: 0
    field :pin_locked_until, :utc_datetime

    field :last_used_at, :utc_datetime
    field :metadata, :map, default: %{}
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles
  def token_prefix, do: @token_prefix
  def pin_max_failures, do: @pin_max_failures
  def pin_lock_minutes, do: @pin_lock_minutes

  @doc """
  새 링크. `{평문_토큰, 평문_PIN|nil, changeset}` 을 돌려준다.

  평문은 이 시점 이후로 다시 구할 수 없다. 발급 응답에 한 번 실어 보내고 버린다.
  """
  def build(meeting_id, created_by_id, attrs \\ %{}) do
    raw = :crypto.strong_rand_bytes(@rand_size)
    token = @token_prefix <> Base.url_encode64(raw, padding: false)

    {pincode, pin_hash} =
      if truthy?(attrs["with_pincode"] || attrs[:with_pincode]) do
        pin = generate_pincode()
        {pin, Bcrypt.hash_pwd_salt(pin)}
      else
        {nil, nil}
      end

    changeset =
      %__MODULE__{}
      |> cast(attrs, [
        :granted_role,
        :max_uses,
        :expires_at,
        :require_name,
        :require_email,
        :metadata
      ])
      # 아래 값들은 **절대 cast 하지 않는다.** 요청 본문이 토큰이나 사용 횟수를 정할 수 없다.
      |> put_change(:id, IdGenerator.generate(:shared_link))
      |> put_change(:meeting_id, meeting_id)
      |> put_change(:created_by_id, created_by_id)
      |> put_change(:token_hash, :crypto.hash(:sha256, raw))
      |> put_change(:token_prefix, String.slice(token, 0, 12))
      |> put_change(:pin_hash, pin_hash)
      |> put_change(:use_count, 0)
      |> put_change(:is_active, true)
      |> validate()

    {token, pincode, changeset}
  end

  @doc """
  발급 뒤 바꿀 수 있는 것.

  **`granted_role` 이 없다.** 배포된 링크의 역할을 올리면 그 링크를 받은
  모두의 권한이 소급 상승한다.
  """
  def update_changeset(link, attrs) do
    link
    |> cast(attrs, [:is_active, :max_uses, :expires_at, :require_name, :require_email, :metadata])
    |> validate()
  end

  @doc "토큰만 새로 만든다. 설정과 사용 횟수는 유지한다. `{평문_토큰, changeset}`."
  def rotate_changeset(link) do
    raw = :crypto.strong_rand_bytes(@rand_size)
    token = @token_prefix <> Base.url_encode64(raw, padding: false)

    changeset =
      change(link, %{
        token_hash: :crypto.hash(:sha256, raw),
        token_prefix: String.slice(token, 0, 12)
      })

    {token, changeset}
  end

  @doc "PIN 을 켜거나 끈다. 켜면 새 PIN 을 만들어 `{평문_PIN, changeset}`."
  def pin_changeset(link, :on) do
    pin = generate_pincode()

    changeset =
      change(link, %{
        pin_hash: Bcrypt.hash_pwd_salt(pin),
        # 새 PIN 을 만들면 이전 실패 기록은 의미가 없다
        failed_pin_attempts: 0,
        pin_locked_until: nil
      })

    {pin, changeset}
  end

  def pin_changeset(link, :off) do
    {nil, change(link, %{pin_hash: nil, failed_pin_attempts: 0, pin_locked_until: nil})}
  end

  @doc "URL 의 토큰 문자열을 DB 조회용 해시로 바꾼다."
  def hash_token(@token_prefix <> encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} -> {:ok, :crypto.hash(:sha256, raw)}
      :error -> :error
    end
  end

  def hash_token(_), do: :error

  @doc """
  6자리 PIN. **CSPRNG 로 만들고 000000~999999 를 균등하게 준다.**

  sisyphus 는 `:rand.uniform(899_999) + 100_000` 이었다 — CSPRNG 가 아니고
  `100000` 이 절대 나오지 않았다.
  """
  def generate_pincode do
    <<value::unsigned-integer-32>> = :crypto.strong_rand_bytes(4)

    # 2^32 는 1_000_000 의 배수가 아니다. 나머지 구간을 버려 균등성을 지킨다.
    limit = div(4_294_967_296, 1_000_000) * 1_000_000

    if value >= limit do
      generate_pincode()
    else
      value
      |> rem(1_000_000)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
    end
  end

  @doc "PIN 이 맞는가. **PIN 미제출도 같은 시간을 쓴다** — 필요 여부가 응답 시간으로 새지 않게."
  def valid_pin?(%__MODULE__{pin_hash: nil}, _pin), do: true

  def valid_pin?(%__MODULE__{pin_hash: hash}, pin) when is_binary(hash) and is_binary(pin),
    do: Bcrypt.verify_pass(pin, hash)

  def valid_pin?(%__MODULE__{pin_hash: hash}, _pin) when is_binary(hash) do
    Bcrypt.no_user_verify()
    false
  end

  @doc "지금 이 링크로 들어올 수 있는가."
  def usable?(link, now \\ nil), do: status(link, now) == :ok

  @doc "왜 못 들어오는지. 로그·어드민 화면용 — **응답 본문에는 쓰지 않는다.**"
  def status(link, now \\ nil) do
    now = now || DateTime.utc_now(:second)

    cond do
      not is_nil(link.deleted_at) -> :deleted
      not is_nil(link.revoked_at) -> :revoked
      not link.is_active -> :inactive
      not is_nil(link.expires_at) and DateTime.compare(link.expires_at, now) != :gt -> :expired
      not is_nil(link.max_uses) and link.use_count >= link.max_uses -> :exhausted
      true -> :ok
    end
  end

  @doc "PIN 잠금 중인가."
  def pin_locked?(%__MODULE__{pin_locked_until: nil}), do: false

  def pin_locked?(%__MODULE__{pin_locked_until: until}),
    do: DateTime.compare(until, DateTime.utc_now(:second)) == :gt

  # ── 내부 ─────────────────────────────────────────────────

  defp validate(changeset) do
    changeset
    |> validate_required([:id, :meeting_id, :token_hash, :token_prefix, :granted_role])
    |> validate_inclusion(:granted_role, @roles)
    |> validate_number(:max_uses, greater_than: 0)
    |> validate_future(:expires_at)
    |> validate_metadata()
    |> unique_constraint(:token_hash)
    |> check_constraint(:granted_role, name: :shared_links_granted_role_check)
    |> check_constraint(:max_uses, name: :shared_links_max_uses_check)
  end

  defp validate_future(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        if DateTime.compare(value, DateTime.utc_now(:second)) == :gt,
          do: changeset,
          else: add_error(changeset, field, "이미 지난 시각입니다")
    end
  end

  defp validate_metadata(changeset) do
    case get_field(changeset, :metadata) do
      value when is_map(value) ->
        if byte_size(Jason.encode!(value)) <= @metadata_max_bytes,
          do: changeset,
          else: add_error(changeset, :metadata, "너무 큽니다")

      nil ->
        changeset

      _ ->
        add_error(changeset, :metadata, "맵이어야 합니다")
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
