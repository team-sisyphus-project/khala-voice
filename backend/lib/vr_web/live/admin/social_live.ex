defmodule VRWeb.Admin.SocialLive do
  @moduledoc """
  Manage social sign-in providers.

  Social sign-in is optional. A provider appears on the sign-in screen **only
  when it has credentials and is enabled**.

  - It cannot be enabled without credentials (we never allow an enabled-but-keyless state)
  - Before disabling, the operator is shown how many accounts can only sign in through that provider
  - `enabled` lives only in the DB; environment variables cannot turn it on
  """

  use VRWeb, :live_view

  import VRWeb.Admin.Components

  alias VR.Auth.Providers

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(editing: nil) |> load()}
  end

  defp load(socket), do: assign(socket, providers: Providers.list_all())

  @impl true
  def handle_event("edit", %{"provider" => name}, socket) do
    {:noreply, assign(socket, editing: name)}
  end

  def handle_event("cancel", _, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("save", %{"provider" => name} = params, socket) do
    attrs = Map.take(params, ["client_id", "client_secret", "redirect_uri", "display_name"])

    case Providers.upsert(name, attrs) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Saved settings for #{name}.") |> assign(editing: nil) |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Save failed.")}
    end
  end

  def handle_event("toggle", %{"provider" => name, "to" => to}, socket) do
    enabled = to == "on"

    case Providers.set_enabled(name, enabled) do
      {:ok, _} ->
        msg = if enabled, do: "Turned on #{name} sign-in.", else: "Turned off #{name} sign-in."
        {:noreply, socket |> put_flash(:info, msg) |> load()}

      {:error, :credentials_missing} ->
        {:noreply, put_flash(socket, :error, "#{name}: enter a Client ID and Secret before turning this on.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      active={:social}
      title="Social sign-in"
      subtitle="Only providers with credentials that are turned on appear on the sign-in screen. Email + password sign-in is always on."
    >
      <div class="space-y-3">
        <div :for={p <- @providers} class="vr-card">
          <div class="vr-card__body space-y-3">
            <div class="flex items-center justify-between gap-4">
              <div class="flex items-center gap-3">
                <span class="font-bold text-[17px]" style="color: var(--text-primary);">
                  {p.display_name}
                </span>
                <span :if={p.active} class="vr-chip vr-chip--ok">Shown on sign-in screen</span>
                <span :if={not p.active} class="vr-chip vr-chip--neutral">Not shown</span>
              </div>

              <div class="flex items-center gap-3">
                <.source_badge source={p.credentials_source} present={p.credentials_present} />
                <button
                  :if={not p.enabled}
                  class="vr-btn vr-btn--sm"
                  disabled={not p.credentials_present}
                  phx-click="toggle"
                  phx-value-provider={p.provider}
                  phx-value-to="on"
                >
                  Turn on
                </button>
                <button
                  :if={p.enabled}
                  class="vr-btn vr-btn--sm vr-btn--outline"
                  phx-click="toggle"
                  phx-value-provider={p.provider}
                  phx-value-to="off"
                  data-confirm={off_confirm(p)}
                >
                  Turn off
                </button>
                <button
                  class="vr-btn vr-btn--sm vr-btn--ghost"
                  phx-click="edit"
                  phx-value-provider={p.provider}
                >
                  {if @editing == p.provider, do: "Close", else: "Set credentials"}
                </button>
              </div>
            </div>

            <p :if={p.enabled and not p.credentials_present} class="vr-notice vr-notice--error">
              Enabled, but not shown on the sign-in screen because credentials are missing.
            </p>

            <form
              :if={@editing == p.provider}
              phx-submit="save"
              class="grid gap-3 pt-3"
              style="border-top: 1px solid var(--border-subtle);"
            >
              <input type="hidden" name="provider" value={p.provider} />

              <label class="block">
                <span class="vr-label mb-1.5">Client ID</span>
                <input
                  type="text"
                  name="client_id"
                  value={p.client_id}
                  autocomplete="off"
                  class="vr-input"
                />
              </label>

              <label class="block">
                <span class="vr-label mb-1.5">
                  Client Secret
                  <span :if={p.credentials_present} class="opacity-60">
                    — leave blank to keep the current value
                  </span>
                </span>
                <input
                  type="password"
                  name="client_secret"
                  value=""
                  autocomplete="off"
                  placeholder={if p.credentials_present, do: "••••••••", else: ""}
                  class="vr-input"
                />
              </label>

              <label class="block">
                <span class="vr-label mb-1.5">Redirect URI</span>
                <input
                  type="text"
                  name="redirect_uri"
                  value={p.resolved_redirect_uri}
                  class="vr-input"
                />
              </label>

              <div class="flex gap-2 justify-end">
                <button type="button" class="vr-btn vr-btn--sm vr-btn--ghost" phx-click="cancel">
                  Cancel
                </button>
                <button type="submit" class="vr-btn vr-btn--sm vr-btn--primary">Save</button>
              </div>
            </form>
          </div>
        </div>
      </div>
    </.shell>
    """
  end

  defp off_confirm(p) do
    case Providers.locked_out_account_count(p.provider) do
      0 ->
        "This will turn off #{p.display_name} sign-in. Continue?"

      n ->
        "#{n} account(s) can only sign in with #{p.display_name}. " <>
          "Turning it off will lock these accounts out. They will be sent an email with instructions to set a password. Continue?"
    end
  end
end
