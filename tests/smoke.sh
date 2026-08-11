#!/usr/bin/env bash
# tests/smoke.sh — boot the image and assert it actually works.
#
#   ./tests/smoke.sh my-nginx:latest
#
# `nginx -t` only proves the config parses. This proves the container serves:
# it starts with no mounted config (so it exercises the entrypoint's fallback
# vhost + self-signed cert path), waits for the HEALTHCHECK to go green, and
# then checks the handful of behaviours that have silently regressed here
# before — security headers surviving snippet includes, HSTS staying off
# plaintext, the QUIC listener actually being bound.

set -euo pipefail

IMAGE="${1:?usage: smoke.sh <image>}"
NAME="nginx-smoke-$$"
NET="nginx-smoke-net-$$"
HTTP_PORT="${HTTP_PORT:-18080}"
TLS_PORT="${TLS_PORT:-18443}"

fail=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

cleanup() {
    docker logs "$NAME" 2>&1 | sed 's/^/    | /' || true
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A user-defined network on purpose, not the default bridge: only user-defined
# networks get Docker's embedded DNS at 127.0.0.11, and that is what the
# entrypoint's resolver generation is supposed to pick up. It is also how
# anybody actually runs this (compose creates one implicitly).
docker network create "$NET" >/dev/null

echo "==> starting $IMAGE"
docker run -d --name "$NAME" --network "$NET" \
    -p "127.0.0.1:${HTTP_PORT}:80/tcp" \
    -p "127.0.0.1:${TLS_PORT}:443/tcp" \
    -p "127.0.0.1:${TLS_PORT}:443/udp" \
    "$IMAGE" >/dev/null

echo "==> waiting for HEALTHCHECK"
for i in $(seq 1 60); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo starting)
    [ "$status" = healthy ] && break
    if [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != true ]; then
        bad "container exited during startup"
        exit 1
    fi
    sleep 1
done
check "container reports healthy" "$status" "healthy"

echo "==> build features"
nginx_v=$(docker run --rm "$IMAGE" nginx -V 2>&1)
case "$nginx_v" in
    *--with-http_v3_module*) pass "built with http_v3_module" ;;
    *) bad "http_v3_module missing from nginx -V" ;;
esac
# The QUIC API nginx compiles against is chosen from the OpenSSL headers:
# below 3.5.1 it silently downgrades to the slower compat shim.
case "$nginx_v" in
    *"OpenSSL 3.5"*|*"OpenSSL 3.6"*|*"OpenSSL 4"*) pass "TLS: $(echo "$nginx_v" | grep -o 'built with OpenSSL[^ ]* [0-9.]*' | head -1)" ;;
    *) bad "expected OpenSSL >= 3.5 for the native QUIC server API: $(echo "$nginx_v" | grep -i 'built with' || true)" ;;
esac

echo "==> listeners"
udp_listeners=$(docker exec "$NAME" netstat -lun 2>/dev/null || true)
if grep -q ':443' <<<"$udp_listeners"; then
    pass "QUIC/UDP :443 bound"
else
    bad "no UDP listener on :443 — HTTP/3 would be advertised but dead"
fi

echo "==> plain HTTP"
code=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}/healthz")
check "GET /healthz" "$code" "200"

code=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}/")
check "GET / redirects to TLS" "$code" "301"

http_hdrs=$(curl -sSI "http://127.0.0.1:${HTTP_PORT}/")
if grep -qi '^strict-transport-security:' <<<"$http_hdrs"; then
    bad "HSTS sent over plaintext (the \$https map is not working)"
else
    pass "no HSTS over plaintext"
fi

echo "==> HTTPS"
code=$(curl -sSk -o /dev/null -w '%{http_code}' "https://127.0.0.1:${TLS_PORT}/")
check "GET / over TLS" "$code" "200"

if curl -sSk --http2 -o /dev/null -w '%{http_version}' "https://127.0.0.1:${TLS_PORT}/" | grep -q '^2'; then
    pass "HTTP/2 negotiated"
else
    bad "HTTP/2 not negotiated"
fi

# The regression that motivated this file: every snippet that carries an
# add_header of its own (http3.conf's Alt-Svc here) used to wipe the whole
# inherited security-header set for the vhost.
tls_hdrs=$(curl -sSkI "https://127.0.0.1:${TLS_PORT}/")
for h in strict-transport-security x-content-type-options x-frame-options \
         referrer-policy cross-origin-opener-policy alt-svc; do
    if grep -qi "^${h}:" <<<"$tls_hdrs"; then
        pass "header $h present alongside Alt-Svc"
    else
        bad "header $h missing"
    fi
done

# Content-Type must appear exactly once (add_header would have duplicated it).
ct=$(grep -ci '^content-type:' <<<"$(curl -sSI "http://127.0.0.1:${HTTP_PORT}/healthz")" || true)
check "healthz has a single Content-Type" "$ct" "1"

echo "==> quic_bpf capability detection"
# Under Docker's default capability set the answer must be "off". Getting this
# wrong is not a subtle bug: nginx refuses to start when quic_bpf is set
# without CAP_BPF/CAP_NET_ADMIN, so a false positive here bricks every
# container that does not opt in. (The container being healthy above already
# proves nginx started, which is half the assertion.)
bpf=$(docker exec "$NAME" cat /etc/nginx/quic-bpf.conf)
if grep -q '^quic_bpf on;' <<<"$bpf"; then
    bad "quic_bpf enabled without the capabilities for it"
else
    pass "quic_bpf correctly off under default capabilities"
fi

echo "==> no startup warnings"
# ssl_stapling used to emit one of these per certificate on every boot.
if docker logs "$NAME" 2>&1 | grep -qi '\[warn\]'; then
    bad "startup emits warnings: $(docker logs "$NAME" 2>&1 | grep -i '\[warn\]' | head -1)"
else
    pass "clean startup, no warnings"
fi

echo "==> resolver"
resolver=$(docker exec "$NAME" cat /etc/nginx/resolver.conf)
if grep -q '^resolver .*127\.0\.0\.11' <<<"$resolver"; then
    pass "resolver picked up Docker embedded DNS"
else
    bad "resolver not generated from /etc/resolv.conf: $resolver"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "all smoke checks passed"
else
    echo "smoke checks FAILED"
fi
exit "$fail"
