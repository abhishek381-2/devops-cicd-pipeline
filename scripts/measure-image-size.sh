#!/usr/bin/env bash
# =============================================================================
# measure-image-size.sh - objectively measure the multi-stage build's benefit.
#
#   ./scripts/measure-image-size.sh
#
# Builds three images and compares them:
#   1. unoptimized  - single stage, full python:3.12 image, root user
#   2. optimized    - the multi-stage Dockerfile in this repository
#   3. alpine       - a slim alternative (optional, needs `apk` tweaks)
#
# Every number in the report comes from `docker image inspect` on THIS machine.
# Nothing is estimated.
# =============================================================================
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_FILE="${PROJECT_DIR}/reports/image-size-report.txt"
UNOPT_TAG="devops-cicd-app:unoptimized"
OPT_TAG="devops-cicd-app:optimized"

mkdir -p "$(dirname "${REPORT_FILE}")"

log() { printf '\033[0;36m[measure]\033[0;m %s\n' "$*"; }

command -v docker >/dev/null 2>&1 || {
    echo "docker is required to run this script." >&2
    exit 1
}

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
image_size() {  # $1 = image ref
    docker image inspect "$1" --format '{{.Size}}' 2>/dev/null || echo 0
}

human() {  # bytes -> MiB
    awk -v b="$1" 'BEGIN {printf "%.1f MiB", b/1048576}'
}

build_timed() {  # $1 = tag, $2 = dockerfile
    local start end
    start=$(date +%s)
    log "Building $1 (dockerfile: $2) ..."
    docker build -f "$2" -t "$1" "${PROJECT_DIR}"
    end=$(date +%s)
    echo $(( end - start ))
}

# --------------------------------------------------------------------------- #
# Builds
# --------------------------------------------------------------------------- #
UNOPT_SECONDS="$(build_timed "${UNOPT_TAG}" "${PROJECT_DIR}/Dockerfile.unoptimized" | tail -1)"
OPT_SECONDS="$(build_timed "${OPT_TAG}" "${PROJECT_DIR}/Dockerfile" | tail -1)"

UNOPT_BYTES="$(image_size "${UNOPT_TAG}")"
OPT_BYTES="$(image_size "${OPT_TAG}")"

REDUCTION="$(awk -v u="${UNOPT_BYTES}" -v o="${OPT_BYTES}" 'BEGIN { if (u>0) printf "%.1f", (u-o)*100/u; else print "0" }')"
SAVED_BYTES=$(( UNOPT_BYTES - OPT_BYTES ))

# --------------------------------------------------------------------------- #
# Report
# --------------------------------------------------------------------------- #
{
    echo "==============================================================="
    echo " Docker image size comparison"
    echo " Generated : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo " Host      : $(uname -srm)"
    echo " Docker    : $(docker --version)"
    echo "==============================================================="
    echo
    printf "%-28s %14s %12s\n" "IMAGE" "SIZE" "BUILD TIME"
    printf "%-28s %14s %12s\n" "----------------------------" "--------------" "------------"
    printf "%-28s %14s %10ss\n" "${UNOPT_TAG}" "$(human "${UNOPT_BYTES}")" "${UNOPT_SECONDS}"
    printf "%-28s %14s %10ss\n" "${OPT_TAG}" "$(human "${OPT_BYTES}")" "${OPT_SECONDS}"
    echo
    echo "Size reduction : ${REDUCTION} %  (saved $(human "${SAVED_BYTES}"))"
    echo
    echo "Layer breakdown (optimized):"
    docker history --no-trunc --format '  {{.Size}}\t{{.CreatedBy}}' "${OPT_TAG}" | cut -c1-110
} | tee "${REPORT_FILE}"

log "Report written to ${REPORT_FILE}"
