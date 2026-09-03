# 05. Authentication, Friends, Sharing, Permissions

## Authentication methods

| Method | Status | Notes |
|---|---|---|
| Email + password | **Always enabled. Cannot be turned off** | The login path of last resort |
| Social login | **Per-provider ON/OFF in admin** | Shown only when keys exist and it is ON |
| MFA (TOTP) | **Mandatory for system admins** | Not required for regular users |

### Admin two-factor authentication is mandatory

An admin account must have TOTP enabled to enter `/_admin`. Accessing it without TOTP
redirects to the setup screen (`MFA.satisfied?/1`).

### The enrollment screen lives **outside** the admin area

`/login/mfa/enroll` — it is part of the login flow. The password has been verified, no
session exists yet, and login only completes once enrollment is finished.

Putting it inside the admin area creates a deadlock: **you must enter through the very
door you have to enable in order to enter.** A new admin could never get in without
touching the DB directly.
devkanban solved the same problem the same way ([14-provenance.md](14-provenance.md)).

| Account | Where login sends you |
|---|---|
| Admin, MFA enabled | `/login/mfa` (code verification) |
| Admin, MFA not enabled | `/login/mfa/enroll` (**enroll first**) |
| Regular user | Logged straight in |

`MFA.verify/2` **does not pass accounts that haven't enabled MFA.** With nothing to
verify against, the answer is rejection, not a pass — it used to return `:ok`, and since
login unconditionally sent admins to the code screen, **an admin without MFA could enter
any digits and get through.**

If one admin is compromised, the entire system's settings, API keys, and every account
fall with it. A single password cannot protect that.

Regular users are not required to enroll — ask people to install an authenticator app
just to read meeting notes and most of them leave.

### High-risk admin operations require recent MFA

Admin promotion, admin privilege revocation, and immediate account deletion by an admin
require **a successful MFA verification within the last 10 minutes** at execution time.
MFA passed at login also counts if it happened within 10 minutes in the same session. If
there is no success timestamp or it is older than 10 minutes, the operation is not
executed; MFA is re-verified, and only after a successful verification can the original
operation be attempted again. All three operations apply the same condition and fail
safely on failure.

We do not require a separate password re-entry. Admins already have mandatory TOTP MFA;
re-entering a password is not an independent additional proof against a stolen password,
and it is hard to apply consistently to social-login accounts. Recent MFA reduces the
risks of session hijacking and long-lived sessions while providing the same step-up
authentication regardless of login method.

Validity is judged by the MFA success timestamp recorded by the server. Timestamps sent
by the client are not trusted, and the MFA success record is valid only for that login
session — it is discarded on logout or session invalidation. A success using a backup
code also counts as MFA success, with the existing one-time-use consumption rules applied
unchanged.

In the implementation, the success timestamp is stored in
`AccountSession.mfa_verified_at`. The three admin services re-verify in the DB that the
actor owns the session, that the session is active and unexpired, and that the success
timestamp is within the last 10 minutes of the server's current time. If the conditions
are not met, the admin verifies at `/_admin/accounts/verify-mfa` and returns to the
account list to select the operation again. Verification alone never auto-executes the
previous operation.

This policy covers only the **actor's step-up authentication**. The actor's admin
permission check and operation audit logging are each handled by separate policies.

> In dev and staging, any six digits pass. This bypass is **baked in at compile time**
> and cannot be enabled in production builds, not even via environment variables.

### Social login ON/OFF

```elixir
# AuthProvider
id              :string
provider        :string    # google | github | kakao | naver | apple | ...
display_name    :string    # button label
client_id       :string
client_secret   VR.Encrypted.Binary   # Cloak encrypted
redirect_uri    :string
scopes          {:array, :string}
enabled         :boolean, default: false
sort_order      :integer
updated_by_id   :string
```

**Activation check**

```elixir
def active?(provider) do
  p = get_provider(provider)
  p.enabled and present?(p.client_id) and present?(p.client_secret)
end
```

| State | Login screen | OAuth routes |
|---|---|---|
| `enabled = true` + keys present | Button shown | Working |
| `enabled = true` + keys missing | **Not shown** + warning badge in admin | 404 |
| `enabled = false` | Not shown | 404 |

Callback routes go through the same check. Callbacks arriving for a disabled provider
are rejected.

**Environment variable fallback**: if the DB has no value, environment variables like
`GOOGLE_OAUTH_CLIENT_ID` are read. But the `enabled` switch comes from the **DB only**.
Environment variables alone cannot turn a provider on.
→ [07-config-admin.md](07-config-admin.md)

**Safety checks before disabling**

Disabling a provider that has social-only accounts locks those accounts out of login.
Before disabling, the admin UI:

1. Shows the number of accounts that can only log in via that provider
2. Requires a confirmation phrase if the count is nonzero
3. On disable, sends those accounts an email guiding them to set a password

### Sessions

- One `AccountSession` row per device (token, UA, IP, last activity, expiry)
- The settings screen shows the device list with individual/global logout
- Changing the password invalidates all other sessions

### Account deletion

Accounts are not deleted immediately; `scheduled_deletion_at` is set instead.
Logging in during the grace period cancels it; once it passes, `DeletionWorker` handles
it. The handling policy for meetings, audio, transcripts, and the credit ledger is
defined alongside.

---

## Friends

### Invitation methods

| Method | Flow |
|---|---|
| **Email invite** | Enter an email → invitation mail sent → link clicked → (sign up if needed) → auto-accepted |
| **Link invite** | Create a link → deliver it any way you like → whoever opens the link accepts |

```
FriendInvitation
  invited_by_id, email(may be nil), token, status, expires_at, message
```

**State transitions**
```
pending ─┬─► accepted    → Friendship created
         ├─► declined
         ├─► expired     (expires_at passed)
         └─► cancelled   (inviter cancelled)
```

### Relationship

```
Friendship(account_a_id, account_b_id)   # always a sorted pair, one row
```
- Duplicates prevented via `unique_index(a, b)`
- Lookups use `where a = me or b = me`
- Blocking is `status = blocked` + `blocked_by_id`

### What friends are for

The friends list replaces sisyphus's "project members".

- Candidates for a meeting's Reviewer / Contributor assignment
- Targets for speaker mapping (`speaker_map.account_id`)
- The audience when `view_scope = all_friends`

---

## Permissions

### Roles (unified naming)

The Korean UI uses these names verbatim too. They are not translated into Korean equivalents.

| Role | Internal code | Permissions |
|---|---|---|
| **Reviewer** | `lv0` | Full control — recording, editing, deletion, archiving, permission changes, share-link issuance |
| **Contributor** | `lv1` | Recording, playback, speaker/transcript editing, summary generation. No deletion, archiving, or permission changes |
| **Viewer** | `lv2` | Read-only. Audio URLs masked, editing UI disabled |
| — | `lv3` | No access. **Responds 404** (existence is not revealed either) |

### View Scope → role resolution

`view_scope` is the visibility level the user picks in the meeting settings. Roles are
computed from it automatically.

| view_scope | Meaning |
|---|---|
| `me_only` | The Reviewer only |
| `assignees_only` | Reviewer + Contributors only (default) |
| `selected_friends` | Only designated friends (as Viewers) |
| `all_friends` | All of my friends (as Viewers). **Based on the `reviewer_id`'s friends list** — handing the meeting over swaps the entire audience |

```elixir
def resolve(meeting, account_id, opts) do
  cond do
    opts[:is_admin]                          -> :lv0   # system admin
    account_id == meeting.reviewer_id        -> :lv0   # Reviewer
    account_id in meeting.contributor_ids    -> :lv1   # Contributor
    scope == "me_only"                       -> :lv3
    scope == "assignees_only"                -> :lv3
    scope == "selected_friends" and
      account_id in selected_account_ids     -> :lv2   # Viewer
    scope == "all_friends" and
      friends?(meeting.reviewer_id, account_id) -> :lv2
    true                                     -> :lv3
  end
end
```

> **Switching to `me_only` does not hide the meeting from Contributors.** The `cond`
> above checks Contributor status before the visibility scope. Users believe they "made
> it private", so the UI announces this fact and offers "remove all Contributors"
> alongside.

Storage format:
```jsonc
meeting.permissions = {
  "view": { "mode": "selected_friends", "accountIds": ["acct_x", "acct_y"] }
}
```

### Guests (share links)

Guests access via a link without needing an account. **The existing permission model is
used unchanged** — a guest is also granted one of Reviewer/Contributor/Viewer, and that
role's permissions apply as-is.

```elixir
SharedLink.granted_role   # "viewer" | "contributor"
```

| Situation | Result |
|---|---|
| Valid link + account **with permission on that meeting** | **Account permission wins.** The link is not used — no PIN prompt, no use count consumed |
| Valid link + account **without permission** | **Treated exactly like an anonymous visitor.** Subject to the meeting toggle and the PIN prompt |
| Valid link + logged-out guest | Access via `granted_role`. Requires `guest_link_enabled` to be on |
| PIN set | Must match the PIN. **Regardless of login state** |
| PIN mismatch | 401. Per-link: 5 tries → 15-min lock; per-IP: 20 tries per 15 min → lock (429) |
| `guest_link_enabled` off | **404** — even the fact that the link was valid is hidden |
| `max_uses` exhausted / expired / inactive / revoked | 410 Gone. **The four are not distinguished** |
| Missing / malformed token | 404 |

> **"Logged in means no PIN" applies only to accounts that have permission.**
> Exempting permission-less accounts too would let anyone sign up to bypass both the
> guest toggle and the PIN at once. sisyphus trusted `params["member_id"]` and had
> exactly this hole.

**One-time invitation** = `max_uses: 1` + an `expires_at`.

### Revocation and exhaustion behave differently

| | Guests already inside |
|---|---|
| **Revoked** (`DELETE`) · **inactive** (`is_active: false`) · **expired** | **Cut off immediately** |
| **Exhausted** (`max_uses` reached) | They stay |

Exhaustion means "no one else gets in", not "kick out whoever is in". If someone who
received the meeting notes via a one-time link got ejected on their second request, the
link would be useless. Revocation is the opposite — it is only meaningful if it also cuts
off whoever is viewing right now.

**Rotation** (`rotate`) only changes the address — guests already inside are kept.
"I lost the link" and "I want to kick people out" are different things.

Guest sessions are managed with their own token and can only access that one meeting.
Even if the guest later creates an account, their permission on that meeting never
exceeds what the link granted.

### Where permissions surface in the UI

| Item | Reviewer | Contributor | Viewer |
|---|---|---|---|
| Edit title / description | ✅ | ✅ | — |
| Record | ✅ | ✅ | — |
| Playback | ✅ | ✅ | ✅ |
| Edit speakers / transcript | ✅ | ✅ | — |
| Generate / regenerate summary | ✅ | ✅ | — |
| Change topic / labels | ✅ | ✅ | — |
| Change visibility scope | ✅ | — | — |
| Issue share links | ✅ | — | — |
| Archive | ✅ | — | — |
| Delete | ✅ | — | — |
| Download audio | ✅ | ✅ | Per settings |
| Markdown export | ✅ | ✅ | ✅ |

**The server has the final say.** Frontend disabling is a convenience only; every
mutating API recomputes and validates the role on the server.
