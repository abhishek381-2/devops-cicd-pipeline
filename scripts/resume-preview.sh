#!/usr/bin/env bash
# =============================================================================
# resume-preview.sh - repair the local environment and (re)start the app.
#
# Useful after a machine/sandbox reset, a fresh clone, or a `git pull` that
# changed the dependencies.
#
#   ./scripts/resume-preview.sh              # repair + start in the background
#   ./scripts/resume-preview.sh --setup-only # repair only, do not start
#   ./scripts/resume-preview.sh --foreground # repair + run in the foreground
#
# What it does
#   1. creates .venv (if missing) and installs the pinned dependencies
#   2. restores the executable bit on the shell scripts
#   3. creates the instance/ directory for the local SQLite database
#   4. starts Gunicorn on 0.0.0.0:${PORT} and waits for /health
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
VENV="$PROJECT_DIR/.venv"
PORT="${PORT:-8000}"
HOST="${HOST:-0.0.0.0}"
LOG_DIR="$PROJECT_DIR/logs"
PID_FILE="$PROJECT_DIR/logs/app.pid"
SETUP_ONLY="false"
FOREGROUND="false"

log()  { printf '\033[0;36m[resume]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[resume][ERROR]\033[0m %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --setup-only) SETUP_ONLY="true"; shift ;;
        --foreground) FOREGROUND="true"; shift ;;
        --port)       PORT="$2"; shift 2 ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *)            err "Unknown option: $1"; exit 2 ;;
    esac
done

cd "$PROJECT_DIR"
mkdir -p logs instance

# --------------------------------------------------------------------------- #
# 1. Python environment
# --------------------------------------------------------------------------- #
if [[ ! -x "$VENV/bin/python" ]]; then
    log "Creating the virtualenv ..."
    python3 -m venv "$VENV"
fi

log "Installing the dependencies ..."
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r requirements.txt -r requirements-dev.txt

# --------------------------------------------------------------------------- #
# 2. Executable bits (lost when the tree is copied / zipped / snapshotted)
# --------------------------------------------------------------------------- #
chmod +x "$PROJECT_DIR"/scripts/*.sh
log "Script permissions restored."

# --------------------------------------------------------------------------- #
# 3. Configuration
# --------------------------------------------------------------------------- #
# A strong random SECRET_KEY is generated per run. It is only needed for the
# local demo - in production the value comes from the EC2 server's secrets.env.
SECRET_KEY="${SECRET_KEY:-$(head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | head -c 48)}"
export APP_ENV="${APP_ENV:-production}"
export APP_NAME="${APP_NAME:-devops-cicd-app}"
export APP_VERSION="${APP_VERSION:-1.0.0}"
export LOG_FORMAT="${LOG_FORMAT:-json}"
export LOG_LEVEL="${LOG_LEVEL:-INFO}"
export SECRET_KEY

# PostgreSQL is used when DATABASE_URL points at it; otherwise SQLite.
if [[ -z "${DATABASE_URL:-}" ]]; then
    export DATABASE_URL="sqlite+pysqlite:///$PROJECT_DIR/instance/app.db"
    log "Using SQLite: $DATABASE_URL"
else
    log "Using DATABASE_URL from the environment."
fi

if [[ "${SETUP_ONLY}" == "true" ]]; then
    log "Setup complete (--setup-only, the server was not started)."
    exit 0
fi

# --------------------------------------------------------------------------- #
# 4. Start Gunicorn
# --------------------------------------------------------------------------- #
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    log "An instance is already running (pid $(cat "$PID_FILE")) - stopping it first."
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    sleep 2
fi
pkill -f "[b]ind ${HOST}:${PORT}" 2>/dev/null || true

GUNICORN_ARGS=(
    --bind "${HOST}:${PORT}"
    --workers "${WEB_CONCURRENCY:-3}"
    --threads 2
    --timeout 30
    --graceful-timeout 20
    --keep-alive 5
    --max-requests 1000
    --max-requests-jitter 50
    --access-logfile -
    --error-logfile -
    --capture-output
    wsgi:app
)

if [[ "${FOREGROUND}" == "true" ]]; then
    log "Starting Gunicorn in the foreground on ${HOST}:${PORT} ..."
    exec "$VENV/bin/gunicorn" "${GUNICORN_ARGS[@]}"
fi

log "Starting Gunicorn in the background on ${HOST}:${PORT} ..."
nohup "$VENV/bin/gunicorn" "${GUNICORN_ARGS[@]}" >>"$LOG_DIR/app.log" 2>&1 &
echo $! >"$PID_FILE"

# --------------------------------------------------------------------------- #
# 5. Wait for the health endpoint
# --------------------------------------------------------------------------- #
log "Waiting for the health endpoint ..."
for attempt in $(seq 1 20); do
    body="$(curl -s --max-time 5 "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)"
    if printf '%s' "${body}" | grep -q '"status"[[:space:]]*:[[:space:]]*"healthy"'; then
        log "Healthy after ${attempt} attempt(s)."
        echo "  ${body}"
        log "Preview URL: http://127.0.0.1:${PORT}/  (health: /health)"
        log "Server log: ${LOG_DIR}/app.log"
        exit 0
    fi
    sleep 1
done

err "The application did not become healthy within 20 seconds."
err "Check ${LOG_DIR}/app.log for details."
exit 1
