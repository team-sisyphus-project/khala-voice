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
    server it names.
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

step_ok "$DB_NAME on $PORT"
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

step_start first-screen
result="$(curl -sS -L -o /dev/null -w '%{http_code} %{num_redirects} %{url_effective}' "$BASE_URL/")" \
  || step_failed "GET / could not be completed." "curl -L $BASE_URL/"

status="${result%% *}"
rest="${result#* }"
redirects="${rest%% *}"
landed="${rest#* }"

[ "$status" = "200" ] || step_failed \
  "GET / answered $status, not 200.
    It landed on $landed after $redirects redirect(s)." \
  "curl -L $BASE_URL/"

step_ok "200 at $landed after $redirects redirect(s)"

# ── Done ─────────────────────────────────────────────────────────

say ""
say "  ✅ The clean-checkout sequence works. Green-field database, built,"
say "     migrated, seeded, started on $PORT, first screen 200 over plain http."
say ""
