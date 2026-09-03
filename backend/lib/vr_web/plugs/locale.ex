defmodule VRWeb.Plugs.Locale do
  @moduledoc """
  Sets the Gettext locale to the current account's `locale` on every request.

  The account's `locale` field is the single source of truth for the UI display
  language. Before sign-in, or when the value is missing, we fall back to
  **English** — this product is published internationally as open source, so
  English is the default, and locales without a catalog also fall back to
  English. (The server enforces the same rule as the React shell's
  `DEFAULT_UI_LOCALE`.)

  This plug handles the locale for **controller renders** (React SPA entry
  pages, share pages, and so on) and the root layout's `<html lang>`. LiveView
  does not go through plugs, so `VRWeb.UserAuth.on_mount(:set_locale, ...)`
  applies the same rule again.
  """

  import Plug.Conn

  @default_locale "en"

  @doc "The default display language. Used for signed-out or unconfigured accounts, and as the fallback."
  def default_locale, do: @default_locale

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = resolve(conn.assigns[:current_account])

    Gettext.put_locale(VRWeb.Gettext, locale)

    conn
    |> assign(:locale, locale)
    |> put_session(:locale, locale)
  end

  @doc """
  Extracts the display language from the account. Returns the default when
  there is no account or `locale` is empty.

  Kept shared so the controller plug and the LiveView `on_mount` hook use the
  same rule.
  """
  def resolve(%{locale: locale}) when is_binary(locale) and locale != "", do: locale
  def resolve(_), do: @default_locale
end
