#!/usr/bin/env bash
# =============================================================================
# deploy.sh - deploy a new image version to this host (runs on the EC2 box).
#
# Called by the GitHub Actions "Deploy" stage:
#     ssh ec2 "cd /opt/devops-cicd/deploy && ./scripts/deploy.sh --image ghcr.io/OWNER/devops-cicd-app --tag sha-<commit>"
#
# Responsibilities:
#   1. remember the currently running image as "previous" (for rollback)
#   2. pull the new, immutable, commit-SHA tagged image
#   3. recreate the stack with Docker Compose
#   4. validate /health with retries
#   5. on failure -> automatic rollback to the previous image
#
# Exit codes:
#   0 - deployment successful and healthy
#   1 - deployment failed (rollback attempted; see log for details)
#   2 - usage / configuration error
# =============================================================================
set -Eeuo pipefail

# --------------------------------------------------------------------------- #
# Paths & defaults
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(dirname "${SCRIPT_DIR}")}"
BASE_DIR="${BASE_DIR:-$(dirname "${DEPLOY_DIR}")}"
STATE_DIR="${STATE_DIR:-$BASE_DIR/state}"
LOG_DIR="${LOG_DIR:-$BASE_DIR/logs}"
COMPOSE_FILE="${COMPOSE_FILE:-$DEPLOY_DIR/docker-compose.prod.yml}"
SECRETS_FILE="${SECRETS_FILE:-$DEPLOY_DIR/secrets.env}"
ENV_FILE="${ENV_FILE:-$DEPLOY_DIR/.env}"
LOCK_FILE="${STATE_DIR}/deploy.lock"

HEALTH_RETRIES="${HEALTH_RETRIES:-10}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-6}"
HEALTH_URL="${HEALTH_URL:-http://localhost/health}"
IMAGE_KEEP_COUNT="${IMAGE_KEEP_COUNT:-5}"

IMAGE=""
TAG=""
AUTO_ROLLBACK="true"

CURRENT_IMAGE_FILE="$STATE_DIR/current-image"
PREVIOUS_IMAGE_FILE="$STATE_DIR/previous-image"
DEPLOYMENTS_FILE="$STATE_DIR/deployments.json"

mkdir -p "$LOG_DIR" "$STATE_DIR"
LOG_FILE="$LOG_DIR/deploy-$(date -u '+%Y%m%d-%H%M%S').log"

# Deployment bookkeeping (used by the dashboard "Deployments" panel).
DEPLOY_START_EPOCH="$(date +%s)"
DEPLOY_OUTCOME="failed"
DEPLOY_REASON="not_started"

log() {
    local line
    line="[deploy] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
    echo "${line}"
    echo "${line}" >>"$LOG_FILE"
}

die() { log "ERROR: $*"; exit 2; }

# --------------------------------------------------------------------------- #
# Deployment history
#
# Every attempt (successful or not) is appended to ${STATE_DIR}/deployments.json
# so the dashboard can show the real deployment history. The file is only ever
# touched when jq is available; a missing jq never breaks a deployment.
# --------------------------------------------------------------------------- #
# shellcheck disable=SC2329,SC2317  # invoked from the EXIT trap (SC2317 is the
# older name of this check; shellcheck 0.9.0 still reports it)
record_deployment() {
    local outcome="$1" reason="$2"
    local duration tmp

    [[ -z "${NEW_IMAGE:-}" ]] && return 0

    if ! command -v jq >/dev/null 2>&1; then
        log "WARN: jq is not installed - the deployment history was not recorded."
        return 0
    fi

    duration=$(( $(date +%s) - DEPLOY_START_EPOCH ))
    tmp="${DEPLOYMENTS_FILE}.tmp"

    [[ -f "${DEPLOYMENTS_FILE}" ]] || printf '%s' '{"deployments":[]}' >"${DEPLOYMENTS_FILE}"

    if ! jq \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg image "${NEW_IMAGE}" \
        --arg tag "${TAG}" \
        --arg commit "${TAG#sha-}" \
        --arg status "${outcome}" \
        --arg reason "${reason}" \
        --argjson duration "${duration}" \
        '.generated_at = $ts
         | .deployments = (
              ((.deployments // [])
               | map(select((.kind // "deploy") != "deploy" or .tag != $tag))
               | . + [{
                     kind: "deploy",
                     timestamp: $ts, image: $image, tag: $tag, commit: $commit,
                     status: $status, reason: $reason, duration_seconds: $duration
                   }])
             )
         | .deployments = (.deployments | sort_by(.timestamp) | reverse | .[0:20])' \
        "${DEPLOYMENTS_FILE}" >"${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        log "WARN: could not update ${DEPLOYMENTS_FILE} - history not recorded."
        return 0
    fi

    mv -f "${tmp}" "${DEPLOYMENTS_FILE}"
    log "Recorded deployment ${TAG} (${outcome}) in ${DEPLOYMENTS_FILE}"
}

# shellcheck disable=SC2329,SC2317  # invoked by the EXIT trap (SC2317 is the
# older name of this check; shellcheck 0.9.0 still reports it)
on_exit() {
    local code=$?
    if [[ "${DEPLOY_OUTCOME}" == "failed" && "${DEPLOY_REASON}" == "not_started" ]]; then
        case "${code}" in
            0) DEPLOY_OUTCOME="success"; DEPLOY_REASON="health_check_passed" ;;
            2) DEPLOY_REASON="configuration_error" ;;
            *) DEPLOY_REASON="exit_${code}" ;;
        esac
    fi
    record_deployment "${DEPLOY_OUTCOME}" "${DEPLOY_REASON}"
    return "${code}"
}
trap on_exit EXIT

usage() {
    cat <<'EOF'
Usage: deploy.sh --image IMAGE --tag TAG [options]

  --image IMAGE     Full image repository, e.g. ghcr.io/owner/devops-cicd-app
  --tag TAG         Immutable tag, e.g. sha-1a2b3c4  (NEVER use "latest")
  --retries N       Health-check attempts (default: 10)
  --interval SEC    Seconds between health-check attempts (default: 6)
  --health-url URL  Health endpoint (default: http://localhost/health)
  --no-rollback     Do not roll back automatically when the health check fails
  --dry-run         Show what would happen without changing anything
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)      IMAGE="$2"; shift 2 ;;
        --tag)        TAG="$2"; shift 2 ;;
        --retries)    HEALTH_RETRIES="$2"; shift 2 ;;
        --interval)   HEALTH_INTERVAL="$2"; shift 2 ;;
        --health-url) HEALTH_URL="$2"; shift 2 ;;
        --no-rollback) AUTO_ROLLBACK="false"; shift ;;
        --dry-run)    DRY_RUN="true"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -z "${IMAGE}" ]] && die "--image is required"
[[ -z "${TAG}" ]]   && die "--tag is required"
[[ "${TAG}" == "latest" ]] && die "Refusing to deploy the mutable tag 'latest'. Use an immutable commit-SHA tag."

[[ -f "${COMPOSE_FILE}" ]]  || die "Compose file not found: ${COMPOSE_FILE}"
[[ -f "${SECRETS_FILE}" ]]  || die "Secrets file not found: ${SECRETS_FILE} (run setup-server.sh first)"

# --------------------------------------------------------------------------- #
# Locking - prevents two deployments from running at the same time.
# --------------------------------------------------------------------------- #
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    die "Another deployment is already running (lock: ${LOCK_FILE})"
fi

# --------------------------------------------------------------------------- #
# Environment
# --------------------------------------------------------------------------- #
# shellcheck disable=SC1090  # the path is dynamic by design
set -a
# shellcheck source=/dev/null
source "${SECRETS_FILE}"
set +a

APP_DOMAIN="${APP_DOMAIN:-localhost}"
APP_VERSION="${APP_VERSION:-1.0.0}"
NEW_IMAGE="${IMAGE}:${TAG}"

CURRENT_IMAGE=""
if [[ -f "${CURRENT_IMAGE_FILE}" ]]; then
    CURRENT_IMAGE=$(tr -d '[:space:]' < "${CURRENT_IMAGE_FILE}")
fi

log "=========================================================="
log "Deployment started"
log "  new image      : ${NEW_IMAGE}"
log "  current image  : ${CURRENT_IMAGE:-<none - first deployment>}"
log "  compose file   : ${COMPOSE_FILE}"
log "  health url     : ${HEALTH_URL}"
log "  log file       : ${LOG_FILE}"
log "=========================================================="

if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log "DRY RUN - stopping before any change."
    exit 0
fi

compose() {
    # `9>&-` closes the lock file descriptor in the child process. Without it a
    # daemonised child would inherit the flock and keep the deployment lock
    # held after this script exits, blocking the next deployment with the
    # confusing error "Another deployment is already running".
    docker compose --env-file "${ENV_FILE}" --env-file "${SECRETS_FILE}" \
        -f "${COMPOSE_FILE}" "$@" 9>&-
}

# --------------------------------------------------------------------------- #
# 1. Remember the current image so we can roll back to it
# --------------------------------------------------------------------------- #
if [[ -n "${CURRENT_IMAGE}" && "${CURRENT_IMAGE}" != "${NEW_IMAGE}" ]]; then
    printf '%s\n' "${CURRENT_IMAGE}" >"${PREVIOUS_IMAGE_FILE}"
    log "Saved previous image for rollback: ${CURRENT_IMAGE}"
else
    log "No different current image to record as previous."
fi

# --------------------------------------------------------------------------- #
# 2. Write the deployment environment file (secrets stay in secrets.env)
# --------------------------------------------------------------------------- #
cat >"${ENV_FILE}" <<EOF
# Generated by deploy.sh - $(date -u '+%Y-%m-%dT%H:%M:%SZ')
APP_IMAGE=${IMAGE}
APP_TAG=${TAG}
APP_NAME=${APP_NAME:-devops-cicd-app}
APP_VERSION=${APP_VERSION}
APP_DOMAIN=${APP_DOMAIN}
POSTGRES_USER=${POSTGRES_USER:-appuser}
POSTGRES_DB=${POSTGRES_DB:-devops_cicd}
EOF
log "Wrote ${ENV_FILE}"

# --------------------------------------------------------------------------- #
# 3. Pull the new image
# --------------------------------------------------------------------------- #
log "Pulling ${NEW_IMAGE} ..."
if ! compose pull app; then
    log "ERROR: failed to pull ${NEW_IMAGE}."
    exit 1
fi

# --------------------------------------------------------------------------- #
# 4. Recreate the stack
# --------------------------------------------------------------------------- #
log "Applying the new configuration (docker compose up -d) ..."
if ! compose up -d --remove-orphans; then
    log "ERROR: 'docker compose up -d' failed."
    log "--- last 50 log lines of the app ---"
    compose logs --tail=50 app || true
    exit 1
fi

log "Waiting for the containers to become healthy ..."
sleep 5
compose ps || true

# --------------------------------------------------------------------------- #
# 4b. Apply the database schema (idempotent create_all)
#     On a brand-new database the tables do not exist yet, so /api/users would
#     fail. `flask init-db` is safe to run on every deployment.
# --------------------------------------------------------------------------- #
log "Applying the database schema (idempotent) ..."
if ! compose exec -T app flask --app wsgi init-db; then
    log "WARN: 'flask init-db' failed. The tables may already exist - continuing."
    log "      Check manually: docker compose exec app flask --app wsgi init-db"
fi

# --------------------------------------------------------------------------- #
# 5. Validate
# --------------------------------------------------------------------------- #
log "Running the health check (${HEALTH_RETRIES} attempts, ${HEALTH_INTERVAL}s apart) ..."
HEALTH_OK=false
export HEALTH_URL HEALTH_RETRIES HEALTH_INTERVAL
if "${SCRIPT_DIR}/health-check.sh" --url "${HEALTH_URL}" \
        --retries "${HEALTH_RETRIES}" --interval "${HEALTH_INTERVAL}" 9>&-; then
    HEALTH_OK=true
fi

if [[ "${HEALTH_OK}" != "true" ]]; then
    log "ERROR: the new version is NOT healthy."
    log "--- last 100 log lines of the app ---"
    compose logs --tail=100 app || true
    log "--- last 30 log lines of the db ---"
    compose logs --tail=30 db || true

    if [[ "${AUTO_ROLLBACK}" == "true" ]]; then
        log "Starting automatic rollback ..."
        if "${SCRIPT_DIR}/rollback.sh"; then
            log "Rollback completed successfully, but the deployment FAILED."
            DEPLOY_OUTCOME="rolled_back"
            DEPLOY_REASON="health_check_failed_rolled_back"
            exit 1
        else
            log "CRITICAL: the rollback also failed. Manual intervention required."
            DEPLOY_REASON="rollback_failed"
            exit 1
        fi
    fi
    log "Deployment failed (rollback disabled)."
    exit 1
fi

# --------------------------------------------------------------------------- #
# 6. Success - record the new image and prune old ones
# --------------------------------------------------------------------------- #
printf '%s\n' "${NEW_IMAGE}" >"${CURRENT_IMAGE_FILE}"
log "Deployment successful. Current image: ${NEW_IMAGE}"

prune_images() {
    local repo="$1" current_ref="$2" previous_ref="$3" keep="$4"
    local -a candidates=()
    local ref id

    while read -r ref id; do
        [[ -z "${ref}" || "${ref}" == "<none>:<none>" ]] && continue
        [[ "${ref}" == "${current_ref}" ]] && continue
        [[ -n "${previous_ref}" && "${ref}" == "${previous_ref}" ]] && continue
        candidates+=("${id}")
    done < <(docker images --filter "reference=${repo}" --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
             | awk '!seen[$2]++')

    local total="${#candidates[@]}"
    if (( total <= keep )); then
        log "Image cleanup: ${total} old image(s) present, keeping up to ${keep}. Nothing removed."
        return 0
    fi

    for (( i = keep; i < total; i++ )); do
        log "Removing old image ${candidates[$i]}"
        docker rmi -f "${candidates[$i]}" >/dev/null 2>&1 || true
    done
    log "Image cleanup done (kept ${keep} most recent + current + previous)."
}

PREVIOUS_REF=""
[[ -f "${PREVIOUS_IMAGE_FILE}" ]] && PREVIOUS_REF=$(tr -d '[:space:]' < "${PREVIOUS_IMAGE_FILE}")
prune_images "${IMAGE}" "${NEW_IMAGE}" "${PREVIOUS_REF}" "${IMAGE_KEEP_COUNT}"

log "=========================================================="
log "DEPLOYMENT SUCCESSFUL - ${NEW_IMAGE}"
log "  health check : passed"
log "  previous kept: ${PREVIOUS_REF:-<none>}"
log "  log file     : ${LOG_FILE}"
log "=========================================================="
exit 0
