# 17. Runtime Config: What Each Entry Point Requires

**Decision record.** Settles which environment variables can stop which entry
point, and reverses an earlier decision that a malformed public-URL variable
must stop them all.

## The problem

A release evaluates `config/runtime.exs` for **every** command it is given.
`bin/vr start` and `bin/vr eval 'VR.Release.migrate()'` read the same file, and
the file used to state one undifferentiated set of requirements. That is how a
missing `SECRET_KEY_BASE` — a value no migration reads — became a deploy step
reporting `migration_failed`, with nothing about migrations in it.

Splitting the *missing-value* requirements (`docs/07-config-admin.md`, "Entry
points") fixed that for `SECRET_KEY_BASE` and `CLOAK_KEY`. It left the same
defect standing under a different name. Four variables describe how the world
reaches a **running** app:

| Variable | Sets |
|---|---|
| `PORT` | the port the app listens on |
| `HTTPS_PORT` | the dev-only TLS listener |
| `PHX_SCHEME` | the scheme in generated links |
| `PHX_URL_PORT` | the port in generated links |

A migration starts no Endpoint and generates no link, so it reads none of them.
Yet `PHX_SCHEME=htp` — one transposed character in a preview's configuration —
halted the migration step. Same failure shape, same wrong conclusion for the
operator reading the log: *the database preparation is broken*.

## What was decided before, and why it is reversed

The previous decision was explicit, and its test carried the rationale:

> The public URL is resolved at both entry points. A migration never reads it,
> but the same file resolves it, so a malformed value must fail the same way
> here as it does for the app — the alternative is a deploy whose migration
> step passes and whose next step fails on a value the migration already saw.

Two claims, and they are not equally good.

The first — *the same file resolves it* — describes the implementation, not the
requirement. `config/runtime.exs` resolving a value in one pass is an artifact
of how Elixir releases are configured; it says nothing about what the command
being run actually needs. The requirement question is "does this entry point
read the value", and the answer is no.

The second — *fail early rather than one step later* — is a real benefit, and it
is kept. What is dropped is the belief that halting is the only way to deliver
it. A warning naming the variable, printed by the migration step, tells the
operator the same thing at the same moment, without turning a preparation step
into a false negative.

## Decision

**`PORT` / `HTTPS_PORT` / `PHX_SCHEME` / `PHX_URL_PORT` halt only the app-boot
entry point. At `RELEASE_COMMAND=eval` a malformed value warns and the default
is used. `DATABASE_URL` stays a hard failure at both.**

| Value | `bin/vr start` · `mix phx.server` · Mix tasks | `bin/vr eval …` |
|---|---|---|
| `DATABASE_URL` missing | halts | **halts** — the migration genuinely reads it |
| `PORT`, `HTTPS_PORT`, `PHX_SCHEME`, `PHX_URL_PORT` malformed | halts | warns on stderr, continues on the default |
| `PORT`, `PHX_URL_PORT` empty | default | default (unchanged: empty has always meant "not decided") |

`RELEASE_COMMAND` is exported by the release launcher and is **unset** under
Mix, so `mix ecto.migrate`, `mix setup` and `mix phx.server` behave exactly as
before. Nothing about default *values* changes; only which entry point a wrong
value is fatal to.

### Why the app still halts

Unchanged, and worth restating because it is the other half of the rule. An
empty variable means "not decided" and takes the default. A malformed one means
"decided wrongly", and swallowing it silently produces the app that is up while
every health check fails, or up while every generated link points at an origin
that does not answer. Both are expensive to trace precisely because the process
looks healthy. The app halts.

### Why the migration warns instead of ignoring

The value is still wrong, and the operator who set it is usually one deploy step
away from meeting it again. So the migration step prints, once, to stderr:

```
[VR.Runtime] ignoring PHX_SCHEME and continuing with the default, https.

environment variable PHX_SCHEME is not a valid URL scheme: "ftp"

It must be one of:

    https   (default) the app is reached over TLS — directly or
            through a terminating proxy
    http    the app is reached over plain HTTP, as in a preview
            environment with no TLS in front of it

It sets the scheme of the links this app generates, not the one it
listens on. Leave it empty to use the default, https.

The database preparation entry point serves no requests and generates no
links, so this run does not read it. `bin/vr start` does, and halts on
this value until it is fixed.
```

The middle block is the **same text** the app halts with, quoted verbatim rather
than paraphrased, so an operator comparing a migration log against a boot log
matches them by eye. The last paragraph is what the warning adds: what this run
did, and which command will not tolerate it.

## Alternatives rejected

- **Keep halting everywhere.** The status quo. It makes a database preparation
  step fail on a value it does not read — the exact defect this Story exists to
  remove, one variable further along.
- **Ignore malformed values silently at `eval`.** Fixes the false negative and
  loses the early warning. The operator then meets the value at `bin/vr start`,
  after the migration reported success, with no hint that anything was seen.
- **Resolve the public URL only at the app-boot entry point.** Tempting — a
  value that is never resolved cannot fail. But then a *well-formed* value is
  never validated by the migration step either, and the config file grows a
  branch whose two halves produce different config trees for the same
  environment. Resolving everything and differing only in how a bad value is
  reported keeps one tree and one code path.

## Consequences

- A preview with a typo in `PHX_SCHEME` prepares its database, then fails to
  start with a message naming the variable — instead of failing to prepare with
  a message naming the variable.
- `deploy.toml`'s migration step can no longer fail on anything the migration
  does not use, except `DATABASE_URL`, which it does.
- The warning is not a log line to be tuned away: it is printed by the config
  file itself, before Logger exists in an `eval`, so it lands on stderr in the
  deploy output.
- Two identical texts now exist for each of the four variables — one raised, one
  quoted in a warning. They are the same string, built once, so they cannot
  drift; `backend/test/vr/runtime_config_test.exs` asserts the warning contains
  the raise message word for word.

## Verification

Against the release image (`_build/prod/rel/vr`) and a green-field PostgreSQL
database:

| Scenario | Result |
|---|---|
| `PHX_SCHEME=ftp PORT=8080a bin/vr eval 'VR.Release.migrate()'` | two warnings, then all 23 migrations applied, 31 tables created |
| The same command a second time | `Migrations already up`, exit 0 — rerun safe |
| `PHX_SCHEME=ftp bin/vr start` | `ERROR! Config provider Config.Reader failed with: ** (RuntimeError) environment variable PHX_SCHEME is not a valid URL scheme: "ftp"` — halts |
| `DATABASE_URL` unset, `bin/vr eval 'VR.Release.migrate()'` | still halts, naming `DATABASE_URL` and this entry point |
