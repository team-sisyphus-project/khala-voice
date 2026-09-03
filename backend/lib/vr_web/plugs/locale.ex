defmodule VRWeb.Plugs.Locale do
  @moduledoc """
  요청마다 Gettext 로케일을 현재 계정의 `locale` 로 맞춘다.

  UI 표시 언어는 계정의 `locale` 필드가 단일 출처다. 로그인 전이거나 값이
  없으면 **영어**로 떨어진다 — 오픈소스로 국제 공개되는 제품이라 영어가 기본이며,
  카탈로그가 없는 로케일도 영어로 폴백한다. (React 셸의 `DEFAULT_UI_LOCALE` 과
  같은 규칙을 서버에서도 지킨다.)

  이 플러그는 **컨트롤러 렌더**(React SPA 진입 페이지·공유 페이지 등)의 로케일과
  루트 레이아웃의 `<html lang>` 을 담당한다. LiveView 는 플러그를 거치지 않으므로
  `VRWeb.UserAuth.on_mount(:set_locale, ...)` 이 같은 규칙을 다시 적용한다.
  """

  import Plug.Conn

  @default_locale "en"

  @doc "기본 표시 언어. 미로그인·미설정 계정과 폴백에 쓴다."
  def default_locale, do: @default_locale

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = resolve(conn.assigns[:current_account])

    Gettext.put_locale(VRWeb.Gettext, locale)

    conn
    |> assign(:locale, locale)
    |> put_session(:locale, locale)
  end

  @doc """
  계정에서 표시 언어를 뽑는다. 계정이 없거나 `locale` 이 비어 있으면 기본값.

  컨트롤러 플러그와 LiveView `on_mount` 가 같은 규칙을 쓰도록 공용으로 둔다.
  """
  def resolve(%{locale: locale}) when is_binary(locale) and locale != "", do: locale
  def resolve(_), do: @default_locale
end
