defmodule VRWeb.API.FriendController do
  @moduledoc """
  Friend list.

  Used by React to connect speakers to people.
  Friend management (inviting, accepting) is handled by the LiveView screens.
  """

  use VRWeb, :controller

  alias VR.Friends

  action_fallback VRWeb.API.FallbackController

  def index(conn, _params) do
    friends = Friends.list_friends(conn.assigns.current_account.id)

    json(conn, %{
      friends: Enum.map(friends, &%{id: &1.id, name: &1.name, email: &1.email})
    })
  end
end
