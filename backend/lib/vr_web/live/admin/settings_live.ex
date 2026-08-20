defmodule VRWeb.Admin.SettingsLive do
  @moduledoc """
  설정 그룹 편집 화면.

  화면은 `VR.Config.Registry`에서 **생성된다.** 새 설정값을 추가하려면
  레지스트리에 항목 하나만 넣으면 되고, 입력 폼·마스킹·출처 표시가 따라온다.

  ## 비밀값 취급

  - 저장된 비밀값은 **되돌려 보여주지 않는다.** 마스킹 + "설정됨(날짜)"만 표시
  - 비밀값 필드를 비운 채 저장하면 **기존 값이 유지된다** (실수 삭제 방지)
  - 지우려면 [지우기] 버튼을 명시적으로 누른다
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
      {:ok, socket |> put_flash(:error, "알 수 없는 설정 그룹입니다") |> redirect(to: ~p"/_admin")}
    end
  rescue
    ArgumentError ->
      {:ok, socket |> put_flash(:error, "알 수 없는 설정 그룹입니다") |> redirect(to: ~p"/_admin")}
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
     |> put_flash(:info, "저장했습니다")
     |> load()}
  end

  def handle_event("clear", %{"key" => key}, socket) do
    Config.delete(key)

    {:noreply,
     socket
     |> put_flash(:info, "#{key} 값을 지웠습니다. 환경변수가 있으면 그 값이 쓰입니다.")
     |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      active={@group}
      title={@meta.label}
      subtitle="DB에 저장된 값이 환경변수보다 우선합니다."
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
                <span :if={entry.secret} class="vr-chip vr-chip--warn">비밀</span>
              </div>
            </div>

            <p :if={entry.help} class="vr-hint">{entry.help}</p>

            <.field entry={entry} />

            <div class="flex items-center justify-between gap-3">
              <p class="vr-hint" style="font-size: 12px;">
                <span :if={entry.secret and entry.present}>
                  설정됨{if entry.updated_at,
                    do: " · #{Calendar.strftime(entry.updated_at, "%Y-%m-%d %H:%M")} 갱신"} — 비워두고 저장하면 그대로 유지됩니다
                </span>
                <span :if={not entry.secret and entry.source == :env}>
                  환경변수에서 읽는 중입니다. 여기서 저장하면 DB 값이 우선하게 됩니다.
                </span>
              </p>
              <button
                :if={entry.source == :db}
                type="button"
                class="vr-btn vr-btn--sm vr-btn--ghost shrink-0"
                style="color: var(--status-error);"
                phx-click="clear"
                phx-value-key={entry.key}
                data-confirm={"#{entry.label} 의 DB 값을 지웁니다. 환경변수가 있으면 그 값이 쓰입니다. 계속할까요?"}
              >
                지우기
              </button>
            </div>
          </div>
        </div>

        <div class="flex justify-end pt-1">
          <button type="submit" class="vr-btn vr-btn--primary">저장</button>
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
      <span class="text-sm">{if @checked, do: "켜짐", else: "꺼짐"}</span>
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

  defp placeholder(%{secret: true, present: true}), do: "••••••••  (비워두면 유지)"
  defp placeholder(%{secret: true}), do: "값을 입력하세요"
  defp placeholder(_), do: ""
end
