defmodule VR.Sharing.GuestSession do
  @moduledoc """
  공유 링크로 들어온 방문자 한 명 = 한 행.

  **출처 없음 — 이 앱에서 새로 만든 개념이다.**

  sisyphus 에는 게스트 세션이 아예 없었다. 게스트 API 가 매번 공유 토큰을 URL 로
  받아 다시 조회했고, 게스트의 신원(이름·id)은 브라우저 JS 메모리 변수였다
  (`assets/webapp/video-call-guest.js`). 그래서 서버가 "지금 들어와 있는 게스트"를
  알지 못했고, 링크를 폐기해도 이미 들어온 사람을 끊을 수 없었다.

  ## 회의 하나에만 묶인다

  `meeting_id` 가 이 행에 박혀 있다. 게스트가 어느 회의를 볼지는 **세션이 정하고**,
  요청 URL 이 정하지 않는다. URL 에 회의 id 를 넣지 않으므로 다른 회의를 가리킬
  방법 자체가 없다.

  ## `granted_role` 을 링크에서 복사해 굳힌다

  참조로 두면 링크의 역할이 바뀔 때 이미 들어온 게스트의 권한이 따라 움직인다.
  들어온 시점의 약속을 그대로 유지한다.

  토큰 취급은 `VR.Accounts.AccountSession` 과 같다 — 원본은 클라이언트에만,
  DB 에는 sha256 해시만.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias VR.IdGenerator
  alias VR.Sharing.SharedLink

  @rand_size 32
  @token_prefix "gst_"
  @validity_hours 12

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "guest_sessions" do
    field :shared_link_id, :string
    field :meeting_id, :string
    field :account_id, :string

    field :token_hash, :binary, redact: true
    field :granted_role, :string
    field :display_name, :string
    field :email, :string
    field :user_agent, :string
    field :ip_address, :string

    field :last_activity_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def validity_hours, do: @validity_hours
  def token_prefix, do: @token_prefix

  @doc """
  게스트 세션을 만든다. `{평문_토큰, changeset}`.

  만료는 **12시간과 링크 만료 중 이른 쪽**이다. 링크가 내일 죽는데
  게스트 세션이 모레까지 살아 있으면 폐기가 반쪽이 된다.
  """
  def build(%SharedLink{} = link, attrs \\ %{}) do
    raw = :crypto.strong_rand_bytes(@rand_size)
    now = DateTime.utc_now(:second)
    expires_at = earliest(DateTime.add(now, @validity_hours, :hour), link.expires_at)

    changeset =
      %__MODULE__{}
      |> cast(attrs, [:display_name, :email])
      |> put_change(:id, IdGenerator.generate(:guest_session))
      |> put_change(:shared_link_id, link.id)
      |> put_change(:meeting_id, link.meeting_id)
      |> put_change(:token_hash, :crypto.hash(:sha256, raw))
      # 링크에서 복사해 굳힌다. 링크가 나중에 바뀌어도 이 세션은 그대로다.
      |> put_change(:granted_role, link.granted_role)
      |> put_change(:account_id, attrs[:account_id] || attrs["account_id"])
      |> put_change(:user_agent, truncate(attrs[:user_agent], 300))
      |> put_change(:ip_address, truncate(attrs[:ip_address], 45))
      |> put_change(:last_activity_at, now)
      |> put_change(:expires_at, expires_at)
      |> validate_required([:id, :shared_link_id, :meeting_id, :token_hash, :granted_role])
      |> validate_inclusion(:granted_role, SharedLink.roles())
      |> validate_identity(link)
      |> check_constraint(:granted_role, name: :guest_sessions_granted_role_check)

    {@token_prefix <> Base.url_encode64(raw, padding: false), changeset}
  end

  @doc "요청 헤더의 토큰을 DB 조회용 해시로 바꾼다."
  def hash_token(@token_prefix <> encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} -> {:ok, :crypto.hash(:sha256, raw)}
      :error -> :error
    end
  end

  def hash_token(_), do: :error

  @doc "아직 유효한가."
  def live?(session, now \\ nil) do
    now = now || DateTime.utc_now(:second)
    is_nil(session.revoked_at) and DateTime.compare(session.expires_at, now) == :gt
  end

  # ── 내부 ─────────────────────────────────────────────────

  defp validate_identity(changeset, %SharedLink{} = link) do
    changeset
    |> maybe_require(:display_name, link.require_name)
    |> maybe_require(:email, link.require_email)
    |> validate_length(:display_name, min: 1, max: 60)
    |> validate_email(link.require_email)
  end

  defp maybe_require(changeset, _field, false), do: changeset
  defp maybe_require(changeset, field, true), do: validate_required(changeset, [field])

  defp validate_email(changeset, false), do: changeset

  defp validate_email(changeset, true) do
    validate_format(changeset, :email, ~r/^[^\s@]+@[^\s@]+$/, message: "형식이 올바르지 않습니다")
  end

  defp earliest(a, nil), do: a
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp truncate(nil, _max), do: nil
  defp truncate(value, max), do: String.slice(to_string(value), 0, max)
end
