defmodule VRWeb.Admin.SettingsLive do
  @moduledoc """
  Settings group editor screen.

  The screen is **generated** from `VR.Config.Registry`. To add a new setting,
  add a single entry to the registry, and the input form, masking, and source
  badge come along with it.

  ## Handling secrets

  - Stored secrets are **never shown back.** Only masking + "Set (date)" is displayed
  - Saving with a secret field left blank **keeps the existing value** (prevents accidental deletion)
  - To erase a value, press the [Clear] button explicitly
  """

  use VRWeb, :live_view

  import VRWeb.Admin.Components

  alias VR.Config
  alias VR.Config.Registry

  @impl true
  def mount(%{"group" => group}, _session, socket) do
    group = String.to_existing_atom(group)

    if Keyword.has_key?(Registry.groups(), group) do
      {:ok, socket |> assign(group: group) |> load()}
    else
      {:ok, socket |> put_flash(:error, "Unknown settings group.") |> redirect(to: ~p"/_admin")}
    end
  rescue
    ArgumentError ->
      {:ok, socket |> put_flash(:error, "Unknown settings group.") |> redirect(to: ~p"/_admin")}
  end

  defp load(socket) do
    meta = Keyword.fetch!(Registry.groups(), socket.assigns.group)

    assign(socket,
      meta: meta,
      entries: Config.admin_view(socket.assigns.group),
      form: to_form(%{}, as: :settings)
    )
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    Config.put_many(params, actor_id: nil)

    {:noreply,
     socket
     |> put_flash(:info, "Saved.")
     |> load()}
  end

  def handle_event("clear", %{"key" => key}, socket) do
    Config.delete(key)

    {:noreply,
     socket
     |> put_flash(:info, "Cleared #{key}. If an environment variable exists, its value will be used.")
     |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      active={@group}
      title={@meta.label}
      subtitle="Values stored in the DB take precedence over environment variables."
    >
      <form phx-submit="save" class="space-y-3">
        <div :for={entry <- @entries} class="vr-card">
          <div class="vr-card__body space-y-2.5">
            <div class="flex items-start justify-between gap-4">
              <div>
                <label class="vr-label" for={entry.key}>
                  {entry.label}<span :if={entry.required} style="color: var(--status-error);">&nbsp;*</span>
                </label>
                <p class="vr-key mt-0.5">{entry.key}</p>
              </div>
              <div class="flex items-center gap-1.5 shrink-0">
                <.source_badge source={entry.source} present={entry.present} />
                <span :if={entry.secret} class="vr-chip vr-chip--warn">Secret</span>
              </div>
            </div>

            <p :if={entry.help} class="vr-hint">{entry.help}</p>

            <.field entry={entry} />

            <div class="flex items-center justify-between gap-3">
              <p class="vr-hint" style="font-size: 12px;">
                <span :if={entry.secret and entry.present}>
                  Set{if entry.updated_at,
                    do: " · updated #{Calendar.strftime(entry.updated_at, "%Y-%m-%d %H:%M")}"} — saving with this blank keeps the current value
                </span>
                <span :if={not entry.secret and entry.source == :env}>
                  Currently read from an environment variable. Saving here makes the DB value take precedence.
                </span>
              </p>
              <button
                :if={entry.source == :db}
                type="button"
                class="vr-btn vr-btn--sm vr-btn--ghost shrink-0"
                style="color: var(--status-error);"
                phx-click="clear"
                phx-value-key={entry.key}
                data-confirm={"This will clear the DB value for #{entry.label}. If an environment variable exists, its value will be used. Continue?"}
              >
                Clear
              </button>
            </div>
          </div>
        </div>

        <div class="flex justify-end pt-1">
          <button type="submit" class="vr-btn vr-btn--primary">Save</button>
        </div>
      </form>
    </.shell>
    """
  end

  attr :entry, :map, required: true

  defp field(%{entry: %{type: :boolean}} = assigns) do
    assigns = assign(assigns, :checked, assigns.entry.display_value == true)

    ~H"""
    <label class="flex items-center gap-3 cursor-pointer w-fit">
      <input type="hidden" name={"settings[#{@entry.key}]"} value="false" />
      <input
        type="checkbox"
        id={@entry.key}
        name={"settings[#{@entry.key}]"}
        value="true"
        checked={@checked}
        class="toggle"
        style="--toggle-bg: var(--accent);"
      />
      <span class="text-sm">{if @checked, do: "On", else: "Off"}</span>
    </label>
    """
  end

  defp field(%{entry: %{type: :text}} = assigns) do
    ~H"""
    <textarea
      id={@entry.key}
      name={"settings[#{@entry.key}]"}
      rows="6"
      class="vr-input"
      placeholder={placeholder(@entry)}
    >{if @entry.secret, do: nil, else: @entry.display_value}</textarea>
    """
  end

  defp field(assigns) do
    ~H"""
    <input
      type={if @entry.secret, do: "password", else: "text"}
      id={@entry.key}
      name={"settings[#{@entry.key}]"}
      value={if @entry.secret, do: "", else: @entry.display_value}
      autocomplete="off"
      class="vr-input"
      placeholder={placeholder(@entry)}
    />
    """
  end

  defp placeholder(%{secret: true, present: true}), do: "••••••••  (leave blank to keep)"
  defp placeholder(%{secret: true}), do: "Enter a value"
  defp placeholder(_), do: ""
end
