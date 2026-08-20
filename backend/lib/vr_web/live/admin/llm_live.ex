defmodule VRWeb.Admin.LlmLive do
  @moduledoc """
  AI 요약용 LLM 제공자 관리.

  여러 제공자를 등록해 두면 `priority` 오름차순으로 시도하고,
  레이트리밋이나 5xx로 실패하면 다음 제공자로 폴백한다.
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
      # 제공자가 없어도 개발 모드면 요약은 동작한다. 실제와 다른 경고를 띄우지 않는다.
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
        {:noreply, socket |> put_flash(:info, "저장했습니다") |> assign(editing: nil) |> load()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "저장 실패: #{errors(changeset)}")}
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
        {:noreply, socket |> put_flash(:info, "삭제했습니다") |> load()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      active={:llm}
      title="LLM 제공자"
      subtitle="AI 요약에 사용합니다. 우선순위가 낮은 값부터 시도하고, 실패하면 다음으로 넘어갑니다."
    >
      <:actions>
        <button class="vr-btn vr-btn--sm vr-btn--primary" phx-click="new">제공자 추가</button>
      </:actions>

      <.notice :if={not @ready} kind={:warn} icon="warning" class="mb-4">
        사용 가능한 LLM 제공자가 없어 <strong>AI 요약이 비활성 상태</strong>입니다.
        API 키를 입력하고 켜주세요.
      </.notice>

      <.notice :if={@dev_mode} kind={:info} icon="science" class="mb-4">
        <strong>개발 모드</strong>가 켜져 있어 LLM을 호출하지 않고 목 요약을 만듭니다.
        실제 전사에서 인용을 뽑으므로 근거 점프까지 확인됩니다. 운영에서는 반드시 끄세요.
      </.notice>

      <div class="vr-card mb-4">
        <div class="vr-card__body space-y-3">
          <.switch_row
            key="llm.dev_mode"
            on={@dev_mode}
            label="개발 모드"
            help="LLM을 호출하지 않고 목 요약을 만듭니다. 키 없이 화면을 확인할 때."
          />
          <.switch_row
            key="llm.auto_summarize"
            on={@auto_summarize}
            label="전사 완료 시 자동 요약"
            help="끄면 사용자가 [요약 만들기] 를 눌렀을 때만 생성합니다."
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
                <span :if={p.usable} class="vr-chip vr-chip--ok">사용 가능</span>
                <span :if={not p.usable} class="vr-chip vr-chip--neutral">사용 불가</span>
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
                  {if p.enabled, do: "끄기", else: "켜기"}
                </button>
                <button
                  :if={p.key_source != :env}
                  class="vr-btn vr-btn--sm vr-btn--ghost"
                  phx-click="edit"
                  phx-value-provider={p.provider}
                >
                  {if @editing == p.provider, do: "닫기", else: "편집"}
                </button>
                <button
                  :if={p.id}
                  class="vr-btn vr-btn--sm vr-btn--ghost"
                  style="color: var(--status-error);"
                  phx-click="delete"
                  phx-value-id={p.id}
                  data-confirm="이 제공자 설정을 삭제합니다. 계속할까요?"
                >
                  삭제
                </button>
              </div>
            </div>

            <p :if={p.key_source == :env} class="vr-hint" style="font-size: 12px;">
              환경변수(LLM_PROVIDER / LLM_API_KEY / LLM_MODEL)로 설정된 항목입니다.
              DB에 같은 제공자를 등록하면 그쪽이 우선합니다.
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
          <span class="vr-label mb-1.5">제공자</span>
          <select name="provider" class="vr-input" disabled={not @is_new}>
            <option :for={p <- LlmProvider.providers()} value={p} selected={@provider.provider == p}>
              {p}
            </option>
          </select>
          <input :if={not @is_new} type="hidden" name="provider" value={@provider.provider} />
        </label>

        <label class="block">
          <span class="vr-label mb-1.5">모델 ID</span>
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
          API 키 <span :if={Map.get(@provider, :key_present)} class="opacity-60">— 비워두면 기존 값 유지</span>
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
          <span class="vr-label mb-1.5">과금 tier</span>
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
          <span class="vr-label mb-1.5">우선순위</span>
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
          <span class="vr-label mb-1.5">입력 단가 (USD/1M)</span>
          <input
            type="text"
            name="input_price_usd_per_1m"
            value={@provider.input_price_usd_per_1m}
            placeholder="0.30"
            class="vr-input"
          />
        </label>
        <label class="block">
          <span class="vr-label mb-1.5">출력 단가 (USD/1M)</span>
          <input
            type="text"
            name="output_price_usd_per_1m"
            value={@provider.output_price_usd_per_1m}
            placeholder="2.50"
            class="vr-input"
          />
        </label>
        <label class="block">
          <span class="vr-label mb-1.5">마진율</span>
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
        단가를 비워두면 크레딧을 계량하지 않습니다. 계산식은 devkanban과 같습니다 —
        (입력토큰 × 단가 ÷ 1M + 출력토큰 × 단가 ÷ 1M) × (1 + 마진율).
      </p>

      <label class="block">
        <span class="vr-label mb-1.5">
          Base URL <span class="opacity-60">— 호환 엔드포인트/프록시용 (선택)</span>
        </span>
        <input
          type="text"
          name="base_url"
          value={@provider.base_url}
          class="vr-input"
        />
      </label>

      <div class="flex gap-2 justify-end">
        <button type="button" class="vr-btn vr-btn--sm vr-btn--ghost" phx-click="cancel">취소</button>
        <button type="submit" class="vr-btn vr-btn--sm vr-btn--primary">저장</button>
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
        {if @on, do: "켜짐", else: "꺼짐"}
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
