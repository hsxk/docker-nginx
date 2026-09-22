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
