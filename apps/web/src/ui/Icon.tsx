/**
 * 아이콘 = **Material Symbols Rounded**.
 *
 * devkanban 원본(`mobile/src/Icon.tsx`)은 인라인 SVG 레지스트리였다. 그대로 옮겼더니
 * 이 앱이 쓰는 이름(`ios_share` · `arrow_upward` · `settings` …)이 레지스트리에 없어
 * 화면마다 빈 동그라미나 이름 글자가 그대로 나왔다. 아이콘 세트를 맞추는 것보다
 * **다 있는 세트를 쓰는 편이 낫다** — sisyphus / LiveView 쪽과도 같은 세트가 된다.
 *
 * 이름은 Material Symbols 이름을 그대로 쓴다. 클래스 이름(`mobile-icon`)은 devkanban
 * CSS 가 걸려 있어 유지한다.
 */

export function Icon({ name }: { name: string }) {
  return (
    <span aria-hidden="true" className="material-symbols-rounded mobile-icon">
      {name}
    </span>
  )
}
