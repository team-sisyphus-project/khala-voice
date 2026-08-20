defmodule VRWeb.KhalaController do
  @moduledoc """
  칼라 계정 연결 — OAuth 2.0 인가 코드 흐름(PKCE).

  브라우저가 왕복하는 부분만 여기 있다. 토큰을 쓰는 일은 `VR.Khala` 가 한다.

  ## 세션에 담는 것

  PKCE 검증자와 `state` 를 세션에 담는다. **쿠키가 아니라 세션이다** —
  검증자가 새어 나가면 PKCE 가 지켜 주는 것이 없어진다.

  `state` 는 CSRF 방어다. 콜백으로 돌아온 값이 우리가 보낸 것과 다르면
  누군가 우리 사용자를 남의 인가 코드로 연결하려는 것이다.
  """

  use VRWeb, :controller

  require Logger

  alias VR.Khala
  alias VR.Khala.OAuth

  @doc "칼라 로그인으로 보낸다."
  def connect(conn, _params) do
    redirect_uri = callback_url(conn)

    with true <- OAuth.enabled?() || :disabled,
         {:ok, meta} <- OAuth.discover(),
         {:ok, client_id} <- OAuth.register_client(meta, redirect_uri) do
      {verifier, challenge} = OAuth.pkce()
      state = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      conn
      |> put_session(:khala_verifier, verifier)
      |> put_session(:khala_state, state)
      |> put_session(:khala_client_id, client_id)
      |> redirect(external: OAuth.authorize_url(meta, client_id, redirect_uri, challenge, state))
    else
      :disabled ->
        conn |> put_flash(:error, "칼라 연동이 꺼져 있습니다") |> redirect(to: "/go/settings")

      {:error, reason} ->
        Logger.warning("[Khala] 연결 시작 실패: #{inspect(reason)}")

        conn
        |> put_flash(:error, "칼라에 연결하지 못했습니다")
        |> redirect(to: "/go/settings")
    end
  end

  @doc "칼라가 되돌려 보낸다."
  def callback(conn, params) do
    account = conn.assigns.current_account
    expected = get_session(conn, :khala_state)
    verifier = get_session(conn, :khala_verifier)
    client_id = get_session(conn, :khala_client_id)

    conn = clear_khala_session(conn)

    cond do
      params["error"] ->
        # 사용자가 거절했을 수도 있다. 오류로 겁주지 않는다.
        conn |> put_flash(:info, "칼라 연결을 취소했습니다") |> redirect(to: "/go/settings")

      is_nil(expected) or params["state"] != expected ->
        # 우리가 시작하지 않은 콜백이다
        conn |> put_flash(:error, "연결 요청이 만료되었습니다") |> redirect(to: "/go/settings")

      is_nil(params["code"]) or is_nil(verifier) or is_nil(client_id) ->
        conn |> put_flash(:error, "칼라에 연결하지 못했습니다") |> redirect(to: "/go/settings")

      true ->
        finish(conn, account, client_id, params["code"], verifier)
    end
  end

  defp finish(conn, account, client_id, code, verifier) do
    with {:ok, meta} <- OAuth.discover(),
         {:ok, tokens} <- OAuth.exchange(meta, client_id, code, verifier, callback_url(conn)),
         {:ok, _connection} <- Khala.connect(account.id, client_id, tokens) do
      # 인박스는 첫 발송 때 만들어도 되지만, 여기서 만들어 두면 설정 화면이
      # 바로 "연결됨 · 인박스 이름"을 보여줄 수 있다. 실패해도 연결은 유효하다.
      _ = Khala.ensure_inbox(account.id)

      conn |> put_flash(:info, "칼라에 연결했습니다") |> redirect(to: "/go/settings")
    else
      {:error, reason} ->
        Logger.warning("[Khala] 토큰 교환 실패: #{inspect(reason)}")

        conn
        |> put_flash(:error, "칼라에 연결하지 못했습니다")
        |> redirect(to: "/go/settings")
    end
  end

  defp clear_khala_session(conn) do
    conn
    |> delete_session(:khala_verifier)
    |> delete_session(:khala_state)
    |> delete_session(:khala_client_id)
  end

  # 칼라에 등록한 것과 인가 요청에 쓰는 것이 **같아야** 한다.
  defp callback_url(_conn), do: url(~p"/khala/callback")
end
