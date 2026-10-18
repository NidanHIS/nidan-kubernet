#!/bin/sh
set -e

# --------------------------------------------------
# Generate self-signed certificate if needed
# --------------------------------------------------
DOMAIN="${GATEWAY_DOMAIN:-localhost}"
LIVE_DIR="/etc/letsencrypt/live/${DOMAIN}"

if [ ! -f "${LIVE_DIR}/fullchain.pem" ] || [ ! -f "${LIVE_DIR}/privkey.pem" ]; then
    echo "No cert found for ${DOMAIN}, generating self-signed certificate..."
    mkdir -p "${LIVE_DIR}"

    openssl req -x509 -nodes -days 365 \
        -subj "/CN=${DOMAIN}" \
        -newkey rsa:2048 \
        -keyout "${LIVE_DIR}/privkey.pem" \
        -out "${LIVE_DIR}/fullchain.pem" 2>/dev/null

    echo "Certificate generated for ${DOMAIN}"
fi

# --------------------------------------------------
# Dynamically detect Kubernetes DNS resolver
# --------------------------------------------------
K8S_DNS_RESOLVER="${K8S_DNS_RESOLVER:-$(awk '
    /^nameserver[[:space:]]/ { print $2; exit }
' /etc/resolv.conf)}"

if [ -z "${K8S_DNS_RESOLVER}" ]; then
    echo "ERROR: Could not detect DNS resolver from /etc/resolv.conf"
    exit 1
fi

export K8S_DNS_RESOLVER
echo "Using DNS resolver: ${K8S_DNS_RESOLVER}"

# --------------------------------------------------
# Template Nginx configuration
# --------------------------------------------------
export OPENELIS_CONTEXT_PATH="${OPENELIS_CONTEXT_PATH:-/api/OpenELIS-Global/}"
export DASHBOARD_ODOO_URL="${DASHBOARD_ODOO_URL:-http://localhost:8069}"

envsubst '${GATEWAY_DOMAIN} ${OPENELIS_CONTEXT_PATH} ${K8S_DNS_RESOLVER}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

# --------------------------------------------------
# Template dashboard HTML
# --------------------------------------------------
INDEX_TEMPLATE="${INDEX_HTML_TEMPLATE:-/etc/nginx/templates/index.html.template}"

envsubst '${DASHBOARD_ODOO_URL}' \
    < "${INDEX_TEMPLATE}" \
    > /usr/share/nginx/html/index.html

# --------------------------------------------------
# Validate configuration before starting
# --------------------------------------------------
nginx -t

# Execute the original command
exec "$@"
