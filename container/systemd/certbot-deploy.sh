#!/bin/bash
# https://github.com/paijp/vps-subdomain-mcp
# certbot-deploy.sh: deploy hook called by certbot after successful renewal.
# Updates the nginx config cert paths and reloads nginx.
set -euo pipefail

SUBDOMAIN="${RENEWED_DOMAINS%% *}"
NGINX_CONF=/etc/nginx/conf.d/vps-mcp.conf
LIVE_DIR="/etc/letsencrypt/live/${SUBDOMAIN}"

sed -i \
    -e "s|ssl_certificate .*|ssl_certificate     ${LIVE_DIR}/fullchain.pem;|" \
    -e "s|ssl_certificate_key .*|ssl_certificate_key ${LIVE_DIR}/privkey.pem;|" \
    "${NGINX_CONF}"

nginx -t && systemctl reload nginx
