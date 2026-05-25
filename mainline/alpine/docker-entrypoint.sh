#!/bin/sh
# docker-entrypoint.sh — runs at container start.
#
# Goals (in order):
#   1. If conf.d/ is empty (user didn't mount anything), seed it with a
#      built-in fallback vhost so the image boots into a working state.
#   2. If no certificate exists at /etc/letsencrypt/_default/, drop in a
#      throw-away self-signed pair so nginx can boot for local testing.
#      In production, mount your real certs into /etc/letsencrypt/.
#   3. Validate config with `nginx -t`.
#   4. Exec the requested command (default: nginx -g 'daemon off;').
#
# Periodic reload (for cert renewal) is the host's job — run e.g.:
#     docker exec nginx nginx -s reload
# from your certbot --deploy-hook. We do NOT run a sleep-and-reload loop
# inside the container; it would mask crashes and leave zombie sleeps.

set -eu

CERT_DIR="${CERT_DIR:-/etc/letsencrypt}"
DEFAULT_CN="${DEFAULT_CN:-localhost}"
CONFD="${CONFD:-/etc/nginx/conf.d}"
DEFAULT_CONFD="${DEFAULT_CONFD:-/usr/share/nginx-defaults}"

# 1. Seed conf.d if empty.
seed_default_confd() {
    [ -d "$CONFD" ] || mkdir -p "$CONFD"
    # If the user mounted their own conf.d, leave it alone.
    if [ -n "$(ls -A "$CONFD" 2>/dev/null)" ]; then
        return 0
    fi
    if [ -d "$DEFAULT_CONFD" ] && [ -n "$(ls -A "$DEFAULT_CONFD" 2>/dev/null)" ]; then
        echo "[entrypoint] conf.d/ is empty, installing built-in fallback vhost"
        cp -a "$DEFAULT_CONFD"/. "$CONFD/"
    fi
}

# 2. Ensure a usable default cert exists at _default/.
#    Path matches certbot's `live/<name>/{fullchain,privkey}.pem` layout so
#    real certs are a drop-in replacement.
ensure_default_cert() {
    target="${CERT_DIR}/_default"
    cert="${target}/fullchain.pem"
    key="${target}/privkey.pem"
    [ -f "$cert" ] && [ -f "$key" ] && return 0

    echo "[entrypoint] no default cert found, generating self-signed for CN=${DEFAULT_CN}"
    mkdir -p "$target"
    openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
        -subj "/CN=${DEFAULT_CN}" \
        -addext "subjectAltName=DNS:${DEFAULT_CN},DNS:localhost,IP:127.0.0.1" \
        -keyout "$key" \
        -out    "$cert" >/dev/null 2>&1
    chmod 600 "$key"
    chmod 644 "$cert"
}

seed_default_confd
ensure_default_cert

# 3. If the user passed `nginx ...`, validate config first.
case "${1:-}" in
    nginx|/usr/sbin/nginx)
        echo "[entrypoint] running 'nginx -t'…"
        nginx -t
        ;;
esac

exec "$@"
