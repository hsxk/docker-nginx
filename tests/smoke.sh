#!/usr/bin/env bash
# tests/smoke.sh — boot the image and assert it actually works.
#
#   ./tests/smoke.sh my-nginx:latest
#
# This is intentionally runtime-heavy. nginx -t only proves syntax; this also
# checks the shipped fallback vhost, protocol listeners, TLS handshakes,
# compression, module loading, and application-owned header behaviour.

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

has_zstd=0
if docker run --rm --entrypoint sh "$IMAGE" -c 'test -f /usr/lib/nginx/modules/ngx_http_zstd_filter_module.so'; then
    has_zstd=1
    pass "optional zstd dynamic module detected"
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

for feature in --with-http_ssl_module --with-http_v2_module --with-http_v3_module; do
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

policy_headers=(
    strict-transport-security
    x-content-type-options
    x-frame-options
    referrer-policy
    permissions-policy
    cross-origin-opener-policy
    cross-origin-resource-policy
    cross-origin-embedder-policy
    content-security-policy
)

assert_policy_headers_absent() {
    label="$1"
    headers="$2"
    for h in "${policy_headers[@]}"; do
        count=$(grep -ci "^${h}:" <<<"$headers" || true)
        check "$label has no $h" "$count" "0"
    done
}

check_one_header() {
    label="$1"
    header="$2"
    headers="$3"
    count=$(grep -ci "^${header}:" <<<"$headers" || true)
    check "$label" "$count" "1"
}

header_value() {
    header="$1"
    headers="$2"
    awk -F': *' -v wanted="$header" '
        tolower($1) == tolower(wanted) {
            gsub("\r", "", $2)
            print $2
        }
    ' <<<"$headers"
}

# Bare image acceptance: HTTP/3 may advertise Alt-Svc, but the base image must
# not invent any application/browser security policy.
tls_hdrs=$(curl --noproxy '*' -sSkI "https://127.0.0.1:${TLS_PORT}/")
assert_policy_headers_absent "bare image" "$tls_hdrs"
if grep -qi '^alt-svc:' <<<"$tls_hdrs"; then
    pass "HTTP/3 Alt-Svc remains present"
else
    bad "HTTP/3 Alt-Svc missing"
fi

# nginx -T is part of the acceptance contract: the opt-in security policy file
# may exist on disk, but it must not be in the active include graph.
if grep -Fq 'include /etc/nginx/snippets/security-headers.conf;' <<<"$runtime_config"; then
    bad "nginx -T shows automatic security-headers.conf loading"
else
    pass "nginx -T does not load security-headers.conf"
fi

ct=$(grep -ci '^content-type:' <<<"$(curl --noproxy '*' -sSI "http://127.0.0.1:${HTTP_PORT}/healthz")" || true)
check "healthz has a single Content-Type" "$ct" "1"

echo "==> application-owned header policy and cache-purge fixture"
docker cp "$ROOT/tests/cache-purge-http.conf" \
    "$NAME:/etc/nginx/http.d/90-cache-purge-test.conf" >/dev/null
if [ "$has_zstd" -eq 1 ]; then
    docker cp "$ROOT/tests/zstd-http.conf" \
        "$NAME:/etc/nginx/http.d/91-zstd-test.conf" >/dev/null
fi
docker cp "$ROOT/tests/header-overrides.conf" \
    "$NAME:/etc/nginx/conf.d/90-header-policy-test.conf" >/dev/null

if docker exec "$NAME" nginx -t >/dev/null 2>&1 && \
   docker exec "$NAME" nginx -s reload >/dev/null 2>&1; then
    pass "application header fixture loads and nginx -t passes"
else
    bad "application header fixture failed nginx -t/reload"
fi
sleep 1

fetch_host_headers() {
    host="$1"
    path="$2"
    extra_header="${3:-}"
    args=(
        --noproxy '*'
        -sSkD -
        -o /dev/null
        --resolve "${host}:${HEADER_PORT}:127.0.0.1"
    )
    if [ -n "$extra_header" ]; then
        args+=(-H "$extra_header")
    fi
    curl "${args[@]}" "https://${host}:${HEADER_PORT}${path}"
}

fetch_test_headers() {
    fetch_host_headers header-policy.test "$1" "${2:-}"
}

# A plain downstream site is just as neutral as the baked fallback vhost.
plain_hdrs=$(fetch_test_headers /plain)
assert_policy_headers_absent "plain application path" "$plain_hdrs"

# Native add_header is now safe from base-image duplication because the base
# image does not set the same policy header at all.
add_hdrs=$(fetch_test_headers /add-header)
check_one_header "add_header emits one Referrer-Policy" "referrer-policy" "$add_hdrs"
check "add_header value is application-owned" \
    "$(header_value referrer-policy "$add_hdrs")" "no-referrer"
for h in "${policy_headers[@]}"; do
    [ "$h" = referrer-policy ] && continue
    count=$(grep -ci "^${h}:" <<<"$add_hdrs" || true)
    check "add_header path has no unrelated $h" "$count" "0"
done

# headers-more remains available without a base policy to fight.
more_hdrs=$(fetch_test_headers /more-set)
check_one_header "more_set_headers emits one Permissions-Policy" "permissions-policy" "$more_hdrs"
check "more_set_headers value is application-owned" \
    "$(header_value permissions-policy "$more_hdrs")" "geolocation=()"
for h in "${policy_headers[@]}"; do
    [ "$h" = permissions-policy ] && continue
    count=$(grep -ci "^${h}:" <<<"$more_hdrs" || true)
    check "more_set_headers path has no unrelated $h" "$count" "0"
done

# Office Add-in style route: COOP is explicitly unsafe-none, CSP belongs to the
# application, and no X-Frame-Options is forced into an embeddable page.
office_hdrs=$(fetch_test_headers /office-addin)
check_one_header "Office path has one COOP" "cross-origin-opener-policy" "$office_hdrs"
check "Office path COOP is unsafe-none" \
    "$(header_value cross-origin-opener-policy "$office_hdrs")" "unsafe-none"
check_one_header "Office path has one CSP" "content-security-policy" "$office_hdrs"
if grep -qi '^content-security-policy: .*frame-ancestors .*office-parent\.example' <<<"$office_hdrs"; then
    pass "Office path keeps application frame-ancestors"
else
    bad "Office path missing application frame-ancestors"
fi
office_xfo_count=$(grep -ci '^x-frame-options:' <<<"$office_hdrs" || true)
check "Office path has no X-Frame-Options" "$office_xfo_count" "0"
for h in strict-transport-security x-content-type-options referrer-policy permissions-policy \
         cross-origin-resource-policy cross-origin-embedder-policy; do
    count=$(grep -ci "^${h}:" <<<"$office_hdrs" || true)
    check "Office path has no unrelated $h" "$count" "0"
done

# Upstream-owned policy must pass through unchanged: one COOP, one XFO, no
# base-image copy appended and no replacement value.
upstream_hdrs=$(fetch_test_headers /upstream-policy)
check_one_header "upstream COOP appears once" "cross-origin-opener-policy" "$upstream_hdrs"
check "upstream COOP value is untouched" \
    "$(header_value cross-origin-opener-policy "$upstream_hdrs")" "unsafe-none"
check_one_header "upstream X-Frame-Options appears once" "x-frame-options" "$upstream_hdrs"
check "upstream X-Frame-Options value is untouched" \
    "$(header_value x-frame-options "$upstream_hdrs")" "SAMEORIGIN"
for h in strict-transport-security x-content-type-options referrer-policy permissions-policy \
         cross-origin-resource-policy cross-origin-embedder-policy content-security-policy; do
    count=$(grep -ci "^${h}:" <<<"$upstream_hdrs" || true)
    check "upstream path has no base-added $h" "$count" "0"
done

brotli_hdrs=$(fetch_test_headers /brotli "Accept-Encoding: br")
if grep -qi '^content-encoding: br' <<<"$brotli_hdrs"; then
    pass "Brotli filter compresses eligible response"
else
    bad "Brotli response missing Content-Encoding: br"
fi

if [ "$has_zstd" -eq 1 ]; then
    zstd_hdrs=$(fetch_test_headers /brotli "Accept-Encoding: zstd")
    if grep -qi '^content-encoding: zstd' <<<"$zstd_hdrs"; then
        pass "zstd filter compresses eligible response"
    else
        bad "zstd response missing Content-Encoding: zstd"
    fi
fi

echo "==> ngx_cache_purge functional test"
cache_url="https://header-policy.test:${HEADER_PORT}/cache-purge/item"
cache_curl=(--noproxy '*' -sSk --resolve "header-policy.test:${HEADER_PORT}:127.0.0.1")

cache_first=$(curl "${cache_curl[@]}" -D - -o /dev/null "$cache_url")
if grep -qi '^x-cache-status: MISS' <<<"$cache_first"; then
    pass "cache purge fixture first GET is MISS"
else
    bad "cache purge fixture first GET was not MISS"
fi

cache_second=$(curl "${cache_curl[@]}" -D - -o /dev/null "$cache_url")
if grep -qi '^x-cache-status: HIT' <<<"$cache_second"; then
    pass "cache purge fixture second GET is HIT"
else
    bad "cache purge fixture second GET was not HIT"
fi

purge_code=$(curl "${cache_curl[@]}" -X PURGE -o /dev/null -w '%{http_code}' "$cache_url")
check "ngx_cache_purge removes cached entry" "$purge_code" "200"

purge_miss_code=$(curl "${cache_curl[@]}" -X PURGE -o /dev/null -w '%{http_code}' "$cache_url")
check "second PURGE reports cache miss" "$purge_miss_code" "412"

cache_after_purge=$(curl "${cache_curl[@]}" -D - -o /dev/null "$cache_url")
if grep -qi '^x-cache-status: MISS' <<<"$cache_after_purge"; then
    pass "GET after PURGE is MISS"
else
    bad "GET after PURGE did not return to MISS"
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
