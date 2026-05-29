#!/bin/bash
# vps-mcp-init.sh: first-boot initialisation for a VPS seminar container.
# Reads SUBDOMAIN and NOTIFY_EMAIL from the container environment
# (passed via Podman --env / Quadlet Environment=), then:
#   1. Writes /etc/vps-mcp-env for subsequent service units.
#   2. Configures Postfix myhostname.
#   3. Substitutes __SUBDOMAIN__ in the nginx config.
#   4. Requests a Let's Encrypt certificate (certonly --webroot).
#   5. Replaces self-signed cert paths in nginx config with live cert paths.
#
# The ConditionPathExists=!/etc/vps-mcp-env guard in the .service unit
# ensures this script runs only once.
set -euo pipefail

# ── 1. Read environment ───────────────────────────────────────────────────────
# When running under systemd inside a container, environment variables set
# on the container (podman run --env or Quadlet Environment=) are available
# in the process environment.
SUBDOMAIN="${SUBDOMAIN:-}"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"

if [[ -z "$SUBDOMAIN" ]]; then
    echo "vps-mcp-init: SUBDOMAIN not set, aborting" >&2
    exit 1
fi

# Persist for other units (mcp-server.service uses EnvironmentFile=).
cat > /etc/vps-mcp-env <<EOF
SUBDOMAIN=${SUBDOMAIN}
NOTIFY_EMAIL=${NOTIFY_EMAIL}
EOF
chmod 640 /etc/vps-mcp-env

# ── 2. Postfix ────────────────────────────────────────────────────────────────
postconf -e "myhostname = ${SUBDOMAIN}"
systemctl reload-or-restart postfix || true

# ── 3. nginx: substitute __SUBDOMAIN__ ───────────────────────────────────────
NGINX_CONF=/etc/nginx/sites-available/vps-mcp.conf
sed -i "s/__SUBDOMAIN__/${SUBDOMAIN}/g" "${NGINX_CONF}"

# Start nginx with self-signed cert so the ACME challenge path is reachable.
systemctl reload-or-restart nginx || systemctl start nginx

# ── 4. certbot: obtain certificate ───────────────────────────────────────────
certbot certonly \
    --webroot \
    --webroot-path /var/www/html \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    --domain "${SUBDOMAIN}" \
    || { echo "vps-mcp-init: certbot failed, keeping self-signed cert" >&2; exit 0; }

# ── 5. nginx: switch to Let's Encrypt certificate ────────────────────────────
LIVE_DIR="/etc/letsencrypt/live/${SUBDOMAIN}"
sed -i \
    -e "s|ssl_certificate .*|ssl_certificate     ${LIVE_DIR}/fullchain.pem;|" \
    -e "s|ssl_certificate_key .*|ssl_certificate_key ${LIVE_DIR}/privkey.pem;|" \
    "${NGINX_CONF}"

nginx -t && systemctl reload nginx
echo "vps-mcp-init: done (${SUBDOMAIN})"
