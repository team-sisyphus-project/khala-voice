# 16. PostgreSQL Extension Privileges

**Decision record.** Settles who creates the two PostgreSQL extensions the
schema depends on, and what happens when nobody can.

## The problem

Bringing khala voice up against a brand-new database on a preview/platform
environment failed at the migration step. The first-order cause is the two
extensions the schema needs:

| Extension | What depends on it |
|---|---|
| `citext` | `accounts.email` and `login_attempts.email` are `citext` columns — `Foo@x.com` and `foo@x.com` must be the same account |
| `pg_trgm` | `meetings_title_trgm_idx`, the GIN index built with `gin_trgm_ops` that backs transcript/title partial-match search |

`CREATE EXTENSION` needs `CREATE` privilege **on the database**, which a managed
or platform-provisioned application role usually does not have. The role can
create tables all day and still not create an extension. Nothing in this
repository can grant itself that privilege, and no source evidence settles what
any particular platform allows.

## The three candidate remediations

The question was left open deliberately, because picking wrong is expensive:

- **(a) Pre-provision** — a database administrator creates the two extensions
  before migrations run.
- **(b) Remove the dependency** — change the schema so neither extension is
  needed.
- **(c) Privileged one-time preparation step** — run the extension creation
  explicitly, as a role that holds the privilege, separately from the migration.

## Decision

**Support (a) and (c). Reject (b).**

(a) and (c) are the *same code path*, which is why both are supported at once
rather than chosen between: the migration attempts `CREATE EXTENSION IF NOT
EXISTS`, which succeeds under (c) — a privileged role runs the migration, or ran
`CREATE EXTENSION` a moment earlier — and is skipped entirely under (a), because
the extension is already there. Neither requires the operator to tell the app
which world it is in.

### Why (b) is rejected

Dropping the dependency is not a migration-layer change; it is a schema and
application rewrite, and it makes the product worse:

- Replacing `citext` means every email comparison, unique index and lookup moves
  to `lower(email)` — in the schema, in queries, and in every code path that
  compares an address. A single missed call site silently creates a duplicate
  account, which is exactly the class of bug `citext` exists to prevent.
- Replacing `pg_trgm` means either a `LIKE '%…%'` sequential scan on every
  search, or a dedicated search engine. The trigram index is what makes partial
  matching work without morphological analysis for languages that would
  otherwise need it — see `docs/03-domain-model.md`.

Both extensions ship in PostgreSQL's standard `contrib` package and are
*trusted* extensions on PostgreSQL 13+. Requesting one `CREATE EXTENSION` from
an administrator is a far smaller ask than either replacement.

## How it is implemented

Both extensions are guarded in the migration that first needs them —
`priv/repo/migrations/20260819073219_create_accounts.exs` (citext) and
`…_create_meetings.exs` (pg_trgm). The guard is **duplicated in both files on
purpose**: a migration must stay self-contained and must not depend on
application code that may change after it was written.

The up direction checks, in order:

| # | Condition | Result |
|---|---|---|
| 1 | Installed, in a schema on the role's `search_path` | `:ok` — nothing to do (this is case (a)) |
| 2 | Installed, but in a schema the role does not search | Raise: name the schema, the role, its `search_path`, and both `ALTER` statements that fix it |
| 3 | Not present in `pg_available_extensions` | Raise: name the contrib package and the exact `CREATE EXTENSION` SQL |
| 4 | Otherwise | Run `CREATE EXTENSION IF NOT EXISTS`; on `insufficient_privilege`, raise naming the extension, the exact SQL, and who has to run it |

Ownership is **never** required. Under (a) the extension is owned by the
administrator who created it, not by the migrating role, and asking for
ownership would defeat the whole point:

- The **up** direction only needs the extension to be *reachable*. Reading
  `pg_extension` and resolving a type needs no privilege beyond `USAGE` on the
  schema holding it.
- The **down** direction drops the extension **only when this role owns it** —
  i.e. only when this migration created it. A pre-provisioned extension belongs
  to the administrator and may back other schemas in the same database; a
  rollback must not remove it. Unconditional `DROP EXTENSION` also *fails* for a
  non-owner (`must be owner of extension citext`), which turned a rollback into
  a hard error before this was fixed.

### Why a reachability check, not just a presence check

`pg_extension` says an extension exists; it does not say the migrating role can
use it. An administrator who installs into a dedicated schema
(`CREATE EXTENSION citext SCHEMA extensions`) leaves the extension present but
unresolvable, and PostgreSQL then reports only `type "citext" does not exist`
— an opaque failure several statements later. Case 2 above turns that into a
named action.

### The preflight asks the same question

`VR.DBPreflight.check_extensions/1` — what `mix vr.doctor` prints and what
`VR.Release.preflight!/2` refuses to migrate past — runs the **same**
`current_schemas(true)` test as case 2 above, and reports the same schema, role
and two `ALTER` statements. A presence check alone would have passed here and
handed the operator the opaque failure the guard exists to prevent, one step
later than necessary.

The two live in different places on purpose (the migration must be
self-contained), so the rule they share is written down in both: **installed is
not reachable, and only reachable is ready.**

## What an administrator has to run

```sql
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
```

Into a schema the application role searches — `public` unless the role's
`search_path` says otherwise. `mix vr.doctor` reports whether this is needed
*before* a migration gets halfway; the migration itself says the same thing if
it is reached first. See the "Database preparation" section of the root
`README.md` for the operator-facing sequence.

## Consequences

- A green-field database plus a privileged role still works with no extra steps.
- A green-field database plus an unprivileged role fails **before creating any
  table**, with a message naming the extension, the SQL, and who must run it.
- Pre-provisioned extensions work on an unprivileged role, in both directions —
  migrate and roll back.
- Any entry point that runs these migrations gets this behaviour, including the
  release `eval` path used by deploys: the guard lives in the migration, not in
  a Mix task or a wrapper script.

## Verification

Run against a real PostgreSQL 18 server with a `LOGIN NOSUPERUSER NOCREATEDB
NOCREATEROLE` role holding `CREATE, USAGE` on `public` but no `CREATE` on the
database:

| Scenario | Result |
|---|---|
| Extensions pre-provisioned by `postgres`, all 23 migrations run as the limited role | All 23 up, then all 23 down; `citext` and `pg_trgm` still installed afterwards |
| Same role, extensions absent | Raises the `insufficient_privilege` message naming `citext`, before any table is created |
| Extensions installed into an unsearched schema | Raises the reachability message naming the schema and both `ALTER` statements |
| Same, seen from `mix vr.doctor` / `VR.Release.preflight!` | Reported as an error naming the same schema, role and `ALTER` statements — before the migration starts |

`backend/test/vr/migration_extension_guard_test.exs` holds the regression tests,
including the limited-role cases; it drives both migration copies of the guard so
the duplicates cannot drift apart.
