#!/usr/bin/env bash
# tests/smoke.sh — boot the image and assert it actually works.
#
#   ./tests/smoke.sh my-nginx:latest
#
# This is intentionally runtime-heavy. nginx -t only proves syntax; this also
# checks the shipped fallback vhost, protocol listeners, TLS handshakes,
# compression, module loading, and security-header override behaviour.

set -euo pipefail

IMAGE="${1:?usage: smoke.sh <image>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="nginx-smoke-$$"
NET="nginx-smoke-net-$$"
HTTP_PORT="${HTTP_PORT:-18080}"
TLS_PORT="${TLS_PORT:-18443}"
HEADER_PORT="${HEADER_PORT:-18444}"

fail=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
check() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        bad "$1 (want '$3', got '$2')"
    fi
}

cleanup() {
    docker logs "$NAME" 2>&1 | sed 's/^/    | /' || true
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$NET" >/dev/null

echo "==> starting $IMAGE"
docker run -d --name "$NAME" --network "$NET" \
    -p "127.0.0.1:${HTTP_PORT}:80/tcp" \
    -p "127.0.0.1:${TLS_PORT}:443/tcp" \
    -p "127.0.0.1:${TLS_PORT}:443/udp" \
    -p "127.0.0.1:${HEADER_PORT}:8444/tcp" \
    "$IMAGE" >/dev/null

echo "==> waiting for HEALTHCHECK"
status=starting
for _ in $(seq 1 60); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo starting)
    [ "$status" = healthy ] && break
    if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)" != true ]; then
        bad "container exited during startup"
        exit 1
    fi
    sleep 1
done
check "container reports healthy" "$status" "healthy"

echo "==> build and runtime versions"
nginx_v=$(docker run --rm --entrypoint nginx "$IMAGE" -V 2>&1)
printf '%s\n' "$nginx_v"

runtime_version=$(docker run --rm --entrypoint sh "$IMAGE" -c 'printf "%s" "$NGINX_VERSION"')
binary_version_line=$(docker run --rm --entrypoint nginx "$IMAGE" -v 2>&1)
binary_version=$(printf '%s\n' "$binary_version_line" | sed 's#^nginx version: nginx/##; s/ .*//')
check "runtime nginx -v matches NGINX_VERSION" "$binary_version" "$runtime_version"
case "$binary_version_line" in
    *" (docker-nginx-quic)"*) pass "custom nginx build marker present" ;;
    *) bad "custom nginx build marker missing" ;;
esac

openssl_version=$(docker run --rm --entrypoint openssl "$IMAGE" version | awk '{print $2}')
check "runtime OpenSSL version" "$openssl_version" "3.5.8"

if docker run --rm --entrypoint nginx "$IMAGE" -t >/dev/null 2>&1; then
    pass "nginx -t"
else
    bad "nginx -t failed"
fi

for module in \
    ngx_http_headers_more_filter_module.so \
    ngx_http_brotli_filter_module.so \
    ngx_http_brotli_static_module.so \
    ngx_http_cache_purge_module.so; do
    if docker run --rm --entrypoint sh "$IMAGE" -c "test -f /usr/lib/nginx/modules/$module"; then
        pass "dynamic module present: $module"
    else
        bad "dynamic module missing: $module"
    fi
done

module_count=$(docker run --rm --entrypoint sh "$IMAGE" -c \
    "find /usr/lib/nginx/modules -maxdepth 1 -type f -name '*.so' | wc -l" | tr -d '[:space:]')
load_count=$(docker run --rm --entrypoint sh "$IMAGE" -c \
    "grep -h '^load_module /usr/lib/nginx/modules/.*\.so;$' /etc/nginx/modules-enabled/*.conf | wc -l" | tr -d '[:space:]')
check "every dynamic module has one load_module entry" "$load_count" "$module_count"

for feature in --with-control-api --with-http_json_module \
               --with-http_ssl_module --with-http_v2_module --with-http_v3_module; do
    case "$nginx_v" in
        *"$feature"*) pass "nginx -V contains $feature" ;;
        *) bad "$feature missing from nginx -V" ;;
    esac
done

case "$nginx_v" in
    *"OpenSSL 3.5"*|*"OpenSSL 3.6"*|*"OpenSSL 4"*) pass "nginx built with QUIC-capable OpenSSL" ;;
    *) bad "nginx -V does not report OpenSSL >= 3.5" ;;
esac

echo "==> listeners and protocol config"
runtime_config=$(docker exec "$NAME" nginx -T 2>&1)

check_config() {
    pattern="$1"
    label="$2"
    if grep -Eq "$pattern" <<<"$runtime_config"; then
        pass "$label"
    else
        bad "$label"
    fi
}

check_config 'http2[[:space:]]+on;' "HTTP/2 enabled in runtime config"
check_config 'listen[[:space:]]+443[[:space:]]+quic' "HTTP/3 QUIC listener configured"
check_config 'ssl_protocols[[:space:]]+TLSv1\.2[[:space:]]+TLSv1\.3;' "TLS 1.2/1.3 configured"
check_config 'brotli[[:space:]]+on;' "Brotli enabled in runtime config"

if docker exec "$NAME" netstat -lun 2>/dev/null | grep -q ':443'; then
    pass "QUIC/UDP :443 bound"
else
    bad "no UDP listener on :443 — HTTP/3 would be advertised but dead"
fi

for tls_flag in -tls1_2 -tls1_3; do
    if docker exec "$NAME" sh -c \
        "printf '\n' | timeout 5 openssl s_client $tls_flag -connect 127.0.0.1:443 -servername localhost >/dev/null 2>&1"; then
        pass "TLS handshake succeeds with $tls_flag"
    else
        bad "TLS handshake failed with $tls_flag"
    fi
done

openssl_sclient_help=$(docker exec "$NAME" openssl s_client -help 2>&1 || true)
if grep -q -- '-quic' <<<"$openssl_sclient_help"; then
    quic_handshake=$(docker exec "$NAME" sh -c \
        "printf '\n' | timeout 5 openssl s_client -quic -connect 127.0.0.1:443 -servername localhost -alpn h3 2>&1 || true")
    if grep -q 'ALPN protocol: h3' <<<"$quic_handshake"; then
        pass "HTTP/3 QUIC handshake negotiates h3 via ALPN"
    else
        bad "QUIC listener did not negotiate h3 via ALPN"
    fi
else
    bad "OpenSSL s_client lacks -quic support"
fi

echo "==> plain HTTP"
code=$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${HTTP_PORT}/healthz")
check "GET /healthz" "$code" "200"

code=$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${HTTP_PORT}/")
check "GET / redirects to TLS" "$code" "301"

http_hdrs=$(curl --noproxy '*' -sSI "http://127.0.0.1:${HTTP_PORT}/")
if grep -qi '^strict-transport-security:' <<<"$http_hdrs"; then
    bad "HSTS sent over plaintext"
else
    pass "no HSTS over plaintext"
fi

echo "==> HTTPS"
code=$(curl --noproxy '*' -sSk -o /dev/null -w '%{http_code}' \
    "https://127.0.0.1:${TLS_PORT}/")
check "GET / over TLS" "$code" "200"

if curl --noproxy '*' -sSk --http2 -o /dev/null -w '%{http_version}' \
    "https://127.0.0.1:${TLS_PORT}/" | grep -q '^2'; then
    pass "HTTP/2 negotiated"
else
    bad "HTTP/2 not negotiated"
fi

tls_hdrs=$(curl --noproxy '*' -sSkI "https://127.0.0.1:${TLS_PORT}/")
for h in strict-transport-security x-content-type-options x-frame-options \
         referrer-policy permissions-policy cross-origin-opener-policy alt-svc; do
    if grep -qi "^${h}:" <<<"$tls_hdrs"; then
        pass "header $h present alongside Alt-Svc"
    else
        bad "header $h missing"
    fi
done

default_xfo_count=$(grep -ci '^x-frame-options:' <<<"$tls_hdrs" || true)
check "default response has exactly one X-Frame-Options" "$default_xfo_count" "1"
default_xfo=$(awk -F': *' 'tolower($1)=="x-frame-options"{gsub("\r","",$2); print $2}' <<<"$tls_hdrs")
check "default X-Frame-Options value" "$default_xfo" "SAMEORIGIN"

ct=$(grep -ci '^content-type:' <<<"$(curl --noproxy '*' -sSI "http://127.0.0.1:${HTTP_PORT}/healthz")" || true)
check "healthz has a single Content-Type" "$ct" "1"

echo "==> security-header overrides"
docker cp "$ROOT/tests/header-overrides.conf" \
    "$NAME:/etc/nginx/conf.d/90-header-overrides-test.conf" >/dev/null

if docker exec "$NAME" nginx -t >/dev/null 2>&1 && \
   docker exec "$NAME" nginx -s reload >/dev/null 2>&1; then
    pass "header override fixture loads and nginx -t passes"
else
    bad "header override fixture failed nginx -t/reload"
fi
sleep 1

fetch_test_headers() {
    path="$1"
    extra_header="${2:-}"
    args=(
        --noproxy '*'
        -sSkD -
        -o /dev/null
        --resolve "header-overrides.test:${HEADER_PORT}:127.0.0.1"
    )
    if [ -n "$extra_header" ]; then
        args+=(-H "$extra_header")
    fi
    curl "${args[@]}" "https://header-overrides.test:${HEADER_PORT}${path}"
}

normal_hdrs=$(fetch_test_headers /normal)
normal_xfo_count=$(grep -ci '^x-frame-options:' <<<"$normal_hdrs" || true)
check "normal path has exactly one X-Frame-Options" "$normal_xfo_count" "1"
normal_xfo=$(awk -F': *' 'tolower($1)=="x-frame-options"{gsub("\r","",$2); print $2}' <<<"$normal_hdrs")
check "normal path X-Frame-Options value" "$normal_xfo" "SAMEORIGIN"

for office_path in /office /office/child /office-addin /office-addin/child; do
    office_hdrs=$(fetch_test_headers "$office_path")
    office_xfo_count=$(grep -ci '^x-frame-options:' <<<"$office_hdrs" || true)
    check "$office_path has no X-Frame-Options" "$office_xfo_count" "0"

    if grep -qi '^content-security-policy: .*frame-ancestors .*office-parent\.example' <<<"$office_hdrs"; then
        pass "$office_path keeps CSP frame-ancestors"
    else
        bad "$office_path missing CSP frame-ancestors"
    fi

    for h in strict-transport-security x-content-type-options referrer-policy \
             permissions-policy cross-origin-opener-policy; do
        if grep -qi "^${h}:" <<<"$office_hdrs"; then
            pass "$office_path keeps $h"
        else
            bad "$office_path lost $h"
        fi
    done
done

custom_hdrs=$(fetch_test_headers /custom)
custom_xfo_count=$(grep -ci '^x-frame-options:' <<<"$custom_hdrs" || true)
check "custom override has one X-Frame-Options" "$custom_xfo_count" "1"
custom_xfo=$(awk -F': *' 'tolower($1)=="x-frame-options"{gsub("\r","",$2); print $2}' <<<"$custom_hdrs")
check "custom override replaces value" "$custom_xfo" "DENY"

oauth_hdrs=$(fetch_test_headers /oauth-popup)
oauth_coop_count=$(grep -ci '^cross-origin-opener-policy:' <<<"$oauth_hdrs" || true)
check "popup auth has one COOP header" "$oauth_coop_count" "1"
oauth_coop=$(awk -F': *' 'tolower($1)=="cross-origin-opener-policy"{gsub("\r","",$2); print $2}' <<<"$oauth_hdrs")
check "popup auth COOP override" "$oauth_coop" "same-origin-allow-popups"

for h in strict-transport-security x-content-type-options x-frame-options \
         referrer-policy permissions-policy; do
    if grep -qi "^${h}:" <<<"$oauth_hdrs"; then
        pass "popup auth keeps $h"
    else
        bad "popup auth lost $h"
    fi
done

brotli_hdrs=$(fetch_test_headers /brotli "Accept-Encoding: br")
if grep -qi '^content-encoding: br' <<<"$brotli_hdrs"; then
    pass "Brotli filter compresses eligible response"
else
    bad "Brotli response missing Content-Encoding: br"
fi

echo "==> quic_bpf capability detection"
bpf=$(docker exec "$NAME" cat /etc/nginx/quic-bpf.conf)
if grep -q '^quic_bpf on;' <<<"$bpf"; then
    bad "quic_bpf enabled without the required capabilities"
else
    pass "quic_bpf correctly off under default capabilities"
fi

echo "==> no startup warnings"
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
