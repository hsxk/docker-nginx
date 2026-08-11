#!/usr/bin/env bash
# tests/validate-examples.sh — prove examples/conf.d/*.conf load together.
#
#   ./tests/validate-examples.sh my-nginx:latest
#
# The examples are templates: they name domains that don't exist and certs
# that aren't there, so nothing in the normal build ever parses them. That is
# how 00-http-redirect.conf and 05-default-deny.conf both ended up claiming
# `default_server` on :80 — a pair nginx refuses to start with.
#
# This mounts all of them at once into the real image, mints throwaway certs
# for exactly the server_names they reference, stubs out the upstream
# hostnames, and runs `nginx -t`.

set -euo pipefail

IMAGE="${1:?usage: validate-examples.sh <image>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mint_certs='
        for cn in example.com app.example.com wp.example.com; do
            mkdir -p "/etc/letsencrypt/live/$cn"
            openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj "/CN=$cn" \
                -keyout "/etc/letsencrypt/live/$cn/privkey.pem" \
                -out    "/etc/letsencrypt/live/$cn/fullchain.pem" >/dev/null 2>&1
        done
        mkdir -p /etc/letsencrypt/_default
        openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj "/CN=localhost" \
            -keyout /etc/letsencrypt/_default/privkey.pem \
            -out    /etc/letsencrypt/_default/fullchain.pem >/dev/null 2>&1
        mkdir -p /var/www/html
'

echo "==> nginx -t against examples/conf.d/ ($IMAGE)"

# --add-host: `upstream { server app:3000; }` is resolved at config-parse time,
# so an unresolvable name fails `nginx -t` with "host not found in upstream"
# regardless of whether the config itself is correct.
docker run --rm \
    --add-host app:127.0.0.1 \
    --add-host php-fpm:127.0.0.1 \
    -v "$ROOT/examples/conf.d:/etc/nginx/conf.d:ro" \
    --entrypoint /bin/sh \
    "$IMAGE" -ec "${mint_certs}
        nginx -t
    "

# ── Phase 2: every shipped snippet, in one config ───────────────────────────
# The examples do not include all of them — error-pages.conf and real-ip.conf
# are referenced by nothing, so nothing ever parsed them. A snippet is the
# product here; "it is at least loadable" is the floor.
#
# Excluded: zstd/geoip2/vts, which need their ENABLE_* build and are covered by
# the matrix flavors, and http3.conf, which needs a quic listener the examples
# already exercise.
echo "==> nginx -t against every non-optional snippet ($IMAGE)"

docker run --rm \
    --add-host php-fpm:127.0.0.1 \
    -v "$ROOT/tests/snippet-coverage.conf:/etc/nginx/conf.d/snippet-coverage.conf:ro" \
    --entrypoint /bin/sh \
    "$IMAGE" -ec "${mint_certs}
        nginx -t
    "

echo "examples and snippets validate cleanly"
