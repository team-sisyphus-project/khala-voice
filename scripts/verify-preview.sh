#!/usr/bin/env bash
#
# Clean-checkout preview verification — the Mix path.
#
#     scripts/verify-preview.sh
#
# Runs the sequence README claims, end to end, and fails naming the step that
# broke: build the web app, create a green-field database, migrate, seed,
# start on PORT, and check that the first screen answers 200 over plain HTTP.
#
# **Plain HTTP is asserted, not assumed.** The run is handed PHX_SCHEME=http and
# no REDIS_URL, and then reads back what the server actually did: no hop of the
# first-screen chain redirects to https://, nothing sends
# Strict-Transport-Security, and the absolute links the app builds from its own
# config say http://. A preview sits behind a TLS terminator that speaks plain
# HTTP to this process — each of those three is a way it breaks while the status
# code still says 200.
#
# **The database is a throwaway.** Every run creates its own, named after this
# process, and drops it on the way out — passed or failed. That is what makes
# the run repeatable: a second run is as green-field as the first, so "it only
# works on a database that has already been migrated once" cannot hide here.
# The server it is created on is the one DATABASE_URL names; the database name
# in that URL is never touched.
#
# What it needs:
#
#     DATABASE_URL      required — the server to create the throwaway database
#                       on. Same form the app takes: ecto://USER:PASS@HOST/NAME
#     PORT              optional — what to start on. Default 4123
#     BOOTSTRAP_ADMIN_* optional — passed through to the seed. Without an
#                       address the seed skips the admin and says so
#
# SECRET_KEY_BASE and CLOAK_KEY are generated for the run when they are not
# already set, and are never written anywhere: they encrypt a database that
# stops existing a minute later. Set them yourself to verify with your own.
#
# This is not the release path. `bin/vr eval 'VR.Release.migrate();
# VR.Release.seed()'` runs these same two functions from inside the image —
# see README, "Deploying a preview (release image)".

set -euo pipefail

# 4000 is the app's own default, so it is the port a `mix phx.server` somebody
# left running is already on. Answering 200 from *that* server would be a pass
# this script has not earned, so it starts somewhere else and refuses the port
# when anything is already listening (see the `preflight` step).
DEFAULT_PORT=4123

# How long `mix phx.server` gets to answer /healthz before the run is called
# failed. Generous: the first start after a compile loads every module.
BOOT_TIMEOUT=90

KEEP_DB=false

usage() {
  cat <<'USAGE'
Verify the clean-checkout preview sequence against a throwaway database.

    scripts/verify-preview.sh [--port N] [--keep-db]

    --port N     start on N instead of PORT, or 4123 when PORT is unset
    --keep-db    leave the throwaway database behind to inspect it

    DATABASE_URL must be set — the throwaway database is created on the
    server it names. REDIS_URL is removed from the environment if you have
    one: nothing here reads it, and the run proves as much by not having it.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      [ $# -ge 2 ] || { echo "--port needs a number"; exit 2; }
      PORT="$2"
      shift 2
      ;;
    --port=*) PORT="${1#*=}"; shift ;;
    --keep-db) KEEP_DB=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$REPO_ROOT/backend"
WEB="$REPO_ROOT/apps/web"

PORT="${PORT:-$DEFAULT_PORT}"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-preview.XXXXXX")"
DB_NAME="vr_preview_verify_$$"
BASE_URL="http://localhost:$PORT"

SERVER_PID=""
DB_CREATED=false
THROWAWAY_URL=""
STEP=""
STEP_LOG=""
STEP_STARTED=0

# ── Output ───────────────────────────────────────────────────────
#
#  Same marks and the same aligned columns as `mix vr.doctor`, because an
#  operator reading this is reading the same kind of screen: one row per thing
#  that had to be true, and the row says which one was not.

say() { printf '%s\n' "$*"; }

# The mark column is two terminal cells wide, the width of ✅ — `mix vr.doctor`
# pads the one-cell marks the same way, and these rows sit next to its rows in
# the same terminal.
row() {
  local mark="$1" label="$2" detail="${3:-}"
  printf '  %s %-18s %s\n' "$mark" "$label" "$detail"
}

# A step's own output, kept under the row it belongs to. The seed's lines are
# the operator's record of what the run created — a generated admin password
# is printed exactly once, and this is that once — so they are shown, not
# filed away in a log nobody opens.
quote_log() {
  sed 's/^/       /' "$1"
}

step_start() {
  STEP="$1"
  STEP_LOG="$LOG_DIR/$STEP.log"
  STEP_STARTED=$SECONDS
  : > "$STEP_LOG"
}

elapsed() { printf '%ss' "$((SECONDS - STEP_STARTED))"; }

step_ok() {
  local detail="${1:-}"
  if [ -n "$detail" ]; then
    row "✅" "$STEP" "$(elapsed) — $detail"
  else
    row "✅" "$STEP" "$(elapsed)"
  fi
}

# Every failure leaves through here, so every failure names the step, quotes
# the command to fix, and says what state the run is being left in. Nothing
# below decides for itself how to report failing.
step_failed() {
  local reason="$1" command="${2:-}"

  say ""
  row "❌" "$STEP" "failed after $(elapsed)"
  say ""
  say "    step      $STEP"
  [ -n "$command" ] && say "    command   $command"
  say "    log       $STEP_LOG"
  say ""
  say "    $reason"

  say ""
  state_note
  say "    Fix the cause, then re-run:"
  say ""
  say "        scripts/verify-preview.sh"

  # The whole step is in the log; a `npm ci` that failed on its 300th line
  # would otherwise push the row that names the step off the screen.
  if [ -s "$STEP_LOG" ]; then
    say ""
    say "    The last 40 lines of that step:"
    say ""
    tail -n 40 "$STEP_LOG" | sed 's/^/    /'
  fi

  exit 1
}

# What this run is leaving behind. A failed step stops the sequence where it
# stands, so the next question is always "what do I have to undo before I try
# again" — and the answer here is nothing.
state_note() {
  if [ "$DB_CREATED" != true ]; then
    say "    No database was created."
  elif [ "$KEEP_DB" = true ]; then
    say "    The database $DB_NAME is kept, as asked."
  else
    say "    The throwaway database is dropped on the way out, so the next run"
    say "    starts green-field again."
  fi
}

# `run_in` and not `env -C`: the -C flag is GNU coreutils only, and README
# tells macOS developers to `brew install ffmpeg` and carry on with the env
# their system ships.
run_in() {
  local dir="$1"
  shift

  local status=0
  (cd "$dir" && "$@") >>"$STEP_LOG" 2>&1 || status=$?
  [ "$status" -eq 0 ] || step_failed "It exited $status." "$*"
}

# ── Plain HTTP ───────────────────────────────────────────────────
#
#  A preview sits behind a TLS terminator: the browser speaks https to the
#  terminator, the terminator speaks plain http to this process. Two response
#  headers break that arrangement while the status code still reads fine:
#
#    Location: https://…    the hop leaves plain http, and nothing answers https
#                          on this port. The chain dead-ends at the browser.
#
#    Strict-Transport-Security
#                          the browser writes the rule down and refuses plain
#                          http for this host from then on — not just for this
#                          run, and not just for this preview.
#
#  `force_ssl` is what produces both, and it is off. This is what keeps it off:
#  the headers are read out of what the run received, so turning it on turns
#  this run red instead of turning a preview into a dead link.

assert_plain_http() {
  local headers="$1" what="$2" hit

  hit="$(grep -i '^location:[[:space:]]*https://' "$headers" | head -n 1 || true)"
  if [ -n "$hit" ]; then
    step_failed "$what was redirected to https:

        $hit

    Behind a TLS terminator nothing answers https on this port, so a browser
    following that hop leaves the preview and never comes back. Serving over
    plain http means not upgrading the scheme — see force_ssl and PHX_SCHEME
    in config/runtime.exs."
  fi

  hit="$(grep -i '^strict-transport-security:' "$headers" | head -n 1 || true)"
  if [ -n "$hit" ]; then
    step_failed "$what carried an HSTS header:

        $hit

    A browser that reads this refuses plain http for this host afterwards —
    including on the next preview, and long after this run is over. A preview
    reached over plain http must not send it."
  fi
}

# ── Cleanup ──────────────────────────────────────────────────────
#
#  Runs on every exit, including a failed step and a Ctrl-C. It stops *this
#  run's* server by the pid the run kept, and drops *this run's* database by
#  the name the run chose — never by pattern. Something else's `mix phx.server`
#  on another port, and every other database on that server, are none of this
#  script's business.

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi

  if [ "$DB_CREATED" = true ]; then
    if [ "$KEEP_DB" = true ]; then
      say ""
      row "· " "kept" "$DB_NAME — drop it when you are done:"
      say "       cd backend && DATABASE_URL=<the same URL, ending in /$DB_NAME> \\"
      say "         MIX_ENV=prod mix ecto.drop --force"
    elif (cd "$BACKEND" && DATABASE_URL="$THROWAWAY_URL" MIX_ENV=prod mix ecto.drop --force --quiet) \
           >>"$LOG_DIR/cleanup.log" 2>&1; then
      DB_CREATED=false
      row "· " "dropped" "$DB_NAME"
    else
      say ""
      row "⚠️ " "cleanup" "$DB_NAME could not be dropped — see $LOG_DIR/cleanup.log"
    fi
  fi

  exit $status
}

trap cleanup EXIT INT TERM

# ── The throwaway URL ────────────────────────────────────────────
#
#  Everything in DATABASE_URL except the database name is kept: the same
#  server, the same role, the same query string (sslmode and friends). Only
#  the name is replaced, so the run connects exactly the way the app would.

throwaway_url() {
  local url="$1" query="" base

  case "$url" in
    *\?*) query="?${url#*\?}"; url="${url%%\?*}" ;;
  esac

  base="${url%/*}"

  if [ "$base" = "$url" ] || [ -z "$base" ]; then
    return 1
  fi

  printf '%s/%s%s' "$base" "$DB_NAME" "$query"
}

port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null
}

# ── 1. preflight ─────────────────────────────────────────────────

say ""
say "━━━ Clean-checkout preview verification (Mix path) ━━━"
say ""

step_start preflight

for tool in mix npm curl openssl; do
  command -v "$tool" >/dev/null 2>&1 || step_failed \
    "The command \`$tool\` is not on PATH.
    README's \"Development\" section lists what a checkout needs."
done

if [ -z "${DATABASE_URL:-}" ]; then
  step_failed "environment variable DATABASE_URL is missing.
    It names the server this run creates its throwaway database on.
    For example: ecto://USER:PASS@HOST/DATABASE — the database name in it is
    not used, so any reachable one will do."
fi

THROWAWAY_URL="$(throwaway_url "$DATABASE_URL")" || step_failed \
  "DATABASE_URL has no database name to replace: it must end in /NAME, as in
    ecto://USER:PASS@HOST/DATABASE."

case "$PORT" in
  ''|*[!0-9]*) port_ok=false ;;
  *) if [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then port_ok=true; else port_ok=false; fi ;;
esac

[ "$port_ok" = true ] || step_failed "PORT is not a port number: \"$PORT\".
    It must be an integer between 1 and 65535."

if port_in_use; then
  step_failed "Something is already listening on port $PORT.
    This run would then check that server's first screen and call it ours.
    Stop it, or choose another port:  scripts/verify-preview.sh --port 4200"
fi

export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -base64 48)}"
export CLOAK_KEY="${CLOAK_KEY:-$(openssl rand -base64 32)}"

# What the app is told it is reachable as. Plain http, no TLS terminator in
# front of it — the topology a preview has to work in, and the one the
# hardcoded https/443 default used to get wrong.
export MIX_ENV=prod
export PHX_HOST=localhost
export PHX_SCHEME=http
export PHX_URL_PORT="$PORT"
export APP_BASE_URL="$BASE_URL"
export DATABASE_URL="$THROWAWAY_URL"
export PORT

# Nothing in this repository reads REDIS_URL — background work runs on
# PostgreSQL — so a preview has to come up without one. It is *removed* rather
# than simply not set: inherited from the caller's shell it would be invisible
# here, and a run that passed only because somebody's environment happened to
# carry one would be evidence of the opposite of what this claims.
if [ -n "${REDIS_URL:-}" ]; then
  unset REDIS_URL
  redis_note="was set in this shell — removed for this run"
else
  redis_note="not set"
fi

step_ok "$DB_NAME on $PORT"
row "· " "REDIS_URL" "$redis_note"
row "· " "logs" "$LOG_DIR"

# ── 2. web build ─────────────────────────────────────────────────
#
#  `mix setup` does not build this, and priv/static/app is gitignored, so a
#  clean checkout serves an empty /app/ until it runs. It goes first because it
#  is the step that needs no database at all.

step_start web-build
run_in "$WEB" npm ci
run_in "$WEB" npm run build
step_ok "apps/web → backend/priv/static/app"

# ── 3. deps + compile ────────────────────────────────────────────

step_start deps
run_in "$BACKEND" mix deps.get --only prod
step_ok

step_start compile
run_in "$BACKEND" mix compile
run_in "$BACKEND" mix assets.deploy
step_ok "MIX_ENV=prod, assets digested"

# ── 4. database ──────────────────────────────────────────────────

step_start database
run_in "$BACKEND" mix ecto.create
DB_CREATED=true
step_ok "created $DB_NAME"

# ── 5. migrate ───────────────────────────────────────────────────
#
#  The same function the release path runs, reached the way Mix reaches it.
#  `--no-start` because migrating starts a repo, not an app: it is the closest
#  Mix gets to `bin/vr eval`, which runs on a system that was never booted.
#
#  And because nothing is started, nothing applies the log level config/prod.exs
#  sets — the level stays at Elixir's default and every Ecto query the two steps
#  run is echoed with its SQL. The seed's three lines are what an operator has
#  to read here, so the level this environment already declares is applied by
#  hand. `mix vr.doctor` quiets itself the same way, for the same reason.

APPLY_LOG_LEVEL='Logger.configure(level: Application.get_env(:logger, :level, :info));'

step_start migrate
run_in "$BACKEND" mix run --no-start -e "$APPLY_LOG_LEVEL VR.Release.migrate()"
step_ok "$(grep -c ' Migrated ' "$STEP_LOG" || true) migrations applied"

# ── 6. seed ──────────────────────────────────────────────────────

# The entry point is passed in, so the seed's own messages name the command
# that reaches it. From here that command is this script — telling an operator
# who has no admin to re-run `bin/vr eval` would send them to the release path
# they are not on. `priv/repo/seeds.exs` passes its own for the same reason.
step_start seed
run_in "$BACKEND" mix run --no-start \
  -e "$APPLY_LOG_LEVEL VR.Release.seed(entry_point: \"scripts/verify-preview.sh\")"
step_ok
quote_log "$STEP_LOG"

# ── 7. start ─────────────────────────────────────────────────────

step_start start
(cd "$BACKEND" && exec mix phx.server) >>"$STEP_LOG" 2>&1 &
SERVER_PID=$!

deadline=$((SECONDS + BOOT_TIMEOUT))

until curl -fsS -o /dev/null "$BASE_URL/healthz" 2>/dev/null; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    SERVER_PID=""
    step_failed "The server stopped before it answered $BASE_URL/healthz." "mix phx.server"
  fi

  if [ "$SECONDS" -ge "$deadline" ]; then
    step_failed "The server did not answer $BASE_URL/healthz within ${BOOT_TIMEOUT}s.
    It is still running, so it is starting slowly, or listening somewhere
    other than $PORT." "mix phx.server"
  fi

  sleep 0.5
done

step_ok "listening on $BASE_URL"

# ── 8. healthz ───────────────────────────────────────────────────

step_start healthz
body="$(curl -fsS "$BASE_URL/healthz")" || step_failed \
  "GET /healthz did not answer." "curl $BASE_URL/healthz"

[ "$body" = "ok" ] || step_failed \
  "GET /healthz answered \"$body\", not \"ok\"." "curl $BASE_URL/healthz"

step_ok "200 ok"

# ── 9. first screen ──────────────────────────────────────────────
#
#  The one assertion the whole run exists for. `-L` because / is a redirect:
#  what has to be 200 is where it lands, over plain http, with nothing in
#  front of it.
#
#  Every hop's headers are kept. The next step reads them; this one reads them
#  only when the request could not be finished, because "a hop went to https"
#  is a far more useful answer there than "curl exited 35".

step_start first-screen
CHAIN_HEADERS="$LOG_DIR/first-screen.headers"
: > "$CHAIN_HEADERS"

if ! result="$(curl -sS -L -D "$CHAIN_HEADERS.raw" -o /dev/null \
                 -w '%{http_code} %{num_redirects} %{url_effective}' \
                 "$BASE_URL/" 2>>"$STEP_LOG")"; then
  # Header lines arrive CRLF-terminated. The CR comes off once, here, so the
  # patterns below can anchor on the end of a value.
  tr -d '\r' < "$CHAIN_HEADERS.raw" > "$CHAIN_HEADERS"
  assert_plain_http "$CHAIN_HEADERS" "GET /"
  step_failed "GET / could not be completed." "curl -L $BASE_URL/"
fi

tr -d '\r' < "$CHAIN_HEADERS.raw" > "$CHAIN_HEADERS"

status="${result%% *}"
rest="${result#* }"
redirects="${rest%% *}"
landed="${rest#* }"

[ "$status" = "200" ] || step_failed \
  "GET / answered $status, not 200.
    It landed on $landed after $redirects redirect(s)." \
  "curl -L $BASE_URL/"

step_ok "200 at $landed after $redirects redirect(s)"

# ── 10. plain http ───────────────────────────────────────────────
#
#  The 200 above says the screen exists. This says it is reachable the way a
#  preview is actually reached — behind a terminator that speaks plain http to
#  this process — which the status code alone cannot show.

step_start plain-http

assert_plain_http "$CHAIN_HEADERS" "The chain from GET /"

# The same chain again, under a name that is not `localhost`.
#
# `Plug.SSL` — what `force_ssl` installs — exempts `localhost` and `127.0.0.1`
# from its https redirect by default. So asking *this* host whether it upgrades
# the scheme gets the answer this run wants for a reason that has nothing to do
# with the answer: a preview served on a platform hostname would upgrade, and
# the check above would still be green. Resolving a name of our own to the same
# loopback address reaches the same server without that exemption.
#
# Only the headers are read. What a foreign Host name renders is the app's
# business; whether it is told to leave plain http is this run's.
FOREIGN_HOST="preview.verify.test"
FOREIGN_HEADERS="$LOG_DIR/plain-http.foreign-host.headers"
: > "$FOREIGN_HEADERS.raw"

foreign_reached=true
curl -sS -L --resolve "$FOREIGN_HOST:$PORT:127.0.0.1" \
     -D "$FOREIGN_HEADERS.raw" -o /dev/null \
     "http://$FOREIGN_HOST:$PORT/" 2>>"$STEP_LOG" || foreign_reached=false

tr -d '\r' < "$FOREIGN_HEADERS.raw" > "$FOREIGN_HEADERS"
assert_plain_http "$FOREIGN_HEADERS" "The chain from GET / as $FOREIGN_HOST"

[ "$foreign_reached" = true ] || step_failed \
  "GET http://$FOREIGN_HOST:$PORT/ could not be completed.
    That is this same server, reached under a host name that is not exempt
    from an https upgrade — which is how a preview is actually reached." \
  "curl -L --resolve $FOREIGN_HOST:$PORT:127.0.0.1 http://$FOREIGN_HOST:$PORT/"

case "$landed" in
  http://*) ;;
  *) step_failed "The first screen was reached at

        $landed

    which is not plain http. The 200 above was answered by something other
    than this run's server." "curl -L $BASE_URL/" ;;
esac

# What the app *generates*, as against what it answered. Every absolute link
# in the app — invite links, confirmation mails, the OAuth callback — is built
# from one `url:` config, and the document below is built from that same
# config and needs no account to read. So it is the one place this run can see
# that config's effect from outside. Get it wrong and every screen still loads
# 200 while every link leading off one goes nowhere.
PROBE_PATH="/.well-known/oauth-protected-resource"
PROBE_HEADERS="$LOG_DIR/plain-http.headers"

probe_body="$(curl -fsS -D "$PROBE_HEADERS.raw" "$BASE_URL$PROBE_PATH" 2>>"$STEP_LOG")" \
  || step_failed "GET $PROBE_PATH did not answer.
    It is what tells this run which scheme the app stamps onto the links it
    generates." "curl $BASE_URL$PROBE_PATH"

tr -d '\r' < "$PROBE_HEADERS.raw" > "$PROBE_HEADERS"
assert_plain_http "$PROBE_HEADERS" "GET $PROBE_PATH"

generated="$(printf '%s' "$probe_body" | sed -n 's/.*"resource":"\([^"]*\)".*/\1/p')"

[ -n "$generated" ] || step_failed \
  "GET $PROBE_PATH answered without a \"resource\" URL in it, so this run
    cannot read which scheme the app generates. What it answered:

        $probe_body" "curl $BASE_URL$PROBE_PATH"

# Phoenix leaves the port out of a generated URL when it is the scheme's own
# default, so on port 80 the expected string has no port either.
if [ "$PORT" = "80" ]; then
  expected="http://localhost/mcp"
else
  expected="$BASE_URL/mcp"
fi

[ "$generated" = "$expected" ] || step_failed \
  "The app generates its absolute links as

        $generated

    but it is being served at $BASE_URL, so they should read

        $expected

    PHX_SCHEME and PHX_URL_PORT are what set this — see config/runtime.exs." \
  "curl $BASE_URL$PROBE_PATH"

step_ok "no https hop, no HSTS, links $generated"

# ── Done ─────────────────────────────────────────────────────────

say ""
say "  ✅ The clean-checkout sequence works. Green-field database, built,"
say "     migrated, seeded, started on $PORT with no REDIS_URL, first screen"
say "     200 over plain http — no https hop, no HSTS, http:// links."
say ""
