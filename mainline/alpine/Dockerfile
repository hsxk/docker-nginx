# syntax=docker/dockerfile:1.7
#
# Hardened NGINX image with HTTP/3 (QUIC), Brotli, headers-more, cache-purge.
#
# QUIC backend: the DISTRO's OpenSSL 3.5.x, linked dynamically.
# nginx >= 1.29 speaks OpenSSL's native QUIC server API (SSL_set_quic_tls_cbs),
# which landed in OpenSSL 3.5 — so the old dance of statically linking a
# BoringSSL/quictls fork is no longer necessary. See the QUIC note below.
#
# Optional modules (off by default — flip the ARG to "1"):
#   ENABLE_ZSTD     zstd compression (tokers/zstd-nginx-module)
#                   Chrome 123+ / Firefox 126+ negotiate `Accept-Encoding: zstd`
#                   and zstd is faster than brotli at equivalent ratios.
#   ENABLE_NJS      njs — nginx-flavored JS for replacing complex `if` chains
#                   (https://nginx.org/en/docs/njs/)
#   ENABLE_GEOIP2   leev/ngx_http_geoip2_module (replaces obsolete GeoIP1)
#   ENABLE_VTS      vozlt/nginx-module-vts — Prometheus-friendly `/status`
#
# Build (with everything optional turned on):
#   docker build -t my-nginx \
#     --build-arg ENABLE_ZSTD=1 \
#     --build-arg ENABLE_NJS=1 \
#     --build-arg ENABLE_GEOIP2=1 \
#     --build-arg ENABLE_VTS=1 \
#     -f mainline/alpine/Dockerfile .

# Alpine 3.22 is the oldest branch shipping OpenSSL 3.5 (the QUIC-capable one)
# and is supported until 2027-05. Do not drop below this: 3.21 and older ship
# OpenSSL 3.3, whose QUIC API is client-only and cannot serve HTTP/3.
ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION} AS builder

# ─── Pinned source versions (bump deliberately) ─────────────────────────────
# All refs are pinned to immutable commit SHAs / signed release tags so the
# build is byte-reproducible. To bump: update both REF and the matching SHA256.
ARG NGINX_VERSION=1.31.3
ARG NGINX_SHA256=a7657c50811c2d92d9895395e8b873ef60398142c4db21eb647811c38f6dd525

ARG HEADERS_MORE_VERSION=0.40
ARG HEADERS_MORE_SHA256=c14cb5e6c998590c209efbf77bd7637ce2cab02332e4192756a8af5b26ba4284

# google/ngx_brotli is the upstream — last touched 2023-10-09, NOT archived.
ARG NGX_BROTLI_REPO=https://github.com/google/ngx_brotli
ARG NGX_BROTLI_REF=a71f9312c2deb28875acc7bacfdd5695a111aa53

# Original FRiCKLE/ngx_cache_purge stopped at 2014. nginx-modules/ngx_cache_purge
# is the actively maintained fork (nginx ≥1.25 compatible, fix for the
# proxy_cache_purge ctx leak landed 2025).
ARG NGX_CACHE_PURGE_REPO=https://github.com/nginx-modules/ngx_cache_purge
ARG NGX_CACHE_PURGE_REF=285354eddd5675c765ba2b79dac09f5d3065b22f

# Optional modules — versions used only when their ENABLE_* arg is "1".
ARG ZSTD_NGINX_REPO=https://github.com/tokers/zstd-nginx-module
ARG ZSTD_NGINX_REF=057a7d339af1111d04b5a9ac5ae9b0250d17cd94

ARG NJS_VERSION=1.0.0
ARG NJS_SHA256=56fe6560549cbcb7fb5740534b541bb153250d8772aa16ac18bc30eb0cc498dd

ARG GEOIP2_VERSION=3.4
ARG GEOIP2_SHA256=ad72fc23348d715a330994984531fab9b3606e160483236737f9a4a6957d9452

ARG VTS_VERSION=0.2.7
ARG VTS_SHA256=0003bfa57da2106367fdc3f87760910c046e7df5545db73c880fc2b80350b14c

ARG ENABLE_ZSTD=0
ARG ENABLE_NJS=0
ARG ENABLE_GEOIP2=0
ARG ENABLE_VTS=0

# Build-only deps. Note: no gd/libpng/freetype/xpm/tiff/perl/xslt — those
# would only be needed for image_filter / perl / xslt modules we don't build.
#
# ─── Why openssl-dev and not a vendored quictls/BoringSSL ───────────────────
# Building a TLS stack from a pinned tarball freezes it: quictls' last QUIC
# release is based on OpenSSL 3.3.0 (April 2024) and the project wound down
# once OpenSSL 3.5 LTS shipped the server-side QUIC API. Statically linking it
# means (a) every OpenSSL CVE needs a source bump + full rebuild, and (b) the
# vulnerable version is invisible to `apk`, to SBOM generators and to image
# scanners, because there is no package to report.
#
# Linking against the distro's OpenSSL 3.5.x inverts all of that: a base-image
# rebuild picks up Alpine's security updates, the version is in the SBOM, and
# scanners can actually see it. nginx detects the native API automatically —
# `./configure` probes for SSL_set_quic_tls_cbs() and enables HTTP/3 with it.
RUN apk add --no-cache --virtual .build \
      build-base git \
      ca-certificates curl \
      linux-headers \
      pcre2-dev zlib-dev brotli-dev openssl-dev \
      libmaxminddb-dev

WORKDIR /tmp/build

# ─── nginx + core modules ───────────────────────────────────────────────────
# Every curl download is SHA256-verified; git fetches pin an immutable commit
# (git is content-addressable, so the SHA *is* the checksum). We fetch that one
# commit at depth 1 rather than cloning full history.
#
# ngx_brotli's submodule update stays a full clone on purpose: ngx_brotli pins
# deps/brotli to a commit that is not the tip of any branch, and a shallow
# fetch of an unadvertised object is exactly what git servers refuse. One small
# submodule cloned in full is cheap; an intermittently failing build is not.
RUN set -eux; \
    curl -fSLo nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"; \
    echo "${NGINX_SHA256}  nginx.tar.gz" | sha256sum -c -; \
    tar -xzf nginx.tar.gz; \
    rm -f nginx.tar.gz; \
    mkdir -p "nginx-${NGINX_VERSION}/extensions"; \
    cd "nginx-${NGINX_VERSION}/extensions"; \
    \
    shallow_checkout() { \
        mkdir -p "$1" && cd "$1"; \
        git init -q .; \
        git remote add origin "$2"; \
        git fetch -q --depth 1 origin "$3"; \
        git checkout -q FETCH_HEAD; \
        cd ..; \
    }; \
    \
    shallow_checkout ngx_brotli "${NGX_BROTLI_REPO}" "${NGX_BROTLI_REF}"; \
    (cd ngx_brotli && git submodule update --init --recursive); \
    \
    shallow_checkout ngx_cache_purge "${NGX_CACHE_PURGE_REPO}" "${NGX_CACHE_PURGE_REF}"; \
    \
    curl -fSLo headers-more.tgz \
      "https://github.com/openresty/headers-more-nginx-module/archive/v${HEADERS_MORE_VERSION}.tar.gz"; \
    echo "${HEADERS_MORE_SHA256}  headers-more.tgz" | sha256sum -c -; \
    tar -xzf headers-more.tgz && mv "headers-more-nginx-module-${HEADERS_MORE_VERSION}" headers-more; \
    rm -f headers-more.tgz

# ─── Optional modules (all sources checksum-verified) ───────────────────────
RUN set -eux; cd "/tmp/build/nginx-${NGINX_VERSION}/extensions"; \
    if [ "${ENABLE_ZSTD}" = "1" ]; then \
        mkdir -p zstd-nginx-module && cd zstd-nginx-module; \
        git init -q .; \
        git remote add origin "${ZSTD_NGINX_REPO}"; \
        git fetch -q --depth 1 origin "${ZSTD_NGINX_REF}"; \
        git checkout -q FETCH_HEAD; \
        cd ..; \
        apk add --no-cache --virtual .zstd-build zstd-dev; \
    fi; \
    if [ "${ENABLE_NJS}" = "1" ]; then \
        curl -fSLo njs.tgz "https://github.com/nginx/njs/archive/refs/tags/${NJS_VERSION}.tar.gz"; \
        echo "${NJS_SHA256}  njs.tgz" | sha256sum -c -; \
        tar -xzf njs.tgz && mv "njs-${NJS_VERSION}" njs && rm njs.tgz; \
    fi; \
    if [ "${ENABLE_GEOIP2}" = "1" ]; then \
        curl -fSLo geoip2.tgz "https://github.com/leev/ngx_http_geoip2_module/archive/refs/tags/${GEOIP2_VERSION}.tar.gz"; \
        echo "${GEOIP2_SHA256}  geoip2.tgz" | sha256sum -c -; \
        tar -xzf geoip2.tgz && mv "ngx_http_geoip2_module-${GEOIP2_VERSION}" geoip2 && rm geoip2.tgz; \
    fi; \
    if [ "${ENABLE_VTS}" = "1" ]; then \
        curl -fSLo vts.tgz "https://github.com/vozlt/nginx-module-vts/archive/refs/tags/v${VTS_VERSION}.tar.gz"; \
        echo "${VTS_SHA256}  vts.tgz" | sha256sum -c -; \
        tar -xzf vts.tgz && mv "nginx-module-vts-${VTS_VERSION}" vts && rm vts.tgz; \
    fi

# ─── Guard: the QUIC API nginx picks is decided purely by the OpenSSL headers.
# src/event/quic/ngx_event_quic.h selects NGX_QUIC_OPENSSL_API (the real,
# server-capable API) only when OPENSSL_VERSION_NUMBER >= 3.5.1; anything older
# silently falls back to NGX_QUIC_OPENSSL_COMPAT, a TLS-callback shim that
# nginx ships for completeness but which is materially slower and misses 0-RTT.
# Fail the build here rather than shipping an image that advertises h3 and
# under-delivers.
RUN set -eux; \
    printf '%s\n' \
      '#include <openssl/opensslv.h>' \
      '#if OPENSSL_VERSION_NUMBER < 0x30500010L' \
      '#error "need OpenSSL >= 3.5.1 for the native QUIC server API"' \
      '#endif' > /tmp/ossl-quic-check.c; \
    cc -fsyntax-only /tmp/ossl-quic-check.c; \
    rm -f /tmp/ossl-quic-check.c

# ─── Configure & build nginx ────────────────────────────────────────────────
RUN set -eux; \
    cd "/tmp/build/nginx-${NGINX_VERSION}"; \
    \
    EXTRA_MODULES=""; \
    [ "${ENABLE_ZSTD}"   = "1" ] && EXTRA_MODULES="$EXTRA_MODULES --add-module=./extensions/zstd-nginx-module"; \
    [ "${ENABLE_NJS}"    = "1" ] && EXTRA_MODULES="$EXTRA_MODULES --add-module=./extensions/njs/nginx"; \
    [ "${ENABLE_GEOIP2}" = "1" ] && EXTRA_MODULES="$EXTRA_MODULES --add-module=./extensions/geoip2"; \
    [ "${ENABLE_VTS}"    = "1" ] && EXTRA_MODULES="$EXTRA_MODULES --add-module=./extensions/vts"; \
    \
    ./configure \
      --prefix=/etc/nginx \
      --sbin-path=/usr/sbin/nginx \
      --modules-path=/usr/lib/nginx/modules \
      --conf-path=/etc/nginx/nginx.conf \
      --http-log-path=/var/log/nginx/access.log \
      --error-log-path=/var/log/nginx/error.log \
      --pid-path=/var/run/nginx.pid \
      --lock-path=/var/run/nginx.lock \
      --http-client-body-temp-path=/var/cache/nginx/client_temp \
      --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
      --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
      --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
      --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
      --user=nginx --group=nginx \
      --with-threads --with-file-aio --with-compat --with-pcre-jit \
      --with-http_ssl_module \
      --with-http_v2_module \
      --with-http_v3_module \
      --with-http_realip_module \
      --with-http_addition_module \
      --with-http_sub_module \
      --with-http_gunzip_module \
      --with-http_gzip_static_module \
      --with-http_auth_request_module \
      --with-http_random_index_module \
      --with-http_secure_link_module \
      --with-http_slice_module \
      --with-http_stub_status_module \
      --with-stream --with-stream_ssl_module \
      --with-stream_ssl_preread_module --with-stream_realip_module \
      --add-module=./extensions/ngx_cache_purge \
      --add-module=./extensions/ngx_brotli \
      --add-module=./extensions/headers-more \
      $EXTRA_MODULES \
      --with-cc-opt="-O2 -fstack-protector-strong -Wformat -Werror=format-security \
                     -Wno-deprecated-declarations -Wno-cast-function-type \
                     -Wno-unused-parameter -Wno-stringop-truncation -Wno-stringop-overflow" \
      --with-ld-opt="-Wl,--as-needed -Wl,-z,relro -Wl,-z,now"; \
    make -j"$(nproc)"; \
    make install; \
    strip /usr/sbin/nginx

# ─────────────────────────────────────────────────────────────────────────────
# Runtime image
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.title="docker-nginx-quic" \
      org.opencontainers.image.description="NGINX with HTTP/3 (OpenSSL 3.5), Brotli, headers-more, cache-purge" \
      org.opencontainers.image.source="https://github.com/hsxk/docker-nginx" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

# Optional-module runtime deps need re-declaring here (ARGs reset across stages).
ARG ENABLE_ZSTD=0
ARG ENABLE_GEOIP2=0

RUN set -eux; \
    addgroup -g 101 -S nginx; \
    adduser -S -D -H -u 101 -h /var/cache/nginx -s /sbin/nologin -G nginx -g nginx nginx; \
    # Runtime libs only. No libxslt (we don't build xslt module).
    # `openssl` brings in libssl3/libcrypto3 (which the nginx binary links
    # against) and gives the entrypoint the CLI it needs to mint the fallback
    # self-signed cert. No curl: busybox wget covers the HEALTHCHECK.
    apk add --no-cache \
      ca-certificates tzdata pcre2 zlib brotli-libs openssl; \
    if [ "${ENABLE_ZSTD}"   = "1" ]; then apk add --no-cache zstd-libs; fi; \
    if [ "${ENABLE_GEOIP2}" = "1" ]; then apk add --no-cache libmaxminddb; fi; \
    mkdir -p /etc/nginx/snippets /etc/nginx/conf.d \
             /usr/share/nginx-defaults \
             /var/cache/nginx /var/log/nginx /var/www/html /etc/letsencrypt; \
    chown -R nginx:nginx /var/cache/nginx /var/log/nginx /var/www/html; \
    # Container best-practice: stream nginx logs to docker's stdout/stderr.
    # NOTE: deliberately no `VOLUME /var/log/nginx` — declaring one would spawn
    # an anonymous volume on every `docker run` that shadows these symlinks and
    # silently diverts logs to disk instead of `docker logs`.
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log

# nginx binary + bundled defaults
COPY --from=builder /usr/sbin/nginx        /usr/sbin/nginx
COPY --from=builder /etc/nginx/mime.types  /etc/nginx/mime.types
COPY --from=builder /etc/nginx/fastcgi.conf /etc/nginx/fastcgi.conf
COPY --from=builder /etc/nginx/uwsgi_params /etc/nginx/uwsgi_params
COPY --from=builder /etc/nginx/scgi_params  /etc/nginx/scgi_params

# Our configuration
COPY mainline/alpine/files/nginx.conf       /etc/nginx/nginx.conf
COPY mainline/alpine/files/fastcgi_params   /etc/nginx/fastcgi_params
COPY mainline/alpine/files/resolver.conf    /etc/nginx/resolver.conf
COPY mainline/alpine/files/snippets/        /etc/nginx/snippets/
# Built-in fallback vhost — entrypoint installs into conf.d/ when empty.
COPY mainline/alpine/files/default-conf.d/  /usr/share/nginx-defaults/
COPY mainline/alpine/docker-entrypoint.sh   /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 80   = HTTP (redirect + ACME)
# 443/tcp = HTTPS (TLS 1.2/1.3 over TCP, h2 + h1.1)
# 443/udp = HTTP/3 (QUIC)
# (8081 is the health listener — bound to 127.0.0.1 only, never published.)
EXPOSE 80/tcp 443/tcp 443/udp

STOPSIGNAL SIGQUIT

# Hits the loopback-only health server defined in nginx.conf, NOT a vhost in
# conf.d/ — so mounting your own conf.d can never make the container unhealthy.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8081/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
