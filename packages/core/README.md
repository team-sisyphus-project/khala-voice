# @vr/core

Recording · upload · domain logic. **Depends on no UI framework.**

Do not put React imports in here. If this rule breaks, the split loses its point.

## Why the split

sisyphus kept **two copies** of this logic — desktop (`meeting-recorder.js`)
and mobile (`mobile.js`) — and as a result the pause behavior diverged.
Desktop split the session; mobile kept one session. Worse, the desktop resume
path called a function that did not exist and never worked at all.

Keeping the logic in one place structurally prevents that class of accident.
How many UIs to build becomes a cheap decision that can change later.

## Structure

```
recorder/   MediaRecorder engine · waveform analysis · timer · pause policy
upload/     IndexedDB queue · presign · PUT · retries
api/        typed API client
domain/     transcript · speaker · permission resolution
```

## How it is consumed

No build artifacts are produced. The TypeScript source is imported directly.

- Phoenix esbuild — spike pages, LiveView hooks
- Vite — the React app

One step fewer, and source maps always point at the original.
