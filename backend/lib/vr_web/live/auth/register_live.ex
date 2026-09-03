defmodule VRWeb.AuthLive.RegisterLive do
  @moduledoc "Sign-up screen. Validates in real time as you type."

  use VRWeb, :live_view

  import VRWeb.AuthLive.Components

  alias VR.Accounts
  alias VR.Auth.Providers
  alias VR.Config

  @impl true
  def mount(_params, _session, socket) do
    changeset = Accounts.change_account_registration()

    {:ok,
     socket
     |> assign(page_title: gettext("Sign up"))
     |> assign(providers: Providers.list_active())
     |> assign(invite_required: Config.fetch("policy.invite_code_required") == true)
     |> assign(trigger_submit: false)
     |> assign_form(changeset), layout: false}
  end

  @impl true
  def handle_event("validate", %{"account" => params}, socket) do
    changeset = Accounts.change_account_registration(%Accounts.Account{}, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("submit", %{"account" => params}, socket) do
    case Accounts.register_account(params) do
      {:ok, account} ->
        {:ok, token} = Accounts.create_email_token(account, "confirm")
        Accounts.Notifier.deliver_confirmation(account, token)

        # Re-submit the form as-is to the controller to set the cookie
        {:noreply,
         socket
         |> assign(trigger_submit: true)
         |> assign_form(Accounts.change_account_registration(%Accounts.Account{}, params))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket, form: to_form(changeset, as: :account))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_shell
      title={gettext("Sign up")}
      subtitle={gettext("Record your meetings and organize them automatically")}
    >
      <.form
        :let={f}
        for={@form}
        id="register-form"
        phx-change="validate"
        phx-submit="submit"
        phx-trigger-action={@trigger_submit}
        action={~p"/login?_action=registered"}
        method="post"
        class="flex flex-col gap-4"
      >
        <div>
          <label class="vr-label mb-1.5" for="account_email">{gettext("Email")}</label>
          <input
            type="email"
            id="account_email"
            name="account[email]"
            value={Phoenix.HTML.Form.input_value(f, :email)}
            required
            autocomplete="username"
            class="vr-input"
            style="font-family: var(--font-sans);"
          />
          <.field_errors field={f[:email]} />
        </div>

        <div>
          <label class="vr-label mb-1.5" for="account_name">{gettext("Name")}</label>
          <input
            type="text"
            id="account_name"
            name="account[name]"
            value={Phoenix.HTML.Form.input_value(f, :name)}
            autocomplete="name"
            class="vr-input"
            style="font-family: var(--font-sans);"
          />
          <.field_errors field={f[:name]} />
        </div>

        <div>
          <label class="vr-label mb-1.5" for="account_password">{gettext("Password")}</label>
          <input
            type="password"
            id="account_password"
            name="account[password]"
            required
            autocomplete="new-password"
            class="vr-input"
            style="font-family: var(--font-sans);"
          />
          <p class="vr-hint mt-1.5" style="font-size: 12px;">{gettext("At least 10 characters")}</p>
          <.field_errors field={f[:password]} />
        </div>

        <div :if={@invite_required}>
          <label class="vr-label mb-1.5" for="account_invite_code">{gettext("Invite code")}</label>
          <input
            type="text"
            id="account_invite_code"
            name="account[invite_code]"
            required
            class="vr-input"
          />
        </div>

        <button
          type="submit"
          class="vr-btn vr-btn--primary w-full mt-1"
          phx-disable-with={gettext("Signing up...")}
        >
          {gettext("Sign up")}
        </button>
      </.form>

      <.social_buttons providers={@providers} />

      <:footer>
        {gettext("Already have an account?")}
        <.link navigate={~p"/login"} style="color: var(--accent); font-weight: 600;">
          {gettext("Sign in")}
        </.link>
      </:footer>
    </.auth_shell>
    """
  end
end
