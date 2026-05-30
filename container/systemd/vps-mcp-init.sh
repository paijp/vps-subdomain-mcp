#!/bin/bash
# vps-mcp-init.sh: first-boot initialisation for a VPS seminar container.
# Run once via: podman exec <name>-web /usr/local/bin/vps-mcp-init.sh
#
# Steps:
#   1. Write /etc/vps-mcp-env  (for mcp-server.service EnvironmentFile=)
#   2. Generate /etc/mcp-server/secret and /etc/mcp-server/token
#   3. Configure Postfix myhostname
#   4. Substitute server_name in the nginx config; reload nginx
#   5. Run certbot certonly --webroot
#   6. Switch nginx cert paths to Let's Encrypt; reload nginx
#   7. systemctl enable --now mcp-server
set -euo pipefail

SUBDOMAIN="${SUBDOMAIN:-}"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"

if [[ -z "$SUBDOMAIN" ]]; then
    echo "vps-mcp-init: SUBDOMAIN not set" >&2; exit 1
fi

# ── 0. Wait for systemd to be ready ──────────────────────────────────────────
echo "vps-mcp-init: waiting for systemd..."
for i in $(seq 60); do
    state=$(systemctl is-system-running 2>/dev/null || true)
    if [[ "$state" == "running" || "$state" == "degraded" ]]; then break; fi
    sleep 1
done
echo "vps-mcp-init: systemd ready (state=${state:-unknown})"

# ── 1. /etc/vps-mcp-env ──────────────────────────────────────────────────────
cat > /etc/vps-mcp-env <<EOF
SUBDOMAIN=${SUBDOMAIN}
NOTIFY_EMAIL=${NOTIFY_EMAIL}
EOF
chmod 640 /etc/vps-mcp-env

# ── 2. MCP credentials ───────────────────────────────────────────────────────
mkdir -p /etc/mcp-server
chmod 700 /etc/mcp-server
openssl rand -hex 32 > /etc/mcp-server/secret
openssl rand -hex 32 > /etc/mcp-server/token
chmod 600 /etc/mcp-server/secret /etc/mcp-server/token
echo "vps-mcp-init: client_secret=$(cat /etc/mcp-server/secret)"

# ── 3. Postfix ────────────────────────────────────────────────────────────────
postconf -e "myhostname = ${SUBDOMAIN}"
postconf -e "relayhost = [10.89.0.1]:25"
postconf -e "smtp_tls_security_level = none"
systemctl reload-or-restart postfix

# ── 4. nginx: replace server_name placeholder ────────────────────────────────
NGINX_CONF=/etc/nginx/sites-available/vps-mcp.conf
sed -i "s/server_name _;/server_name ${SUBDOMAIN};/g" "${NGINX_CONF}"
nginx -t && systemctl reload nginx

# ── 5. certbot ───────────────────────────────────────────────────────────────
if [[ -n "${NOTIFY_EMAIL}" ]]; then
    CERTBOT_EMAIL_FLAGS="--email ${NOTIFY_EMAIL} --no-eff-email"
else
    CERTBOT_EMAIL_FLAGS="--register-unsafely-without-email"
fi
certbot certonly \
    --staging \
    --webroot --webroot-path /var/www/html \
    --non-interactive --agree-tos \
    ${CERTBOT_EMAIL_FLAGS} \
    --domain "${SUBDOMAIN}" \
    || { echo "vps-mcp-init: certbot failed, keeping self-signed cert" >&2
         systemctl enable --now mcp-server
         exit 0; }

# ── 6. nginx: switch to Let's Encrypt cert ───────────────────────────────────
LIVE_DIR="/etc/letsencrypt/live/${SUBDOMAIN}"
sed -i \
    -e "s|ssl_certificate .*|ssl_certificate     ${LIVE_DIR}/fullchain.pem;|" \
    -e "s|ssl_certificate_key .*|ssl_certificate_key ${LIVE_DIR}/privkey.pem;|" \
    "${NGINX_CONF}"
nginx -t && systemctl reload nginx

# ── 7. mcp-server ────────────────────────────────────────────────────────────
systemctl enable --now mcp-server

echo "vps-mcp-init: done (${SUBDOMAIN})"
