# Security Policy

This project handles **meeting recordings and transcripts**. A single
vulnerability could expose people's conversations wholesale.

## Reporting a vulnerability

**Do not open a public issue.** Contact the repository maintainers privately
(GitHub Security Advisory or the maintainer's email).

Including the following speeds up triage:

- Reproduction steps (down to the exact request sequence)
- Impact — what can be read or changed
- The affected version / commit

## Defenses by design

When contributing, take care not to break the properties below.
Each one is here because it was, or nearly was, a real problem.

| Defense | Why |
|---|---|
| No access is a **404**; 403 is never used | A 403 reveals that the resource exists |
| Share tokens are stored only as sha256 hashes | A token is a credential that works without further authentication. Whoever sees the DB becomes a visitor |
| PINs use Bcrypt | Six digits is 10^6, so a sha256 hash can be reversed in seconds after a leak |
| `slt_`/`gst_` tokens are masked in logs | Share tokens sit in URL paths and were left in request logs in plaintext |
| Audio is served only via signed URLs | Storage keys are deterministic, so an unsigned address is a permanent public link |
| Workers download only from our bucket's addresses | Following a client-supplied address turns into a private-network request (SSRF) |
| Guest API paths carry no meeting id | The meeting is determined by the guest session. There is simply no way to point at a different meeting |
| Guests get no transcription, summary, or upload routes | A single link must not become a power of attorney over the meeting owner's credits |
| No secrets in code | `DB → environment variable → nil`. No literal defaults |

## What operators must do

These cannot be closed by code alone.

- **Keep the S3 bucket private.** With a public bucket, every audio defense above is meaningless
- **Store `CLOAK_KEY` somewhere separate from the DB credentials.** If they leak together, the encryption loses its meaning
- **Set `APP_TRUST_PROXY_HEADERS=true` only when behind a reverse proxy.**
  Enabling it without a proxy lets a single header bypass IP-based rate limits
- **Access logs outside the app** (proxy, CDN, load balancer) still contain share
  tokens verbatim. The app can only mask its own logs
- Enable MFA on admin accounts, and delete the bootstrap account once a real
  user account exists

## Known limitations

- **Guest sessions last up to 12 hours.** Within that window, only revoking the
  link cuts access immediately (revocation, deactivation, and expiry cut access
  immediately; exhausting `max_uses` does not eject people already inside)
- The service keeps running even with a negative balance (metering is after the
  fact, so it cannot block). If abuse is a concern, enable
  `policy.hard_stop_on_zero_credits`
