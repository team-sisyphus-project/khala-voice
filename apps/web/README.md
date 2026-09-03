# @vr/web

Meeting · recording · transcription · summary screens. React + TypeScript + Vite.

## Development

```bash
npm install
npm run dev      # vite build --watch → backend/priv/static/app
```

No separate Vite dev server. Phoenix serves everything and Vite only refreshes
the files. With a single server, cookies, CSRF, and the address real devices
connect to never drift apart.

Run Phoenix alongside it.

```bash
cd ../../backend && mix phx.server
```

`http://localhost:4000/app/meetings`

## Rules

1. **Business logic lives in `@core`.** This package holds only screens and
   thin adapters. Connecting core to React, as in `src/hooks/useRecorder.ts`,
   is the upper bound.
2. **Styles use `.vr-*` classes.** They live in `backend/assets/css/app.css`,
   shared with the admin (LiveView) from the same file. No color literals.
3. **The server decides permissions.** The `role` in responses is used only to
   draw the UI. Hiding a button is a convenience; the server verifies again.

## Routes

| Path | Screen |
|---|---|
| `/app/meetings` | Meeting list |
| `/app/meetings/:id` | Meeting detail — record · sessions · summary tabs |
| `/app/archive` | Archive search |

Login, friends, and settings are handled by Phoenix LiveView (`/login`,
`/friends`, `/settings`).
