defmodule VRWeb.ConfirmationController do
  @moduledoc "Handles email confirmation links."

  use VRWeb, :controller

  alias VR.Accounts

  def confirm(conn, %{"token" => token}) do
    case Accounts.confirm_account(token) do
      {:ok, _account} ->
        conn
        |> put_flash(:info, "Your email has been confirmed")
        |> redirect(to: redirect_target(conn))

      _ ->
        conn
        |> put_flash(:error, "This link has expired or has already been used")
        |> redirect(to: redirect_target(conn))
    end
  end

  defp redirect_target(conn) do
    if conn.assigns[:current_account], do: "/go/meetings", else: ~p"/login"
  end
end
