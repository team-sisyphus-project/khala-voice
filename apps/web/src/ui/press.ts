/**
 * **출처: devkanban** `mobile/src/press.ts` — 그대로 가져왔다.
 *
 * 버튼의 누름 반응 · 헤더 표현 · 인풋 · 모달의 표현 방식을 그대로 쓰기 위해
 * 마크업(클래스 이름)까지 원본과 같게 둔다. CSS 가 이 이름에 걸려 있다.
 */

/**
 * 누름 상태 추적 — 손가락이 닿아 있는 동안 그 컨트롤에 `data-pressed`를 건다.
 * 그림은 전부 CSS(`styles/press.css`)가 그리고, 여기서는 **언제 켜고 끄는가**만
 * 정한다.
 *
 * 왜 `:active`를 안 쓰는가:
 *
 *   1. iOS 사파리는 `:active`를 컨트롤에 인색하게 준다 — 요소나 조상에 터치
 *      리스너가 없으면 아예 안 붙는 경우가 있어서, 같은 버튼이 기기마다 다르게
 *      반응한다.
 *   2. **스크롤을 시작해도 안 풀리는 구간**이 있다. 목록을 훑으려고 행에 손을
 *      댄 채 밀면 그 행이 눌린 채로 남아, 스크롤이 끝난 뒤에도 하나가 밝게 떠
 *      있다. 여기서는 `pointercancel`과 스크롤 양쪽으로 푼다.
 *   3. 손가락을 컨트롤 **밖으로 끌면** 네이티브는 즉시 하이라이트를 지우는데,
 *      터치 포인터는 암묵적 캡처라 `pointerleave`가 오지 않는다. 좌표로 직접
 *      판정한다(아래 `withinTarget`).
 *
 * 대상은 선택자 하나로 정한다 — 컴포넌트마다 속성을 달지 않는다. 세기(얼마나
 * 커지는가)만 CSS 변수로 컴포넌트가 고른다. 빼려면 `data-press="off"`.
 */

const PRESSABLE = 'button, [role="button"], a[href], summary, [data-press]'

// 손가락이 이만큼 벗어나면 누름을 푼다. 0이면 경계에서 미세하게 떨 때
// 깜빡이고, 너무 크면 이미 스크롤 중인데 계속 눌려 보인다.
const SLOP_PX = 12

let pressed: HTMLElement | null = null
let pointerId: number | null = null
let installed = false

function pressableFrom(target: EventTarget | null): HTMLElement | null {
  if (!(target instanceof Element)) {
    return null
  }

  const found = target.closest<HTMLElement>(PRESSABLE)

  if (!found || found.dataset.press === "off") {
    return null
  }

  // 비활성 컨트롤은 눌리지 않는다 — 반응하면 "먹혔다"고 읽힌다.
  if (found.matches(":disabled") || found.getAttribute("aria-disabled") === "true") {
    return null
  }

  return found
}

function release() {
  if (pressed) {
    delete pressed.dataset.pressed
  }

  pressed = null
  pointerId = null
}

function withinTarget(event: PointerEvent) {
  if (!pressed) {
    return false
  }

  const box = pressed.getBoundingClientRect()

  return (
    event.clientX >= box.left - SLOP_PX &&
    event.clientX <= box.right + SLOP_PX &&
    event.clientY >= box.top - SLOP_PX &&
    event.clientY <= box.bottom + SLOP_PX
  )
}

function onPointerDown(event: PointerEvent) {
  // 주 버튼(터치·펜·좌클릭)만. 우클릭·보조 버튼은 누름 연출 대상이 아니다.
  if (!event.isPrimary || (event.pointerType === "mouse" && event.button !== 0)) {
    return
  }

  release()

  const target = pressableFrom(event.target)

  if (!target) {
    return
  }

  pressed = target
  pointerId = event.pointerId
  target.dataset.pressed = ""
}

function onPointerMove(event: PointerEvent) {
  if (pressed && event.pointerId === pointerId && !withinTarget(event)) {
    release()
  }
}

function onPointerEnd(event: PointerEvent) {
  if (!pressed || event.pointerId === pointerId) {
    release()
  }
}

/**
 * 앱 수명 동안 한 번 설치한다. 리스너는 전부 **캡처 단계**다 — 중간에서
 * `stopPropagation()`하는 핸들러가 있어도 누름 해제는 반드시 도달해야 한다
 * (안 그러면 컨트롤 하나가 눌린 채 영구히 남는다).
 */
export function installPressFeedback() {
  if (installed || typeof document === "undefined") {
    return
  }

  installed = true

  const passive = { capture: true, passive: true } as const

  document.addEventListener("pointerdown", onPointerDown, passive)
  document.addEventListener("pointermove", onPointerMove, passive)
  document.addEventListener("pointerup", onPointerEnd, passive)
  document.addEventListener("pointercancel", onPointerEnd, passive)
  // 스크롤이 시작되면 그건 누름이 아니라 훑기다. `pointercancel`이 오지 않는
  // 브라우저를 위한 두 번째 그물이라 요소별이 아니라 문서 캡처로 받는다.
  document.addEventListener("scroll", release, passive)
  // 탭 전환·시스템 시트로 화면이 넘어가면 pointerup이 영영 안 온다.
  document.addEventListener("visibilitychange", release)
  window.addEventListener("blur", release)
  document.addEventListener("contextmenu", release, { capture: true })
}
