/**
 * **Source: devkanban** `mobile/src/press.ts` — brought over verbatim.
 *
 * To reuse the button press feedback, header treatment, inputs, and modal
 * styling as-is, even the markup (class names) matches the original. The CSS
 * is keyed to these names.
 */

/**
 * Press-state tracking — while a finger is down, the control gets
 * `data-pressed`. All the drawing is done by CSS (`styles/press.css`); here we
 * only decide **when it turns on and off**.
 *
 * Why not `:active`:
 *
 *   1. iOS Safari grants `:active` to controls stingily — without a touch
 *      listener on the element or an ancestor it sometimes never applies, so
 *      the same button reacts differently across devices.
 *   2. There's a window where **starting to scroll doesn't release it**. Rest
 *      a finger on a row to skim the list and push, and that row stays
 *      pressed, one item glowing even after the scroll ends. Here we release
 *      on both `pointercancel` and scroll.
 *   3. Drag the finger **off the control** and native UIs clear the highlight
 *      immediately, but touch pointers have implicit capture so
 *      `pointerleave` never fires. We judge by coordinates instead
 *      (`withinTarget` below).
 *
 * Targets are defined by a single selector — no per-component attributes.
 * Components only choose the intensity (how much it grows) via a CSS
 * variable. Opt out with `data-press="off"`.
 */

const PRESSABLE = 'button, [role="button"], a[href], summary, [data-press]'

// Release the press once the finger strays this far. At 0 it flickers on tiny
// jitters at the boundary; too large and it still looks pressed mid-scroll.
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

  // Disabled controls don't press — reacting would read as "it registered".
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
  // Primary button only (touch, pen, left-click). Right/auxiliary clicks get no press effect.
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
 * Installed once for the app's lifetime. All listeners are in the **capture
 * phase** — even with a `stopPropagation()` handler in between, the press
 * release must get through (otherwise a control stays pressed forever).
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
  // Once scrolling starts, it's a skim, not a press. This is the second net for
  // browsers that don't fire `pointercancel`, so it's a document-level capture
  // listener, not per-element.
  document.addEventListener("scroll", release, passive)
  // Tab switches and system sheets take over the screen, and pointerup never arrives.
  document.addEventListener("visibilitychange", release)
  window.addEventListener("blur", release)
  document.addEventListener("contextmenu", release, { capture: true })
}
