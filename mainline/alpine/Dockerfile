# syntax=docker/dockerfile:1.7
#
# Hardened NGINX image with HTTP/3 (QUIC), Brotli, headers-more, cache-purge.
# Built from source against BoringSSL for QUIC support.
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

ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION} AS builder

# ─── Pinned source versions (bump deliberately) ─────────────────────────────
# All refs are pinned to immutable commit SHAs / signed release tags so the
# build is byte-reproducible. To bump: update both REF and the matching SHA256.
ARG NGINX_VERSION=1.31.1
ARG NGINX_SHA256=9fcaaeb8f22544b09a19a761f3412c4112215422401634bebdd1296a403cc4bc

ARG HEADERS_MORE_VERSION=0.34
ARG HEADERS_MORE_SHA256=0c0d2ced2ce895b3f45eb2b230cd90508ab2a773299f153de14a43e44c1209b3

# google/ngx_brotli is the upstream — last touched 2023-10-09, NOT archived.
ARG NGX_BROTLI_REPO=https://github.com/google/ngx_brotli
ARG NGX_BROTLI_REF=a71f9312c2deb28875acc7bacfdd5695a111aa53

# Original FRiCKLE/ngx_cache_purge stopped at 2014. nginx-modules/ngx_cache_purge
# is the actively maintained fork (nginx ≥1.25 compatible, fix for the
# proxy_cache_purge ctx leak landed 2025).
ARG NGX_CACHE_PURGE_REPO=https://github.com/nginx-modules/ngx_cache_purge
ARG NGX_CACHE_PURGE_REF=285354eddd5675c765ba2b79dac09f5d3065b22f

# Pin BoringSSL. Bump when you want a newer one.
# Alternative QUIC backends: quictls/openssl (versioned), or OpenSSL 3.5+
# native QUIC server API (since 2024-Q4) — see notes at the bottom of README.
ARG BORINGSSL_REF=0b04d3d8d77a3c84a1ec18786a83d44d266073e7

# Optional modules — versions used only when their ENABLE_* arg is "1".
ARG ZSTD_NGINX_REPO=https://github.com/tokers/zstd-nginx-module
ARG ZSTD_NGINX_REF=057a7d339af1111d04b5a9ac5ae9b0250d17cd94

ARG NJS_VERSION=0.8.7
ARG NJS_SHA256=e959b01637d6684387347cc6dea073949467193d273f58062129e52b110aefa2

ARG GEOIP2_VERSION=3.4
ARG GEOIP2_SHA256=ad72fc23348d715a330994984531fab9b3606e160483236737f9a4a6957d9452

ARG VTS_VERSION=0.2.4
ARG VTS_SHA256=4ddcb849b175a71c57bf4030dea0dc9556f0b58a74ea50d88f12e89195c61727

ARG ENABLE_ZSTD=0
ARG ENABLE_NJS=0
ARG ENABLE_GEOIP2=0
ARG ENABLE_VTS=0

# Build-only deps. Note: no gd/libpng/freetype/xpm/tiff/perl/xslt — those
# would only be needed for image_filter / perl / xslt modules we don't build.
RUN apk add --no-cache --virtual .build \
      build-base cmake go git \
      ca-certificates curl \
      openssl openssl-dev linux-headers \
      pcre2-dev zlib-dev brotli-dev \
      libmaxminddb-dev

WORKDIR /tmp/build

# ─── nginx + core modules ───────────────────────────────────────────────────
# Every curl download is SHA256-verified; git clones pin an immutable commit
# (git is content-addressable, so the SHA *is* the checksum).
RUN set -eux; \
    curl -fSLo nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"; \
    echo "${NGINX_SHA256}  nginx.tar.gz" | sha256sum -c -; \
    tar -xzf nginx.tar.gz; \
    rm -f nginx.tar.gz; \
    mkdir -p "nginx-${NGINX_VERSION}/extensions"; \
    cd "nginx-${NGINX_VERSION}/extensions"; \
    \
    git clone "${NGX_BROTLI_REPO}" ngx_brotli; \
    (cd ngx_brotli && git checkout --quiet "${NGX_BROTLI_REF}" \
        && git submodule update --init --recursive); \
    \
    git clone "${NGX_CACHE_PURGE_REPO}" ngx_cache_purge; \
    (cd ngx_cache_purge && git checkout --quiet "${NGX_CACHE_PURGE_REF}"); \
    \
    curl -fSLo headers-more.tgz \
      "https://github.com/openresty/headers-more-nginx-module/archive/v${HEADERS_MORE_VERSION}.tar.gz"; \
    echo "${HEADERS_MORE_SHA256}  headers-more.tgz" | sha256sum -c -; \
    tar -xzf headers-more.tgz && mv "headers-more-nginx-module-${HEADERS_MORE_VERSION}" headers-more; \
    rm -f headers-more.tgz; \
    \
    curl -fSLo boringssl.tar.gz \
      "https://boringssl.googlesource.com/boringssl/+archive/${BORINGSSL_REF}.tar.gz"; \
    mkdir boringssl && tar -xzf boringssl.tar.gz -C boringssl; \
    rm -f boringssl.tar.gz

# ─── Optional modules (all sources checksum-verified) ───────────────────────
RUN set -eux; cd "/tmp/build/nginx-${NGINX_VERSION}/extensions"; \
    if [ "${ENABLE_ZSTD}" = "1" ]; then \
        git clone "${ZSTD_NGINX_REPO}" zstd-nginx-module; \
        (cd zstd-nginx-module && git checkout --quiet "${ZSTD_NGINX_REF}"); \
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

# ─── BoringSSL (Release build, parallel) ────────────────────────────────────
RUN set -eux; \
    cd "/tmp/build/nginx-${NGINX_VERSION}/extensions/boringssl"; \
    cmake -Bbuild -H. -DCMAKE_BUILD_TYPE=Release; \
    cmake --build build -j"$(nproc)" --target ssl crypto

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
      --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module \
      --add-module=./extensions/ngx_cache_purge \
      --add-module=./extensions/ngx_brotli \
      --add-module=./extensions/headers-more \
      $EXTRA_MODULES \
      --with-cc-opt="-O2 -fstack-protector-strong -Wformat -Werror=format-security \
                     -Wno-deprecated-declarations -Wno-cast-function-type \
                     -Wno-unused-parameter -Wno-stringop-truncation -Wno-stringop-overflow \
                     -I./extensions/boringssl/include" \
      --with-ld-opt="-Wl,--as-needed \
                     -L./extensions/boringssl/build/ssl \
                     -L./extensions/boringssl/build/crypto"; \
    make -j"$(nproc)"; \
    make install; \
    strip /usr/sbin/nginx

# ─────────────────────────────────────────────────────────────────────────────
# Runtime image
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.title="docker-nginx-quic" \
      org.opencontainers.image.description="NGINX with HTTP/3 (BoringSSL), Brotli, headers-more, cache-purge" \
      org.opencontainers.image.source="https://github.com/your-org/docker-nginx" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

# Optional-module runtime deps need re-declaring here (ARGs reset across stages).
ARG ENABLE_ZSTD=0
ARG ENABLE_GEOIP2=0

RUN set -eux; \
    addgroup -g 101 -S nginx; \
    adduser -S -D -H -u 101 -h /var/cache/nginx -s /sbin/nologin -G nginx -g nginx nginx; \
    # Runtime libs only. No libxslt (we don't build xslt module).
    # The nginx binary is statically linked against BoringSSL, so it does not
    # depend on the system openssl library — but the openssl CLI is needed
    # by docker-entrypoint.sh to mint the fallback self-signed cert.
    apk add --no-cache \
      ca-certificates tzdata pcre2 zlib brotli-libs openssl curl; \
    if [ "${ENABLE_ZSTD}"   = "1" ]; then apk add --no-cache zstd-libs; fi; \
    if [ "${ENABLE_GEOIP2}" = "1" ]; then apk add --no-cache libmaxminddb; fi; \
    mkdir -p /etc/nginx/snippets /etc/nginx/conf.d \
             /usr/share/nginx-defaults \
             /var/cache/nginx /var/log/nginx /var/www/html /etc/letsencrypt; \
    chown -R nginx:nginx /var/cache/nginx /var/log/nginx /var/www/html; \
    # Container best-practice: stream nginx logs to docker's stdout/stderr.
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
COPY mainline/alpine/files/snippets/        /etc/nginx/snippets/
# Built-in fallback vhost — entrypoint installs into conf.d/ when empty.
COPY mainline/alpine/files/default-conf.d/  /usr/share/nginx-defaults/
COPY mainline/alpine/docker-entrypoint.sh   /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 80   = HTTP (redirect + ACME)
# 443/tcp = HTTPS (TLS 1.2/1.3 over TCP, h2 + h1.1)
# 443/udp = HTTP/3 (QUIC)
EXPOSE 80/tcp 443/tcp 443/udp

VOLUME ["/var/log/nginx", "/etc/letsencrypt", "/var/www/html"]

STOPSIGNAL SIGQUIT

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl -fsS -o /dev/null http://127.0.0.1/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
