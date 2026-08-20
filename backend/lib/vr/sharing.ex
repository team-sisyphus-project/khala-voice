defmodule VR.Sharing do
  @moduledoc """
  공유 링크와 게스트 세션.

  **출처: sisyphus** `lib/sisyphus/shared_links.ex`. 바꾼 것:

  - **`consume_use/1` 을 조건부 UPDATE 한 문장으로.** 원본은 `valid?` 로 검사한 뒤
    별도 쿼리로 증가시켜서, 동시 요청이 `max_uses` 를 넘길 수 있었다.
  - **사용 횟수는 게스트 세션이 실제로 발급될 때만 증가한다.** 원본은 링크를 열 때마다
    올려서 새로고침이 1회성 링크를 태웠다.
  - `granted_role` 과 게스트 세션이 추가됐다.
  - 화상 세션 전용 헬퍼와 `resource_type` 분기는 전부 없앴다.

  ## 폐기와 소진은 다르게 동작한다

  | | 이미 들어온 게스트 |
  |---|---|
  | **폐기**(`revoke_link/1`) | **즉시 끊긴다** |
  | **소진**(`max_uses` 도달) | 그대로 남는다 |

  소진은 "더 못 들어온다"는 뜻이지 "들어온 사람을 내보낸다"는 뜻이 아니다.
  1회성 링크로 회의록을 받은 사람이 두 번째 요청에서 쫓겨나면 링크가 쓸모없어진다.
  폐기는 반대로 지금 보고 있는 사람까지 끊어야 의미가 있다.

  ## 게스트 권한 판정은 `guest_authorize/2` 한 곳만 쓴다

  컨트롤러가 `Meetings.authorize/4` 에 `guest_role:` 을 직접 넘기지 않는다.
  넘기는 자리가 여럿이면 하나만 빠뜨려도 다른 회의가 열린다.
  """

  import Ecto.Query, warn: false

  alias VR.Access.AccessLevel
  alias VR.Accounts.Account
  alias VR.Config
  alias VR.Meetings
  alias VR.Meetings.Meeting
  alias VR.Repo
  alias VR.Sharing.{GuestSession, SharedLink, ShareAttempt}

  require Logger

  @ip_window_minutes 15
  @ip_max_failures 20

  # ── 발급 · 관리 ──────────────────────────────────────────
  # 권한 판정은 호출자가 `Meetings.authorize(:lv0)` 로 먼저 끝낸다.

  @doc "링크를 발급한다. **평문 토큰과 PIN 은 여기서만 나온다.**"
  def issue_link(%Meeting{} = meeting, %Account{} = actor, attrs \\ %{}) do
    {token, pincode, changeset} = SharedLink.build(meeting.id, actor.id, attrs)

    case Repo.insert(changeset) do
      {:ok, link} -> {:ok, link, token, pincode}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "회의의 링크 목록. 폐기된 것은 빼고 최신순."
  def list_links(meeting_id) when is_binary(meeting_id) do
    Repo.all(
      from l in SharedLink,
        where: l.meeting_id == ^meeting_id and is_nil(l.deleted_at),
        order_by: [desc: l.inserted_at]
    )
  end

  def get_link(id) when is_binary(id) do
    Repo.one(from l in SharedLink, where: l.id == ^id and is_nil(l.deleted_at))
  end

  def get_link(_), do: nil

  def update_link(%SharedLink{} = link, attrs) do
    link |> SharedLink.update_changeset(attrs) |> Repo.update()
  end

  @doc """
  토큰만 새로 만든다. 설정·사용 횟수는 유지하고 **이미 들어온 게스트도 끊지 않는다** —
  그들은 자기 게스트 토큰을 갖고 있고, 재발급은 "링크 주소를 잃어버렸다"는 뜻이다.
  """
  def rotate_token(%SharedLink{} = link) do
    {token, changeset} = SharedLink.rotate_changeset(link)

    case Repo.update(changeset) do
      {:ok, updated} -> {:ok, updated, token}
      error -> error
    end
  end

  @doc "PIN 을 켜거나 끈다. 켜면 새 PIN 을 한 번만 돌려준다."
  def set_pincode(%SharedLink{} = link, mode) when mode in [:on, :off] do
    {pincode, changeset} = SharedLink.pin_changeset(link, mode)

    case Repo.update(changeset) do
      {:ok, updated} -> {:ok, updated, pincode}
      error -> error
    end
  end

  @doc """
  링크를 폐기한다. **이 링크로 들어와 있는 게스트 세션도 같이 끊는다.**

  sisyphus 는 `is_active` 만 껐고 이미 들어온 사람은 그대로 남았다.
  """
  def revoke_link(%SharedLink{} = link) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      updated =
        link
        |> Ecto.Changeset.change(%{is_active: false, revoked_at: now, deleted_at: now})
        |> Repo.update!()

      Repo.update_all(
        from(g in GuestSession, where: g.shared_link_id == ^link.id and is_nil(g.revoked_at)),
        set: [revoked_at: now]
      )

      updated
    end)
  end

  @doc "공유 URL. 앱 주소가 설정돼 있지 않으면 경로만 준다."
  def link_url(token) when is_binary(token) do
    case Config.fetch("app.base_url") do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/") <> "/share/" <> token

      _ ->
        "/share/" <> token
    end
  end

  # ── 게스트 진입 ──────────────────────────────────────────

  @doc """
  토큰으로 링크를 찾는다. **해시로 조회한다** — 평문은 DB 에 없다.

  폐기된 링크도 찾는다. 링크를 받은 사람에게 "끝난 링크입니다"(410)를 보여주려면
  없는 것(404)과 구분해야 한다. 사용 가능 여부는 `check_usable/1` 이 따로 본다.
  """
  def fetch_by_token(token) when is_binary(token) do
    with {:ok, hash} <- SharedLink.hash_token(token),
         %SharedLink{} = link <- Repo.one(from l in SharedLink, where: l.token_hash == ^hash) do
      {:ok, link}
    else
      _ -> {:error, :not_found}
    end
  end

  def fetch_by_token(_), do: {:error, :not_found}

  @doc """
  지금 들어올 수 있는 링크인가.

  **왜 못 들어오는지는 응답에 싣지 않는다.** 만료인지 소진인지 알려주면
  토큰이 유효했다는 사실이 새어 나간다.
  """
  def check_usable(%SharedLink{} = link) do
    if SharedLink.usable?(link), do: :ok, else: {:error, :gone}
  end

  @doc """
  PIN 을 확인한다.

  링크별 잠금(5회 → 15분)과 **IP 별 잠금**(15분간 20회)을 함께 본다.
  링크별만 두면 공격자가 여러 링크를 번갈아 때리는 것을 못 막는다.
  """
  def verify_pincode(%SharedLink{} = link, pincode, ip \\ nil) do
    # **DB 에서 다시 읽는다.** 호출자가 들고 있는 구조체는 이 요청 전에 읽은 것이라
    # 다른 요청이 올린 실패 횟수가 반영돼 있지 않다. 그대로 쓰면 동시 요청 N 건이
    # 모두 "실패 0회" 를 보고 잠금을 통과한다.
    link = get_link(link.id) || link

    cond do
      SharedLink.pin_locked?(link) ->
        {:error, :locked}

      ip_locked?(ip) ->
        {:error, :locked}

      SharedLink.valid_pin?(link, pincode) ->
        record_attempt(link, ip, true)
        reset_failures(link)
        :ok

      true ->
        record_attempt(link, ip, false)
        bump_failures(link)
        {:error, :invalid_pincode}
    end
  end

  @doc """
  사용 횟수를 하나 태운다. **검사와 증가가 한 문장이다.**

  검사한 뒤 따로 증가시키면 동시 요청 두 건이 둘 다 검사를 통과해
  `max_uses: 1` 링크가 두 번 쓰인다.
  """
  def consume_use(%SharedLink{} = link) do
    now = DateTime.utc_now(:second)

    query =
      from l in SharedLink,
        where: l.id == ^link.id,
        where: l.is_active and is_nil(l.deleted_at) and is_nil(l.revoked_at),
        where: is_nil(l.expires_at) or l.expires_at > ^now,
        where: is_nil(l.max_uses) or l.use_count < l.max_uses,
        select: l

    case Repo.update_all(query, inc: [use_count: 1], set: [last_used_at: now]) do
      {1, [updated]} -> {:ok, updated}
      _ -> {:error, :gone}
    end
  end

  @doc """
  게스트로 입장한다.

  ## 로그인한 계정은 게스트 세션을 만들지 않는다

  계정 권한이 우선이다. 이미 Contributor 인 사람이 viewer 링크로 들어왔다고
  Viewer 로 내려앉으면 안 되고, 반대로 링크 때문에 사용 횟수가 타면 안 된다.
  그래서 계정이 있으면 **회의로 보내기만** 한다.

  ## `guest_link_enabled` 가 꺼져 있으면 비로그인은 못 들어온다

  링크는 살아 있어도 회의 쪽 스위치가 닫혀 있으면 게스트는 거절된다.
  이때도 **404** 다 — 링크가 유효했다는 사실을 노출하지 않는다.
  """
  def enter(token, params \\ %{}, opts \\ []) do
    with {:ok, link} <- fetch_by_token(token),
         :ok <- check_usable(link) do
      case opts[:account] do
        %Account{} = account -> enter_as_account(link, account, params, opts)
        _ -> enter_as_guest(link, params, opts)
      end
    end
  end

  defp enter_as_account(%SharedLink{} = link, %Account{} = account, params, opts) do
    case Meetings.authorize(link.meeting_id, account, :lv2) do
      # 계정 권한으로 이미 볼 수 있다. 링크를 쓰지 않는다 —
      # PIN 도 묻지 않고 사용 횟수도 태우지 않는다.
      {:ok, meeting, level} ->
        {:ok, %{mode: :account, meeting: meeting, level: level, guest_token: nil}}

      # 로그인은 했지만 그 회의 권한이 없다. **익명 방문자와 똑같이 취급한다** —
      # 회의 스위치도 보고 PIN 도 묻는다. 로그인했다는 사실만으로 관문을 건너뛰면
      # 아무나 가입해서 게스트 차단을 우회할 수 있다.
      {:error, :not_found} ->
        enter_as_guest(link, params, Keyword.put(opts, :account, account))
    end
  end

  defp enter_as_guest(%SharedLink{} = link, params, opts) do
    with :ok <- ensure_guest_link_enabled(link, opts),
         :ok <- verify_pincode(link, params["pincode"] || params[:pincode], opts[:ip_address]),
         {:ok, session_changeset} <- build_guest(link, params, opts),
         {:ok, link} <- consume_use(link) do
      {token, changeset} = session_changeset

      case Repo.insert(changeset) do
        {:ok, session} ->
          {:ok,
           %{
             mode: :guest,
             meeting_id: link.meeting_id,
             granted_role: session.granted_role,
             guest_token: token,
             expires_at: session.expires_at
           }}

        {:error, changeset} ->
          # 사용 횟수를 이미 태웠다. 세션을 못 만들었으니 되돌린다.
          refund_use(link)
          {:error, changeset}
      end
    end
  end

  # 스위치는 "이 회의는 게스트를 받지 않는다"는 뜻이다. **로그인 여부와 무관하다.**
  # 로그인을 면제 조건으로 두면 아무나 가입해서 차단을 우회하고, 1회성 링크를
  # 대신 태워 정당한 수신자가 못 들어오게 만들 수 있다.
  #
  # 계정 권한으로 이미 볼 수 있는 사람은 여기까지 오지 않는다 (`enter_as_account`).
  defp ensure_guest_link_enabled(%SharedLink{} = link, _opts) do
    # 403 이 아니다. 링크가 유효했다는 사실도 숨긴다.
    if guest_link_enabled?(link.meeting_id), do: :ok, else: {:error, :not_found}
  end

  defp guest_link_enabled?(meeting_id) do
    Repo.one(
      from m in Meeting,
        where: m.id == ^meeting_id and is_nil(m.deleted_at),
        select: m.guest_link_enabled
    ) == true
  end

  defp build_guest(link, params, opts) do
    attrs = %{
      display_name: params["display_name"] || params[:display_name],
      email: params["email"] || params[:email],
      account_id: opts[:account] && opts[:account].id,
      user_agent: opts[:user_agent],
      ip_address: opts[:ip_address]
    }

    {token, changeset} = GuestSession.build(link, attrs)

    if changeset.valid?,
      do: {:ok, {token, changeset}},
      else: {:error, %{changeset | action: :insert}}
  end

  # 세션 생성이 실패했는데 사용 횟수만 타면 1회성 링크가 아무도 못 쓰게 된다
  defp refund_use(%SharedLink{} = link) do
    Repo.update_all(
      from(l in SharedLink, where: l.id == ^link.id and l.use_count > 0),
      inc: [use_count: -1]
    )
  end

  # ── 게스트 세션 ──────────────────────────────────────────

  @doc """
  게스트 토큰으로 세션을 찾는다. 만료·폐기된 것은 없는 것과 같다.

  찾으면 마지막 활동 시각을 갱신한다.
  """
  def fetch_live_guest(token) when is_binary(token) do
    now = DateTime.utc_now(:second)

    with {:ok, hash} <- GuestSession.hash_token(token),
         %GuestSession{} = session <-
           Repo.one(
             from g in GuestSession,
               # **링크가 지금도 살아 있는지 매 요청 다시 본다.**
               # 세션만 보면 Reviewer 가 링크를 끄거나 만료를 당겨도 이미 들어온
               # 사람이 계속 읽는다 — 껐다고 믿는 조작이 아무 일도 안 하는 셈이다.
               #
               # `max_uses` 소진은 **일부러 뺐다.** 소진은 "더 못 들어온다"는 뜻이지
               # "들어온 사람을 내보낸다"가 아니다 (모듈 문서의 폐기/소진 구분).
               join: l in SharedLink,
               on: l.id == g.shared_link_id,
               where: g.token_hash == ^hash and is_nil(g.revoked_at) and g.expires_at > ^now,
               where: l.is_active and is_nil(l.deleted_at) and is_nil(l.revoked_at),
               where: is_nil(l.expires_at) or l.expires_at > ^now,
               select: g
           ) do
      Repo.update_all(
        from(g in GuestSession, where: g.id == ^session.id),
        set: [last_activity_at: now]
      )

      {:ok, session}
    else
      _ -> :error
    end
  end

  def fetch_live_guest(_), do: :error

  @doc "게스트 세션을 끊는다."
  def revoke_guest(%GuestSession{} = session) do
    session
    |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  @doc """
  게스트가 이 회의를 이 수준으로 볼 수 있는가. **게스트 권한 판정은 여기 하나뿐이다.**

  회의는 요청이 아니라 **세션이 정한다** — `session.meeting_id` 를 쓴다.
  요청이 다른 회의를 가리켜도 세션이 가진 회의가 이긴다.
  """
  def guest_authorize(%GuestSession{} = session, required) do
    with %Meeting{} = meeting <- Meetings.get_meeting(session.meeting_id),
         true <- guest_link_enabled?(meeting.id),
         level <-
           AccessLevel.resolve(meeting, nil,
             guest_role: session.granted_role,
             # 세션이 묶인 회의와 대조한다. 이 인자가 없으면 AccessLevel 은 lv3 을 준다.
             guest_resource_id: session.meeting_id
           ),
         true <- AccessLevel.at_least?(level, required) do
      {:ok, meeting, level}
    else
      _ -> {:error, :not_found}
    end
  end

  # ── 내부 ─────────────────────────────────────────────────

  defp record_attempt(%SharedLink{} = link, ip, success) do
    %ShareAttempt{}
    |> ShareAttempt.changeset(%{
      token_hash: link.token_hash,
      ip_address: ip && String.slice(to_string(ip), 0, 45),
      success: success
    })
    |> Repo.insert()
  end

  defp ip_locked?(nil), do: false

  defp ip_locked?(ip) do
    since = DateTime.add(DateTime.utc_now(:second), -@ip_window_minutes, :minute)

    count =
      Repo.one(
        from a in ShareAttempt,
          where: a.ip_address == ^to_string(ip) and not a.success and a.attempted_at > ^since,
          select: count(a.id)
      ) || 0

    count >= @ip_max_failures
  end

  # 증가와 잠금 판정을 **한 UPDATE 문**에서 한다.
  #
  # 읽어서 +1 해 쓰면 동시 요청들이 서로의 증가를 덮어써(lost update) 5회 잠금이
  # 무너진다. 6자리 PIN 은 그 순간 대입 가능해진다.
  defp bump_failures(%SharedLink{} = link) do
    max = SharedLink.pin_max_failures()
    until = DateTime.add(DateTime.utc_now(:second), SharedLink.pin_lock_minutes(), :minute)

    query =
      from l in SharedLink,
        where: l.id == ^link.id,
        update: [
          inc: [failed_pin_attempts: 1],
          set: [
            pin_locked_until:
              fragment(
                "CASE WHEN ? + 1 >= ? THEN ? ELSE ? END",
                l.failed_pin_attempts,
                ^max,
                ^until,
                l.pin_locked_until
              )
          ]
        ]

    Repo.update_all(query, [])
  end

  defp reset_failures(%SharedLink{failed_pin_attempts: 0, pin_locked_until: nil}), do: :ok

  defp reset_failures(%SharedLink{} = link) do
    link
    |> Ecto.Changeset.change(%{failed_pin_attempts: 0, pin_locked_until: nil})
    |> Repo.update()
  end
end
