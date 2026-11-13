#!/usr/bin/env bash
# =============================================================================
# health-check.sh - validate that the application is actually serving traffic.
#
# A deployment is only successful when the /health endpoint answers with
# HTTP 200 AND reports `"status": "healthy"` (which includes a working
# database connection). Anything else is treated as a failure.
#
# Usage:
#   ./health-check.sh [--url URL] [--retries N] [--interval SEC] [--timeout SEC]
#
# Exit codes:
#   0 - healthy
#   1 - unhealthy (after all retries)
#   2 - usage / configuration error
# =============================================================================
set -Eeuo pipefail

URL="${HEALTH_URL:-http://localhost/health}"
RETRIES="${HEALTH_RETRIES:-10}"
INTERVAL="${HEALTH_INTERVAL:-5}"
TIMEOUT="${HEALTH_TIMEOUT:-10}"

usage() {
    cat <<'EOF'
Usage: health-check.sh [options]

  --url URL        Health endpoint to probe (default: http://localhost/health)
  --retries N      Number of attempts (default: 10)
  --interval SEC   Seconds between attempts (default: 5)
  --timeout SEC    Per-request timeout in seconds (default: 10)
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)      URL="$2"; shift 2 ;;
        --retries)  RETRIES="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --timeout)  TIMEOUT="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

log() { printf '[health-check] %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

if ! command -v curl >/dev/null 2>&1; then
    log "ERROR: curl is not installed on this host."
    exit 2
fi

log "Probing ${URL} (max ${RETRIES} attempts, ${INTERVAL}s interval)"

last_body=""
last_code="000"

for attempt in $(seq 1 "${RETRIES}"); do
    response="$(curl --silent --show-error --max-time "${TIMEOUT}" \
                     --write-out '\n%{http_code}' \
                     --output - "${URL}" 2>/dev/null || true)"

    last_code="$(printf '%s' "${response}" | tail -n1)"
    last_body="$(printf '%s' "${response}" | sed '$d')"

    if [[ "${last_code}" == "200" ]] && printf '%s' "${last_body}" | grep -q '"status"[[:space:]]*:[[:space:]]*"healthy"'; then
        log "SUCCESS - HTTP 200 and status=healthy (attempt ${attempt}/${RETRIES})"
        log "Response: ${last_body}"
        exit 0
    fi

    log "Attempt ${attempt}/${RETRIES} failed - HTTP ${last_code}"
    if [[ -n "${last_body}" ]]; then
        log "Response: ${last_body}"
    else
        log "No response body received (service not listening or timed out)"
    fi

    if [[ "${attempt}" -lt "${RETRIES}" ]]; then
        sleep "${INTERVAL}"
    fi
done

log "FAILED - the application did not become healthy after ${RETRIES} attempts."
exit 1
