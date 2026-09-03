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
  title: "Display" | "Recording" | "Notifications" | "Account & security";
  items: readonly SettingItem[];
}> = [
  { id: "display", title: "Display", items: ["theme", "install"] },
  { id: "recording", title: "Recording", items: ["microphone-and-language"] },
  { id: "notifications", title: "Notifications", items: ["completion-notification"] },
  {
    id: "account-security",
    title: "Account & security",
    items: ["billing", "integrations", "account"],
  },
] as const;
