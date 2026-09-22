#!/usr/bin/env bash
# tests/local-release-verify.sh
#
# Release-grade LOCAL verification. This script never pushes, tags Git, logs in
# to a registry, or invokes GitHub Actions. It builds the same two meaningful
# coverage points locally:
#   base - mandatory modules only
#   all  - zstd + njs + geoip2 + vts in addition to mandatory modules
#
# Artifacts (plain build logs, nginx -V/-t, smoke output, image metadata) are
# written under .artifacts/ by default so they can be attached to a release
# report without scraping terminal history.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$ROOT/mainline/alpine/Dockerfile"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT/.artifacts/nginx-verify-$STAMP}"
IMAGE_PREFIX="${IMAGE_PREFIX:-docker-nginx-local}"

mkdir -p "$ARTIFACT_DIR"

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: required command not found: $1" >&2
        exit 127
    }
}

need docker
need bash
need curl
need awk
need sed
need grep
need tee
need sha256sum

# Fail before spending build time if a tracked test script is syntactically
# broken. This caught a real regression while preparing the 1.31.6 upgrade.
bash -n "$ROOT/tests/smoke.sh"
bash -n "$ROOT/tests/validate-examples.sh"
bash -n "$ROOT/tests/local-release-verify.sh"

if ! docker info >/dev/null 2>&1; then
    echo "error: Docker daemon is not available" >&2
    exit 1
fi

NGINX_VERSION="$(sed -n 's/^ARG NGINX_VERSION=//p' "$DOCKERFILE" | head -n1)"
NGINX_FROM_IMAGE="$(sed -n 's/^ARG NGINX_FROM_IMAGE=//p' "$DOCKERFILE" | head -n1)"
NGINX_FROM_DIGEST="$(sed -n 's/^ARG NGINX_FROM_DIGEST=//p' "$DOCKERFILE" | head -n1)"
NGINX_SHA256="$(sed -n 's/^ARG NGINX_SHA256=//p' "$DOCKERFILE" | head -n1)"
OPENSSL_PACKAGE_VERSION="$(sed -n 's/^ARG OPENSSL_PACKAGE_VERSION=//p' "$DOCKERFILE" | head -n1)"

for value_name in NGINX_VERSION NGINX_FROM_IMAGE NGINX_FROM_DIGEST NGINX_SHA256 OPENSSL_PACKAGE_VERSION; do
    value="${!value_name}"
    if [ -z "$value" ]; then
        echo "error: could not read $value_name from Dockerfile" >&2
        exit 1
    fi
done

cat >"$ARTIFACT_DIR/pins.txt" <<EOF
NGINX_VERSION=$NGINX_VERSION
NGINX_FROM_IMAGE=$NGINX_FROM_IMAGE
NGINX_FROM_DIGEST=$NGINX_FROM_DIGEST
NGINX_SHA256=$NGINX_SHA256
OPENSSL_PACKAGE_VERSION=$OPENSSL_PACKAGE_VERSION
EOF

printf 'Local verification artifacts: %s\n' "$ARTIFACT_DIR"
printf 'NGINX_VERSION=%s\n' "$NGINX_VERSION"

printf '\n===== UPSTREAM PIN CHECK =====\n'
if ! docker buildx version >/dev/null 2>&1; then
    echo "error: docker buildx is required to verify the official image digest" >&2
    exit 1
fi

upstream_inspect=$(docker buildx imagetools inspect "$NGINX_FROM_IMAGE")
printf '%s\n' "$upstream_inspect" >"$ARTIFACT_DIR/upstream-image-inspect.txt"
remote_digest=$(printf '%s\n' "$upstream_inspect" | awk '$1 == "Digest:" {print $2; exit}')

if [ -z "$remote_digest" ]; then
    echo "error: could not determine current digest for $NGINX_FROM_IMAGE" >&2
    exit 1
fi

if [ "$remote_digest" != "$NGINX_FROM_DIGEST" ]; then
    echo "error: official tag moved since the Dockerfile was pinned" >&2
    echo "  tag:      $NGINX_FROM_IMAGE" >&2
    echo "  pinned:   $NGINX_FROM_DIGEST" >&2
    echo "  current:  $remote_digest" >&2
    echo "Re-audit the new official image, update the immutable digest deliberately, then rerun." >&2
    exit 1
fi
printf 'ok: official tag still resolves to %s\n' "$NGINX_FROM_DIGEST"

source_tar="$ARTIFACT_DIR/nginx-$NGINX_VERSION.tar.gz"
curl -fsSL "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz" -o "$source_tar"
source_digest=$(sha256sum "$source_tar" | awk '{print $1}')
printf '%s  nginx-%s.tar.gz\n' "$source_digest" "$NGINX_VERSION" \
    >"$ARTIFACT_DIR/nginx-source-sha256.txt"
if [ "$source_digest" != "$NGINX_SHA256" ]; then
    echo "error: nginx source SHA256 mismatch" >&2
    echo "  pinned:  $NGINX_SHA256" >&2
    echo "  actual:  $source_digest" >&2
    exit 1
fi
rm -f "$source_tar"
printf 'ok: nginx source SHA256 matches %s\n' "$NGINX_SHA256"

printf '\n===== SECURITY HEADER CONFIG LINT =====\n'
managed_headers='Strict-Transport-Security|X-Content-Type-Options|X-Frame-Options|Referrer-Policy|Permissions-Policy|Cross-Origin-Opener-Policy'
bad_header_lines=$(find "$ROOT/mainline/alpine/files" "$ROOT/examples" "$ROOT/tests" \
    -type f -name '*.conf' -print0 \
    | xargs -0 grep -nEi "^[[:space:]]*add_header[[:space:]]+($managed_headers)([[:space:];]|$)" \
    || true)
if [ -n "$bad_header_lines" ]; then
    echo "error: managed security headers must use headers-more, not add_header:" >&2
    printf '%s\n' "$bad_header_lines" >&2
    exit 1
fi
echo "ok: no managed security header uses add_header in shipped configs"

build_and_verify() {
    flavor="$1"
    shift
    image="$IMAGE_PREFIX:$NGINX_VERSION-$flavor"

    printf '\n===== BUILD %s =====\n' "$flavor"
    build_flags=(--progress=plain)
    if [ "${NO_CACHE:-1}" = "1" ]; then
        build_flags+=(--no-cache)
    fi

    docker build \
        "${build_flags[@]}" \
        "$@" \
        -t "$image" \
        -f "$DOCKERFILE" \
        "$ROOT" 2>&1 | tee "$ARTIFACT_DIR/build-$flavor.log"

    printf '\n===== VERSION / CONFIG %s =====\n' "$flavor"
    docker run --rm --entrypoint nginx "$image" -V \
        2>&1 | tee "$ARTIFACT_DIR/nginx-V-$flavor.txt"

    docker run --rm --entrypoint nginx "$image" -t \
        >"$ARTIFACT_DIR/nginx-t-$flavor.txt" 2>&1
    cat "$ARTIFACT_DIR/nginx-t-$flavor.txt"

    docker run --rm --entrypoint sh "$image" -c '
        set -eu
        nginx -v 2>&1
        openssl version
        printf "Alpine "
        cat /etc/alpine-release
        echo "modules:"
        find /usr/lib/nginx/modules -maxdepth 1 -type f -name "*.so" -print | sort
        echo "load_module config:"
        cat /etc/nginx/modules-enabled/*.conf
    ' >"$ARTIFACT_DIR/runtime-$flavor.txt" 2>&1
    cat "$ARTIFACT_DIR/runtime-$flavor.txt"

    if [ "$flavor" = all ]; then
        docker run --rm --entrypoint sh "$image" -ec '
            for module in \
                ngx_http_zstd_filter_module.so \
                ngx_http_zstd_static_module.so \
                ngx_http_js_module.so \
                ngx_stream_js_module.so \
                ngx_http_geoip2_module.so \
                ngx_stream_geoip2_module.so \
                ngx_http_vhost_traffic_status_module.so; do
                test -f "/usr/lib/nginx/modules/$module"
                grep -Fq "load_module /usr/lib/nginx/modules/$module;" \
                    /etc/nginx/modules-enabled/*.conf
                echo "optional module loaded: $module"
            done
        ' | tee "$ARTIFACT_DIR/optional-modules-all.txt"
    fi

    docker image inspect "$image" \
        >"$ARTIFACT_DIR/image-inspect-$flavor.json"

    printf '\n===== SMOKE %s =====\n' "$flavor"
    "$ROOT/tests/smoke.sh" "$image" \
        2>&1 | tee "$ARTIFACT_DIR/smoke-$flavor.log"

    printf '\n===== EXAMPLES %s =====\n' "$flavor"
    "$ROOT/tests/validate-examples.sh" "$image" \
        2>&1 | tee "$ARTIFACT_DIR/examples-$flavor.log"
}

build_and_verify base

build_and_verify all \
    --build-arg ENABLE_ZSTD=1 \
    --build-arg ENABLE_NJS=1 \
    --build-arg ENABLE_GEOIP2=1 \
    --build-arg ENABLE_VTS=1

printf '\n===== RESULT =====\n'
printf 'All local release checks passed for NGINX %s.\n' "$NGINX_VERSION"
printf 'Artifacts: %s\n' "$ARTIFACT_DIR"
printf 'No Git tag, registry push, or CI workflow was triggered.\n'
