#!/usr/bin/env bash
# =============================================================================
# rollback.sh - restore the previously deployed (known-good) image.
#
# State files (under $BASE_DIR/state):
#   current-image  full image reference currently deployed  (owner/app:tag)
#   previous-image  full image reference of the last known-good release
#
# Exit codes:
#   0 - rollback succeeded and the restored version is healthy
#   1 - rollback was attempted but FAILED (production is still broken)
#   2 - nothing to roll back to (no previous image recorded) or usage error
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(dirname "${SCRIPT_DIR}")}"
BASE_DIR="${BASE_DIR:-$(dirname "${DEPLOY_DIR}")}"
STATE_DIR="${STATE_DIR:-$BASE_DIR/state}"
LOG_DIR="${LOG_DIR:-$BASE_DIR/logs}"
COMPOSE_FILE="${COMPOSE_FILE:-$DEPLOY_DIR/docker-compose.prod.yml}"
SECRETS_FILE="${SECRETS_FILE:-$DEPLOY_DIR/secrets.env}"
ENV_FILE="${ENV_FILE:-$DEPLOY_DIR/.env}"
HEALTH_RETRIES="${HEALTH_RETRIES:-5}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"
HEALTH_URL="${HEALTH_URL:-http://localhost/health}"

CURRENT_IMAGE_FILE="$STATE_DIR/current-image"
PREVIOUS_IMAGE_FILE="$STATE_DIR/previous-image"
DEPLOYMENTS_FILE="$STATE_DIR/deployments.json"

mkdir -p "$LOG_DIR" "$STATE_DIR"
LOG_FILE="$LOG_DIR/rollback-$(date -u '+%Y%m%d-%H%M%S').log"

# Rollback bookkeeping (shown in the dashboard "Deployments" panel).
ROLLBACK_START_EPOCH="$(date +%s)"
ROLLBACK_OUTCOME="failed"
ROLLBACK_REASON="not_started"

# Append the rollback to the deployment history. The file is only touched when
# jq is available; a missing jq never breaks a rollback.
# shellcheck disable=SC2329,SC2317  # invoked from the EXIT trap (SC2317 is the
# older name of this check; shellcheck 0.9.0 still reports it)
record_rollback() {
    local image="$1" outcome="$2" reason="$3"
    local duration tmp commit

    if ! command -v jq >/dev/null 2>&1; then
        log "WARN: jq is not installed - the rollback was not added to the history."
        return 0
    fi

    duration=$(( $(date +%s) - ROLLBACK_START_EPOCH ))
    tmp="${DEPLOYMENTS_FILE}.tmp"
    commit="${image##*:}"
    commit="${commit#sha-}"

    [[ -f "${DEPLOYMENTS_FILE}" ]] || printf '%s' '{"deployments":[]}' >"${DEPLOYMENTS_FILE}"

    if ! jq \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg image "${image}" \
        --arg tag "${image##*:}" \
        --arg commit "${commit}" \
        --arg status "${outcome}" \
        --arg reason "${reason}" \
        --argjson duration "${duration}" \
        '.generated_at = $ts
         | .deployments = (
              ((.deployments // [])
               | . + [{
                     kind: "rollback",
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
    log "Recorded rollback to ${image} (${outcome}) in ${DEPLOYMENTS_FILE}"
}

# shellcheck disable=SC2329,SC2317  # invoked by the EXIT trap (SC2317 is the
# older name of this check; shellcheck 0.9.0 still reports it)
on_exit() {
    local code=$?
    if [[ "${ROLLBACK_OUTCOME}" == "failed" && "${ROLLBACK_REASON}" == "not_started" ]]; then
        case "${code}" in
            0) ROLLBACK_OUTCOME="rolled_back"; ROLLBACK_REASON="rollback_completed" ;;
            1) ROLLBACK_OUTCOME="rollback_failed"; ROLLBACK_REASON="restored_version_unhealthy" ;;
            2) ROLLBACK_OUTCOME="failed"; ROLLBACK_REASON="nothing_to_roll_back" ;;
            *) ROLLBACK_OUTCOME="failed"; ROLLBACK_REASON="exit_${code}" ;;
        esac
    fi
    if [[ -n "${PREVIOUS_IMAGE:-}" ]]; then
        record_rollback "${PREVIOUS_IMAGE}" "${ROLLBACK_OUTCOME}" "${ROLLBACK_REASON}"
    fi
    return "${code}"
}
trap on_exit EXIT

log() {
    local line
    line="[rollback] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
    echo "${line}"
    echo "${line}" >>"$LOG_FILE"
}

log "Starting rollback (log file: ${LOG_FILE})"

if [[ ! -f "${COMPOSE_FILE}" ]]; then
    log "ERROR: compose file not found: ${COMPOSE_FILE}"
    exit 2
fi
if [[ ! -f "${PREVIOUS_IMAGE_FILE}" ]]; then
    log "ERROR: no previous image recorded at ${PREVIOUS_IMAGE_FILE} - nothing to roll back to."
    exit 2
fi

PREVIOUS_IMAGE=$(tr -d '[:space:]' < "${PREVIOUS_IMAGE_FILE}")
if [[ -z "${PREVIOUS_IMAGE}" ]]; then
    log "ERROR: previous-image file is empty - nothing to roll back to."
    exit 2
fi

PREVIOUS_TAG="${PREVIOUS_IMAGE##*:}"
PREVIOUS_REPO="${PREVIOUS_IMAGE%:*}"

CURRENT_IMAGE=""
if [[ -f "${CURRENT_IMAGE_FILE}" ]]; then
    CURRENT_IMAGE=$(tr -d '[:space:]' < "${CURRENT_IMAGE_FILE}")
fi

log "Current (failing) image : ${CURRENT_IMAGE:-<unknown>}"
log "Previous (known-good)    : ${PREVIOUS_IMAGE}"

# ---------------------------------------------------------------------------
# Write the deployment environment file so `docker compose` pulls the old tag.
# The secrets file is preserved untouched.
# ---------------------------------------------------------------------------
write_env_file() {
    cat >"${ENV_FILE}" <<EOF
# Generated by rollback.sh - $(date -u '+%Y-%m-%dT%H:%M:%SZ')
APP_IMAGE=${PREVIOUS_REPO}
APP_TAG=${PREVIOUS_TAG}
APP_NAME=devops-cicd-app
APP_VERSION=${APP_VERSION:-1.0.0}
APP_DOMAIN=${APP_DOMAIN:-localhost}
POSTGRES_USER=${POSTGRES_USER:-appuser}
POSTGRES_DB=${POSTGRES_DB:-devops_cicd}
EOF
    log "Wrote ${ENV_FILE} (APP_TAG=${PREVIOUS_TAG})"
}

compose() {
    docker compose --env-file "${ENV_FILE}" --env-file "${SECRETS_FILE}" -f "${COMPOSE_FILE}" "$@"
}

write_env_file

log "Pulling previous image ${PREVIOUS_IMAGE} ..."
if ! compose pull app; then
    log "ERROR: failed to pull ${PREVIOUS_IMAGE} (was the image pruned?)."
    exit 1
fi

log "Restarting services with the previous image ..."
if ! compose up -d --remove-orphans; then
    log "ERROR: 'docker compose up' failed during rollback."
    exit 1
fi

log "Validating the restored version (${HEALTH_RETRIES} attempts) ..."
export HEALTH_URL HEALTH_RETRIES HEALTH_INTERVAL
if "${SCRIPT_DIR}/health-check.sh" --url "${HEALTH_URL}" \
        --retries "${HEALTH_RETRIES}" --interval "${HEALTH_INTERVAL}"; then

    log "Rollback SUCCESSFUL - ${PREVIOUS_IMAGE} is serving traffic again."
    # The restored image becomes the new "current" one. The previous pointer is
    # cleared so a second rollback cannot silently re-apply an older release.
    printf '%s\n' "${PREVIOUS_IMAGE}" >"${CURRENT_IMAGE_FILE}"
    : >"${PREVIOUS_IMAGE_FILE}"
    [[ -n "${CURRENT_IMAGE}" ]] && log "Failed image ${CURRENT_IMAGE} was left on disk for debugging."
    exit 0
fi

log "ERROR: the rolled-back version did NOT become healthy. Production is still broken."
log "Inspect the logs with: docker compose -f ${COMPOSE_FILE} logs --tail=200 app db"
exit 1
