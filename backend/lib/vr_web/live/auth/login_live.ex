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
     |> assign(page_title: "로그인")
     |> assign(providers: Providers.list_active())
     |> assign(form: to_form(%{"email" => "", "password" => ""}, as: :account)), layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_shell title="로그인" subtitle="회의를 녹음하고 자동으로 정리하세요">
      <.form :let={f} for={@form} action={~p"/login"} method="post" class="flex flex-col gap-4">
        <div>
          <label class="vr-label mb-1.5" for="account_email">이메일</label>
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
          <label class="vr-label mb-1.5" for="account_password">비밀번호</label>
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
            <input type="checkbox" name="account[remember_me]" value="true" /> 로그인 상태 유지
          </label>
          <.link navigate={~p"/forgot-password"} class="vr-hint" style="color: var(--accent);">
            비밀번호를 잊으셨나요?
          </.link>
        </div>

        <button type="submit" class="vr-btn vr-btn--primary w-full mt-1">로그인</button>
      </.form>

      <.social_buttons providers={@providers} />

      <:footer>
        계정이 없으신가요?
        <.link navigate={~p"/register"} style="color: var(--accent); font-weight: 600;">가입하기</.link>
      </:footer>
    </.auth_shell>
    """
  end
end
