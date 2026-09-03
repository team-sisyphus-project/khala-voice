defmodule VRWeb.AppController do
  @moduledoc """
  React SPA entry point.

  Serves the same `index.html` for every path under `/app`.
  The client-side router handles the path, so a refresh or a direct
  link must not produce a 404.

  Actual assets (js/css) are intercepted by `Plug.Static` first and never reach this controller.
  """

  use VRWeb, :controller

  @index_path Path.join(:code.priv_dir(:vr), "static/app/index.html")

  def index(conn, _params) do
    case File.read(@index_path) do
      {:ok, html} ->
        conn
        |> put_resp_content_type("text/html")
        # Never cache the SPA shell. Assets use hashed filenames and are cached separately.
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, html)

      {:error, _} ->
        conn
        |> put_resp_content_type("text/html; charset=utf-8")
        |> send_resp(503, """
        <!doctype html><meta charset="utf-8">
        <div style="font-family:system-ui;padding:40px;max-width:520px;margin:0 auto">
          <h1 style="font-size:20px">Frontend has not been built</h1>
          <p style="color:#6b7684;line-height:1.6">
            Build <code>apps/web</code> first.
          </p>
          <pre style="background:#f3f4f6;padding:12px;border-radius:8px">cd apps/web
        npm install
        npm run build      # or npm run dev during development</pre>
        </div>
        """)
    end
  end
end
