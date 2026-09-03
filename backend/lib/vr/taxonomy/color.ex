defmodule VR.Taxonomy.Color do
  @moduledoc """
  Color palette for topics and labels.

  **Source: sisyphus** — `DEFAULT_PALETTE` in
  `assets/shared/utils/color-picker-utils.js` plus the default label colors in
  `lib/sisyphus/accounts/onboarding_templates.ex`. The HEX values were taken from there.

  ## What changed — palette keys instead of free-form HEX

  sisyphus accepted any color via `~r/^#[0-9A-Fa-f]{6}$/`. This app has four
  themes — light, dark, pencil, game — so there is no guarantee a single
  user-picked HEX reads well against all four backgrounds. **The DB stores the
  key; the actual color is decided by the theme.**
  (In sisyphus, free-form HEX eventually split the palette into four copies.)

  The column stays `color :string`.
  """

  @palette [
    {"red", "#f04452"},
    {"orange", "#ff9500"},
    {"yellow", "#ffcc00"},
    {"green", "#34c759"},
    {"teal", "#14b8a6"},
    {"blue", "#3182f6"},
    {"indigo", "#5856d6"},
    {"violet", "#7c5cff"},
    {"purple", "#9d4edd"},
    {"gray", "#6b7280"}
  ]

  @keys Enum.map(@palette, &elem(&1, 0))

  @doc "The available color keys."
  def keys, do: @keys

  @doc "Key → reference HEX. The actual display may be overridden by the theme."
  def hex(key), do: Enum.find_value(@palette, fn {k, hex} -> if k == key, do: hex end)

  @doc "When no color was chosen."
  def default, do: "blue"

  @doc "All key-HEX pairs. Used when building design tokens."
  def palette, do: @palette

  @doc "Is this a usable key?"
  def valid?(key), do: key in @keys
end
