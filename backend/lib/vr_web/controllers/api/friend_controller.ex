defmodule VRWeb.API.FriendController do
  @moduledoc """
  친구 목록.

  React 가 화자를 사람에 연결할 때 쓴다.
  친구 관리(초대·수락)는 LiveView 화면이 담당한다.
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
