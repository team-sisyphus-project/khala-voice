defmodule VRWeb.AuthLive.LoginLive do
  @moduledoc """
  로그인 화면.

  폼은 LiveView가 그리지만 제출은 `SessionController`로 간다.
  LiveView(WebSocket)에서는 쿠키를 심을 수 없기 때문이다.
  """

  use VRWeb, :live_view

  import VRWeb.AuthLive.Components

  alias VR.Auth.Providers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Sign in"))
     |> assign(providers: Providers.list_active())
     |> assign(form: to_form(%{"email" => "", "password" => ""}, as: :account)), layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_shell
      title={gettext("Sign in")}
      subtitle={gettext("Record your meetings and organize them automatically")}
    >
      <.form :let={f} for={@form} action={~p"/login"} method="post" class="flex flex-col gap-4">
        <div>
          <label class="vr-label mb-1.5" for="account_email">{gettext("Email")}</label>
          <input
            type="email"
            id="account_email"
            name="account[email]"
            value={Phoenix.HTML.Form.input_value(f, :email)}
            required
            autocomplete="username"
            class="vr-input"
            style="font-family: var(--font-sans);"
          />
        </div>

        <div>
          <label class="vr-label mb-1.5" for="account_password">{gettext("Password")}</label>
          <input
            type="password"
            id="account_password"
            name="account[password]"
            required
            autocomplete="current-password"
            class="vr-input"
            style="font-family: var(--font-sans);"
          />
        </div>

        <div class="flex items-center justify-between">
          <label class="flex items-center gap-2 cursor-pointer vr-hint">
            <input type="checkbox" name="account[remember_me]" value="true" /> {gettext(
              "Keep me signed in"
            )}
          </label>
          <.link navigate={~p"/forgot-password"} class="vr-hint" style="color: var(--accent);">
            {gettext("Forgot your password?")}
          </.link>
        </div>

        <button type="submit" class="vr-btn vr-btn--primary w-full mt-1">{gettext("Sign in")}</button>
      </.form>

      <.social_buttons providers={@providers} />

      <:footer>
        {gettext("Don't have an account?")}
        <.link navigate={~p"/register"} style="color: var(--accent); font-weight: 600;">
          {gettext("Sign up")}
        </.link>
      </:footer>
    </.auth_shell>
    """
  end
end
