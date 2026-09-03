defmodule VRWeb.AuthLive.Components do
  @moduledoc "Shared layout for the sign-in and sign-up screens."
  use Phoenix.Component
  use VRWeb, :verified_routes
  use Gettext, backend: VRWeb.Gettext

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true
  slot :footer

  def auth_shell(assigns) do
    ~H"""
    <div
      class="min-h-screen flex flex-col items-center justify-center px-5 py-10"
      style="background: var(--surface-canvas);"
    >
      <div class="w-full" style="max-width: 400px;">
        <div class="text-center mb-7">
          <%!-- Brand mark. The **same image** as the intro screen and home icon. --%>
          <img
            src={~p"/images/icon-512.png"}
            alt=""
            aria-hidden="true"
            class="vr-auth__mark"
            width="64"
            height="64"
          />
          <h1 class="text-[24px] font-bold" style="color: var(--text-primary);">{@title}</h1>
          <p :if={@subtitle} class="vr-hint mt-1.5">{@subtitle}</p>
        </div>

        <div class="vr-card">
          <div class="vr-card__body" style="padding: 24px;">
            {render_slot(@inner_block)}
          </div>
        </div>

        <div :if={@footer != []} class="text-center mt-5 vr-hint">
          {render_slot(@footer)}
        </div>
      </div>
    </div>
    """
  end

  @doc "Social sign-in button group. Renders nothing when no provider is enabled."
  attr :providers, :list, required: true

  def social_buttons(assigns) do
    ~H"""
    <div :if={@providers != []} class="mt-5">
      <div class="flex items-center gap-3 mb-4">
        <span style="flex:1; height:1px; background: rgba(0,0,0,.08);"></span>
        <span class="vr-hint" style="font-size: 12px;">{gettext("or")}</span>
        <span style="flex:1; height:1px; background: rgba(0,0,0,.08);"></span>
      </div>

      <div class="flex flex-col gap-2">
        <a :for={p <- @providers} href={~p"/auth/#{p.provider}"} class="vr-btn vr-btn--outline w-full">
          {gettext("Continue with %{provider}", provider: p.display_name)}
        </a>
      </div>
    </div>
    """
  end

  @doc "Form error list."
  attr :field, :any, required: true

  def field_errors(assigns) do
    ~H"""
    <p
      :for={{msg, _} <- @field.errors}
      class="mt-1.5"
      style="font-size: 13px; color: var(--status-error);"
    >
      {translate_error(msg)}
    </p>
    """
  end

  defp translate_error("can't be blank"), do: gettext("This field is required")
  defp translate_error("has already been taken"), do: gettext("This is already taken")
  defp translate_error(msg) when is_binary(msg), do: msg
  defp translate_error(msg), do: to_string(msg)
end
