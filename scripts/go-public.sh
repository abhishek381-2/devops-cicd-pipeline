#!/usr/bin/env bash
# =============================================================================
# go-public.sh - put this project on a public HTTPS URL in one command.
#
#   ./scripts/go-public.sh              # start the app + open a public tunnel
#   ./scripts/go-public.sh --no-tunnel  # only start the app locally
#   ./scripts/go-public.sh --stop       # stop the tunnel and the app
#
# What it does
#   1. repairs the environment (venv, dependencies, script permissions)
#   2. collects real host metrics so the dashboard gauges are populated
#   3. starts Gunicorn on 0.0.0.0:8000 and waits for /health
#   4. downloads cloudflared (if needed) and opens a quick tunnel
#   5. prints the public URL and verifies it end to end
#
# NOTE: a Cloudflare *quick tunnel* is a demo convenience - the hostname
# changes on every restart and Cloudflare gives no uptime guarantee. For a
# permanent deployment use AWS EC2 + your own domain (docs/GO_LIVE.md).
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
STATE_DIR="${STATE_DIR:-/tmp/hoststate}"
CF_BIN="${CF_BIN:-/tmp/cloudflared}"
TUNNEL_LOG="${TUNNEL_LOG:-/tmp/tunnel.log}"
PORT="${PORT:-8000}"

WITH_TUNNEL="true"
ACTION="start"

log()  { printf '\033[0;36m[go-public]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[go-public]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[go-public][ERROR]\033[0m %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-tunnel) WITH_TUNNEL="false"; shift ;;
        --stop)      ACTION="stop"; shift ;;
        -h|--help)   sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           err "Unknown option: $1"; exit 2 ;;
    esac
done

cd "${PROJECT_DIR}"

# --------------------------------------------------------------------------- #
# Stop
# --------------------------------------------------------------------------- #
if [[ "${ACTION}" == "stop" ]]; then
    log "Stopping the tunnel and the app ..."
    pkill -f "[c]loudflared tunnel" 2>/dev/null || true
    pkill -f "[b]ind 0.0.0.0:${PORT}" 2>/dev/null || true
    pkill -f "[g]unicorn.*wsgi:app" 2>/dev/null || true
    ok "Stopped."
    exit 0
fi

# --------------------------------------------------------------------------- #
# 1. Repair the environment
# --------------------------------------------------------------------------- #
log "1/5 Repairing the environment (venv, dependencies, permissions) ..."
bash "${SCRIPT_DIR}/resume-preview.sh" --setup-only

# --------------------------------------------------------------------------- #
# 2. Real host metrics for the dashboard
# --------------------------------------------------------------------------- #
log "2/5 Collecting real host metrics into ${STATE_DIR} ..."
mkdir -p "${STATE_DIR}"
if STATE_DIR="${STATE_DIR}" bash "${SCRIPT_DIR}/collect-metrics.sh" >/dev/null 2>&1; then
    ok "    $(python3 -c "
import json
d = json.load(open('${STATE_DIR}/metrics.json'))
print('cpu {0}% / mem {1}% / disk {2}%'.format(
    d['cpu']['percent'], d['memory']['percent'], d['disk'][0]['percent']))
" 2>/dev/null || echo 'metrics written')"
else
    err "    The metrics collector failed - the dashboard will show 'Not configured'."
fi

# --------------------------------------------------------------------------- #
# 3. Start the app
# --------------------------------------------------------------------------- #
log "3/5 Starting Gunicorn on 0.0.0.0:${PORT} ..."
pkill -f "[b]ind 0.0.0.0:${PORT}" 2>/dev/null || true
sleep 1

export APP_ENV="${APP_ENV:-production}"
export APP_NAME="${APP_NAME:-devops-cicd-app}"
export APP_VERSION="${APP_VERSION:-1.0.0}"
export LOG_FORMAT="${LOG_FORMAT:-json}"
export LOG_LEVEL="${LOG_LEVEL:-INFO}"
export SECRET_KEY="${SECRET_KEY:-$(head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | head -c 48)}"
export DATABASE_URL="${DATABASE_URL:-sqlite+pysqlite:///${PROJECT_DIR}/instance/app.db}"
export HOST_STATE_DIR="${STATE_DIR}"
export HOST_LOG_DIR="${STATE_DIR}/logs"

mkdir -p logs instance
nohup "${PROJECT_DIR}/.venv/bin/gunicorn" \
    --bind "0.0.0.0:${PORT}" --workers 3 --threads 2 \
    --timeout 30 --graceful-timeout 20 --keep-alive 5 \
    --max-requests 1000 --max-requests-jitter 50 \
    --access-logfile - --error-logfile - --capture-output \
    wsgi:app >>logs/app.log 2>&1 &
echo $! >logs/app.pid

for attempt in $(seq 1 20); do
    if curl -sf -m 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
        ok "    App healthy after ${attempt} attempt(s)."
        break
    fi
    [[ "${attempt}" == "20" ]] && { err "The app did not become healthy. See logs/app.log"; exit 1; }
    sleep 1
done

if [[ "${WITH_TUNNEL}" != "true" ]]; then
    ok "Local only: http://127.0.0.1:${PORT}/"
    exit 0
fi

# --------------------------------------------------------------------------- #
# 4. Public tunnel
# --------------------------------------------------------------------------- #
log "4/5 Opening the public HTTPS tunnel ..."
if [[ ! -x "${CF_BIN}" ]]; then
    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64)          CF_ARCH="amd64" ;;
        aarch64|arm64)   CF_ARCH="arm64" ;;
        *)               err "Unsupported architecture: ${ARCH}"; exit 1 ;;
    esac
    log "    Downloading cloudflared (${CF_ARCH}) ..."
    curl -sL -o "${CF_BIN}" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    chmod +x "${CF_BIN}"
fi

pkill -f "[c]loudflared tunnel" 2>/dev/null || true
sleep 1
: >"${TUNNEL_LOG}"
nohup "${CF_BIN}" tunnel --no-autoupdate --url "http://127.0.0.1:${PORT}" \
    --logfile "${TUNNEL_LOG}" >>/dev/null 2>&1 &

PUBLIC_URL=""
for _ in $(seq 1 40); do
    PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "${TUNNEL_LOG}" 2>/dev/null | head -1 || true)"
    [[ -n "${PUBLIC_URL}" ]] && break
    sleep 1
done

if [[ -z "${PUBLIC_URL}" ]]; then
    err "The tunnel did not produce a URL. Check ${TUNNEL_LOG}"
    exit 1
fi

# --------------------------------------------------------------------------- #
# 5. Verify through the public edge
# --------------------------------------------------------------------------- #
log "5/5 Verifying the public URL ..."

# This sandbox cannot resolve trycloudflare.com, so resolve it over DNS-over-HTTPS
# and pin the IP. A normal machine can just use the URL directly.
resolve_ip() {
    curl -s -m 15 --resolve cloudflare-dns.com:443:1.1.1.1 \
        -H "accept: application/dns-json" \
        "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null \
      | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(next((a['data'] for a in d.get('Answer', []) if a.get('type') == 1), ''))
except Exception:
    print('')
"
}

HOST_NAME="${PUBLIC_URL#https://}"
IP="$(resolve_ip "${HOST_NAME}")"

check() {
    local path="$1"
    if [[ -n "${IP}" ]]; then
        curl -s -m 20 --resolve "${HOST_NAME}:443:${IP}" -o /dev/null \
            -w '%{http_code}' "${PUBLIC_URL}${path}"
    else
        curl -s -m 20 -o /dev/null -w '%{http_code}' "${PUBLIC_URL}${path}"
    fi
}

# A brand-new quick tunnel registers with Cloudflare immediately, but its DNS
# record can take up to a minute to propagate to the edge. Poll until it answers.
log "    Waiting for the Cloudflare edge to serve the new hostname ..."
READY="false"
for attempt in $(seq 1 30); do
    [[ -z "${IP}" ]] && IP="$(resolve_ip "${HOST_NAME}")"
    if [[ -n "${IP}" && "$(check /health)" == "200" ]]; then
        ok "    Reachable after ${attempt} attempt(s) (edge IP ${IP})."
        READY="true"
        break
    fi
    sleep 4
done

if [[ "${READY}" != "true" ]]; then
    err "    The tunnel registered but the edge did not answer with 200 within ~2 minutes."
    err "    The URL usually starts working shortly after. Check it in a browser,"
    err "    or see ${TUNNEL_LOG} for details."
fi

for path in / /health /api/dashboard; do
    printf '    %-16s → HTTP %s\n' "${path}" "$(check "${path}")"
done

echo
ok "================================================================"
ok " PUBLIC URL : ${PUBLIC_URL}/"
ok " Health     : ${PUBLIC_URL}/health"
ok " Dashboard  : ${PUBLIC_URL}/"
ok " Local      : http://127.0.0.1:${PORT}/"
ok "================================================================"
echo
log "This URL is a temporary demo. It changes on every restart."
log "For a permanent deployment: docs/GO_LIVE.md (AWS EC2 + your domain)."
log "Stop everything with: ./scripts/go-public.sh --stop"
