defmodule VRWeb.Admin.BillingLive do
  @moduledoc """
  Billing policy — plans, revisions, and the credit conversion rate.

  **Source: devkanban** — a slimmed-down version of
  `lib/manualsquad_web/live/admin/commerce_*_live.ex`.

  ## Metadata and commercial terms are shown separately

  **Metadata** such as name and description **applies to everyone immediately**.
  **Commercial terms** such as price and included credits **create a new
  revision** — existing subscriptions are untouched.

  If this distinction is not visible on the screen, operators cannot understand
  why existing customers are unaffected after they change a price.
  """

  use VRWeb, :live_view

  import VRWeb.Admin.Components

  alias VR.Billing
  alias VR.Billing.{Credits, PlanRevision}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(editing: nil) |> load()}
  end

  defp load(socket) do
    setting = Credits.conversion_setting()

    assign(socket,
      plans: Billing.list_plans(),
      setting: setting,
      conversion_form:
        to_form(%{"credit_value_usd" => setting && to_string(setting.credit_value_usd)},
          as: :conversion
        )
    )
  end

  @impl true
  def handle_event("save_conversion", %{"conversion" => params}, socket) do
    actor = socket.assigns.current_account

    case Credits.put_conversion_setting(
           %{credit_value_usd: params["credit_value_usd"]},
           actor.id
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Conversion rate saved.") |> load()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Enter a number greater than zero.")}
    end
  end

  def handle_event("new_revision", %{"plan_id" => plan_id}, socket) do
    {:noreply, assign(socket, editing: plan_id)}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("publish", %{"plan_id" => plan_id} = params, socket) do
    plan = Billing.get_plan(plan_id)

    attrs = %{
      included_credits: parse_int(params["included_credits"]),
      interval: params["interval"] || "month",
      prices: %{
        "KRW" => %{"amount" => parse_int(params["price_krw"])},
        "USD" => %{"amount" => parse_int(params["price_usd"])}
      }
    }

    case Billing.publish_revision(plan, attrs) do
      {:ok, revision} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Revision #{revision.revision} published. Existing subscriptions keep their previous revision."
         )
         |> assign(editing: nil)
         |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not publish the revision.")}
    end
  end

  defp parse_int(nil), do: 0

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell active={:billing} title="Billing" subtitle="Plans and credit conversion rate">
      <.notice
        :if={is_nil(@setting)}
        kind={:warn}
        icon="error"
        title="No credit conversion rate"
        class="mb-4"
      >
        Without a conversion rate, transcription and summary usage cannot be converted into credits, so <strong>metering stops.</strong>
      </.notice>

      <div class="vr-card mb-4" data-surface="raised">
        <div class="vr-card__body">
          <h2 class="font-bold mb-1" style="color: var(--text-primary);">Credit conversion rate</h2>
          <p class="vr-hint mb-3">
            The rate used to convert usage cost (USD) into credits. Results are rounded up.
          </p>

          <.form for={@conversion_form} phx-submit="save_conversion" class="flex gap-2 items-end">
            <div style="flex:1">
              <label class="vr-label mb-1.5" for="credit_value_usd">USD per credit</label>
              <input
                type="text"
                id="credit_value_usd"
                name="conversion[credit_value_usd]"
                value={Phoenix.HTML.Form.input_value(@conversion_form, :credit_value_usd)}
                inputmode="decimal"
                required
                data-surface="sunken"
                class="vr-input"
              />
            </div>
            <button type="submit" data-surface="control" class="vr-btn vr-btn--sm vr-btn--primary">
              Save
            </button>
          </.form>

          <p :if={@setting} class="vr-hint mt-3" style="font-size:12px;">
            Example: usage cost $0.016 → {Decimal.div(Decimal.new("0.016"), @setting.credit_value_usd)
            |> Decimal.round(2)} → rounded up to
            <strong>
              {Credits.apply_rounding(
                Decimal.div(Decimal.new("0.016"), @setting.credit_value_usd),
                "ceil"
              )}
            </strong>
            credits
          </p>
        </div>
      </div>

      <div :for={plan <- @plans} class="vr-card mb-3" data-surface="raised">
        <div class="vr-card__body">
          <div class="flex items-start justify-between gap-3 mb-2">
            <div>
              <div class="flex items-center gap-2">
                <span class="font-bold" style="color: var(--text-primary);">{plan.display_name}</span>
                <span class="vr-key">{plan.key}</span>
                <span class={["vr-chip", chip_for(plan.status)]}>{plan.status}</span>
              </div>
              <p :if={plan.description} class="vr-hint mt-1">{plan.description}</p>
            </div>

            <button
              data-surface="control"
              class="vr-btn vr-btn--sm vr-btn--outline shrink-0"
              phx-click="new_revision"
              phx-value-plan_id={plan.id}
            >
              {if @editing == plan.id, do: "Close", else: "New revision"}
            </button>
          </div>

          <.revision_form
            :if={@editing == plan.id}
            plan={plan}
            current={Billing.current_revision(plan)}
          />

          <table class="w-full" style="font-size:13px; margin-top:8px;">
            <thead>
              <tr style="color: var(--text-faint); text-align:left;">
                <th style="padding:6px 0;">Revision</th>
                <th>Included credits</th>
                <th>Price</th>
                <th>Interval</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={revision <- plan.revisions}
                style="border-top: var(--hairline-width) solid var(--border-subtle);"
              >
                <td style="padding:8px 0;">v{revision.revision}</td>
                <td>{revision.included_credits}</td>
                <td>{format_price(revision)}</td>
                <td>{revision.interval}</td>
                <td>
                  <span :if={revision.purchasable} class="vr-chip vr-chip--ok">Current</span>
                  <span :if={not revision.purchasable} class="vr-chip vr-chip--neutral">Previous</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.shell>
    """
  end

  attr :plan, :map, required: true
  attr :current, :map, default: nil

  defp revision_form(assigns) do
    ~H"""
    <form
      phx-submit="publish"
      class="grid gap-3 py-3 mb-2"
      style="border-top: var(--hairline-width) solid var(--border-subtle); border-bottom: var(--hairline-width) solid var(--border-subtle);"
    >
      <input type="hidden" name="plan_id" value={@plan.id} />

      <p class="vr-hint">
        When you publish a new revision, <strong>only new signups</strong> get these terms.
        Existing subscriptions keep their current revision.
      </p>

      <div class="grid grid-cols-2 gap-3">
        <label class="block">
          <span class="vr-label mb-1.5">Included credits (granted each period)</span>
          <input
            type="number"
            name="included_credits"
            min="0"
            value={@current && @current.included_credits}
            data-surface="sunken"
            class="vr-input"
          />
        </label>

        <label class="block">
          <span class="vr-label mb-1.5">Interval</span>
          <select name="interval" data-surface="sunken" class="vr-input">
            <option value="month" selected={@current && @current.interval == "month"}>Monthly</option>
            <option value="year" selected={@current && @current.interval == "year"}>Yearly</option>
          </select>
        </label>

        <label class="block">
          <span class="vr-label mb-1.5">Price (KRW, won)</span>
          <input
            type="number"
            name="price_krw"
            min="0"
            value={@current && PlanRevision.price(@current, "KRW")}
            data-surface="sunken"
            class="vr-input"
          />
        </label>

        <label class="block">
          <span class="vr-label mb-1.5">Price (USD, cents)</span>
          <input
            type="number"
            name="price_usd"
            min="0"
            value={@current && PlanRevision.price(@current, "USD")}
            data-surface="sunken"
            class="vr-input"
          />
        </label>
      </div>

      <div class="flex gap-2 justify-end">
        <button
          type="button"
          data-surface="control"
          class="vr-btn vr-btn--sm vr-btn--ghost"
          phx-click="cancel"
        >
          Cancel
        </button>
        <button type="submit" data-surface="control" class="vr-btn vr-btn--sm vr-btn--primary">
          Publish
        </button>
      </div>
    </form>
    """
  end

  defp chip_for("published"), do: "vr-chip--ok"
  defp chip_for("draft"), do: "vr-chip--neutral"
  defp chip_for(_), do: "vr-chip--warn"

  defp format_price(revision) do
    case PlanRevision.price(revision, "KRW") do
      nil -> "-"
      0 -> "Free"
      amount -> "₩#{delimit(amount)}"
    end
  end

  # Thousands separator. Not worth adding a library for just this.
  defp delimit(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
