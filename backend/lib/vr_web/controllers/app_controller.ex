defmodule VRWeb.AppController do
  @moduledoc """
  React SPA 진입점.

  `/app` 아래 모든 경로에서 같은 `index.html` 을 준다.
  클라이언트 라우터가 경로를 처리하므로, 새로고침이나 링크로 직접 들어와도
  404 가 나지 않아야 한다.

  실제 자산(js/css)은 `Plug.Static` 이 먼저 가로채므로 여기까지 오지 않는다.
  """

  use VRWeb, :controller

  @index_path Path.join(:code.priv_dir(:vr), "static/app/index.html")

  def index(conn, _params) do
    case File.read(@index_path) do
      {:ok, html} ->
        conn
        |> put_resp_content_type("text/html")
        # SPA 셸은 캐시하지 않는다. 자산은 해시 파일명이라 따로 캐시된다.
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, html)

      {:error, _} ->
        conn
        |> put_resp_content_type("text/html; charset=utf-8")
        |> send_resp(503, """
        <!doctype html><meta charset="utf-8">
        <div style="font-family:system-ui;padding:40px;max-width:520px;margin:0 auto">
          <h1 style="font-size:20px">프론트엔드가 빌드되지 않았습니다</h1>
          <p style="color:#6b7684;line-height:1.6">
            <code>apps/web</code> 을 먼저 빌드하세요.
          </p>
          <pre style="background:#f3f4f6;padding:12px;border-radius:8px">cd apps/web
        npm install
        npm run build      # 또는 개발 중에는 npm run dev</pre>
        </div>
        """)
    end
  end
end
