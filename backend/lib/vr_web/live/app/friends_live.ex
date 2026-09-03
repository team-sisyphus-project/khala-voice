defmodule VRWeb.AppLive.FriendsLive do
  @moduledoc """
  친구 목록과 초대.

  초대는 두 방식을 한 화면에서 제공한다.
  - 이메일을 입력하면 메일을 보낸다
  - 비워두면 링크만 만들어 준다 (아무 경로로 전달)
  """

  use VRWeb, :live_view

  import VRWeb.AppLive.Components

  alias VR.Accounts
  alias VR.Friends

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: gettext("Friends"), invite_link: nil) |> load(),
     layout: false}
  end

  defp load(socket) do
    account = socket.assigns.current_account

    assign(socket,
      friends: Friends.list_friends(account.id),
      sent:
        account.id |> Friends.list_sent_invitations() |> Enum.filter(&(&1.status == "pending")),
      received: Friends.list_received_invitations(account),
      form: to_form(%{"email" => "", "message" => ""}, as: :invite)
    )
  end

  @impl true
  def handle_event("invite", %{"invite" => params}, socket) do
    account = socket.assigns.current_account
    email = String.trim(params["email"] || "")

    attrs = %{email: email, message: params["message"]}

    case Friends.create_invitation(account, attrs) do
      {:ok, _invitation, token} ->
        link = url(~p"/invite/#{token}")

        socket =
          if email == "" do
            # 링크 초대 — 화면에 보여준다
            assign(socket, invite_link: link)
          else
            Accounts.Notifier.deliver_friend_invitation(email, account, token, params["message"])

            socket
            |> put_flash(:info, gettext("Invitation sent to %{email}", email: email))
            |> assign(invite_link: nil)
          end

        {:noreply, load(socket)}

      {:error, reason} when is_atom(reason) ->
        {:noreply, put_flash(socket, :error, invite_error(reason))}

      {:error, changeset} ->
        msg =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {m, _} -> m end)
          |> Enum.map(fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
          |> Enum.join("; ")

        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    case Friends.cancel_invitation(id, socket.assigns.current_account) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Invitation canceled")) |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't cancel the invitation"))}
    end
  end

  def handle_event("remove", %{"id" => other_id}, socket) do
    Friends.remove_friend(socket.assigns.current_account.id, other_id)
    {:noreply, socket |> put_flash(:info, gettext("Friend removed")) |> load()}
  end

  def handle_event("clear_link", _, socket), do: {:noreply, assign(socket, invite_link: nil)}

  defp invite_error(:cannot_invite_self), do: gettext("You can't invite yourself")
  defp invite_error(:already_friends), do: gettext("You're already friends")
  defp invite_error(:already_invited), do: gettext("You already sent an invitation")
  defp invite_error(_), do: gettext("Couldn't create the invitation")

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell
      current_account={@current_account}
      active={:friends}
      title={gettext("Friends")}
      subtitle={gettext("Share meeting notes with friends")}
    >
      <div class="vr-card mb-4">
        <div class="vr-card__body">
          <h2 class="font-bold mb-3" style="color: var(--text-primary);">{gettext("Invite")}</h2>

          <.form for={@form} phx-submit="invite" class="flex flex-col gap-3">
            <div>
              <label class="vr-label mb-1.5" for="invite_email">
                {gettext("Email")} <span class="vr-hint">{gettext("(optional)")}</span>
              </label>
              <input
                type="email"
                id="invite_email"
                name="invite[email]"
                placeholder={gettext("Leave empty to create a share link only")}
                class="vr-input"
                style="font-family: var(--font-sans);"
              />
            </div>
            <div>
              <label class="vr-label mb-1.5" for="invite_message">
                {gettext("Message")} <span class="vr-hint">{gettext("(optional)")}</span>
              </label>
              <input
                type="text"
                id="invite_message"
                name="invite[message]"
                maxlength="300"
                class="vr-input"
                style="font-family: var(--font-sans);"
              />
            </div>
            <div class="flex justify-end">
              <button type="submit" class="vr-btn vr-btn--primary vr-btn--sm">
                {gettext("Create invitation")}
              </button>
            </div>
          </.form>

          <div :if={@invite_link} class="vr-notice vr-notice--ok mt-3">
            <span class="material-symbols-rounded vr-notice__icon">link</span>
            <div class="min-w-0 flex-1">
              <div class="vr-notice__title">{gettext("Invitation link created")}</div>

              <%!--
                링크를 손으로 옮겨 적게 두지 않는다. 토큰이 길어서 한 글자만 틀려도
                열리지 않고, 어디서 틀렸는지 알 방법이 없다.
                읽기 전용 입력에 담아 두면 클립보드가 막힌 환경에서도 길게 눌러 복사할 수 있다.
              --%>
              <div class="flex gap-1.5 mt-1.5" id="invite-link-copy" phx-hook="CopyToClipboard">
                <input
                  type="text"
                  class="vr-input flex-1 min-w-0"
                  value={@invite_link}
                  readonly
                  data-copy-source
                  onfocus="this.select()"
                  aria-label={gettext("Invitation link")}
                />
                <button type="button" class="vr-btn vr-btn--sm shrink-0" data-copy-trigger>
                  {gettext("Copy")}
                </button>
              </div>

              <p class="vr-hint mt-1.5" style="font-size: 12px;">{gettext("Valid for 14 days.")}</p>
            </div>
            <button class="vr-btn vr-btn--sm vr-btn--ghost shrink-0" phx-click="clear_link">
              {gettext("Close")}
            </button>
          </div>
        </div>
      </div>

      <div :if={@received != []} class="vr-card mb-4">
        <div class="vr-card__body">
          <h2 class="font-bold mb-3" style="color: var(--text-primary);">
            {gettext("Received invitations")} <span class="vr-hint">({length(@received)})</span>
          </h2>
          <p class="vr-hint">
            {gettext("Open the link in the email to accept.")}
          </p>
        </div>
      </div>

      <div :if={@sent != []} class="vr-card mb-4">
        <div class="vr-card__body">
          <h2 class="font-bold mb-3" style="color: var(--text-primary);">
            {gettext("Sent invitations")} <span class="vr-hint">({length(@sent)})</span>
          </h2>
          <ul class="flex flex-col gap-2">
            <li
              :for={i <- @sent}
              class="flex items-center justify-between gap-3"
              style="font-size: 14px;"
            >
              <span>{i.email || gettext("Share link")}</span>
              <button
                class="vr-btn vr-btn--sm vr-btn--ghost"
                style="color: var(--status-error);"
                phx-click="cancel"
                phx-value-id={i.id}
              >
                {gettext("Cancel")}
              </button>
            </li>
          </ul>
        </div>
      </div>

      <div class="vr-card">
        <div class="vr-card__body">
          <h2 class="font-bold mb-3" style="color: var(--text-primary);">
            {gettext("Friends")} <span class="vr-hint">({length(@friends)})</span>
          </h2>

          <.empty_state
            :if={@friends == []}
            icon="group"
            title={gettext("No friends yet")}
            desc={gettext("Send an invitation above.")}
          />

          <ul :if={@friends != []} class="flex flex-col">
            <li
              :for={f <- @friends}
              class="flex items-center gap-3 py-2.5"
              style="border-bottom: 1px solid var(--border-subtle);"
            >
              <.avatar account={f} />
              <div class="min-w-0 flex-1">
                <div class="font-semibold" style="color: var(--text-primary); font-size: 14px;">
                  {f.name || f.email}
                </div>
                <div :if={f.name} class="vr-hint" style="font-size: 12px;">{f.email}</div>
              </div>
              <button
                class="vr-btn vr-btn--sm vr-btn--ghost shrink-0"
                style="color: var(--status-error);"
                phx-click="remove"
                phx-value-id={f.id}
                data-confirm={gettext("Remove %{name} from your friends?", name: f.name || f.email)}
              >
                {gettext("Remove")}
              </button>
            </li>
          </ul>
        </div>
      </div>
    </.app_shell>
    """
  end
end
