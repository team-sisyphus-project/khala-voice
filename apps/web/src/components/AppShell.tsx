import { useEffect, useRef, useState } from "react";
import { useRoutes } from "@/lib/routes";
import type { Routes } from "@/lib/routes";
import type { ReactNode } from "react";
import { useLocation, useNavigate } from "react-router";
import { Icon, PageHeader, Screen, TopAppBar } from "@/ui";
import { InstallBanner } from "@/components/InstallBanner";

/**
 * 앱 껍데기.
 *
 * **출처: devkanban** `mobile/src/AppShell.tsx` 의 레이아웃 문법 —
 * `mobile-app` 컨테이너 + `TopAppBar` + `Screen` + 하단 `.bottom-nav`.
 * 클래스 이름을 그대로 쓴다. CSS 가 이 이름에 걸려 있다.
 *
 * ## 원본과 다른 점
 *
 * - **햄버거(Drawer)를 쓰지 않는다.** devkanban 은 서랍으로 이동하지만
 *   이 앱은 화면이 넷뿐이라 하단 탭바로 충분하다
 * - 어드민 링크가 없다. 주소를 직접 입력해서만 들어간다
 *
 * ## 제목은 한 곳에만 둔다
 *
 * `TopAppBar` 가 제목을 그린다. 본문에서 같은 제목을 또 그리지 않는다 —
 * 화면에 제목이 두 벌 뜨면 어느 쪽이 편집 가능한지 알 수 없다.
 */
type Tab = "meetings" | "archive" | "friends" | "settings";

type TabDef = { id: Tab; label: string; icon: string; to: string; external?: boolean };

/**
 * 하단 탭. 주소는 **표면마다 다르다**(`/m/*` · `/app/*`) — 그래서 상수가 아니라
 * 지금 주소에서 만든다. 친구는 LiveView 라 표면 접두어가 없다.
 */
function tabsFor(routes: Routes): TabDef[] {
  return [
    { id: "meetings", label: "회의", icon: "mic", to: routes.meetings },
    { id: "archive", label: "아카이브", icon: "inventory_2", to: routes.archive },
    { id: "friends", label: "친구", icon: "group", to: routes.friends, external: true },
    { id: "settings", label: "설정", icon: "settings", to: routes.settings },
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
  /** 뎁스 화면에서 뒤로 가기. 주면 상단바가 detail 모양이 된다 */
  onBack?: () => void;
  /** 본문을 세로로 꽉 채우고 가운데 정렬한다 */
  center?: boolean;
  /**
   * 화면 높이를 **스크롤 없이** 다 쓴다.
   *
   * 녹음 화면처럼 "한 화면 안에서 끝나는" 화면용이다. 타이머 · 파형 · 녹음 버튼이
   * 스크롤 아래로 밀리면 녹음 중에 버튼을 찾아 내려야 한다.
   */
  fill?: boolean;
  children: ReactNode;
}) {
  const routes = useRoutes();
  const navigate = useNavigate();
  const location = useLocation();
  const mainRef = useRef<HTMLElement>(null);
  const [scrolled, setScrolled] = useState(false);

  /**
   * 상단바는 **스크롤한 뒤에만** 제목 캡슐을 띄운다 (devkanban 문법).
   * 처음에는 본문 큰 제목이 그 역할을 하고, 그것이 위로 사라질 때 상단바가 이어받는다.
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

    // 스크롤은 버블링하지 않는다. 캡처 단계로 받는다.
    main.addEventListener("scroll", onScroll, true);
    return () => main.removeEventListener("scroll", onScroll, true);
  }, [location.pathname]);

  return (
    <main
      className={`mobile-app ${onBack ? "is-detail" : "is-tabs"}${fill ? " is-fill" : ""}`}
      ref={mainRef}
    >
      {/*
        상단바는 **스크롤한 뒤에** 제목을 이어받는다 (`--tabs` 는 처음에 제목이 숨어 있다).
        큰 제목은 본문 맨 위 `PageHeader` 가 그린다 — devkanban 문법 그대로다.
        뎁스 화면(`onBack`)은 반대로 상단바가 제목을 들고 본문에는 두지 않는다.
      */}
      {/*
        **최상위 네 탭에는 뒤로가기가 없다.** 그래서 상단바가 자리를 차지하지 않고,
        제목이 화면 맨 위에 붙는다. 액션 버튼은 그 제목과 **같은 줄**에 선다.
        상단바는 스크롤 뒤 제목 캡슐만 띄우는 오버레이로 남는다.

        뎁스 화면은 devkanban 문법 그대로다 — 좌측 원형 뒤로가기 + 우측 원형 액션,
        제목은 상단바가 들고 본문에는 두지 않는다.
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

      <nav className="bottom-nav" aria-label="주 메뉴">
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

                // 같은 탭을 다시 누르면 그 탭의 첫 화면으로 돌아간다 (뎁스 탈출)
                if (location.pathname !== tab.to) navigate(tab.to);
              }}
            >
              <Icon name={tab.icon} />
              <span>{tab.label}</span>
            </button>
          );
        })}
      </nav>
    </main>
  );
}
