# 13. Real-Device Testing

## Why this comes first

This product's biggest unverified risk is **whether mobile browsers keep recording in the background.**

When the screen locks or the app goes to the background, the OS may reclaim the microphone.
iOS Safari is especially restrictive. If "record a one-hour meeting on your phone" doesn't
hold, the product's premise is shaken.

Discovering this after building everything is too late, so it is verified **early in M2.**

## Spike page

```
/spike/recorder
```

Opens only in the development environment. Doesn't require login either —
forcing a login flow on the phone would blur what we're trying to verify (the recording itself).

What it shows:

| Item | Why we look at it |
|---|---|
| Secure context · MediaRecorder · IndexedDB · WakeLock | What works on this device |
| Full UA string | For recording which browser/OS |
| State · elapsed time · waveform | Whether the recording is alive |
| **Visibility change log** | Traces of going to the background and back. **The heart of this verification** |
| Platform detection · permission state | Whether the permission guidance correctly recognizes this device |
| Results (duration · size · bitrate · format) | Whether data actually survived |

## ⚠️ HTTPS is required

`getUserMedia` works **only in a secure context.** `localhost` is an exception, but
connecting from a phone to `http://192.168.x.x:4000` means **the microphone will not open.**

The spike page detects and explains this, but you should connect over https in the first place.

### Method 1 — self-signed certificate (no external service)

```bash
cd backend
mix phx.gen.cert                    # Once only. Generated under priv/cert/ (git-ignored)
DEV_BIND_ALL=true mix phx.server
```

On the phone:

```
https://<your Mac's LAN IP>:4001/spike/recorder
```

Find the LAN IP with: `ipconfig getifaddr en0`

A certificate warning appears. Per browser:

| Browser | Handling |
|---|---|
| Android Chrome | "Advanced" → "Proceed (unsafe)" — this is enough for a secure context |
| **iOS Safari** | Even past the warning, **the microphone stays blocked.** The certificate must be added to the trust list |

**iOS certificate trust procedure**

1. Send `backend/priv/cert/selfsigned.pem` to the iPhone (AirDrop / email)
2. Settings → General → VPN & Device Management → install the profile
3. Settings → General → About → **Certificate Trust Settings** → enable the certificate

Skip step 3 and it stays blocked. On iOS, installing and trusting are separate steps.

> Enabling `DEV_BIND_ALL` exposes the dev server on the LAN. Turn it off when testing is done.
> The default is binding to `127.0.0.1`.

### Method 2 — tunnel (easier)

If the certificate setup is a hassle, a tunnel is better. It's a real certificate, so no warnings.

```bash
cloudflared tunnel --url http://localhost:4000
# or  ngrok http 4000
```

Open the printed https address + `/spike/recorder`.

## Verification scenarios

For each case, record **recording duration · file size · logs.**
If the file size is 0 or far smaller than the elapsed time, that span was lost.

| # | Scenario | What to check |
|---|---|---|
| 1 | 5 minutes with the screen on | Baseline. Are size and bitrate normal |
| 2 | **Lock the screen** for 3 minutes mid-recording → return | Did the timer keep going. Is the audio continuous |
| 3 | **Switch to another app** for 3 minutes mid-recording → return | Same as above |
| 4 | **Receive a phone call** mid-recording | Does the `interrupted` event fire. Is everything up to that point saved |
| 5 | Lock the screen with WakeLock **off** | Any difference vs. having it on |
| 6 | Pause → wait 3 minutes → resume | Is the paused span excluded from the elapsed time |
| 7 | 30+ minutes continuous | Memory and stability over long runs |
| 8 | Low storage | How does it fail |

### Permission scenarios

Separate from recording itself, check **whether the screen tells the truth when blocked.**
Even the same "denied" state requires different user actions per browser, so getting it
right on one device doesn't mean it's right on another.

| # | Scenario | Expected |
|---|---|---|
| P1 | **Dismiss** the permission prompt (neither allow nor block) | `permission_dismissed` · [Try again] is shown and actually reopens the prompt |
| P2 | Press **Block** in the permission prompt | Chrome: `permission_blocked` · [Try again] is **absent** · the address-bar procedure is shown |
| P3 | Reload the page in the P2 state | "Microphone blocked" already shows **before** pressing anything, and the button is locked |
| P4 | From the P3 state, unblock via browser settings in another tab | The button comes back to life without a reload (`permissionchange`) |
| P5 | Deny on iOS Safari | `permission_denied` · **the button is not locked** · the iOS settings path is shown |
| P6 | Disable the browser's microphone in macOS/Windows system settings | `system_denied` · the **system settings** procedure is shown, not the browser's |
| P7 | Record while Zoom/Teams holds the microphone | `device_busy` · "another app is using it" · [Try again] is present |
| P8 | Pick a Bluetooth mic, power it off, then record | `device_unavailable` · [Switch to default microphone] appears |
| P9 | Open the link in the **KakaoTalk in-app browser** | Shows "Open in Safari / open in another browser," not a settings procedure |
| P10 | Launch as a home-screen PWA | Is **not** mistaken for an in-app browser — no "open in another browser" message |

P9 and P10 share the same detection. On iOS, both in-app browsers and PWAs drop the
`Safari` token from the UA, so fixing one easily breaks the other.

The `Detection:` line at the top of the spike page shows exactly how the device was read.
If the guidance points at the wrong menu, look at this line first.

### Recording template

```
Device:      iPhone 15 / iOS 18.2 / Safari
Scenario:    2 (screen lock, 3 minutes)
Result:      ✅ kept / ⚠️ partial loss / ❌ stopped
Duration:    05:12
File size:   2.4 MB (78 kbps)
Log summary: visibilitychange ×2, no freeze
```

## Known constraints

| Item | Details |
|---|---|
| iOS Safari background | Can drop the audio session. Keeping the screen on via WakeLock is the most reliable approach |
| iOS format | `audio/mp4` (AAC). webm is unsupported — `pickMimeType()` picks accordingly |
| Android Chrome | Mostly stable, but battery optimization can freeze the tab (detected via the `freeze` event) |
| Safari permission state | Doesn't support `permissions.query({name:"microphone"})`. Blocked state is unknowable, so it stays `unknown` and the button is not locked |
| In-app browsers | In KakaoTalk, Instagram, etc., no permission setting helps. The only way out is opening an external browser |
| WakeLock | Requires HTTPS. Not automatically re-acquired on return from background, so the spike requests it again |

## Responses depending on results

| Result | Response |
|---|---|
| Mostly kept | Proceed as-is. Turn WakeLock on by default |
| Cuts out in the background | Force keep-screen-on during recording and explain in the UI. Partial save on interruption |
| Doesn't work at all on iOS | Re-verify as an installed PWA. If it still fails, explicitly mark iOS as "screen-on only" |
