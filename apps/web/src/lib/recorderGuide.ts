import type { TFunction } from "i18next";
import type { GuideMessage, RecorderErrorCode } from "@core/recorder";

/**
 * `@core/recorder` 의 마이크 안내를 화면 문안으로 옮긴다.
 *
 * ## 왜 여기서 번역하나
 *
 * 녹음 엔진(`packages/core`)은 프레임워크·i18n 비의존이어야 한다(CLAUDE.md #4).
 * 그래서 core 는 번역된 문자열이 아니라 **로케일-프리 키**(`GuideMessage`)만 낸다 —
 * 어떤 안내인지(키)와 기기·상황에 따라 달라지는 값(파라미터)만. UI 표시 언어에
 * 맞춘 실제 문안은 셸이 이 함수로 만든다. `@core/domain` 의 `VIEW_SCOPES` 를
 * web 이 `visibility.scopes.{mode}` 키로 렌더하는 것과 같은 경계다.
 *
 * core 가 낸 순수 키(`cause.permission_blocked` 등)에 카탈로그 접두사
 * `recorder.guide.` 를 붙여 번역한다 — core 는 카탈로그 레이아웃을 몰라도 된다.
 */
export function guideText(t: TFunction, message: GuideMessage): string {
  return t(`recorder.guide.${message.key}`, message.params);
}

/** 오류 코드의 알림 띠 제목. 제목은 코드에만 달렸다 — `recorder.guide.title.{code}`. */
export function errorTitle(t: TFunction, code: RecorderErrorCode): string {
  return t(`recorder.guide.title.${code}`);
}
