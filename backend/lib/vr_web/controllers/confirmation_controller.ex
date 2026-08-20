defmodule VRWeb.ConfirmationController do
  @moduledoc "이메일 확인 링크 처리."

  use VRWeb, :controller

  alias VR.Accounts

  def confirm(conn, %{"token" => token}) do
    case Accounts.confirm_account(token) do
      {:ok, _account} ->
        conn
        |> put_flash(:info, "이메일 확인이 완료되었습니다")
        |> redirect(to: redirect_target(conn))

      _ ->
        conn
        |> put_flash(:error, "링크가 만료되었거나 이미 사용되었습니다")
        |> redirect(to: redirect_target(conn))
    end
  end

  defp redirect_target(conn) do
    if conn.assigns[:current_account], do: "/go/meetings", else: ~p"/login"
  end
end
