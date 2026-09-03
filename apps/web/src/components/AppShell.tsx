import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { useRoutes } from "@/lib/routes";
import type { Routes } from "@/lib/routes";
import type { ReactNode } from "react";
import { useLocation, useNavigate } from "react-router";
import { Icon, PageHeader, Screen, TopAppBar } from "@/ui";
import { InstallBanner } from "@/components/InstallBanner";

/**
 * App shell.
 *
 * **Source: devkanban** — the layout grammar of `mobile/src/AppShell.tsx`:
 * `mobile-app` container + `TopAppBar` + `Screen` + bottom `.bottom-nav`.
 * Class names are used verbatim. The CSS is keyed to these names.
 *
 * ## Differences from the original
 *
 * - **No hamburger (Drawer).** devkanban navigates via a drawer, but this app
 *   has only four screens, so a bottom tab bar is enough
 * - No admin link. It's reached only by typing the address directly
 *
 * ## The title lives in one place
 *
 * `TopAppBar` draws the title. The body never draws the same title again —
 * with two copies on screen, it's unclear which one is editable.
 */
type Tab = "meetings" | "archive" | "friends" | "settings";

type TabDef = { id: Tab; labelKey: string; icon: string; to: string; external?: boolean };

/**
 * Bottom tabs. The addresses **differ per surface** (`/m/*` · `/app/*`) — so
 * they're built from the current address, not constants. Friends is LiveView,
 * so it has no surface prefix.
 */
function tabsFor(routes: Routes): TabDef[] {
  return [
    { id: "meetings", labelKey: "nav.meetings", icon: "mic", to: routes.meetings },
    { id: "archive", labelKey: "nav.archive", icon: "inventory_2", to: routes.archive },
    { id: "friends", labelKey: "nav.friends", icon: "group", to: routes.friends, external: true },
    { id: "settings", labelKey: "nav.settings", icon: "settings", to: routes.settings },
  ];
}

export function AppShell({
  active,
  title,
  subtitle,
  actions,
  onBack,
  center = false,
  fill = false,
  children,
}: {
  active: Tab;
  title: string;
  subtitle?: string;
  actions?: ReactNode;
  /** Back action for depth screens. When given, the top bar takes its detail form */
  onBack?: () => void;
  /** Fill the body vertically and center its content */
  center?: boolean;
  /**
   * Use the full screen height **without scrolling**.
   *
   * For screens that "fit in one view", like the recorder. If the timer,
   * waveform, and record button get pushed below the fold, you'd have to
   * scroll down hunting for the button mid-recording.
   */
  fill?: boolean;
  children: ReactNode;
}) {
  const { t } = useTranslation();
  const routes = useRoutes();
  const navigate = useNavigate();
  const location = useLocation();
  const mainRef = useRef<HTMLElement>(null);
  const [scrolled, setScrolled] = useState(false);

  /**
   * The top bar shows its title capsule **only after scrolling** (devkanban
   * grammar). Initially the body's large title plays that role; when it
   * scrolls out of view, the top bar takes over.
   */
  useEffect(() => {
    const main = mainRef.current;
    if (!main) return;

    setScrolled(false);

    const onScroll = (event: Event) => {
      const target = event.target;

      if (target instanceof HTMLElement && target.classList.contains("mobile-screen")) {
        setScrolled(target.scrollTop > 8);
      }
    };

    // Scroll events don't bubble. Listen in the capture phase.
    main.addEventListener("scroll", onScroll, true);
    return () => main.removeEventListener("scroll", onScroll, true);
  }, [location.pathname]);

  return (
    <main
      className={`mobile-app ${onBack ? "is-detail" : "is-tabs"}${fill ? " is-fill" : ""}`}
      ref={mainRef}
    >
      {/*
        The top bar takes over the title **after scrolling** (`--tabs` starts
        with the title hidden). The large title is drawn by `PageHeader` at the
        top of the body — pure devkanban grammar. Depth screens (`onBack`) do
        the opposite: the top bar holds the title and the body doesn't.
      */}
      {/*
        **The four top-level tabs have no back button.** So the top bar takes no
        space and the title sits at the very top of the screen, with action
        buttons on the **same line** as that title. The top bar remains an
        overlay that only shows the title capsule after scrolling.

        Depth screens follow devkanban grammar as-is — circular back on the
        left + circular action on the right; the top bar holds the title and
        the body doesn't.
      */}
      <TopAppBar
        title={title}
        subtitle={subtitle}
        action={onBack ? actions : undefined}
        onBack={onBack}
        scrolled={scrolled}
      />

      <Screen center={center}>
        <InstallBanner />

        {!onBack && !center && (
          <PageHeader
            title={title}
            subtitle={subtitle}
            action={actions ? <div className="vr-page-actions">{actions}</div> : undefined}
          />
        )}

        {children}
      </Screen>

      <nav className="bottom-nav" aria-label={t("nav.menu")}>
        {tabsFor(routes).map((tab) => {
          const isActive = active === tab.id;

          return (
            <button
              key={tab.id}
              type="button"
              aria-current={isActive ? "page" : undefined}
              onClick={() => {
                if (tab.external) {
                  window.location.href = tab.to;
                  return;
                }

                // Pressing the active tab again returns to that tab's first screen (escaping depth)
                if (location.pathname !== tab.to) navigate(tab.to);
              }}
            >
              <Icon name={tab.icon} />
              <span>{t(tab.labelKey)}</span>
            </button>
          );
        })}
      </nav>
    </main>
  );
}
