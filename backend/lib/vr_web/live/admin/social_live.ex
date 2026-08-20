defmodule VRWeb.Admin.SocialLive do
  @moduledoc """
  소셜 로그인 제공자 관리.

  소셜 로그인은 필수가 아니다. **키가 있고 켜져 있을 때만** 로그인 화면에 나타난다.

  - 키가 없으면 켤 수 없다 (켜진 채 키가 없는 상태를 만들지 않는다)
  - 끄기 전에 그 제공자로만 로그인 가능한 계정 수를 확인시킨다
  - `enabled`는 DB에만 있다. 환경변수로는 켜지지 않는다
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
         socket |> put_flash(:info, "#{name} 설정을 저장했습니다") |> assign(editing: nil) |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "저장에 실패했습니다")}
    end
  end

  def handle_event("toggle", %{"provider" => name, "to" => to}, socket) do
    enabled = to == "on"

    case Providers.set_enabled(name, enabled) do
      {:ok, _} ->
        msg = if enabled, do: "#{name} 로그인을 켰습니다", else: "#{name} 로그인을 껐습니다"
        {:noreply, socket |> put_flash(:info, msg) |> load()}

      {:error, :credentials_missing} ->
        {:noreply, put_flash(socket, :error, "#{name}: Client ID와 Secret을 먼저 입력해야 켤 수 있습니다")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      active={:social}
      title="소셜 로그인"
      subtitle="키가 있고 켜져 있는 제공자만 로그인 화면에 나타납니다. 이메일+비밀번호 로그인은 항상 켜져 있습니다."
    >
      <div class="space-y-3">
        <div :for={p <- @providers} class="vr-card">
          <div class="vr-card__body space-y-3">
            <div class="flex items-center justify-between gap-4">
              <div class="flex items-center gap-3">
                <span class="font-bold text-[17px]" style="color: var(--text-primary);">
                  {p.display_name}
                </span>
                <span :if={p.active} class="vr-chip vr-chip--ok">로그인 화면에 노출 중</span>
                <span :if={not p.active} class="vr-chip vr-chip--neutral">미노출</span>
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
                  켜기
                </button>
                <button
                  :if={p.enabled}
                  class="vr-btn vr-btn--sm vr-btn--outline"
                  phx-click="toggle"
                  phx-value-provider={p.provider}
                  phx-value-to="off"
                  data-confirm={off_confirm(p)}
                >
                  끄기
                </button>
                <button
                  class="vr-btn vr-btn--sm vr-btn--ghost"
                  phx-click="edit"
                  phx-value-provider={p.provider}
                >
                  {if @editing == p.provider, do: "닫기", else: "키 설정"}
                </button>
              </div>
            </div>

            <p :if={p.enabled and not p.credentials_present} class="vr-notice vr-notice--error">
              켜져 있지만 키가 없어 로그인 화면에 노출되지 않습니다.
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
                    — 비워두면 기존 값 유지
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
                  취소
                </button>
                <button type="submit" class="vr-btn vr-btn--sm vr-btn--primary">저장</button>
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
        "#{p.display_name} 로그인을 끕니다. 계속할까요?"

      n ->
        "#{p.display_name} 로만 로그인 가능한 계정이 #{n}개 있습니다. " <>
          "끄면 이 계정들은 로그인할 수 없게 됩니다. 비밀번호 설정 안내 메일이 발송됩니다. 계속할까요?"
    end
  end
end
