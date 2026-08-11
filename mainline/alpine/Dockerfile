# syntax=docker/dockerfile:1.7
#
# NGINX toolbox based on the official nginx.org Alpine image.
#
# The official binary supplies HTTP/2, HTTP/3 (QUIC), stream, threads, AIO,
# and the standard HTTP modules used by this repository.  We only
# build the third-party functionality missing upstream, as ABI-matched dynamic
# modules.  Keeping the nginx binary owned by the official image means nginx,
# OpenSSL, and Alpine security updates no longer depend on our compiler recipe.

ARG NGINX_FROM_IMAGE=nginx:1.31.3-alpine3.24-slim@sha256:45b82ed5f285b90d63df07ba70430fdd8f25624b416617d9e6dc93412b2006dc

FROM ${NGINX_FROM_IMAGE} AS module-builder

ARG NGINX_VERSION=1.31.3
ARG NGINX_SHA256=a7657c50811c2d92d9895395e8b873ef60398142c4db21eb647811c38f6dd525
# Optional build-only mirror override for environments where Alpine's CDN is
# slow. It does not change the repositories baked into the runtime image.
ARG ALPINE_MIRROR=

ARG HEADERS_MORE_VERSION=0.40
ARG HEADERS_MORE_SHA256=c14cb5e6c998590c209efbf77bd7637ce2cab02332e4192756a8af5b26ba4284

ARG NGX_BROTLI_REPO=https://github.com/google/ngx_brotli
ARG NGX_BROTLI_REF=a71f9312c2deb28875acc7bacfdd5695a111aa53

ARG NGX_CACHE_PURGE_REPO=https://github.com/nginx-modules/ngx_cache_purge
ARG NGX_CACHE_PURGE_REF=285354eddd5675c765ba2b79dac09f5d3065b22f

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
ARG ENABLE_NJS_XML=0
ARG ENABLE_GEOIP2=0
ARG ENABLE_VTS=0

RUN set -eux; \
    actual="$(nginx -v 2>&1 | sed 's|.*/||')"; \
    [ "$actual" = "${NGINX_VERSION}" ]; \
    if [ -n "${ALPINE_MIRROR}" ]; then \
      sed -i "s|https://dl-cdn.alpinelinux.org/alpine|${ALPINE_MIRROR}|g" /etc/apk/repositories; \
    fi; \
    apk add --no-cache --virtual .module-build \
      build-base git curl ca-certificates linux-headers \
      pcre2-dev zlib-dev brotli-dev openssl-dev libmaxminddb-dev; \
    if [ "${ENABLE_ZSTD}" = "1" ]; then apk add --no-cache zstd-dev; fi; \
    if [ "${ENABLE_NJS_XML}" = "1" ]; then apk add --no-cache libxml2-dev libxslt-dev; fi

WORKDIR /tmp/build

# Fetch nginx and every enabled module from an immutable, verified source.
RUN set -eux; \
    curl -fSLo nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"; \
    echo "${NGINX_SHA256}  nginx.tar.gz" | sha256sum -c -; \
    tar -xzf nginx.tar.gz; \
    rm -f nginx.tar.gz; \
    mkdir -p "nginx-${NGINX_VERSION}/extensions"; \
    cd "nginx-${NGINX_VERSION}/extensions"; \
    shallow_checkout() { \
        mkdir -p "$1"; \
        cd "$1"; \
        git init -q .; \
        git remote add origin "$2"; \
        git fetch -q --depth 1 origin "$3"; \
        git checkout -q FETCH_HEAD; \
        cd ..; \
    }; \
    shallow_checkout ngx_brotli "${NGX_BROTLI_REPO}" "${NGX_BROTLI_REF}"; \
    (cd ngx_brotli && git submodule update --init --recursive); \
    shallow_checkout ngx_cache_purge "${NGX_CACHE_PURGE_REPO}" "${NGX_CACHE_PURGE_REF}"; \
    curl -fSLo headers-more.tgz \
      "https://github.com/openresty/headers-more-nginx-module/archive/v${HEADERS_MORE_VERSION}.tar.gz"; \
    echo "${HEADERS_MORE_SHA256}  headers-more.tgz" | sha256sum -c -; \
    tar -xzf headers-more.tgz; \
    mv "headers-more-nginx-module-${HEADERS_MORE_VERSION}" headers-more; \
    rm -f headers-more.tgz; \
    if [ "${ENABLE_ZSTD}" = "1" ]; then \
        shallow_checkout zstd-nginx-module "${ZSTD_NGINX_REPO}" "${ZSTD_NGINX_REF}"; \
    fi; \
    if [ "${ENABLE_NJS}" = "1" ]; then \
        curl -fSLo njs.tgz "https://github.com/nginx/njs/archive/refs/tags/${NJS_VERSION}.tar.gz"; \
        echo "${NJS_SHA256}  njs.tgz" | sha256sum -c -; \
        tar -xzf njs.tgz; \
        mv "njs-${NJS_VERSION}" njs; \
        rm -f njs.tgz; \
    fi; \
    if [ "${ENABLE_GEOIP2}" = "1" ]; then \
        curl -fSLo geoip2.tgz "https://github.com/leev/ngx_http_geoip2_module/archive/refs/tags/${GEOIP2_VERSION}.tar.gz"; \
        echo "${GEOIP2_SHA256}  geoip2.tgz" | sha256sum -c -; \
        tar -xzf geoip2.tgz; \
        mv "ngx_http_geoip2_module-${GEOIP2_VERSION}" geoip2; \
        rm -f geoip2.tgz; \
    fi; \
    if [ "${ENABLE_VTS}" = "1" ]; then \
        curl -fSLo vts.tgz "https://github.com/vozlt/nginx-module-vts/archive/refs/tags/v${VTS_VERSION}.tar.gz"; \
        echo "${VTS_SHA256}  vts.tgz" | sha256sum -c -; \
        tar -xzf vts.tgz; \
        mv "nginx-module-vts-${VTS_VERSION}" vts; \
        rm -f vts.tgz; \
    fi

# Match the configure feature set of the pinned official nginx package.  The
# official binary is built with --with-compat, so these .so files can be loaded
# without replacing /usr/sbin/nginx.
RUN set -eux; \
    cd "/tmp/build/nginx-${NGINX_VERSION}"; \
    if [ "${ENABLE_NJS_XML}" = "1" ]; then NJS_LIBXSLT=YES; else NJS_LIBXSLT=NO; fi; \
    export NJS_LIBXSLT; \
    modules="--add-dynamic-module=./extensions/ngx_cache_purge \
             --add-dynamic-module=./extensions/ngx_brotli \
             --add-dynamic-module=./extensions/headers-more"; \
    [ "${ENABLE_ZSTD}" = "1" ] && modules="$modules --add-dynamic-module=./extensions/zstd-nginx-module"; \
    [ "${ENABLE_NJS}" = "1" ] && modules="$modules --add-dynamic-module=./extensions/njs/nginx"; \
    [ "${ENABLE_GEOIP2}" = "1" ] && modules="$modules --add-dynamic-module=./extensions/geoip2"; \
    [ "${ENABLE_VTS}" = "1" ] && modules="$modules --add-dynamic-module=./extensions/vts"; \
    ./configure \
      --prefix=/etc/nginx \
      --sbin-path=/usr/sbin/nginx \
      --modules-path=/usr/lib/nginx/modules \
      --conf-path=/etc/nginx/nginx.conf \
      --error-log-path=/var/log/nginx/error.log \
      --http-log-path=/var/log/nginx/access.log \
      --pid-path=/run/nginx.pid \
      --lock-path=/run/nginx.lock \
      --http-client-body-temp-path=/var/cache/nginx/client_temp \
      --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
      --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
      --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
      --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
      --with-perl_modules_path=/usr/lib/perl5/vendor_perl \
      --user=nginx --group=nginx \
      --with-compat --with-file-aio --with-threads \
      --with-http_addition_module --with-http_auth_request_module \
      --with-http_dav_module --with-http_flv_module \
      --with-http_gunzip_module --with-http_gzip_static_module \
      --with-http_mp4_module --with-http_random_index_module \
      --with-http_realip_module --with-http_secure_link_module \
      --with-http_slice_module --with-http_ssl_module \
      --with-http_stub_status_module --with-http_sub_module \
      --with-http_v2_module --with-http_v3_module \
      --with-mail --with-mail_ssl_module \
      --with-stream --with-stream_realip_module \
      --with-stream_ssl_module --with-stream_ssl_preread_module \
      $modules; \
    make -j"$(nproc)" modules; \
    mkdir -p /tmp/modules; \
    cp objs/*.so /tmp/modules/; \
    strip /tmp/modules/*.so; \
    : > /tmp/modules/00-third-party.conf; \
    for module in /tmp/modules/*.so; do \
        printf 'load_module modules/%s;\n' "$(basename "$module")" >> /tmp/modules/00-third-party.conf; \
    done

FROM ${NGINX_FROM_IMAGE}

LABEL org.opencontainers.image.title="docker-nginx-quic" \
      org.opencontainers.image.description="Official NGINX with HTTP/3, Brotli, headers-more, and cache-purge" \
      org.opencontainers.image.source="https://github.com/hsxk/docker-nginx" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

ARG ENABLE_ZSTD=0
ARG ENABLE_GEOIP2=0
ARG ENABLE_NJS_XML=0

RUN set -eux; \
    apk add --no-cache openssl brotli-libs; \
    if [ "${ENABLE_ZSTD}" = "1" ]; then apk add --no-cache zstd-libs; fi; \
    if [ "${ENABLE_GEOIP2}" = "1" ]; then apk add --no-cache libmaxminddb; fi; \
    if [ "${ENABLE_NJS_XML}" = "1" ]; then apk add --no-cache libxml2 libxslt; fi; \
    rm -f /etc/nginx/conf.d/default.conf; \
    mkdir -p /etc/nginx/modules-enabled /etc/nginx/snippets \
             /etc/nginx/conf.d /etc/nginx/http.d /usr/share/nginx-defaults \
             /var/cache/nginx /var/log/nginx /var/www/html /etc/letsencrypt; \
    chown -R nginx:nginx /var/cache/nginx /var/log/nginx /var/www/html; \
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log

COPY --from=module-builder /tmp/modules/*.so /usr/lib/nginx/modules/
COPY --from=module-builder /tmp/modules/00-third-party.conf /etc/nginx/modules-enabled/00-third-party.conf

COPY mainline/alpine/files/nginx.conf       /etc/nginx/nginx.conf
COPY mainline/alpine/files/fastcgi_params   /etc/nginx/fastcgi_params
COPY mainline/alpine/files/resolver.conf    /etc/nginx/resolver.conf
COPY mainline/alpine/files/quic-bpf.conf    /etc/nginx/quic-bpf.conf
COPY mainline/alpine/files/snippets/        /etc/nginx/snippets/
COPY mainline/alpine/files/default-conf.d/  /usr/share/nginx-defaults/
COPY mainline/alpine/docker-entrypoint.sh   /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 80/tcp 443/tcp 443/udp

STOPSIGNAL SIGQUIT

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8081/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
