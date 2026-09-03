defmodule VRWeb.Admin.LlmLive do
  @moduledoc """
  Manage LLM providers for AI summaries.

  With multiple providers registered, they are tried in ascending `priority`
  order, falling back to the next provider on rate limits or 5xx failures.
  """

  use VRWeb, :live_view

  import VRWeb.Admin.Components

  alias VR.{Config, Summarize}
  alias VR.Summarize.{LlmProvider, LlmProviders}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(editing: nil) |> load()}
  end

  defp load(socket) do
    assign(socket,
      providers: LlmProviders.list_all(),
      # Even without a provider, summaries work in dev mode. Don't show a warning that contradicts reality.
      ready: Summarize.ready?(),
      dev_mode: Summarize.dev_mode?(),
      auto_summarize: Config.fetch("llm.auto_summarize") in [true, "true"]
    )
  end

  @impl true
  def handle_event("new", _, socket), do: {:noreply, assign(socket, editing: :new)}
  def handle_event("cancel", _, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("edit", %{"provider" => name}, socket),
    do: {:noreply, assign(socket, editing: name)}

  def handle_event("save", params, socket) do
    attrs =
      Map.take(
        params,
        ~w(provider display_name api_key base_url model tier temperature max_output_tokens priority
           input_price_usd_per_1m output_price_usd_per_1m margin_rate)
      )

    case LlmProviders.upsert(attrs) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Saved.") |> assign(editing: nil) |> load()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{errors(changeset)}")}
    end
  end

  def handle_event("toggle", %{"provider" => name, "to" => to}, socket) do
    {:ok, _} = LlmProviders.upsert(%{"provider" => name, "enabled" => to == "on"})
    {:noreply, load(socket)}
  end

  def handle_event("switch", %{"key" => key, "to" => to}, socket) do
    Config.put(key, to, socket.assigns.current_account.id)
    {:noreply, load(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case LlmProviders.get(id) do
      nil ->
        {:noreply, socket}

      p ->
        LlmProviders.delete(p)
        {:noreply, socket |> put_flash(:info, "Deleted.") |> load()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      active={:llm}
      title="LLM providers"
      subtitle="Used for AI summaries. Providers are tried from the lowest priority value; on failure the next one takes over."
    >
      <:actions>
        <button class="vr-btn vr-btn--sm vr-btn--primary" phx-click="new">Add provider</button>
      </:actions>

      <.notice :if={not @ready} kind={:warn} icon="warning" class="mb-4">
        No LLM provider is available, so <strong>AI summaries are disabled</strong>.
        Enter an API key and turn one on.
      </.notice>

      <.notice :if={@dev_mode} kind={:info} icon="science" class="mb-4">
        <strong>Dev mode</strong> is on, so mock summaries are generated without calling an LLM.
        Quotes are pulled from the real transcription, so evidence jumps can still be verified. Be sure to turn this off in production.
      </.notice>

      <div class="vr-card mb-4">
        <div class="vr-card__body space-y-3">
          <.switch_row
            key="llm.dev_mode"
            on={@dev_mode}
            label="Dev mode"
            help="Generates mock summaries without calling an LLM. For checking screens without a key."
          />
          <.switch_row
            key="llm.auto_summarize"
            on={@auto_summarize}
            label="Auto-summarize when transcription completes"
            help="When off, summaries are generated only when the user clicks [Create summary]."
          />
        </div>
      </div>

      <.provider_form :if={@editing == :new} provider={%LlmProvider{}} is_new={true} />

      <div class="space-y-3">
        <div :for={p <- @providers} class="vr-card">
          <div class="vr-card__body space-y-2.5">
            <div class="flex items-center justify-between gap-4">
              <div class="flex items-center gap-3">
                <span class="vr-chip vr-chip--neutral">#{p.priority}</span>
                <span class="font-bold" style="color: var(--text-primary);">
                  {p.display_name || String.capitalize(p.provider)}
                </span>
                <span class="vr-key">{p.model}</span>
                <span :if={p.usable} class="vr-chip vr-chip--ok">Usable</span>
                <span :if={not p.usable} class="vr-chip vr-chip--neutral">Unusable</span>
              </div>

              <div class="flex items-center gap-2">
                <.source_badge source={p.key_source} present={p.key_present} />
                <button
                  :if={p.key_source != :env}
                  class="vr-btn vr-btn--sm"
                  phx-click="toggle"
                  phx-value-provider={p.provider}
                  phx-value-to={if p.enabled, do: "off", else: "on"}
                >
                  {if p.enabled, do: "Turn off", else: "Turn on"}
                </button>
                <button
                  :if={p.key_source != :env}
                  class="vr-btn vr-btn--sm vr-btn--ghost"
                  phx-click="edit"
                  phx-value-provider={p.provider}
                >
                  {if @editing == p.provider, do: "Close", else: "Edit"}
                </button>
                <button
                  :if={p.id}
                  class="vr-btn vr-btn--sm vr-btn--ghost"
                  style="color: var(--status-error);"
                  phx-click="delete"
                  phx-value-id={p.id}
                  data-confirm="This will delete this provider configuration. Continue?"
                >
                  Delete
                </button>
              </div>
            </div>

            <p :if={p.key_source == :env} class="vr-hint" style="font-size: 12px;">
              This entry is configured via environment variables (LLM_PROVIDER / LLM_API_KEY / LLM_MODEL).
              Registering the same provider in the DB takes precedence.
            </p>

            <.provider_form :if={@editing == p.provider} provider={p} is_new={false} />
          </div>
        </div>
      </div>
    </.shell>
    """
  end

  attr :provider, :map, required: true
  attr :is_new, :boolean, required: true

  defp provider_form(assigns) do
    ~H"""
    <form
      phx-submit="save"
      class="grid gap-3 pt-3 mb-3"
      style="border-top: 1px solid var(--border-subtle);"
    >
      <div class="grid grid-cols-2 gap-3">
        <label class="block">
          <span class="vr-label mb-1.5">Provider</span>
          <select name="provider" class="vr-input" disabled={not @is_new}>
            <option :for={p <- LlmProvider.providers()} value={p} selected={@provider.provider == p}>
              {p}
            </option>
          </select>
          <input :if={not @is_new} type="hidden" name="provider" value={@provider.provider} />
        </label>

        <label class="block">
          <span class="vr-label mb-1.5">Model ID</span>
          <input
            type="text"
            name="model"
            value={@provider.model}
            placeholder="gemini-2.5-flash"
            class="vr-input"
          />
        </label>
      </div>

      <label class="block">
        <span class="vr-label mb-1.5">
          API key <span :if={Map.get(@provider, :key_present)} class="opacity-60">— leave blank to keep the current value</span>
        </span>
        <input
          type="password"
          name="api_key"
          value=""
          autocomplete="off"
          placeholder={if Map.get(@provider, :key_present), do: "••••••••", else: ""}
          class="vr-input"
        />
      </label>

      <div class="grid grid-cols-4 gap-3">
        <label class="block">
          <span class="vr-label mb-1.5">Billing tier</span>
          <select name="tier" class="vr-input">
            <option :for={t <- LlmProvider.tiers()} value={t} selected={@provider.tier == t}>
              {t}
            </option>
          </select>
        </label>
        <label class="block">
          <span class="vr-label mb-1.5">temperature</span>
          <input
            type="text"
            name="temperature"
            value={@provider.temperature}
            class="vr-input"
          />
        </label>
        <label class="block">
          <span class="vr-label mb-1.5">max tokens</span>
          <input
            type="number"
            name="max_output_tokens"
            value={@provider.max_output_tokens}
            class="vr-input"
          />
        </label>
        <label class="block">
          <span class="vr-label mb-1.5">Priority</span>
          <input
            type="number"
            name="priority"
            value={@provider.priority}
            class="vr-input"
          />
        </label>
      </div>

      <div class="grid grid-cols-3 gap-3">
        <label class="block">
          <span class="vr-label mb-1.5">Input price (USD/1M)</span>
          <input
            type="text"
            name="input_price_usd_per_1m"
            value={@provider.input_price_usd_per_1m}
            placeholder="0.30"
            class="vr-input"
          />
        </label>
        <label class="block">
          <span class="vr-label mb-1.5">Output price (USD/1M)</span>
          <input
            type="text"
            name="output_price_usd_per_1m"
            value={@provider.output_price_usd_per_1m}
            placeholder="2.50"
            class="vr-input"
          />
        </label>
        <label class="block">
          <span class="vr-label mb-1.5">Margin rate</span>
          <input
            type="text"
            name="margin_rate"
            value={@provider.margin_rate}
            placeholder="0"
            class="vr-input"
          />
        </label>
      </div>

      <p class="vr-hint" style="font-size: 12px;">
        Leave the prices blank to skip credit metering. The formula matches devkanban —
        (input tokens × price ÷ 1M + output tokens × price ÷ 1M) × (1 + margin rate).
      </p>

      <label class="block">
        <span class="vr-label mb-1.5">
          Base URL <span class="opacity-60">— for compatible endpoints/proxies (optional)</span>
        </span>
        <input
          type="text"
          name="base_url"
          value={@provider.base_url}
          class="vr-input"
        />
      </label>

      <div class="flex gap-2 justify-end">
        <button type="button" class="vr-btn vr-btn--sm vr-btn--ghost" phx-click="cancel">Cancel</button>
        <button type="submit" class="vr-btn vr-btn--sm vr-btn--primary">Save</button>
      </div>
    </form>
    """
  end

  attr :key, :string, required: true
  attr :on, :boolean, required: true
  attr :label, :string, required: true
  attr :help, :string, required: true

  defp switch_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4">
      <div>
        <div class="font-bold" style="color: var(--text-primary); font-size: 14px;">{@label}</div>
        <p class="vr-hint" style="font-size: 12px;">{@help}</p>
      </div>
      <button
        class={["vr-btn vr-btn--sm", @on && "vr-btn--primary"]}
        phx-click="switch"
        phx-value-key={@key}
        phx-value-to={if @on, do: "false", else: "true"}
      >
        {if @on, do: "On", else: "Off"}
      </button>
    </div>
    """
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map(fn {k, v} -> "#{k} #{Enum.join(v, ", ")}" end)
    |> Enum.join("; ")
  end
end
