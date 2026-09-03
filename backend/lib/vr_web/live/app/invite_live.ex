defmodule VRWeb.AppLive.InviteLive do
  @moduledoc """
  친구 초대 링크를 연 화면.

  **로그인하지 않아도 볼 수 있다** — 누가 초대했는지 보여줘야 가입할 마음이 생긴다.
  수락은 로그인 후에만 된다.
  """

  use VRWeb, :live_view

  import VRWeb.AuthLive.Components

  alias VR.Accounts
  alias VR.Friends

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Friends.get_invitation_by_token(token) do
      {:ok, invitation} ->
        inviter = Accounts.get_account(invitation.invited_by_id)

        {:ok,
         socket
         |> assign(page_title: gettext("Friend invitation"))
         |> assign(token: token, invitation: invitation, inviter: inviter, state: :pending),
         layout: false}

      {:error, reason} ->
        {:ok,
         socket
         |> assign(page_title: gettext("Friend invitation"))
         |> assign(token: token, invitation: nil, inviter: nil, state: reason), layout: false}
    end
  end

  @impl true
  def handle_event("accept", _params, socket) do
    case socket.assigns.current_account do
      nil ->
        {:noreply, redirect(socket, to: ~p"/login")}

      account ->
        case Friends.accept_invitation(socket.assigns.token, account) do
          {:ok, _} ->
            {:noreply, assign(socket, state: :accepted)}

          {:error, :cannot_accept_own} ->
            {:noreply, assign(socket, state: :own_invitation)}

          {:error, reason} when is_atom(reason) ->
            {:noreply, assign(socket, state: reason)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't accept the invitation"))}
        end
    end
  end

  def handle_event("decline", _params, socket) do
    case socket.assigns.current_account do
      nil ->
        {:noreply, redirect(socket, to: ~p"/login")}

      account ->
        Friends.decline_invitation(socket.assigns.token, account)
        {:noreply, assign(socket, state: :declined)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_shell title={gettext("Friend invitation")}>
      <div :if={@state == :pending} class="text-center">
        <p style="color: var(--text-primary); font-size: 15px;">
          <strong>{inviter_name(@inviter)}</strong> {gettext("invited you as a friend.")}
        </p>
        <p
          :if={@invitation.message}
          class="vr-hint mt-3 p-3"
          style="background: var(--surface-canvas); border-radius: var(--radius-sm);"
        >
          “{@invitation.message}”
        </p>

        <div :if={@current_account} class="flex gap-2 mt-6">
          <button class="vr-btn vr-btn--outline flex-1" phx-click="decline">
            {gettext("Decline")}
          </button>
          <button class="vr-btn vr-btn--primary flex-1" phx-click="accept">
            {gettext("Accept")}
          </button>
        </div>

        <div :if={is_nil(@current_account)} class="mt-6">
          <p class="vr-hint mb-3">{gettext("Sign in to accept this invitation.")}</p>
          <.link navigate={~p"/login"} class="vr-btn vr-btn--primary w-full">
            {gettext("Sign in")}
          </.link>
          <.link navigate={~p"/register"} class="vr-btn vr-btn--outline w-full mt-2">
            {gettext("Sign up")}
          </.link>
        </div>
      </div>

      <.result
        :if={@state == :accepted}
        icon="check_circle"
        color="var(--status-success)"
        title={gettext("You're now connected")}
      >
        {gettext("You can now share meeting notes with each other.")}
      </.result>

      <.result
        :if={@state == :declined}
        icon="do_not_disturb_on"
        color="var(--text-tertiary)"
        title={gettext("Invitation declined")}
      />

      <.result
        :if={@state == :expired}
        icon="schedule"
        color="var(--warning)"
        title={gettext("This invitation has expired")}
      >
        {gettext("Ask the person who invited you for a new link.")}
      </.result>

      <.result
        :if={@state == :not_pending}
        icon="info"
        color="var(--text-tertiary)"
        title={gettext("This invitation was already handled")}
      />

      <.result
        :if={@state == :not_found}
        icon="link_off"
        color="var(--text-tertiary)"
        title={gettext("Invitation not found")}
      >
        {gettext("Check that the link is correct.")}
      </.result>

      <.result
        :if={@state == :own_invitation}
        icon="info"
        color="var(--text-tertiary)"
        title={gettext("This is your own invitation")}
      >
        {gettext("Share this link with someone else.")}
      </.result>

      <:footer>
        <.link navigate="/go/meetings" style="color: var(--accent); font-weight: 600;">
          {gettext("Home")}
        </.link>
      </:footer>
    </.auth_shell>
    """
  end

  attr :icon, :string, required: true
  attr :color, :string, required: true
  attr :title, :string, required: true
  slot :inner_block

  defp result(assigns) do
    ~H"""
    <div class="text-center py-2">
      <span class="material-symbols-rounded mb-3" style={"font-size: 40px; color: #{@color};"}>
        {@icon}
      </span>
      <p style="color: var(--text-primary); font-weight: 600;">{@title}</p>
      <p :if={@inner_block != []} class="vr-hint mt-2">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  defp inviter_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp inviter_name(%{email: email}), do: email
  defp inviter_name(_), do: gettext("Someone")
end
