#!/usr/bin/env bash
# =============================================================================
# collect-metrics.sh - collect real host metrics for the DevOps dashboard.
#
# Runs on the EC2 host (NOT inside the container) and writes a JSON snapshot
# that the Flask application reads through a read-only bind mount.
#
# Why a separate script?
#   The application container must NOT have the Docker socket or a shell on
#   the host. A tiny collector runs on the host, writes plain JSON, and the
#   container only ever reads that file. Credentials never leave the host.
#
# Usage:
#   ./scripts/collect-metrics.sh              # write the snapshot once
#   ./scripts/collect-metrics.sh --install    # install as a systemd timer
#
# Output:
#   ${STATE_DIR}/metrics.json   (default: /opt/devops-cicd/state/metrics.json)
#
# The script is intentionally defensive: if a command is missing (no Docker,
# no /proc, ...) the corresponding section is reported as unavailable instead
# of failing the whole collection.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(dirname "${SCRIPT_DIR}")}"
BASE_DIR="${BASE_DIR:-$(dirname "${DEPLOY_DIR}")}"
STATE_DIR="${STATE_DIR:-$BASE_DIR/state}"
OUTPUT_FILE="${OUTPUT_FILE:-$STATE_DIR/metrics.json}"
TMP_FILE="${OUTPUT_FILE}.tmp"

INSTALL_TIMER=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL_TIMER=true ;;
        -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "${STATE_DIR}"

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
json_escape() {
    # Escape a string so it can be embedded in a JSON string.
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\n\r'
}

# Read the whole aggregate "cpu" line from /proc/stat.
cpu_line() {
    awk '$1 == "cpu" { print; exit }' /proc/stat 2>/dev/null || true
}

# Read a value from /proc/meminfo ("MemTotal:  16316540 kB").
meminfo_kb() {
    awk -v k="$1:" '$1 == k { print $2; exit }' /proc/meminfo 2>/dev/null || true
}

# --- CPU --------------------------------------------------------------------
cpu_percent() {
    # Two samples of /proc/stat, 0.25 s apart -> real utilisation %.
    local line1 line2 idle1 idle2 total1 total2
    line1="$(cpu_line)"
    [[ -z "${line1}" ]] && { echo ""; return; }
    idle1="$(awk '{print $5 + $6}' <<<"${line1}")"
    total1="$(awk '{s = 0; for (i = 2; i <= NF; i++) s += $i; print s}' <<<"${line1}")"

    sleep 0.25

    line2="$(cpu_line)"
    [[ -z "${line2}" ]] && { echo ""; return; }
    idle2="$(awk '{print $5 + $6}' <<<"${line2}")"
    total2="$(awk '{s = 0; for (i = 2; i <= NF; i++) s += $i; print s}' <<<"${line2}")"

    awk -v t1="$total1" -v t2="$total2" -v i1="$idle1" -v i2="$idle2" 'BEGIN {
        dt = t2 - t1; di = i2 - i1;
        if (dt <= 0) { print "0"; exit }
        printf "%.1f", (1 - (di / dt)) * 100
    }'
}

CPU_CORES="$(nproc 2>/dev/null || echo '')"
CPU_PERCENT="$(cpu_percent)"

# --- Memory -----------------------------------------------------------------
MEM_TOTAL_KB="$(meminfo_kb MemTotal)"
MEM_AVAIL_KB="$(meminfo_kb MemAvailable)"
MEM_USED_KB=""
MEM_PERCENT=""
if [[ -n "${MEM_TOTAL_KB}" && -n "${MEM_AVAIL_KB}" ]]; then
    MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAIL_KB))
    MEM_PERCENT="$(awk -v u="${MEM_USED_KB}" -v t="${MEM_TOTAL_KB}" 'BEGIN { printf "%.1f", (u / t) * 100 }')"
fi

# --- Load / uptime ----------------------------------------------------------
LOAD_AVG="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '')"
HOSTNAME_VALUE="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"
# shellcheck source=/dev/null  # the path is a standard system file
OS_NAME="$( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}") || echo '' )"
[[ -z "${OS_NAME}" ]] && OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
KERNEL="$(uname -r 2>/dev/null || echo unknown)"
UPTIME_SECONDS="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo '')"

# --- Disk -------------------------------------------------------------------
DISK_JSON="["
DISK_FIRST=true
while read -r mountpoint; do
    [[ -z "${mountpoint}" ]] && continue
    usage="$(df -P "${mountpoint}" 2>/dev/null | awk 'NR == 2 {print $2, $3, $4, $5}')"
    [[ -z "${usage}" ]] && continue
    read -r total_kb used_kb avail_kb pct_raw <<<"${usage}"
    pct="${pct_raw%\%}"
    mountpoint_escaped="$(json_escape "${mountpoint}")"
    if [[ "${DISK_FIRST}" == "true" ]]; then DISK_FIRST=false; else DISK_JSON+=","; fi
    DISK_JSON+="{\"mount\":\"${mountpoint_escaped}\","
    DISK_JSON+="\"total_gb\":$(awk -v k="${total_kb}" 'BEGIN { printf "%.2f", k / 1048576 }'),"
    DISK_JSON+="\"used_gb\":$(awk -v k="${used_kb}" 'BEGIN { printf "%.2f", k / 1048576 }'),"
    DISK_JSON+="\"available_gb\":$(awk -v k="${avail_kb}" 'BEGIN { printf "%.2f", k / 1048576 }'),"
    DISK_JSON+="\"percent\":${pct}}"
done < <(df -P -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | awk 'NR > 1 {print $6}')
DISK_JSON+="]"

# --- Docker containers ------------------------------------------------------
DOCKER_AVAILABLE=false
CONTAINERS_JSON="[]"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    DOCKER_AVAILABLE=true
    CONTAINERS_JSON="$(docker ps -a --format '{{json .}}' 2>/dev/null | python3 -c '
import json, sys
out = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        item = json.loads(line)
    except json.JSONDecodeError:
        continue
    out.append({
        "id": item.get("ID", "")[:12],
        "name": item.get("Names", ""),
        "image": item.get("Image", ""),
        "state": item.get("State", ""),
        "status": item.get("Status", ""),
        "health": item.get("Status", "").split("(")[-1].rstrip(")") if "(" in item.get("Status", "") else None,
        "ports": item.get("Ports", ""),
    })
print(json.dumps(out))
' 2>/dev/null || echo '[]')"
fi

# --- Assemble ---------------------------------------------------------------
GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

{
    printf '%s' "{"
    printf '%s' "\"generated_at\":\"${GENERATED_AT}\","
    printf '%s' "\"hostname\":\"$(json_escape "${HOSTNAME_VALUE}")\","
    printf '%s' "\"os\":\"$(json_escape "${OS_NAME}")\","
    printf '%s' "\"kernel\":\"$(json_escape "${KERNEL}")\","
    printf '%s' "\"uptime_seconds\":${UPTIME_SECONDS:-0},"
    printf '%s' "\"load_average\":[${LOAD_AVG// /,}],"
    printf '%s' "\"docker_available\":${DOCKER_AVAILABLE},"
    printf '%s' "\"cpu\":{"
    printf '%s' "\"percent\":${CPU_PERCENT:-0},"
    printf '%s' "\"cores\":${CPU_CORES:-0}"
    printf '%s' "},"
    printf '%s' "\"memory\":{"
    if [[ -n "${MEM_PERCENT}" ]]; then
        printf '%s' "\"percent\":${MEM_PERCENT},"
        printf '%s' "\"total_mb\":$(awk -v k="${MEM_TOTAL_KB}" 'BEGIN { printf "%.0f", k / 1024 }'),"
        printf '%s' "\"used_mb\":$(awk -v k="${MEM_USED_KB}" 'BEGIN { printf "%.0f", k / 1024 }'),"
        printf '%s' "\"available_mb\":$(awk -v k="${MEM_AVAIL_KB}" 'BEGIN { printf "%.0f", k / 1024 }')"
    else
        printf '%s' "\"percent\":null,\"total_mb\":null,\"used_mb\":null,\"available_mb\":null"
    fi
    printf '%s' "},"
    printf '%s' "\"disk\":${DISK_JSON},"
    printf '%s' "\"containers\":${CONTAINERS_JSON}"
    printf '%s' "}"
} >"${TMP_FILE}"

# Only replace the live snapshot when it is valid JSON.
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${TMP_FILE}" 2>/dev/null; then
    mv -f "${TMP_FILE}" "${OUTPUT_FILE}"
    chmod 0644 "${OUTPUT_FILE}"
    echo "[collect-metrics] wrote ${OUTPUT_FILE}"
else
    rm -f "${TMP_FILE}"
    echo "[collect-metrics] ERROR: generated JSON was invalid - the previous snapshot was kept" >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Optional: install as a systemd timer (one snapshot per minute).
# --------------------------------------------------------------------------- #
if [[ "${INSTALL_TIMER}" == "true" ]]; then
    UNIT_DIR="/etc/systemd/system"
    cat >"${UNIT_DIR}/devops-metrics.service" <<EOF
[Unit]
Description=Collect DevOps host metrics for the monitoring dashboard
After=docker.service

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/collect-metrics.sh
EOF
    cat >"${UNIT_DIR}/devops-metrics.timer" <<EOF
[Unit]
Description=Run the DevOps metrics collector every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now devops-metrics.timer
    echo "[collect-metrics] systemd timer installed (devops-metrics.timer)"
fi
