export type SettingItem =
  | "theme"
  | "install"
  | "microphone-and-language"
  | "completion-notification"
  | "billing"
  | "integrations"
  | "account";

export const SETTINGS_SECTIONS: ReadonlyArray<{
  id: "display" | "recording" | "notifications" | "account-security";
  title: "화면" | "녹음" | "알림" | "계정 및 보안";
  items: readonly SettingItem[];
}> = [
  { id: "display", title: "화면", items: ["theme", "install"] },
  { id: "recording", title: "녹음", items: ["microphone-and-language"] },
  { id: "notifications", title: "알림", items: ["completion-notification"] },
  {
    id: "account-security",
    title: "계정 및 보안",
    items: ["billing", "integrations", "account"],
  },
] as const;
