defmodule VRWeb.AppLive.SettingsLive do
  @moduledoc """
  계정 설정 — 프로필, 비밀번호, 기기 세션, 계정 삭제.

  기기 세션 목록을 보여주는 이유: 어디서 로그인 중인지 사용자가 직접 확인하고
  모르는 기기를 끊을 수 있어야 한다.
  """

  use VRWeb, :live_view

  import VRWeb.AppLive.Components

  alias VR.Accounts
  alias VR.Accounts.Account

  @impl true
  def mount(_params, session, socket) do
    account = socket.assigns.current_account

    {:ok,
     socket
     |> assign(page_title: gettext("Settings"))
     |> assign(current_token: session["account_token"])
     |> assign(profile_form: to_form(Account.profile_changeset(account, %{}), as: :profile))
     |> assign(password_form: to_form(%{}, as: :password))
     |> load_sessions(), layout: false}
  end

  defp load_sessions(socket) do
    account = socket.assigns.current_account
    sessions = Accounts.list_sessions(account.id)

    current_id =
      case Accounts.get_account_by_session_token(socket.assigns.current_token || "") do
        {:ok, _, session} -> session.id
        _ -> nil
      end

    assign(socket, sessions: sessions, current_session_id: current_id)
  end

  @impl true
  def handle_event("set_theme", %{"theme" => theme}, socket) do
    case Accounts.update_theme(socket.assigns.current_account, theme) do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign(current_account: account)
         # 클라이언트가 즉시 반영하고 localStorage 캐시도 갱신한다
         |> push_event("vr:theme", %{theme: account.theme})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't change the theme"))}
    end
  end

  def handle_event("save_profile", %{"profile" => params}, socket) do
    case Accounts.update_profile(socket.assigns.current_account, params) do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign(current_account: account)
         |> assign(profile_form: to_form(Account.profile_changeset(account, %{}), as: :profile))
         |> put_flash(:info, gettext("Saved"))}

      {:error, changeset} ->
        {:noreply, assign(socket, profile_form: to_form(changeset, as: :profile))}
    end
  end

  def handle_event("change_password", %{"password" => params}, socket) do
    case Accounts.update_password(socket.assigns.current_account, params,
           keep_session_id: socket.assigns.current_session_id
         ) do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign(current_account: account)
         |> put_flash(:info, gettext("Password changed. All other devices have been signed out."))
         |> load_sessions()}

      {:error, changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset, as: :password))}
    end
  end

  def handle_event("revoke_session", %{"id" => id}, socket) do
    Accounts.revoke_session_by_id(socket.assigns.current_account.id, id)
    {:noreply, socket |> put_flash(:info, gettext("Signed out that device")) |> load_sessions()}
  end

  def handle_event("schedule_deletion", _, socket) do
    {:ok, _} = Accounts.schedule_deletion(socket.assigns.current_account)
    {:noreply, redirect(socket, to: ~p"/login")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell
      current_account={@current_account}
      active={:settings}
      back="/go/settings"
      title={gettext("Account settings")}
    >
      <%!--
        테마 고르는 자리는 **설정 탭**이다 (`AppSettingsPage`). 화면 모양을 바꾸려고
        계정 설정까지 들어가는 것은 iOS 문법이 아니다. 값은 여전히 계정에 저장되고
        `set_theme` 이벤트도 남겨 둔다 — 서버 렌더 시 `html[data-theme]` 의 원본이다.
      --%>

      <div class="vr-card mb-4" data-surface="raised">
        <div class="vr-card__body">
          <h2 class="font-bold mb-3" style="color: var(--text-primary);">{gettext("Profile")}</h2>

          <.form :let={f} for={@profile_form} phx-submit="save_profile" class="flex flex-col gap-3">
            <div>
              <label class="vr-label mb-1.5">{gettext("Email")}</label>
              <input
                type="text"
                value={@current_account.email}
                disabled
                class="vr-input"
                style="opacity:.6;"
              />
            </div>
            <div>
              <label class="vr-label mb-1.5" for="profile_name">{gettext("Name")}</label>
              <input
                type="text"
                id="profile_name"
                name="profile[name]"
                value={Phoenix.HTML.Form.input_value(f, :name)}
                class="vr-input"
                style="font-family: var(--font-sans);"
              />
            </div>
            <div>
              <label class="vr-label mb-1.5" for="profile_locale">{gettext("Language")}</label>
              <select id="profile_locale" name="profile[locale]" class="vr-input">
                <option
                  :for={{code, label} <- locales()}
                  value={code}
                  selected={Phoenix.HTML.Form.input_value(f, :locale) == code}
                >
                  {label}
                </option>
              </select>
            </div>
            <div class="flex justify-end">
              <button type="submit" class="vr-btn vr-btn--sm vr-btn--primary">
                {gettext("Save")}
              </button>
            </div>
          </.form>
        </div>
      </div>

      <div class="vr-card mb-4">
        <div class="vr-card__body">
          <h2 class="font-bold mb-1" style="color: var(--text-primary);">{gettext("Password")}</h2>
          <p class="vr-hint mb-3">
            {gettext("Changing it signs out every device except this one.")}
          </p>

          <.form
            :let={f}
            for={@password_form}
            phx-submit="change_password"
            class="flex flex-col gap-3"
          >
            <div>
              <label class="vr-label mb-1.5" for="password_password">{gettext("New password")}</label>
              <input
                type="password"
                id="password_password"
                name="password[password]"
                autocomplete="new-password"
                required
                class="vr-input"
                style="font-family: var(--font-sans);"
              />
              <p
                :for={{msg, _} <- f[:password].errors}
                class="mt-1.5"
                style="font-size:13px; color: var(--danger);"
              >
                {msg}
              </p>
            </div>
            <div>
              <label class="vr-label mb-1.5" for="password_confirmation">
                {gettext("Confirm password")}
              </label>
              <input
                type="password"
                id="password_confirmation"
                name="password[password_confirmation]"
                autocomplete="new-password"
                required
                class="vr-input"
                style="font-family: var(--font-sans);"
              />
              <p
                :for={{msg, _} <- f[:password_confirmation].errors}
                class="mt-1.5"
                style="font-size:13px; color: var(--danger);"
              >
                {msg}
              </p>
            </div>
            <div class="flex justify-end">
              <button type="submit" class="vr-btn vr-btn--sm vr-btn--primary">
                {gettext("Change password")}
              </button>
            </div>
          </.form>
        </div>
      </div>

      <div class="vr-card mb-4">
        <div class="vr-card__body">
          <h2 class="font-bold mb-1" style="color: var(--text-primary);">
            {gettext("Signed-in devices")}
          </h2>
          <p class="vr-hint mb-3">
            {gettext("If you don't recognize a device, sign it out and change your password.")}
          </p>

          <ul class="flex flex-col">
            <li
              :for={s <- @sessions}
              class="flex items-center gap-3 py-2.5"
              style="border-bottom: 1px solid var(--line);"
            >
              <span class="material-symbols-rounded" style="color: var(--muted);">
                {device_icon(s.user_agent)}
              </span>
              <div class="min-w-0 flex-1">
                <div style="font-size: 14px; color: var(--text-primary);">
                  {device_label(s.user_agent)}
                  <span :if={s.id == @current_session_id} class="vr-chip vr-chip--ok ml-1">
                    {gettext("This device")}
                  </span>
                </div>
                <div class="vr-hint" style="font-size: 12px;">
                  {s.ip_address} · {gettext("last active")} {format_time(s.last_activity_at)}
                </div>
              </div>
              <button
                :if={s.id != @current_session_id}
                class="vr-btn vr-btn--sm vr-btn--ghost shrink-0"
                phx-click="revoke_session"
                phx-value-id={s.id}
              >
                {gettext("Sign out")}
              </button>
            </li>
          </ul>
        </div>
      </div>

      <%!--
        로그아웃. **폼 POST 다** — `DELETE /logout` 은 CSRF 토큰을 요구한다.
        링크(GET)로 두면 이미지 태그 하나로 남을 로그아웃시킬 수 있다.
      --%>
      <div class="vr-card mb-4">
        <div class="vr-card__body">
          <h2 class="font-bold mb-1" style="color: var(--text-primary);">로그아웃</h2>
          <p class="vr-hint mb-3">
            이 기기에서만 나갑니다. 다른 기기는 위의 "로그인된 기기"에서 끊습니다.
          </p>

          <form action={~p"/logout"} method="post">
            <input type="hidden" name="_method" value="delete" />
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <button type="submit" data-surface="control" class="vr-btn vr-btn--outline w-full">
              로그아웃
            </button>
          </form>
        </div>
      </div>

      <div class="vr-card" style="border-color: rgba(240,68,82,.2);">
        <div class="vr-card__body">
          <h2 class="font-bold mb-1" style="color: var(--danger);">{gettext("Delete account")}</h2>
          <p class="vr-hint mb-3">
            {gettext(
              "Your account will be deleted in %{days} days. Sign in again before then to cancel.",
              days: Account.deletion_grace_days()
            )}
          </p>
          <button
            class="vr-btn vr-btn--sm vr-btn--danger"
            phx-click="schedule_deletion"
            data-confirm={
              gettext("Schedule account deletion? Sign in within %{days} days to cancel.",
                days: Account.deletion_grace_days()
              )
            }
          >
            {gettext("Schedule deletion")}
          </button>
        </div>
      </div>
    </.app_shell>
    """
  end

  defp locales do
    [
      {"ko", "한국어"},
      {"en", "English"},
      {"ja", "日本語"},
      {"zh_CN", "中文 (简体)"},
      {"zh_TW", "中文 (繁體)"},
      {"es", "Español"}
    ]
  end

  defp device_icon(ua) when is_binary(ua) do
    cond do
      String.contains?(ua, ["iPhone", "Android", "Mobile"]) -> "smartphone"
      String.contains?(ua, "iPad") -> "tablet"
      true -> "computer"
    end
  end

  defp device_icon(_), do: "device_unknown"

  defp device_label(ua) when is_binary(ua) do
    browser =
      cond do
        String.contains?(ua, "Edg/") -> "Edge"
        String.contains?(ua, "Chrome") -> "Chrome"
        String.contains?(ua, "Firefox") -> "Firefox"
        String.contains?(ua, "Safari") -> "Safari"
        true -> gettext("Browser")
      end

    os =
      cond do
        String.contains?(ua, "iPhone") -> "iPhone"
        String.contains?(ua, "iPad") -> "iPad"
        String.contains?(ua, "Android") -> "Android"
        String.contains?(ua, "Mac OS X") -> "macOS"
        String.contains?(ua, "Windows") -> "Windows"
        String.contains?(ua, "Linux") -> "Linux"
        true -> gettext("Unknown")
      end

    "#{browser} · #{os}"
  end

  defp device_label(_), do: gettext("Unknown device")

  defp format_time(nil), do: "-"

  defp format_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> gettext("%{count} min ago", count: div(diff, 60))
      diff < 86_400 -> gettext("%{count} hr ago", count: div(diff, 3600))
      true -> Calendar.strftime(dt, "%Y-%m-%d")
    end
  end
end
