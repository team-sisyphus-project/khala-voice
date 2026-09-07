#!/usr/bin/env bash
#
# Clean-checkout preview verification.
#
#     scripts/verify-preview.sh              # the Mix path, run from source
#     scripts/verify-preview.sh --release    # the release image, via docker
#
# Runs the sequence README claims, end to end, and fails naming the step that
# broke: build, create a green-field database, migrate, seed, start on PORT,
# and check that the first screen answers 200 over plain HTTP.
#
# **Two modes, one set of assertions.** Everything from `start` onwards —
# healthz, first-screen, plain-http — is the same code in both, asking the same
# questions of whatever is listening on PORT. What differs is how the thing
# answering was built and prepared:
#
#     Mix path       npm ci, mix deps.get, mix compile, mix ecto.create,
#                    VR.Release.migrate/0 and VR.Release.seed/1 reached through
#                    `mix run --no-start`, then `mix phx.server`.
#
#     Release image  `docker build` from the repository root, then every other
#                    step through `bin/vr` inside a container: deploy.toml's
#                    line `bin/vr eval 'VR.Release.migrate();
#                    VR.Release.seed()'`, and the image's own CMD,
#                    `bin/vr start`.
#
# **Both modes check detection first.** One `detect` step reads the repository
# root and fails when it names more than one way to build, when the Dockerfile
# stops declaring a CMD, or when deploy.toml stops declaring the database,
# preparation and health path. Those three are the whole reason this repository
# carries no `preview.toml`: an explicit preview configuration exists to answer
# what a checkout leaves ambiguous, and this one leaves nothing. The step is
# there so that stops being a sentence and starts being a run that can go red.
#
# The release mode is the one that answers "does a *clean checkout* work".
# `.dockerignore` drops `_build`, `deps` and `node_modules` from the build
# context, so the image is built from the tracked tree no matter what state the
# worktree is in — where the Mix path compiles into whatever `_build` is
# already sitting there. It is also handed exactly the six values README's
# preview table marks required, by name: DATABASE_URL, PORT, SECRET_KEY_BASE,
# CLOAK_KEY, PHX_HOST, PHX_SCHEME. An APP_BASE_URL or PHX_URL_PORT inherited
# from the calling shell does not reach the container.
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
# `--release` additionally needs docker, and **skips with exit 0** when it is
# not there: a machine without docker has not failed a preview, it has not
# looked at one. The `preflight` row says which of the two happened.
#
# The container runs on docker's host network, so DATABASE_URL is read from
# inside it exactly as the host reads it, and PORT is bound where the same curl
# commands reach it. That is the default on Linux; Docker Desktop needs host
# networking turned on.

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

# Which of the two things this run verifies. `mix` is the default: README
# quotes the bare command, and it is the mode that needs no daemon.
MODE=mix

# A stable tag, not one per run. A second run then reuses the layer cache
# instead of rebuilding Elixir from scratch, and no run leaves a dangling tag
# behind. `docker rmi` it when you are done — this script never does, because
# throwing away a cache the next run wants is not cleanup.
IMAGE_TAG="khala-voice:preview-verify"

# What the app is told it is reachable as. Plain http, no TLS terminator in
# front of it — the topology a preview has to work in, and the one the
# hardcoded https/443 default used to get wrong.
PHX_HOST=localhost

usage() {
  cat <<'USAGE'
Verify the clean-checkout preview sequence against a throwaway database.

    scripts/verify-preview.sh [--release] [--port N] [--keep-db]

    --release    verify the release image instead of the Mix path: docker
                 build, then migrate, seed and start through bin/vr inside
                 a container. Skips with exit 0 when docker is unavailable
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
    --release) MODE=release; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$REPO_ROOT/backend"
WEB="$REPO_ROOT/apps/web"

PORT="${PORT:-$DEFAULT_PORT}"

# The command that re-runs *this* run. `--release` has to survive into the
# failure block: an operator who was checking the image and is handed the Mix
# path's command goes and checks the other thing (see the seed's :entry_point,
# for the same reason).
if [ "$MODE" = release ]; then
  RERUN_COMMAND="scripts/verify-preview.sh --release"
else
  RERUN_COMMAND="scripts/verify-preview.sh"
fi
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-preview.XXXXXX")"
DB_NAME="vr_preview_verify_$$"
BASE_URL="http://localhost:$PORT"

SERVER_PID=""
DB_CREATED=false
THROWAWAY_URL=""
STEP=""
STEP_LOG=""
STEP_STARTED=0

# Release mode only. Named after this process for the same reason the database
# is: cleanup removes *this run's* container by that name, never by pattern.
CONTAINER_NAME="vr-preview-verify-$$"
CONTAINER_STARTED=false
LOGS_PID=""

# What the app is expected to stamp onto the links it generates. The two modes
# ask for different things, so they expect different strings — see the
# `plain-http` step.
EXPECTED_LINK=""

# `bin/vr eval` expressions. Creating and dropping a database is what
# `mix ecto.create` / `mix ecto.drop` do, and this is those two tasks' own
# implementation — `repo.__adapter__().storage_up(repo.config())` — reached
# from a release, where there is no Mix to run the task. Nothing else in the
# release path can bring a green-field database into existence, and requiring
# `mix` on the host to prepare one would be verifying the release path with the
# Mix path's tools.
#
# `{:error, :already_up}` is a failure here, not a no-op: this run's whole
# claim is that the sequence works on a database that has never been migrated.
# Creating says so in a sentence because it is a step with a row of its own to
# explain; dropping is a strict match, because it runs from `cleanup`, which
# has its own row and its own log to point at.
#
# The long line stays one line: it is quoted verbatim as that step's `command`,
# and something an operator is meant to paste is not broken across lines.
DB_CREATE_EVAL='Application.load(:vr); case VR.Repo.__adapter__().storage_up(VR.Repo.config()) do :ok -> :ok; {:error, :already_up} -> raise "the database already exists, so this run would not be green-field"; {:error, reason} -> raise "the database could not be created: #{inspect(reason)}" end'
DB_DROP_EVAL='Application.load(:vr); :ok = VR.Repo.__adapter__().storage_down(VR.Repo.config())'

# The line deploy.toml carries, character for character. Splitting it into a
# migrate step and a seed step would give two tidier rows and verify a command
# no platform runs.
PREPARE_EVAL='VR.Release.migrate(); VR.Release.seed()'

# What the container is given, by name and not by value. `-e NAME` passes this
# shell's value through; `-e NAME=value` would write CLOAK_KEY into the
# container's argv, where `ps` shows it to every user on the host. Docker drops
# a name that is unset here, which is also how BOOTSTRAP_ADMIN_* stay optional.
#
# The first six are README's preview table, and there is no seventh. That is
# the claim this mode is making, so the list is the claim's only enforcement.
DOCKER_ENV=(
  -e DATABASE_URL
  -e PORT
  -e SECRET_KEY_BASE
  -e CLOAK_KEY
  -e PHX_HOST
  -e PHX_SCHEME
  -e BOOTSTRAP_ADMIN_EMAIL
  -e BOOTSTRAP_ADMIN_PASSWORD
)

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

# The same lines out of a log that also holds the migration's. The release path
# runs migrate and seed as one command, so the two share a log; everything from
# the first `[seeds]` line to the end is the seed's, because `VR.Release.seed/1`
# runs after `migrate/0` and prints nothing before its first row.
quote_seed_log() {
  sed -n '/^\[seeds\]/,$p' "$1" | sed 's/^/       /'
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
  say "        $RERUN_COMMAND"

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

# Not a pass and not a failure: this machine cannot run the check at all.
#
# It exits 0, so it has to be unmistakable in the output — a caller who reads
# only the status code will read this as a pass, and the row is the only thing
# standing between them and that. So the mark is `·`, the one this file already
# uses for "could not be judged", the detail begins with `not checked`, and the
# block says in a sentence that nothing was asserted.
skip_run() {
  local reason="$1" detail="$2"

  row "· " "$STEP" "not checked — $reason"
  say ""
  say "    step      $STEP"
  say "    reason    $reason"
  say ""
  say "$detail"
  say ""
  say "    Nothing was built and no database was created, so this run asserts"
  say "    nothing about the preview. It exits 0 because a check this machine"
  say "    cannot run is not a broken preview — read the row, not the status"
  say "    code."
  say ""

  exit 0
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

  if [ "$MODE" = release ] && [ "$CONTAINER_STARTED" = true ]; then
    say "    The container goes with it. The image $IMAGE_TAG is kept,"
    say "    so the next run rebuilds only the layers that changed."
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

# `run_in` for a command that goes through docker.
#
# The `command` an operator is shown is passed in separately from the argv,
# because on this path the two are not the same sentence. What ran is
# `docker run --rm --network host -e … -e … image bin/vr eval …`; what they
# would fix is `bin/vr eval '…'`, the line deploy.toml carries, with 150
# characters of this script's plumbing taken off the front. The full argv is
# the step log's first line, so nothing is hidden — it is just not the answer
# to "what failed".
run_docker() {
  local shown="$1"
  shift

  printf '$ %s\n' "$*" >>"$STEP_LOG"

  local status=0
  "$@" >>"$STEP_LOG" 2>&1 || status=$?
  [ "$status" -eq 0 ] || step_failed "It exited $status." "$shown"
}

# Is the thing this run started still up? The Mix path has a pid; the release
# path has a container, and a container that exited is not a pid that died.
server_running() {
  if [ "$MODE" = release ]; then
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]
  else
    [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null
  fi
}

# Dropping this run's database, by the same route the run created it: Mix's
# task on the Mix path, the release's own storage_down inside the image on the
# release path. Neither is given a database name it did not choose.
drop_database() {
  if [ "$MODE" = release ]; then
    docker run --rm --network host "${DOCKER_ENV[@]}" "$IMAGE_TAG" \
      bin/vr eval "$DB_DROP_EVAL"
  else
    (cd "$BACKEND" && DATABASE_URL="$THROWAWAY_URL" MIX_ENV=prod mix ecto.drop --force --quiet)
  fi
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

  if [ -n "$LOGS_PID" ] && kill -0 "$LOGS_PID" 2>/dev/null; then
    kill "$LOGS_PID" 2>/dev/null || true
    wait "$LOGS_PID" 2>/dev/null || true
  fi

  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi

  # Before the database, because the release path drops it from inside the
  # image and a running container still holds connections to it.
  if [ "$CONTAINER_STARTED" = true ]; then
    CONTAINER_STARTED=false
    docker rm -f "$CONTAINER_NAME" >>"$LOG_DIR/cleanup.log" 2>&1 || true
  fi

  if [ "$DB_CREATED" = true ]; then
    if [ "$KEEP_DB" = true ]; then
      say ""
      row "· " "kept" "$DB_NAME — drop it when you are done:"
      if [ "$MODE" = release ]; then
        say "       DATABASE_URL=<the same URL, ending in /$DB_NAME> \\"
        say "         docker run --rm --network host -e DATABASE_URL $IMAGE_TAG \\"
        say "         bin/vr eval '$DB_DROP_EVAL'"
      else
        say "       cd backend && DATABASE_URL=<the same URL, ending in /$DB_NAME> \\"
        say "         MIX_ENV=prod mix ecto.drop --force"
      fi
    elif drop_database >>"$LOG_DIR/cleanup.log" 2>&1; then
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
if [ "$MODE" = release ]; then
  say "━━━ Clean-checkout preview verification (release image) ━━━"
else
  say "━━━ Clean-checkout preview verification (Mix path) ━━━"
fi
say ""

step_start preflight

# What each mode actually calls. Refusing a machine for want of `mix` when the
# run never types it would turn this check into its own obstacle.
if [ "$MODE" = release ]; then
  REQUIRED_TOOLS="curl openssl"
else
  REQUIRED_TOOLS="mix npm curl openssl"
fi

for tool in $REQUIRED_TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || step_failed \
    "The command \`$tool\` is not on PATH.
    README's \"Development\" section lists what a checkout needs."
done

# Docker first, and before anything is created: with no docker there is no
# release mode to run, and everything checked below would be checked for a run
# that is not going to happen.
if [ "$MODE" = release ]; then
  command -v docker >/dev/null 2>&1 || skip_run "docker is not on PATH" \
    "    The release mode builds the image and runs every step inside it — the
    build, the preparation eval, and the server. There is no part of it
    docker is not needed for.

    Install docker, or check the same sequence from source:

        scripts/verify-preview.sh"

  if ! docker_info="$(docker info 2>&1 >/dev/null)"; then
    skip_run "the docker daemon is not reachable" \
      "    docker is on PATH, but \`docker info\` did not answer:

$(printf '%s\n' "$docker_info" | head -n 3 | sed 's/^/        /')

    Start it, or check the same sequence from source:

        scripts/verify-preview.sh"
  fi
fi

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

# Plain http and nothing else, in both modes.
export PHX_HOST
export PHX_SCHEME=http
export DATABASE_URL="$THROWAWAY_URL"
export PORT

# Where the two modes part, and it is deliberate.
#
# The release mode is handed the six values README's preview table marks
# required and no others, because that is what it claims a preview needs. A
# platform preview listens on PORT and is reached through something in front of
# it at the scheme's own port, so the links it generates carry no port at all.
# Setting PHX_URL_PORT here would make the assertion in `plain-http` easier to
# write and the topology wrong.
#
# The Mix path has nothing in front of it: it is reached on the very port it
# listens on, so that is the port its links have to carry.
if [ "$MODE" = release ]; then
  EXPECTED_LINK="http://$PHX_HOST/mcp"
else
  export MIX_ENV=prod
  export PHX_URL_PORT="$PORT"
  export APP_BASE_URL="$BASE_URL"

  if [ "$PORT" = "80" ]; then
    EXPECTED_LINK="http://$PHX_HOST/mcp"
  else
    EXPECTED_LINK="$BASE_URL/mcp"
  fi
fi

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

# ── 2. detect ────────────────────────────────────────────────────
#
#  Why this repository needs no `preview.toml`, checked rather than asserted.
#
#  A platform reads a checkout and has to answer two questions on its own: how
#  do I build this, and how do I start what I built. An explicit preview
#  configuration exists for when the checkout does not answer them — when the
#  root offers two plausible builds, or the built artifact does not say how it
#  runs. This repository answers both, and the rest of this run is the evidence:
#  `image` builds with `docker build .` and no `-f`, and `start` runs the
#  container with **no command argument**, so the server that answers `healthz`
#  was started by the image's own CMD and nothing else.
#
#  What that leaves is the part a passing run cannot notice: the answer stops
#  being singular the day a second build descriptor lands at the root. A stray
#  `package-lock.json` sat there for exactly that reason once — six lines, no
#  `package.json` beside it, describing no build, and readable by any detector
#  that keys on lockfiles. This step is what turns "there is only one" from a
#  sentence somebody wrote into something a run can contradict.
#
#  It runs in both modes. The release mode is the one that proves the image,
#  and it is also the one that skips on a machine without docker — a guard that
#  only ran there would be off on every CI push.

# The names build detection keys on, at the repository root. Not a list of
# every file a language uses: a marker is a file whose *presence at the root*
# is taken as "this is a project of that kind". Anything under a subdirectory
# is addressed by the Dockerfile, which is why `apps/web/package.json` and
# `backend/mix.exs` are not detection surface and are not listed.
DETECTOR_MARKERS="
  Dockerfile Containerfile
  docker-compose.yml docker-compose.yaml compose.yml compose.yaml
  Procfile app.json nixpacks.toml .buildpacks
  fly.toml render.yaml railway.toml railway.json vercel.json netlify.toml
  package.json package-lock.json yarn.lock pnpm-lock.yaml bun.lockb
  mix.exs elixir_buildpack.config phoenix_static_buildpack.config
  requirements.txt pyproject.toml Pipfile runtime.txt
  go.mod Gemfile Cargo.toml composer.json pom.xml
  build.gradle build.gradle.kts
"

step_start detect

found=""
for marker in $DETECTOR_MARKERS; do
  if [ -e "$REPO_ROOT/$marker" ]; then
    found="$found $marker"
  fi
done
found="${found# }"

if [ -z "$found" ]; then
  step_failed "The repository root carries no build descriptor at all.
    Something removed the Dockerfile. Nothing here can tell a platform how to
    build this checkout, and an explicit preview configuration would only name
    a file that is gone."
fi

if [ "$found" != "Dockerfile" ]; then
  step_failed "The repository root names more than one way to build:

$(printf '%s\n' $found | sed 's/^/        /')

    Detection was unambiguous when it was decided that this repository needs
    no preview.toml, and that is no longer true. Either the extra file
    describes nothing and should go, or it describes a real second build — in
    which case something has to say which one a preview takes, and the
    decision it overturns has to be re-settled rather than quietly broken." \
    "ls \$REPO_ROOT"
fi

# The run half. `start` runs the container with no command, so a Dockerfile
# that stopped declaring one would fail there — but it would fail as a server
# that never came up, 90 seconds later, with the reason two steps away from the
# cause.
grep -q '^CMD ' "$REPO_ROOT/Dockerfile" || step_failed \
  "The Dockerfile declares no CMD.
    Then the image does not say how to start it, and a platform has to be told
    — which is the case an explicit preview configuration exists for. This run
    starts the container without a command precisely because the image carries
    one." \
    "grep '^CMD ' Dockerfile"

# The three things the image genuinely cannot state about itself: that it wants
# a database, what to run before first boot, and where to ask whether it is up.
# deploy.toml already states all three. A preview.toml would restate them.
for key in database migrate healthcheck; do
  grep -q "^$key[[:space:]]*=" "$REPO_ROOT/deploy.toml" || step_failed \
    "deploy.toml has no \`$key\` key.
    It is where this repository states the parts of a preview the image cannot
    carry — that it needs a database, the preparation command, and the health
    path. Dropping one moves that part back to being undeclared." \
    "grep '^$key' deploy.toml"
done

step_ok "Dockerfile + deploy.toml, one build descriptor at the root"


if [ "$MODE" = release ]; then

# ── 3. image ─────────────────────────────────────────────────────
#
#  The whole build, in one command, from the repository root. `.dockerignore`
#  keeps `_build`, `deps` and `node_modules` out of the context, so this is a
#  clean checkout being built whatever the worktree looks like — which is the
#  reason this mode exists. The Dockerfile does the rest: the React app, then
#  the Elixir release with those assets copied in.

step_start image
run_docker "docker build -t $IMAGE_TAG ." \
  docker build -t "$IMAGE_TAG" "$REPO_ROOT"
step_ok "built $IMAGE_TAG"

# ── 4. database ──────────────────────────────────────────────────
#
#  A platform hands over a database that already exists; this run has to make
#  one, and has to make it the way the release can — there is no `mix` in the
#  image. `DB_CREATE_EVAL` is what `mix ecto.create` itself runs.

step_start database
run_docker "bin/vr eval '$DB_CREATE_EVAL'" \
  docker run --rm --network host "${DOCKER_ENV[@]}" "$IMAGE_TAG" \
    bin/vr eval "$DB_CREATE_EVAL"
DB_CREATED=true
step_ok "created $DB_NAME"

# ── 5. prepare ───────────────────────────────────────────────────
#
#  deploy.toml's line, run as deploy.toml runs it. One row for both halves
#  because it is one command: splitting it would read better and verify a
#  command no platform types.

step_start prepare
run_docker "bin/vr eval '$PREPARE_EVAL'" \
  docker run --rm --network host "${DOCKER_ENV[@]}" "$IMAGE_TAG" \
    bin/vr eval "$PREPARE_EVAL"

# The count comes out of the migrator's own log lines, and `bin/vr eval` starts
# no Logger of its own. When they are not there the row says what the step did
# and no number: "0 migrations applied" after a successful migration would be a
# figure this run never read.
migrated="$(grep -c ' Migrated ' "$STEP_LOG" || true)"
if [ "$migrated" -gt 0 ]; then
  step_ok "$migrated migrations applied, then seeded"
else
  step_ok "migrated, then seeded"
fi
quote_seed_log "$STEP_LOG"

else

# ── 3. web build ─────────────────────────────────────────────────
#
#  `mix setup` does not build this, and priv/static/app is gitignored, so a
#  clean checkout serves an empty /app/ until it runs. It goes first because it
#  is the step that needs no database at all.

step_start web-build
run_in "$WEB" npm ci
run_in "$WEB" npm run build
step_ok "apps/web → backend/priv/static/app"

# ── 4. deps + compile ────────────────────────────────────────────

step_start deps
run_in "$BACKEND" mix deps.get --only prod
step_ok

step_start compile
run_in "$BACKEND" mix compile
run_in "$BACKEND" mix assets.deploy
step_ok "MIX_ENV=prod, assets digested"

# ── 5. database ──────────────────────────────────────────────────

step_start database
run_in "$BACKEND" mix ecto.create
DB_CREATED=true
step_ok "created $DB_NAME"

# ── 6. migrate ───────────────────────────────────────────────────
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

# ── 7. seed ──────────────────────────────────────────────────────

# The entry point is passed in, so the seed's own messages name the command
# that reaches it. From here that command is this script — telling an operator
# who has no admin to re-run `bin/vr eval` would send them to the release path
# they are not on. `priv/repo/seeds.exs` passes its own for the same reason.
step_start seed
run_in "$BACKEND" mix run --no-start \
  -e "$APPLY_LOG_LEVEL VR.Release.seed(entry_point: \"scripts/verify-preview.sh\")"
step_ok
quote_log "$STEP_LOG"

fi

# ── 8. start ─────────────────────────────────────────────────────

step_start start

if [ "$MODE" = release ]; then
  # No command: `bin/vr start` is the image's own CMD, and starting the
  # container normally is the thing a platform does. Naming the command here
  # would verify one this deployment does not use.
  #
  # Detached, then `docker logs -f` into the step log, so this step reads the
  # way the Mix path's does — something running in the background with its
  # output accumulating in one file. `--network host` is what puts PORT on this
  # host, where the requests below are made from.
  SERVER_COMMAND="bin/vr start"
  printf '$ docker run -d --name %s --network host %s\n' \
    "$CONTAINER_NAME" "$IMAGE_TAG" >>"$STEP_LOG"

  docker run -d --name "$CONTAINER_NAME" --network host "${DOCKER_ENV[@]}" \
    "$IMAGE_TAG" >>"$STEP_LOG" 2>&1 \
    || step_failed "The container could not be started." "docker run $IMAGE_TAG"

  CONTAINER_STARTED=true
  docker logs -f "$CONTAINER_NAME" >>"$STEP_LOG" 2>&1 &
  LOGS_PID=$!
else
  SERVER_COMMAND="mix phx.server"
  (cd "$BACKEND" && exec mix phx.server) >>"$STEP_LOG" 2>&1 &
  SERVER_PID=$!
fi

deadline=$((SECONDS + BOOT_TIMEOUT))

until curl -fsS -o /dev/null "$BASE_URL/healthz" 2>/dev/null; do
  if ! server_running; then
    SERVER_PID=""
    step_failed "The server stopped before it answered $BASE_URL/healthz." \
      "$SERVER_COMMAND"
  fi

  if [ "$SECONDS" -ge "$deadline" ]; then
    if [ "$MODE" = release ]; then
      # The third possibility is this script's own doing, so it is this
      # script's to name: it chose host networking, and Docker Desktop has to
      # be told to allow it.
      step_failed "The server did not answer $BASE_URL/healthz within ${BOOT_TIMEOUT}s.
    The container is still running, so it is starting slowly, listening
    somewhere other than $PORT, or not on this host's network —
    \`docker run --network host\` is what puts its port here." "$SERVER_COMMAND"
    else
      step_failed "The server did not answer $BASE_URL/healthz within ${BOOT_TIMEOUT}s.
    It is still running, so it is starting slowly, or listening somewhere
    other than $PORT." "$SERVER_COMMAND"
    fi
  fi

  sleep 0.5
done

step_ok "listening on $BASE_URL"

# ── 9. healthz ───────────────────────────────────────────────────

step_start healthz
body="$(curl -fsS "$BASE_URL/healthz")" || step_failed \
  "GET /healthz did not answer." "curl $BASE_URL/healthz"

[ "$body" = "ok" ] || step_failed \
  "GET /healthz answered \"$body\", not \"ok\"." "curl $BASE_URL/healthz"

step_ok "200 ok"

# ── 10. first screen ─────────────────────────────────────────────
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

# ── 11. plain http ───────────────────────────────────────────────
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

# What the string should be was decided in `preflight`, where the two modes'
# configurations were. Phoenix leaves the port out of a generated URL when it is
# the scheme's own default, which is why the release mode — given no
# PHX_URL_PORT, as a platform preview is — expects no port here.
[ "$generated" = "$EXPECTED_LINK" ] || step_failed \
  "The app generates its absolute links as

        $generated

    but it was configured to be reached at

        $EXPECTED_LINK

    PHX_SCHEME and PHX_URL_PORT are what set this — see config/runtime.exs." \
  "curl $BASE_URL$PROBE_PATH"

step_ok "no https hop, no HSTS, links $generated"

# ── Done ─────────────────────────────────────────────────────────

say ""
if [ "$MODE" = release ]; then
  say "  ✅ The release image works from a clean checkout. Built by docker,"
  say "     green-field database, prepared by deploy.toml's own eval line,"
  say "     started on $PORT from six variables and no REDIS_URL, first screen"
  say "     200 over plain http — no https hop, no HSTS, http:// links."
else
  say "  ✅ The clean-checkout sequence works. Green-field database, built,"
  say "     migrated, seeded, started on $PORT with no REDIS_URL, first screen"
  say "     200 over plain http — no https hop, no HSTS, http:// links."
fi
say ""
