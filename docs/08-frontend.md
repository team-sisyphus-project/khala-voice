# 08. Frontend

## Principle: separate logic from UI

```
packages/core/     ← Zero React dependencies. Pure TypeScript
  recorder/          MediaRecorder engine · waveform · timer · pause policy
  upload/            IndexedDB queue · presign · PUT · retry
  api/               Typed API client · SSE subscriptions
  domain/            transcript · speaker · summary transforms, permission checks
  store/             State management
apps/web/          ← UI shell (desktop + mobile responsive)
```

sisyphus kept **two copies** of the same logic — one for desktop (`meeting-recorder.js`, 6,575 lines)
and one for mobile (about 1,700 lines inside `mobile.js`) — and as a result the pause behavior
diverged between them. Keeping the logic in one place structurally prevents that class of accident.

Another effect of this separation: **how many UIs to build becomes a cheap decision you can change later.**
Start with a single responsive UI, and if you ever truly need it, add `apps/mobile` without touching the logic.

---

## Routing

### Current state in sisyphus (for reference)

| | Entry | URL |
|---|---|---|
| Desktop | `/projects/:id?view=meetings&meeting=<id>` | Query parameters, single page |
| Mobile | Opens an overlay | **No URL.** Screen transitions via internal state only |

On mobile, deep links, the back button, and refresh all failed to work.
**Share links are a core feature of this app, so mobile must have URLs too.**

### Route table (shared by desktop and mobile)

| Path | Desktop | Mobile |
|---|---|---|
| `/` | Landing / login | Same |
| `/app/meetings` | **Record immediately** (open an empty meeting and go to the recording screen) | Same |
| `/meetings/:id` | **Two-pane list + detail** | Detail only. Back → `/meetings` |
| `/meetings/:id?tab=record` | Left panel [Record] tab | Recording screen |
| `/meetings/:id?tab=info` | Left panel [Info] tab | Info screen |
| `/meetings/:id?tab=summary` | Right panel [Summary] tab | Summary screen |
| `/meetings/:id?tab=sessions` | Right panel [Sessions] tab | Session list |
| `/meetings/:id/s/:session_id` | Transcription in the right panel | Full-screen transcription |
| `/app/archive` | **Meeting list + search** | Same |
| `/share/:token` | Shared view (no authentication required) | Same |
| `/friends` | Friend list · invitations | Same |
| `/settings` | Account · sessions · language | Same |
| `/billing` | Plan · credit balance · usage history | Same |
| `/_admin/*` | LiveView (separate app) | — |

### How the depth difference is absorbed

There is only one resource hierarchy: `list → meeting → session`.
Desktop shows these **side by side**; mobile shows them **one at a time**. A classic master-detail.

```tsx
// Same route, different layout depending on width
function MeetingsLayout() {
  const wide = useMediaQuery('(min-width: 1024px)')
  const { id } = useParams()

  if (wide) return <><MeetingList selectedId={id} /><MeetingDetail id={id} /></>
  return id ? <MeetingDetail id={id} withBackButton /> : <MeetingList />
}
```

Tabs live in query parameters. On desktop they highlight a tab; on mobile they switch screens.
**The depth difference is absorbed by the layout component, not by the routes.**

### Why we don't split off a `/m/` path (reversed 2026-08-20 — see the section above)

It would create **two kinds** of share links. A `/m/share/abc` copied on mobile opens the
mobile UI on desktop, and vice versa. Blocking that with UA-sniffing redirects turns this into
an app whose "URLs change depending on context," which leads to real bugs in a product
where sharing is the core feature.

---

## Screen structure

### Meeting detail (desktop)

```
┌──────────┬─────────────────────────────────────────────┐
│ Meeting  │ Title · description                          │
│ list     │ [Export][Share][Archive][Delete]              │
│ (sidebar)├──────────────────┬──────────────────────────┤
│ □ Mtg A  │ [Record | Info]   │ [Summary | Sessions]      │
│ ■ Mtg B  │                  │                          │
│ □ Mtg C  │  Timer 00:00      │  One-line summary         │
│          │  ▁▃▅▇▅▃▁ waveform │  Decisions (cards)        │
│          │  ⏸  ●  ✕         │  Action items (cards)     │
│          │  Mic / language   │  Key facts · open questions│
│          │                  │  Next steps · key topics   │
│          ├──────────────────┴──────────────────────────┤
│          │ ▶ ──────●───────── 00:12 / 45:30    [bottom] │
└──────────┴─────────────────────────────────────────────┘
```

### Meeting detail (mobile)

```
List → Detail → (tabs) Record / Info / Summary / Sessions → Session transcription
                                   ↑ back button returns here
```
- Pickers (friend selection · topic · label · visibility) are bottom sheets
- The audio player is pinned to the bottom (same as desktop)

### Shared view (`/share/:token`)

What a guest sees. Editing UI appears or hides depending on the permission (`granted_role`).

```
Meeting title
├ Summary (read-only or editable)
├ Transcription (chat-style, per speaker)
└ Audio player
```
For a Viewer, the audio URL is masked and there is no download button.

---

## Archive search

The screen for finding `status = archived` meetings. **Topics and labels are the primary filters.**

| Filter | Behavior |
|---|---|
| Topic | Single select |
| Label | Multi select (AND / OR toggle) |
| Date range | `started_at` range |
| Participant | Reviewer / Contributor accounts |
| Language | Session `metadata.language` |
| Full-text search | Title · description · summary · **transcription body** |

Transcription body search uses PostgreSQL full-text search (`tsvector` + GIN index).
For Korean we are evaluating `pg_bigm` or a trigram-based approach. No separate search engine.

Result items show the matching utterance snippet along with its timestamp,
and clicking one jumps to that point in the meeting.

---

## Offline · PWA

| Item | Behavior |
|---|---|
| Recording | Runs entirely on the client. Records even while offline |
| Upload | Queued in IndexedDB → retried sequentially once back online |
| Browsing | App shell is cached. Meeting data requires the network |
| Notifications | Push on transcription complete · summary complete (VAPID) |
| Install | Capture `beforeinstallprompt`, then show an install button |

**Risk that needs verification**: on mobile, when the screen locks or the app goes to the
background, the browser may suspend `MediaRecorder`. iOS Safari is especially restrictive.
Real-device verification is included in the milestones. → [11-roadmap.md](11-roadmap.md)

---

## Main menu

There are **only four** main menu items — Meetings · Archive · Friends · Settings.

| Tab | What the screen does |
|---|---|
| **Meetings** | **Record immediately.** Not a list — the moment you enter, it opens a meeting and shows the recording screen |
| **Archive** | **Meeting list.** Split by status (all · in progress · completed · archived), with results grouped in a **per-topic accordion**. Search filters are tucked into a sheet behind an icon in the top right |
| **Friends** | Friend list · invitations |
| **Settings** | App settings. Account settings and credits live inside here |

| Screen | Location | Why |
|---|---|---|
| Taxonomy management | **Inside** Archive (`/app/taxonomy`) | Taxonomy exists to make the archive searchable. Not opened often enough to earn a spot in the main menu |
| Credits | **Under** Settings (`/app/billing`) | Not something you look at every day |
| Account settings | **Under** Settings (`/settings`, LiveView) | Profile · password · theme. Different in nature from app settings |
| Admin | **Not linked anywhere** | Reached only by typing the address (`/_admin`) directly |

Adding more tabs squashes the icons on narrow screens and erases the distinction between
"used every day" and "opened occasionally."

### Layout of the Meetings tab

```
New meeting                          [Export] [Share]    ← large header + circular actions
Meeting on Aug 19, 2026  ✎                              ← small line. Tap opens a modal
[In progress] [Participants only] [Topic] [Label]
[Record][Sessions][Transcription][Summary][Info]        ← only as wide as the text
              00:00
              ▁▃▅▇▅▃▁                                 ← only while recording
              ▬▬▬▬▬░░░                                ← input level
                ●                                     ← record button
           🎙 Default microphone ›                      ← only before recording
```

- No title input field on this screen. The star of this screen is the record button, and
  a form in the way blurs "what am I supposed to do right now." **Title and taxonomy are
  edited in a modal**
- **The input level is drawn only while recording.** When stopped there is no stream, so
  the level is 0, and continuously showing 0 reads as "the microphone is dead."
  Without this indicator you can record an hour of silence and only find out at the end
- **Microphone selection happens only before recording.** Switching mid-recording requires
  reopening the stream, which cuts audio at that point — the kind of feature that quietly
  loses data in the middle of a meeting.
  The chosen device is remembered per device (if you have to re-pick the conference-room
  mic every time, the first meeting always ends up on the built-in mic)

### Why the Meetings tab is not a list

User decision (2026-08-20): **"Meetings means record immediately (opening a new session); Archive is the list of meetings."**

The most frequent event in this app is "the meeting just started, I need to hit record."
Showing a list first and making people tap [New meeting] inserts that extra tap every time.

However, creating a new meeting on every tab visit piles up **empty meetings that were
never recorded** (just tapping in and backing out creates one). So if a freshly created
empty meeting exists, it is reopened instead — either way, what the user sees is
"straight to the recording screen."

### Picking a taxonomy — dropdowns

If all chips are laid out flat, the screen drowns in chips the moment you have thirty topics.
The trigger shows **only what's selected**, and the list opens only while choosing. The list
always includes search.

| | Count | Creation |
|---|---|---|
| **Topic** | Exactly one (domain rule, `docs/03-domain-model.md`) | **Created right on the meeting screen** — deciding "what kind of meeting is this" is part of the flow, and a round-trip to the taxonomy screen breaks it |
| **Label** | Multiple | **Pick only** from existing labels. Labels are tags that span multiple meetings, so ad-hoc creation quickly produces duplicates |

The topic picker closes on selection; the label picker stays open while picking several.

### Topic accordion in the Archive

Results are grouped by topic, and tapping a header collapses the group. With several topics,
a fully expanded list is unskimmable.

- Ordering follows the topic's `sort_order` — the order set on the taxonomy screen must
  match here, or "putting something on top" loses its meaning
- Meetings without a topic go in **one group at the bottom**
- State **remembers which groups are collapsed** (not which are expanded). New topics must
  default to "expanded" so they don't vanish from the list
- The group header carries the topic, so cards keep only the labels

## Surface split — `/app` desktop · `/m` mobile

| Prefix | What |
|---|---|
| `/app/*` | **Desktop** surface (three panes) |
| `/m/*` | **Mobile** surface (one screen at a time) |
| `/go/*` | **Surface-neutral deep links.** Links generated by the server (push · mail · workers). The opener picks the surface |
| `/share/:token` · `/invite/:token` | **Outside both surfaces.** So links sent to other people come in exactly one form |

### Why split by path instead of responsive design

This document originally argued against the `/m/` split (see the section below). Reversed on 2026-08-20:

1. **The information architecture differs.** The mobile Meetings tab is "record immediately,"
   while desktop is "list + detail side by side." These are not the same screen at different widths
2. **The imported design system has no desktop layer.** The only media queries in the
   devkanban mobile CSS are `max-width: 360px` and `prefers-reduced-motion`. Even if we
   absorbed it responsively, we would have to write a second design layer from scratch anyway
3. **The original objection no longer applies to this structure.** The section below worried
   about share links coming in two kinds, but `/share/:token` lives **outside both surfaces**

### Link portability

Only the prefix differs; **everything after it is identical.** `/m/meetings/123` ↔ `/app/meetings/123` map 1:1.

- Automatic switching happens **only on first entry** (`/`, `/app`, `/m`, `/go/*`)
- A deep link that already carries a surface opens **exactly as received** — flipping it
  based on width would make a link received from someone else open a different screen
- If the user picks a surface explicitly, remember it. If the choice to view desktop in a
  narrow window is reverted every time, there is no way to reach that screen at all

All the rules live in one place: [`apps/web/src/lib/surface.ts`](../apps/web/src/lib/surface.ts).
Screen code does not know which surface it runs on — addresses are produced by `useRoutes()`.

## Navigation grammar

**Source: devkanban** mobile. The markup (class names) is used as-is.

| Screen type | Top left | Title | Top right |
|---|---|---|---|
| **Top-level four tabs** | None | Large title at the top of the body (`mobile-page-header`) | Circular icon buttons **on the same line** as the title |
| **Depth** (`/app/meetings/:id` · taxonomy management · credits · account settings) | **Circular back button** | Capsule in the top bar | Circular icon buttons |

- Top actions are **icons only.** An icon+text button weighs the same as the title capsule,
  making the top bar read as two competing blocks
- Top-level tabs have no back button, so **the top bar takes up no space.** The title sits
  flush at the top of the screen
- The title is drawn **in exactly one place.** Depth screens put it in the top bar; top-level
  screens put it in the body
- No hamburger (Drawer) — with only four screens, the bottom tab bar is enough

The bottom tab bar uses **the same markup** in the web app (React) and LiveView. If one app
carries two navigation implementations, no one can tell which is the real one.

### Why admin is excluded from the menu

The system admin operates the entire system. Placing it next to everyday menu items
(a) reveals to ordinary users that such a screen exists, and
(b) makes it easy for the operator to tap by mistake during normal use.

Unauthorized requests get a **404** from the server, not a 403.
Admin access requires **two-factor authentication enabled** ([05-auth-sharing.md](05-auth-sharing.md)).

## Design system

Styles live in one place: `packages/ui-styles/`. **The web app (React) and LiveView read
the same files** — two copies would inevitably diverge.

```
packages/ui-styles/
  index.css          ← Entry point. Import order is the rule
  devkanban/         ← Pristine originals. Never modified
  overrides.css      ← All adjustments for this app go here
```

- Web app: `apps/web/src/styles/app.css` imports `index.css`
- LiveView: `backend/assets/css/app.css` imports the same file, and legacy token names
  are mapped to devkanban tokens by `legacy-tokens.css`

What was overridden and why is recorded in [14-provenance.md](14-provenance.md).

### Four themes, all shipped in the bundle

| Theme | Where it comes from |
|---|---|
| Light · Dark | The `[data-theme]` blocks in `devkanban/tokens.css` |
| Pencil (`pencil-warm`) | Tokens + `devkanban/media-skin.css` (hand-drawn border SVGs) |
| Game | Tokens + `devkanban/game-skin.css` (pixel font · CRT scanlines) |

Previously the Pencil (247KB) and Game (35KB) CSS were fetched separately when selected.
Those files were written to override the **legacy token names** (`--surface-*` · `--accent`),
so after the design system moved to devkanban (`--mobile-*`), they **changed nothing while
still costing a 280KB download.** All four themes are now in the bundle.

**The default theme is Light.** It applies to first-time visitors and new accounts with no
browser cache or account value. Accounts that already chose another theme are left untouched —
once you can no longer distinguish a user's choice from the default, there is no way back.

## Accessibility · i18n

- Supported languages: ko / en / ja / es / zh_CN / zh_TW (same as sisyphus)
- All strings are managed by key. **No Korean hardcoded in components**
  (sisyphus mixed hardcoded strings with i18n keys; this is cleaned up during the port)
- Recording state changes are announced via `aria-live`
- Speakers are never distinguished by color alone. Names are always shown alongside
