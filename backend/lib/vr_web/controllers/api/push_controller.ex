defmodule VRWeb.API.PushController do
  @moduledoc """
  Web push subscriptions. **Self only.**
  """

  use VRWeb, :controller

  alias VR.Push

  action_fallback VRWeb.API.FallbackController

  @doc "The browser needs the public key in order to subscribe."
  def show(conn, _params) do
    account = conn.assigns.current_account

    json(conn, %{
      enabled: Push.ready?(),
      public_key: Push.public_key(),
      subscriptions: length(Push.list_subscriptions(account.id))
    })
  end

  def subscribe(conn, params) do
    account = conn.assigns.current_account

    attrs =
      %{
        "endpoint" => params["endpoint"],
        "p256dh" => get_in(params, ["keys", "p256dh"]),
        "auth" => get_in(params, ["keys", "auth"]),
        "user_agent" => user_agent(conn)
      }

    with {:ok, _subscription} <- Push.subscribe(account.id, attrs) do
      send_resp(conn, :no_content, "")
    end
  end

  def unsubscribe(conn, %{"endpoint" => endpoint}) do
    account = conn.assigns.current_account

    with {:ok, _} <- Push.unsubscribe(account.id, endpoint) do
      send_resp(conn, :no_content, "")
    end
  end

  def unsubscribe(_conn, _params), do: {:error, :invalid_request}

  defp user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [value | _] -> String.slice(value, 0, 300)
      _ -> nil
    end
  end
end
