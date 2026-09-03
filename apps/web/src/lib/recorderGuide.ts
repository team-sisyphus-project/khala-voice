import type { TFunction } from "i18next";
import type { GuideMessage, RecorderErrorCode } from "@core/recorder";

/**
 * Turns `@core/recorder`'s mic guidance into on-screen copy.
 *
 * ## Why translate here
 *
 * The recording engine (`packages/core`) must stay framework- and
 * i18n-agnostic (CLAUDE.md #4). So core emits **locale-free keys**
 * (`GuideMessage`), not translated strings — just which guidance it is (the
 * key) and the device/situation-dependent values (the params). The actual
 * copy in the UI display language is built by the shell through this
 * function. It's the same boundary as web rendering `@core/domain`'s
 * `VIEW_SCOPES` through `visibility.scopes.{mode}` keys.
 *
 * The pure keys core emits (`cause.permission_blocked`, etc.) get the catalog
 * prefix `recorder.guide.` before translation — core never needs to know the
 * catalog layout.
 */
export function guideText(t: TFunction, message: GuideMessage): string {
  return t(`recorder.guide.${message.key}`, message.params);
}

/** The notice-strip title for an error code. Titles depend only on the code — `recorder.guide.title.{code}`. */
export function errorTitle(t: TFunction, code: RecorderErrorCode): string {
  return t(`recorder.guide.title.${code}`);
}
