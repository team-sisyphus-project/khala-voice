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
     |> assign(page_title: "설정")
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
        {:noreply, put_flash(socket, :error, "테마를 바꾸지 못했습니다")}
    end
  end

  def handle_event("save_profile", %{"profile" => params}, socket) do
    case Accounts.update_profile(socket.assigns.current_account, params) do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign(current_account: account)
         |> assign(profile_form: to_form(Account.profile_changeset(account, %{}), as: :profile))
         |> put_flash(:info, "저장했습니다")}

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
         |> put_flash(:info, "비밀번호를 변경했습니다. 다른 기기의 로그인은 모두 해제되었습니다.")
         |> load_sessions()}

      {:error, changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset, as: :password))}
    end
  end

  def handle_event("revoke_session", %{"id" => id}, socket) do
    Accounts.revoke_session_by_id(socket.assigns.current_account.id, id)
    {:noreply, socket |> put_flash(:info, "해당 기기의 로그인을 해제했습니다") |> load_sessions()}
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
      title="계정 설정"
    >
      <%!--
        테마 고르는 자리는 **설정 탭**이다 (`AppSettingsPage`). 화면 모양을 바꾸려고
        계정 설정까지 들어가는 것은 iOS 문법이 아니다. 값은 여전히 계정에 저장되고
        `set_theme` 이벤트도 남겨 둔다 — 서버 렌더 시 `html[data-theme]` 의 원본이다.
      --%>

      <div class="vr-card mb-4" data-surface="raised">
        <div class="vr-card__body">
          <h2 class="font-bold mb-3" style="color: var(--text-primary);">프로필</h2>

          <.form :let={f} for={@profile_form} phx-submit="save_profile" class="flex flex-col gap-3">
            <div>
              <label class="vr-label mb-1.5">이메일</label>
              <input
                type="text"
                value={@current_account.email}
                disabled
                class="vr-input"
                style="opacity:.6;"
              />
            </div>
            <div>
              <label class="vr-label mb-1.5" for="profile_name">이름</label>
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
              <label class="vr-label mb-1.5" for="profile_locale">언어</label>
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
              <button type="submit" class="vr-btn vr-btn--sm vr-btn--primary">저장</button>
            </div>
          </.form>
        </div>
      </div>

      <div class="vr-card mb-4">
        <div class="vr-card__body">
          <h2 class="font-bold mb-1" style="color: var(--text-primary);">비밀번호</h2>
          <p class="vr-hint mb-3">
            변경하면 지금 쓰는 기기를 제외한 모든 로그인이 해제됩니다.
          </p>

          <.form
            :let={f}
            for={@password_form}
            phx-submit="change_password"
            class="flex flex-col gap-3"
          >
            <div>
              <label class="vr-label mb-1.5" for="password_password">새 비밀번호</label>
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
              <label class="vr-label mb-1.5" for="password_confirmation">비밀번호 확인</label>
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
              <button type="submit" class="vr-btn vr-btn--sm vr-btn--primary">비밀번호 변경</button>
            </div>
          </.form>
        </div>
      </div>

      <div class="vr-card mb-4">
        <div class="vr-card__body">
          <h2 class="font-bold mb-1" style="color: var(--text-primary);">로그인된 기기</h2>
          <p class="vr-hint mb-3">모르는 기기가 있으면 해제하고 비밀번호를 바꾸세요.</p>

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
                    현재 기기
                  </span>
                </div>
                <div class="vr-hint" style="font-size: 12px;">
                  {s.ip_address} · 마지막 활동 {format_time(s.last_activity_at)}
                </div>
              </div>
              <button
                :if={s.id != @current_session_id}
                class="vr-btn vr-btn--sm vr-btn--ghost shrink-0"
                phx-click="revoke_session"
                phx-value-id={s.id}
              >
                해제
              </button>
            </li>
          </ul>
        </div>
      </div>

      <div class="vr-card" style="border-color: rgba(240,68,82,.2);">
        <div class="vr-card__body">
          <h2 class="font-bold mb-1" style="color: var(--danger);">계정 삭제</h2>
          <p class="vr-hint mb-3">
            {Account.deletion_grace_days()}일 뒤에 삭제됩니다. 그 안에 다시 로그인하면 취소됩니다.
          </p>
          <button
            class="vr-btn vr-btn--sm vr-btn--danger"
            phx-click="schedule_deletion"
            data-confirm={"계정 삭제를 예약합니다. #{Account.deletion_grace_days()}일 안에 로그인하면 취소됩니다. 계속할까요?"}
          >
            계정 삭제 예약
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
        true -> "브라우저"
      end

    os =
      cond do
        String.contains?(ua, "iPhone") -> "iPhone"
        String.contains?(ua, "iPad") -> "iPad"
        String.contains?(ua, "Android") -> "Android"
        String.contains?(ua, "Mac OS X") -> "macOS"
        String.contains?(ua, "Windows") -> "Windows"
        String.contains?(ua, "Linux") -> "Linux"
        true -> "알 수 없음"
      end

    "#{browser} · #{os}"
  end

  defp device_label(_), do: "알 수 없는 기기"

  defp format_time(nil), do: "-"

  defp format_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "방금"
      diff < 3600 -> "#{div(diff, 60)}분 전"
      diff < 86_400 -> "#{div(diff, 3600)}시간 전"
      true -> Calendar.strftime(dt, "%Y-%m-%d")
    end
  end
end
