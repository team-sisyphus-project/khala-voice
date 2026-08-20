defmodule VRWeb.PageController do
  use VRWeb, :controller

  @doc """
  루트(`/`)는 앱으로 보낸다.

  `/go` 는 **표면 중립** 접두어다 — 데스크톱(`/app`)인지 모바일(`/m`)인지는
  브라우저가 정한다 (`apps/web/src/lib/surface.ts`). 서버는 폭을 모른다.

  랜딩 페이지를 두지 않는다 — 이 서비스는 로그인해서 쓰는 것이고, 소개는
  리포의 README 가 한다. Phoenix 기본 템플릿이 그대로 떠 있던 자리다.

  로그인하지 않았다면 `/go/meetings` 의 `:require_auth` 가 다시 `/login` 으로
  보낸다. 그래서 여기서 로그인 여부를 따지지 않는다 — 판정은 한 곳(플러그)에만 둔다.
  """
  def home(conn, _params) do
    redirect(conn, to: "/go/meetings")
  end
end
