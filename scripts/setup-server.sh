#!/usr/bin/env bash
# =============================================================================
# setup-server.sh - one-shot bootstrap of an Ubuntu AWS EC2 instance.
#
# Run ON the EC2 host (as root or with sudo):
#     sudo bash scripts/setup-server.sh
#
# It is idempotent: running it twice is safe.
#
# What it does
#   1. updates the system and installs base packages
#   2. installs Docker Engine + the Docker Compose plugin (official repo)
#   3. creates the `deployer` user and grants it Docker access
#   4. creates /opt/devops-cicd/{deploy,state,logs,backups}
#   5. generates the production secrets (random DB password + Flask secret key)
#   6. hardens the Docker daemon (log rotation, live-restore)
#   7. configures the UFW firewall (22, 80, 443 only)
#   8. installs log rotation for the deploy logs
#   9. installs the host metrics collector for the monitoring dashboard
# =============================================================================
set -Eeuo pipefail

# --------------------------------------------------------------------------- #
# Configuration (override with environment variables)
# --------------------------------------------------------------------------- #
DEPLOY_USER="${DEPLOY_USER:-deployer}"
BASE_DIR="${BASE_DIR:-/opt/devops-cicd}"
DEPLOY_DIR="${BASE_DIR}/deploy"
STATE_DIR="${BASE_DIR}/state"
LOG_DIR="${BASE_DIR}/logs"
BACKUP_DIR="${BASE_DIR}/backups"
SECRETS_FILE="${DEPLOY_DIR}/secrets.env"
DOCKER_GID=""

log()  { printf '\033[0;36m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[setup][WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[setup][ERROR]\033[0m %s\n' "$*" >&2; }

if [[ "${EUID}" -ne 0 ]]; then
    err "This script must be run as root:  sudo bash $0"
    exit 1
fi

# --------------------------------------------------------------------------- #
# 1. System packages
# --------------------------------------------------------------------------- #
log "1/8 Updating the system and installing base packages ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y \
    ca-certificates curl gnupg lsb-release apt-transport-https \
    ufw fail2ban unattended-upgrades \
    jq rsync unzip git

# --------------------------------------------------------------------------- #
# 2. Docker Engine + Compose plugin
# --------------------------------------------------------------------------- #
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "2/8 Docker and the Compose plugin are already installed."
else
    log "2/8 Installing Docker Engine and the Compose plugin ..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    # shellcheck disable=SC1091  # /etc/os-release is provided by the OS
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      >/etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi

systemctl enable --now docker
log "    Docker: $(docker --version)"
log "    Compose: $(docker compose version)"

# --------------------------------------------------------------------------- #
# 3. Deployment user
# --------------------------------------------------------------------------- #
log "3/8 Configuring the '${DEPLOY_USER}' user ..."
if id "${DEPLOY_USER}" >/dev/null 2>&1; then
    log "    User '${DEPLOY_USER}' already exists."
else
    adduser --disabled-password --gecos "Deployment user" "${DEPLOY_USER}"
    log "    User '${DEPLOY_USER}' created."
fi
usermod -aG docker "${DEPLOY_USER}"
DOCKER_GID="$(getent group docker | cut -d: -f3)"
log "    '${DEPLOY_USER}' is in the 'docker' group (gid ${DOCKER_GID})."

# --------------------------------------------------------------------------- #
# 3b. Authorise SSH for the deployment user
#
# The EC2 key pair is installed for the default login user (ubuntu/ec2-user).
# The pipeline logs in as the deploy user with the SAME key, so the deploy
# user needs those public keys too. Copy them over instead of making the
# student run `ssh-copy-id` by hand.
# --------------------------------------------------------------------------- #
DEPLOY_HOME="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
if [[ -n "${DEPLOY_HOME}" ]]; then
    install -d -m 0700 "${DEPLOY_HOME}/.ssh"
    AUTH_LINES="$(mktemp)"
    # Every key that is already trusted on this host, deduplicated.
    for f in /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys; do
        [[ -r "${f}" ]] && cat "${f}"
    done | grep -v '^[[:space:]]*$' | sort -u >"${AUTH_LINES}"

    if [[ -s "${AUTH_LINES}" ]]; then
        # NEVER overwrite keys the deploy user already has (e.g. a CI key).
        if [[ -f "${DEPLOY_HOME}/.ssh/authorized_keys" ]]; then
            cat "${AUTH_LINES}" "${DEPLOY_HOME}/.ssh/authorized_keys" \
                | grep -v '^[[:space:]]*$' | sort -u >"${AUTH_LINES}.merged"
            mv "${AUTH_LINES}.merged" "${AUTH_LINES}"
        fi
        install -m 0600 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" \
            "${AUTH_LINES}" "${DEPLOY_HOME}/.ssh/authorized_keys"
        log "    SSH keys authorised for '${DEPLOY_USER}' ($(wc -l <"${AUTH_LINES}") key(s))."
    else
        warn "    No authorized_keys found on this host."
        warn "    Authorise a key manually:  ssh-copy-id -i ~/.ssh/id_ed25519.pub ${DEPLOY_USER}@<EC2-IP>"
    fi
    rm -f "${AUTH_LINES}"
    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_HOME}/.ssh"
    chmod 0700 "${DEPLOY_HOME}/.ssh"
    chmod 0600 "${DEPLOY_HOME}/.ssh/authorized_keys" 2>/dev/null || true
fi

# --------------------------------------------------------------------------- #
# 4. Directory layout
# --------------------------------------------------------------------------- #
log "4/8 Creating the deployment directory tree ..."
install -d -m 0755 "${BASE_DIR}" "${DEPLOY_DIR}" "${STATE_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
install -d -m 0755 "${DEPLOY_DIR}/nginx" "${DEPLOY_DIR}/nginx/conf.d" "${DEPLOY_DIR}/nginx/templates"
install -d -m 0755 "${DEPLOY_DIR}/scripts"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${BASE_DIR}"
chmod 0750 "${STATE_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"

# The monitoring dashboard reads the state and log directories through a
# READ-ONLY bind mount. The application container runs as uid/gid 10001, so
# those two directories are group-owned by 10001: the app can read them, every
# other host user cannot.
if getent group 10001 >/dev/null 2>&1 || chgrp 10001 "${STATE_DIR}" "${LOG_DIR}" 2>/dev/null; then
    chgrp 10001 "${STATE_DIR}" "${LOG_DIR}" || warn "    Could not chgrp the state directories to gid 10001."
    chmod 0750 "${STATE_DIR}" "${LOG_DIR}"
    log "    State directories are readable by the app container (gid 10001)."
fi

# --------------------------------------------------------------------------- #
# 5. Production secrets
# --------------------------------------------------------------------------- #
log "5/8 Generating production secrets (only if they do not exist yet) ..."
if [[ -f "${SECRETS_FILE}" ]]; then
    warn "    ${SECRETS_FILE} already exists - keeping the current values."
else
    DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
    SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))' 2>/dev/null || head -c 48 /dev/urandom | base64)"
    cat >"${SECRETS_FILE}" <<EOF
# ---------------------------------------------------------------------------
# PRODUCTION SECRETS - generated by setup-server.sh
# NEVER commit this file, never share it, back it up somewhere safe.
# ---------------------------------------------------------------------------
POSTGRES_USER=appuser
POSTGRES_PASSWORD=${DB_PASSWORD}
POSTGRES_DB=devops_cicd
SECRET_KEY=${SECRET_KEY}
APP_DOMAIN=${APP_DOMAIN:-localhost}
EOF
    chmod 0600 "${SECRETS_FILE}"
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${SECRETS_FILE}"
    log "    Secrets written to ${SECRETS_FILE} (mode 0600)."
fi

# --------------------------------------------------------------------------- #
# 6. Docker daemon hardening
# --------------------------------------------------------------------------- #
log "6/8 Hardening the Docker daemon ..."
install -d -m 0755 /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
    cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" },
  "live-restore": true,
  "userland-proxy": false
}
EOF
    log "    /etc/docker/daemon.json created (log rotation + live-restore)."
else
    log "    /etc/docker/daemon.json already exists - leaving it untouched."
fi
systemctl restart docker

# --------------------------------------------------------------------------- #
# 7. Firewall
# --------------------------------------------------------------------------- #
log "7/8 Configuring the UFW firewall ..."
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH          >/dev/null   # 22
ufw allow 80/tcp            >/dev/null   # HTTP  (and the ACME challenge)
ufw allow 443/tcp           >/dev/null   # HTTPS
ufw --force enable >/dev/null
log "    UFW enabled: only ports 22, 80 and 443 are open."
ufw status verbose || true

systemctl enable --now fail2ban || warn "fail2ban could not be started."

# --------------------------------------------------------------------------- #
# 8. Log rotation for the deployment logs
# --------------------------------------------------------------------------- #
log "8/8 Configuring log rotation for ${LOG_DIR} ..."
cat >/etc/logrotate.d/devops-cicd <<'EOF'
${LOG_DIR}/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su ${DEPLOY_USER} ${DEPLOY_USER}
}
EOF

# --------------------------------------------------------------------------- #
# 9. Metrics collector for the monitoring dashboard
# --------------------------------------------------------------------------- #
log "9/9 Installing the host metrics collector (systemd timer) ..."
if [[ -x "${DEPLOY_DIR}/scripts/collect-metrics.sh" ]]; then
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_DIR}/scripts/collect-metrics.sh"
    if "${DEPLOY_DIR}/scripts/collect-metrics.sh" --install; then
        log "    The collector writes ${STATE_DIR}/metrics.json every minute."
    else
        warn "    The metrics collector could not be installed - the dashboard will show 'Unavailable'."
    fi
else
    warn "    ${DEPLOY_DIR}/scripts/collect-metrics.sh is missing - skipping the collector."
fi

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #
log ""
log "=========================================================="
log " Server setup complete"
log "=========================================================="
log " Base directory : ${BASE_DIR}"
log " Deploy user    : ${DEPLOY_USER}"
log " Next steps     :"
log "   1. Copy the repository to ${DEPLOY_DIR} (the CI pipeline does this)."
log "   2. The SSH key(s) that got you onto this host now also work as"
log "      ${DEPLOY_USER}:  ssh -i <your>.pem ${DEPLOY_USER}@<EC2-PUBLIC-IP>"
log "   3. Log in as ${DEPLOY_USER} and run: docker compose ps"
log "   4. Configure the domain:  sudo bash scripts/setup-ssl.sh <your-domain>"
log "   5. IMPORTANT: also restrict the AWS Security Group to 22/80/443."
log ""
exit 0
