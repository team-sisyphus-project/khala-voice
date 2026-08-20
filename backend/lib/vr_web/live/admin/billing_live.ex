defmodule VRWeb.Admin.BillingLive do
  @moduledoc """
  요금 정책 — 플랜 · 리비전 · 크레딧 환산율.

  **출처: devkanban** `lib/manualsquad_web/live/admin/commerce_*_live.ex` 의 축소판.

  ## 메타와 상업 조건을 구분해 보여준다

  이름·설명 같은 **메타는 즉시 전원에게** 반영된다.
  가격·포함 크레딧 같은 **상업 조건은 새 리비전을 만든다** — 기존 구독은 그대로다.

  이 구분이 화면에서 드러나지 않으면 운영자가 "가격을 고쳤는데 왜 기존 고객은
  그대로인가"를 이해하지 못한다.
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
        {:noreply, socket |> put_flash(:info, "환산율을 저장했습니다") |> load()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "0보다 큰 숫자를 입력하세요")}
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
           "리비전 #{revision.revision} 을 발행했습니다. 기존 구독은 이전 리비전을 유지합니다."
         )
         |> assign(editing: nil)
         |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "리비전을 발행하지 못했습니다")}
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
    <.shell active={:billing} title="요금" subtitle="플랜과 크레딧 환산율">
      <.notice
        :if={is_nil(@setting)}
        kind={:warn}
        icon="error"
        title="크레딧 환산율이 없습니다"
        class="mb-4"
      >
        환산율이 없으면 전사·요약 사용량을 크레딧으로 바꿀 수 없어 <strong>집계가 멈춥니다.</strong>
      </.notice>

      <div class="vr-card mb-4" data-surface="raised">
        <div class="vr-card__body">
          <h2 class="font-bold mb-1" style="color: var(--text-primary);">크레딧 환산율</h2>
          <p class="vr-hint mb-3">
            사용 원가(USD)를 크레딧으로 바꾸는 기준입니다. 올림으로 계산합니다.
          </p>

          <.form for={@conversion_form} phx-submit="save_conversion" class="flex gap-2 items-end">
            <div style="flex:1">
              <label class="vr-label mb-1.5" for="credit_value_usd">1 크레딧당 USD</label>
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
              저장
            </button>
          </.form>

          <p :if={@setting} class="vr-hint mt-3" style="font-size:12px;">
            예: 사용 원가 $0.016 → {Decimal.div(Decimal.new("0.016"), @setting.credit_value_usd)
            |> Decimal.round(2)} → 올림
            <strong>
              {Credits.apply_rounding(
                Decimal.div(Decimal.new("0.016"), @setting.credit_value_usd),
                "ceil"
              )}
            </strong>
            크레딧
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
              {if @editing == plan.id, do: "닫기", else: "새 리비전"}
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
                <th style="padding:6px 0;">리비전</th>
                <th>포함 크레딧</th>
                <th>가격</th>
                <th>주기</th>
                <th>상태</th>
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
                  <span :if={revision.purchasable} class="vr-chip vr-chip--ok">현재</span>
                  <span :if={not revision.purchasable} class="vr-chip vr-chip--neutral">이전</span>
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
        새 리비전을 발행하면 <strong>신규 가입만</strong> 이 조건을 받습니다.
        기존 구독은 지금 리비전을 그대로 유지합니다.
      </p>

      <div class="grid grid-cols-2 gap-3">
        <label class="block">
          <span class="vr-label mb-1.5">포함 크레딧 (매 기간 지급)</span>
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
          <span class="vr-label mb-1.5">주기</span>
          <select name="interval" data-surface="sunken" class="vr-input">
            <option value="month" selected={@current && @current.interval == "month"}>월</option>
            <option value="year" selected={@current && @current.interval == "year"}>년</option>
          </select>
        </label>

        <label class="block">
          <span class="vr-label mb-1.5">가격 (KRW · 원)</span>
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
          <span class="vr-label mb-1.5">가격 (USD · 센트)</span>
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
          취소
        </button>
        <button type="submit" data-surface="control" class="vr-btn vr-btn--sm vr-btn--primary">
          발행
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
      0 -> "무료"
      amount -> "#{delimit(amount)}원"
    end
  end

  # 천 단위 구분. 이것만 쓰자고 라이브러리를 더하지 않는다.
  defp delimit(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
