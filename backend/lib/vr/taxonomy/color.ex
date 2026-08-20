defmodule VR.Taxonomy.Color do
  @moduledoc """
  토픽·라벨 색 팔레트.

  **출처: sisyphus** `assets/shared/utils/color-picker-utils.js` `DEFAULT_PALETTE` +
  `lib/sisyphus/accounts/onboarding_templates.ex` 의 기본 라벨 색. HEX 값을 가져왔다.

  ## 바꾼 것 — 자유 HEX 대신 팔레트 키

  sisyphus 는 `~r/^#[0-9A-Fa-f]{6}$/` 로 아무 색이나 받았다. 이 앱은 테마가
  light · dark · pencil · game 넷이라, 사용자가 고른 HEX 하나가 네 배경 모두에서
  읽히리라는 보장이 없다. **DB 에는 키를 저장하고 실제 색은 테마가 정한다.**
  (sisyphus 는 자유 HEX 때문에 팔레트가 결국 네 벌로 갈라졌다.)

  컬럼은 `color :string` 그대로다.
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

  @doc "쓸 수 있는 색 키."
  def keys, do: @keys

  @doc "키 → 기준 HEX. 실제 표시는 테마가 덮을 수 있다."
  def hex(key), do: Enum.find_value(@palette, fn {k, hex} -> if k == key, do: hex end)

  @doc "색을 고르지 않았을 때."
  def default, do: "blue"

  @doc "키와 HEX 쌍 전체. 디자인 토큰을 만들 때 쓴다."
  def palette, do: @palette

  @doc "쓸 수 있는 키인가."
  def valid?(key), do: key in @keys
end
