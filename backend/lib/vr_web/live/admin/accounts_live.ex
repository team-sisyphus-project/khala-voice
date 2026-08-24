defmodule VRWeb.Admin.AccountsLive do
  @moduledoc """
  계정 관리 — 승격 · 강등 · 삭제.

  ## 잠금 방지

  어드민이 0명이 되면 아무도 이 화면에 들어올 수 없다. 그래서 버튼 자체를
  막는다 (`Admin.capabilities/2`). 서버도 같은 판정을 다시 하므로
  버튼을 우회해도 통하지 않는다.

  ## 부트스트랩 계정

  아직 남아 있으면 상단에 배너를 띄워 삭제를 권한다.
  임시 열쇠를 남겨두면 영구 백도어가 된다.
  """

  use VRWeb, :live_view

  import VRWeb.Admin.Components

  alias VR.Accounts.Admin

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(query: "", filter: :all) |> load()}
  end

  defp load(socket) do
    actor = socket.assigns.current_account

    opts = [q: socket.assigns.query]

    opts =
      if socket.assigns.filter == :all, do: opts, else: [{:only, socket.assigns.filter} | opts]

    accounts = Admin.list_accounts(opts)

    assign(socket,
      accounts: Enum.map(accounts, &{&1, Admin.capabilities(&1, actor)}),
      admin_count: Admin.count_admins(),
      bootstrap: Admin.bootstrap_account()
    )
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(query: q) |> load()}
  end

  def handle_event("filter", %{"only" => only}, socket) do
    {:noreply, socket |> assign(filter: String.to_existing_atom(only)) |> load()}
  end

  def handle_event("promote", %{"id" => id}, socket) do
    apply_action(socket, id, &Admin.promote/3, "어드민 권한을 부여했습니다")
  end

  def handle_event("demote", %{"id" => id}, socket) do
    apply_action(socket, id, &Admin.demote/3, "어드민 권한을 회수했습니다")
  end

  def handle_event("delete", %{"id" => id}, socket) do
    apply_action(socket, id, &Admin.delete_account/3, "계정을 삭제했습니다")
  end

  defp apply_action(socket, id, fun, success_message) do
    actor = socket.assigns.current_account
    target = Enum.find_value(socket.assigns.accounts, fn {a, _} -> a.id == id && a end)

    cond do
      is_nil(target) ->
        {:noreply, put_flash(socket, :error, "계정을 찾지 못했습니다")}

      true ->
        case fun.(target, actor, socket.assigns.current_session) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, success_message) |> load()}

          {:error, reason} ->
            handle_action_error(socket, reason)
        end
    end
  end

  defp handle_action_error(socket, :recent_mfa_required) do
    {:noreply,
     socket
     |> put_flash(:error, message_for(:recent_mfa_required))
     |> push_navigate(to: ~p"/_admin/accounts/verify-mfa")}
  end

  defp handle_action_error(socket, reason) do
    {:noreply, socket |> put_flash(:error, message_for(reason)) |> load()}
  end

  defp message_for(:last_admin),
    do: "마지막 어드민입니다. 다른 계정을 먼저 어드민으로 만드세요."

  defp message_for(:cannot_demote_self), do: "자기 자신의 권한은 회수할 수 없습니다"
  defp message_for(:cannot_delete_self), do: "자기 계정은 설정 화면에서 삭제 예약을 쓰세요"
  defp message_for(:account_deleted), do: "이미 삭제된 계정입니다"
  defp message_for(:already_deleted), do: "이미 삭제된 계정입니다"
  defp message_for(:recent_mfa_required), do: "계속하려면 MFA를 다시 확인해 주세요."
  defp message_for(_), do: "처리하지 못했습니다"

  @impl true
  def render(assigns) do
    ~H"""
    <.shell active={:accounts} title="계정" subtitle={"어드민 #{@admin_count}명"}>
      <.notice
        :if={@bootstrap}
        kind={:warn}
        icon="key"
        title="임시 어드민 계정이 남아 있습니다"
        class="mb-4"
      >
        <p class="mt-1">
          <span class="vr-key">{@bootstrap.email}</span> — 설치할 때 입구를 열려고 만든 계정입니다.
        </p>
        <p class="mt-1.5">
          본인 계정을 어드민으로 승격한 뒤 <strong>이 계정을 삭제해 입구를 닫으세요.</strong> 남겨두면 영구 백도어가 됩니다.
        </p>
      </.notice>

      <div class="vr-card mb-4" data-surface="raised">
        <div class="vr-card__body">
          <form phx-change="search" phx-submit="search">
            <input
              type="text"
              name="q"
              value={@query}
              data-surface="sunken"
              class="vr-input"
              style="font-family: var(--font-sans);"
              placeholder="이메일 또는 이름으로 찾기"
              phx-debounce="300"
            />
          </form>

          <div class="flex gap-1.5 mt-3">
            <.filter_chip active={@filter} id={:all} label="전체" />
            <.filter_chip active={@filter} id={:admins} label="어드민" />
            <.filter_chip active={@filter} id={:deleted} label="삭제됨" />
          </div>
        </div>
      </div>

      <div class="vr-card" data-surface="raised">
        <div class="vr-card__body">
          <p :if={@accounts == []} class="vr-hint" style="text-align:center; padding: 32px 0;">
            해당하는 계정이 없습니다.
          </p>

          <ul class="flex flex-col">
            <li
              :for={{account, caps} <- @accounts}
              class="flex items-center gap-3 py-3"
              style="border-bottom: var(--hairline-width) solid var(--border-subtle);"
            >
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-1.5 flex-wrap">
                  <span style="font-size:14px; font-weight:600; color: var(--text-primary);">
                    {account.name || "이름 없음"}
                  </span>
                  <span :if={account.is_admin} class="vr-chip vr-chip--ok">어드민</span>
                  <span :if={account.is_bootstrap} class="vr-chip vr-chip--warn">임시</span>
                  <span :if={caps.is_self} class="vr-chip vr-chip--info">나</span>
                  <span :if={account.mfa_enabled} class="vr-chip vr-chip--neutral">MFA</span>
                  <span :if={account.deleted_at} class="vr-chip vr-chip--neutral">삭제됨</span>
                </div>
                <div class="vr-key mt-0.5">{account.email}</div>
              </div>

              <div class="flex gap-1.5 shrink-0">
                <button
                  :if={caps.can_promote and is_nil(account.deleted_at)}
                  class="vr-btn vr-btn--sm vr-btn--outline"
                  phx-click="promote"
                  phx-value-id={account.id}
                  data-confirm={"#{account.email} 을(를) 어드민으로 만듭니다. 이 계정은 모든 계정과 API 키에 접근할 수 있게 됩니다. 계속할까요?"}
                >
                  어드민으로
                </button>

                <button
                  :if={caps.can_demote}
                  class="vr-btn vr-btn--sm vr-btn--outline"
                  phx-click="demote"
                  phx-value-id={account.id}
                  data-confirm={"#{account.email} 의 어드민 권한을 회수합니다. 계속할까요?"}
                >
                  권한 회수
                </button>

                <button
                  :if={caps.can_delete and is_nil(account.deleted_at)}
                  class="vr-btn vr-btn--sm vr-btn--ghost"
                  style="color: var(--status-error);"
                  phx-click="delete"
                  phx-value-id={account.id}
                  data-confirm={"#{account.email} 을(를) 삭제합니다. 세션·친구 관계가 정리되고 이메일이 익명화됩니다. 되돌릴 수 없습니다. 계속할까요?"}
                >
                  삭제
                </button>

                <span
                  :if={caps.is_last_admin and caps.is_self}
                  class="vr-hint"
                  style="font-size:12px; align-self:center;"
                >
                  마지막 어드민
                </span>
              </div>
            </li>
          </ul>
        </div>
      </div>
    </.shell>
    """
  end

  attr :active, :atom, required: true
  attr :id, :atom, required: true
  attr :label, :string, required: true

  defp filter_chip(assigns) do
    ~H"""
    <button
      type="button"
      data-surface="control"
      class={["vr-btn vr-btn--sm", if(@active == @id, do: "vr-btn--primary", else: "vr-btn--outline")]}
      phx-click="filter"
      phx-value-only={@id}
    >
      {@label}
    </button>
    """
  end
end
