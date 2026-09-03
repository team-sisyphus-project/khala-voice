defmodule VRWeb.Admin.AccountsLive do
  @moduledoc """
  Account management — promote, demote, delete.

  ## Lockout prevention

  If the admin count drops to zero, nobody can enter this screen anymore. So we
  disable the buttons themselves (`Admin.capabilities/2`). The server repeats the
  same check, so bypassing the buttons does not work either.

  ## Bootstrap account

  If it still exists, a banner at the top urges its deletion.
  A temporary key left in place becomes a permanent backdoor.
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
    apply_action(socket, id, &Admin.promote/3, "Admin privileges granted.")
  end

  def handle_event("demote", %{"id" => id}, socket) do
    apply_action(socket, id, &Admin.demote/3, "Admin privileges revoked.")
  end

  def handle_event("delete", %{"id" => id}, socket) do
    apply_action(socket, id, &Admin.delete_account/3, "Account deleted.")
  end

  defp apply_action(socket, id, fun, success_message) do
    actor = socket.assigns.current_account
    target = Enum.find_value(socket.assigns.accounts, fn {a, _} -> a.id == id && a end)

    cond do
      is_nil(target) ->
        {:noreply, put_flash(socket, :error, "Account not found.")}

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
    do: "This is the last admin. Make another account an admin first."

  defp message_for(:cannot_demote_self), do: "You cannot revoke your own privileges."
  defp message_for(:cannot_delete_self), do: "Use scheduled deletion in Settings for your own account."
  defp message_for(:account_deleted), do: "This account has already been deleted."
  defp message_for(:already_deleted), do: "This account has already been deleted."
  defp message_for(:recent_mfa_required), do: "Please verify MFA again to continue."
  defp message_for(_), do: "The action could not be completed."

  @impl true
  def render(assigns) do
    ~H"""
    <.shell active={:accounts} title="Accounts" subtitle={"#{@admin_count} admins"}>
      <.notice
        :if={@bootstrap}
        kind={:warn}
        icon="key"
        title="A temporary admin account still exists"
        class="mb-4"
      >
        <p class="mt-1">
          <span class="vr-key">{@bootstrap.email}</span> — this account was created at install time to open the front door.
        </p>
        <p class="mt-1.5">
          Promote your own account to admin, then <strong>delete this account to close the door.</strong> Leaving it in place creates a permanent backdoor.
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
              placeholder="Search by email or name"
              phx-debounce="300"
            />
          </form>

          <div class="flex gap-1.5 mt-3">
            <.filter_chip active={@filter} id={:all} label="All" />
            <.filter_chip active={@filter} id={:admins} label="Admins" />
            <.filter_chip active={@filter} id={:deleted} label="Deleted" />
          </div>
        </div>
      </div>

      <div class="vr-card" data-surface="raised">
        <div class="vr-card__body">
          <p :if={@accounts == []} class="vr-hint" style="text-align:center; padding: 32px 0;">
            No matching accounts.
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
                    {account.name || "No name"}
                  </span>
                  <span :if={account.is_admin} class="vr-chip vr-chip--ok">Admin</span>
                  <span :if={account.is_bootstrap} class="vr-chip vr-chip--warn">Temporary</span>
                  <span :if={caps.is_self} class="vr-chip vr-chip--info">You</span>
                  <span :if={account.mfa_enabled} class="vr-chip vr-chip--neutral">MFA</span>
                  <span :if={account.deleted_at} class="vr-chip vr-chip--neutral">Deleted</span>
                </div>
                <div class="vr-key mt-0.5">{account.email}</div>
              </div>

              <div class="flex gap-1.5 shrink-0">
                <button
                  :if={caps.can_promote and is_nil(account.deleted_at)}
                  class="vr-btn vr-btn--sm vr-btn--outline"
                  phx-click="promote"
                  phx-value-id={account.id}
                  data-confirm={"This will make #{account.email} an admin. The account will gain access to all accounts and API keys. Continue?"}
                >
                  Make admin
                </button>

                <button
                  :if={caps.can_demote}
                  class="vr-btn vr-btn--sm vr-btn--outline"
                  phx-click="demote"
                  phx-value-id={account.id}
                  data-confirm={"This will revoke admin privileges from #{account.email}. Continue?"}
                >
                  Revoke admin
                </button>

                <button
                  :if={caps.can_delete and is_nil(account.deleted_at)}
                  class="vr-btn vr-btn--sm vr-btn--ghost"
                  style="color: var(--status-error);"
                  phx-click="delete"
                  phx-value-id={account.id}
                  data-confirm={"This will delete #{account.email}. Sessions and friend connections will be removed and the email will be anonymized. This cannot be undone. Continue?"}
                >
                  Delete
                </button>

                <span
                  :if={caps.is_last_admin and caps.is_self}
                  class="vr-hint"
                  style="font-size:12px; align-self:center;"
                >
                  Last admin
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
