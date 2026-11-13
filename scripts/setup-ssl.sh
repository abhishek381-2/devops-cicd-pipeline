#!/usr/bin/env bash
# =============================================================================
# setup-ssl.sh - issue and install a Let's Encrypt certificate (Certbot).
#
# Run ON the EC2 host:
#     sudo bash scripts/setup-ssl.sh app.example.com
#
# Prerequisites
#   * the domain's A record points to this server's public IP
#   * ports 80 and 443 are open in BOTH the AWS security group and UFW
#   * the stack is already running (docker compose ps shows healthy services)
#
# What it does
#   1. requests a certificate from Let's Encrypt (HTTP-01 challenge)
#   2. renders nginx/templates/app-https.conf.template -> nginx/conf.d/
#   3. disables the plain-HTTP vhost and reloads Nginx
#   4. installs a renewal timer so the certificate renews automatically
# =============================================================================
set -Eeuo pipefail

DOMAIN="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(dirname "${SCRIPT_DIR}")}"
NGINX_DIR="${DEPLOY_DIR}/nginx"
TEMPLATE="${NGINX_DIR}/templates/app-https.conf.template"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.prod.yml"

log()  { printf '\033[0;36m[ssl]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[ssl][ERROR]\033[0m %s\n' "$*" >&2; }

[[ -z "${DOMAIN}" ]] && { err "Usage: sudo bash $0 <your-domain.com>"; exit 2; }
[[ "${EUID}" -ne 0 ]] && { err "Run this script with sudo."; exit 2; }
[[ -f "${TEMPLATE}" ]] || { err "Template not found: ${TEMPLATE}"; exit 2; }
[[ -f "${COMPOSE_FILE}" ]] || { err "Compose file not found: ${COMPOSE_FILE}"; exit 2; }

log "Domain        : ${DOMAIN}"
log "Public IP     : $(curl -fsS https://checkip.amazonaws.com || echo 'unknown')"
log ""

# --------------------------------------------------------------------------- #
# 1. Sanity checks
# --------------------------------------------------------------------------- #
log "1/4 Checking DNS resolution ..."
RESOLVED_IP="$(getent hosts "${DOMAIN}" | awk '{print $1}' | head -1 || true)"
SERVER_IP="$(curl -fsS https://checkip.amazonaws.com || echo '')"
if [[ -z "${RESOLVED_IP}" ]]; then
    err "The domain '${DOMAIN}' does not resolve. Add an A record pointing to ${SERVER_IP} first."
    exit 1
fi
log "    ${DOMAIN} -> ${RESOLVED_IP} (server public IP: ${SERVER_IP})"
if [[ -n "${SERVER_IP}" && "${RESOLVED_IP}" != "${SERVER_IP}" ]]; then
    err "The domain resolves to a different IP than this server. Fix the DNS record first."
    exit 1
fi

# --------------------------------------------------------------------------- #
# 2. Request the certificate
# --------------------------------------------------------------------------- #
log "2/4 Requesting the certificate from Let's Encrypt ..."
docker compose -f "${COMPOSE_FILE}" run --rm --entrypoint "\
certbot certonly --webroot --webroot-path=/var/www/certbot \
  --domain ${DOMAIN} --email ${CERTBOT_EMAIL:-admin@example.com} \
  --agree-tos --no-eff-email --non-interactive" certbot || {
    err "Certbot failed. Check that port 80 is open and that the ACME path is reachable:"
    err "  curl -I http://${DOMAIN}/.well-known/acme-challenge/test"
    exit 1
}

# --------------------------------------------------------------------------- #
# 3. Render the TLS virtual host
# --------------------------------------------------------------------------- #
log "3/4 Rendering the HTTPS virtual host ..."
install -d -m 0755 "${NGINX_DIR}/conf.d"
# The single quotes are intentional: envsubst must receive the LITERAL
# variable name '${APP_DOMAIN}', not its expanded value.
# shellcheck disable=SC2016
APP_DOMAIN="${DOMAIN}" envsubst '${APP_DOMAIN}' <"${TEMPLATE}" >"${NGINX_DIR}/conf.d/app-https.conf"

# The plain-HTTP vhost would conflict on port 80 -> disable it.
if [[ -f "${NGINX_DIR}/conf.d/app.conf" ]]; then
    mv "${NGINX_DIR}/conf.d/app.conf" "${NGINX_DIR}/conf.d/app.conf.disabled"
    log "    Disabled the plain-HTTP vhost (app.conf -> app.conf.disabled)."
fi

log "    Validating the configuration ..."
docker compose -f "${COMPOSE_FILE}" exec -T nginx nginx -t || {
    err "The generated Nginx configuration is invalid - check ${NGINX_DIR}/conf.d/app-https.conf"
    exit 1
}
docker compose -f "${COMPOSE_FILE}" exec -T nginx nginx -s reload
log "    Nginx reloaded."

# --------------------------------------------------------------------------- #
# 4. Automatic renewal
# --------------------------------------------------------------------------- #
log "4/4 Configuring the automatic renewal timer ..."
cat >/etc/systemd/system/certbot-renew.service <<EOF
[Unit]
Description=Renew the Let's Encrypt certificate for ${DOMAIN}
After=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/docker compose -f ${COMPOSE_FILE} run --rm --entrypoint "certbot renew --quiet" certbot
ExecStartPost=/usr/bin/docker compose -f ${COMPOSE_FILE} exec -T nginx nginx -s reload
EOF

cat >/etc/systemd/system/certbot-renew.timer <<'EOF'
[Unit]
Description=Run the Let's Encrypt renewal twice a day

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now certbot-renew.timer

log ""
log "=========================================================="
log " HTTPS is configured for ${DOMAIN}"
log "=========================================================="
log " Test it :  curl -I https://${DOMAIN}/health"
log " Renewal:  systemctl list-timers certbot-renew.timer"
log " Dry run:  docker compose -f ${COMPOSE_FILE} run --rm --entrypoint 'certbot renew --dry-run' certbot"
log ""
exit 0
