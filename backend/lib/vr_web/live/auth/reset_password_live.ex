defmodule VRWeb.AuthLive.ResetPasswordLive do
  @moduledoc """
  비밀번호 재설정.

  토큰은 마운트 시 존재만 확인하고, 실제 소진은 제출 시점에 한 번만 일어난다.
  """

  use VRWeb, :live_view

  import VRWeb.AuthLive.Components

  alias VR.Accounts

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "새 비밀번호 설정")
     |> assign(token: token)
     |> assign(done: false)
     |> assign(form: to_form(%{}, as: :account)), layout: false}
  end

  @impl true
  def handle_event("submit", %{"account" => params}, socket) do
    case Accounts.reset_password(socket.assigns.token, params) do
      {:ok, _account} ->
        {:noreply, assign(socket, done: true)}

      :error ->
        {:noreply, put_flash(socket, :error, "링크가 만료되었거나 이미 사용되었습니다. 다시 요청해 주세요.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :account))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_shell title="새 비밀번호 설정">
      <div :if={@done} class="text-center py-2">
        <span
          class="material-symbols-rounded mb-3"
          style="font-size: 40px; color: var(--status-success);"
        >
          check_circle
        </span>
        <p style="color: var(--text-primary); font-weight: 600;">비밀번호를 변경했습니다</p>
        <p class="vr-hint mt-2">보안을 위해 다른 기기의 로그인이 모두 해제되었습니다.</p>
        <.link navigate={~p"/login"} class="vr-btn vr-btn--primary w-full mt-5">로그인하기</.link>
      </div>

      <.form :let={f} :if={not @done} for={@form} phx-submit="submit" class="flex flex-col gap-4">
        <div>
          <label class="vr-label mb-1.5" for="account_password">새 비밀번호</label>
          <input
            type="password"
            id="account_password"
            name="account[password]"
            required
            autocomplete="new-password"
            class="vr-input"
            style="font-family: var(--font-sans);"
          />
          <p class="vr-hint mt-1.5" style="font-size: 12px;">10자 이상</p>
          <.field_errors field={f[:password]} />
        </div>

        <div>
          <label class="vr-label mb-1.5" for="account_password_confirmation">비밀번호 확인</label>
          <input
            type="password"
            id="account_password_confirmation"
            name="account[password_confirmation]"
            required
            autocomplete="new-password"
            class="vr-input"
            style="font-family: var(--font-sans);"
          />
          <.field_errors field={f[:password_confirmation]} />
        </div>

        <button type="submit" class="vr-btn vr-btn--primary w-full" phx-disable-with="변경 중...">
          비밀번호 변경
        </button>
      </.form>
    </.auth_shell>
    """
  end
end
