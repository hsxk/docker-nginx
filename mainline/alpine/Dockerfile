FROM --platform=$BUILDPLATFORM alpine:3.18
LABEL maintainer="KeXin Hao<haokexin1214@gmail.com>"

ENV NGINX_VERSION 1.25.1

ENV NGINX_DEPS gnupg \
    ca-certificates \
    gcc \
    g++ \
    make  \
    cmake \
    autoconf \
    automake \
    patch \
    ruby-rake \
    curl \
    curl-dev \
    musl-dev \
    perl-dev \
    libxslt-dev \
    openssl \
    openssl-dev \
    linux-headers \
    libpng-dev \
    freetype-dev \
    libxpm-dev \
    expat-dev \
    tiff-dev \
    libxcb-dev \
    pcre-dev \
    geoip-dev \
    gd-dev \
    brotli-dev \
    ruby-etc \
    ruby-dev \
    fontconfig-dev \
    libuuid \
    util-linux-dev \
    zlib-dev \
    libmaxminddb-dev \
    go

COPY mainline/alpine/files/naxsi.patch /tmp/naxsi.patch

RUN : \
    set -x \
    # create nginx user/group first, to be consistent throughout docker variants
    && addgroup -g 101 -S nginx \
    && adduser -S -D -H -u 101 -h /var/cache/nginx -s /sbin/nologin -G nginx -g nginx nginx \
    # add build pkg
    && ngx_cache_purge_version=2.3 \
    && ngx_brotli_version=1.0.0rc \
    && naxsi_tarball_name=naxsi \
    && naxsi_version=1.3 \
    && headers_more_module_version=0.34 \
    && vts_version=0.2.2 \
    && geoip2_version=3.4 \
    && apk add --no-cache --virtual .builddep ${NGINX_DEPS} \
    && mkdir /tmp/build \
    && cd /tmp/build \
    && curl -fSL http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz -o nginx.tar.gz \
    && tar xf nginx.tar.gz \
    && mkdir nginx-${NGINX_VERSION}/extensions \
    && cd ./nginx-${NGINX_VERSION}/extensions \
    && curl -fSLo ngx_cache_purge-${ngx_cache_purge_version}.tar.gz  \
    https://github.com/FRiCKLE/ngx_cache_purge/archive/${ngx_cache_purge_version}.tar.gz \
    && curl -fSLo ngx_brotli-${ngx_brotli_version}.tar.gz \
    https://github.com/google/ngx_brotli/archive/v${ngx_brotli_version}.tar.gz \
    && curl -fSLo headers-more-nginx-module-${headers_more_module_version}.tar.gz \
    https://github.com/openresty/headers-more-nginx-module/archive/v${headers_more_module_version}.tar.gz \
    && curl -fSLo ${naxsi_tarball_name}-${naxsi_version}.tar.gz \
    https://github.com/nbs-system/naxsi/archive/${naxsi_version}.tar.gz \
    && curl -fSLo vts-${vts_version}.tar.gz \
    https://github.com/vozlt/nginx-module-vts/archive/refs/tags/v${vts_version}.tar.gz \
    && curl -fSLo geoip2-${geoip2_version}.tar.gz \
    https://github.com/leev/ngx_http_geoip2_module/archive/refs/tags/${geoip2_version}.tar.gz \ 
    && curl -fSLo boringssl.tar.gz \
    https://boringssl.googlesource.com/boringssl/+archive/HEAD.tar.gz \
    && tar xf ngx_cache_purge-${ngx_cache_purge_version}.tar.gz \
    && mv ngx_cache_purge-${ngx_cache_purge_version} ngx_cache_purge \
    && tar xf ngx_brotli-${ngx_brotli_version}.tar.gz \
    && mv ngx_brotli-${ngx_brotli_version} ngx_brotli \
    && tar xf ${naxsi_tarball_name}-${naxsi_version}.tar.gz \
    && mv ${naxsi_tarball_name}-${naxsi_version} ${naxsi_tarball_name} \
    && tar xf headers-more-nginx-module-${headers_more_module_version}.tar.gz \
    && mv headers-more-nginx-module-${headers_more_module_version} headers-more-nginx-module \
    && tar xf vts-${vts_version}.tar.gz \
    && mv nginx-module-vts-${vts_version} vts \
    && tar xf geoip2-${geoip2_version}.tar.gz \
    && mv ngx_http_geoip2_module-${geoip2_version} geoip2 \
    && mkdir -p ./boringssl/build \
    && tar xf boringssl.tar.gz -C ./boringssl \
    && cd ./boringssl/build \
    && cmake .. \
    && make  \ 
    && cd ../../.. \
    && patch -p1 < /tmp/naxsi.patch \
    && CC=/usr/bin/cc \
    && CXX=/usr/bin/c++ \
    && CONF="\
    --prefix=/etc/nginx \
    --conf-path=/etc/nginx/nginx.conf \
    --sbin-path=/usr/sbin/nginx \
    --modules-path=/usr/lib/nginx/modules \
    --http-log-path=/var/log/nginx/access.log \
    --error-log-path=/var/log/nginx/error.log \
    --pid-path=/var/run/nginx.pid \
    --lock-path=/var/run/nginx.lock \
    --http-client-body-temp-path=/var/cache/nginx/client_temp \
    --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
    --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
    --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
    --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
    --modules-path=/usr/lib64/nginx/modules \
    --with-poll_module \
    --with-threads \
    --with-http_degradation_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_realip_module \
    --with-http_addition_module \
    --with-http_sub_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_mp4_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_random_index_module \
    --with-http_secure_link_module \
    --with-http_stub_status_module \
    --with-http_auth_request_module \
    --with-http_xslt_module \
    --with-http_image_filter_module \
    --with-http_geoip_module \
    --with-stream \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --with-stream_realip_module \
    --with-stream_geoip_module \
    --with-http_slice_module \
    --with-mail \
    --with-mail_ssl_module \
    --with-compat \
    --with-file-aio \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-http_image_filter_module \
    --with-http_geoip_module \
    --with-http_perl_module \
    --with-pcre-jit \
    --add-module=./extensions/ngx_cache_purge \
    --add-module=./extensions/ngx_brotli \
    --add-module=./extensions/${naxsi_tarball_name}/naxsi_src \
    --add-module=./extensions/headers-more-nginx-module \
    --add-module=./extensions/vts \
    --add-module=./extensions/geoip2 \
    " \
    && CFLAGS='-O2 -g -pipe -Wp,-D_FORTIFY_SOURCE=2 \
    -fexceptions -fstack-protector \
    -m64 -mtune=generic \
    -Wno-deprecated-declarations \
    -Wno-cast-function-type \
    -Wno-unused-parameter \
    -Wno-stringop-truncation \
    -Wno-stringop-overflow \
    -I./extensions/boringssl/include' \
    && ./configure $CONF --with-cc-opt="$CFLAGS" --with-ld-opt='-L./extensions/boringssl/build/ssl -L./extensions/boringssl/build/crypto'  \
    \
    # build
    && make -j$(getconf _NPROCESSORS_ONLN) \
    && (find . -type f -a -name 'nginx' -o -name '*.so*' | xargs strip ; true) \
    && (find . -type f -a -name '*.so*' | xargs chmod 755 ; true) \
    && make install \
    && mkdir -p /usr/lib/nginx/modules /etc/nginx/naxsi.d \
    && install -m644 extensions/${naxsi_tarball_name}/naxsi_config/naxsi_core.rules /etc/nginx/naxsi.d/naxsi_core.rules.conf \
    && (for so in `find extensions -type f -name '*.so'`; do mv $so /usr/lib/nginx/modules ; done; true) \
    \
    # remove pkg
    && runDeps="$( \
    scanelf --needed --nobanner --format '%n#p' /usr/sbin/nginx /usr/lib/nginx/modules/*.so /tmp/envsubst \
    | tr ',' '\n' \
    | sort -u \
    | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )" \
    && apk add --no-cache --virtual .nginx-rundeps $runDeps tzdata openssl \
    && apk del --purge .builddep \
    \
    && rm -rf /tmp/build /tmp/*.patch \
    && ln -s ../../usr/lib/nginx/modules /etc/nginx/modules \
    # && ln -sf /dev/stdout /var/log/nginx/access.log \
    # && ln -sf /dev/stderr /var/log/nginx/error.log \
    && : # END of RUN

#COPY mainline/alpine/files/geoip2/* /usr/share/GeoIP2/
COPY mainline/alpine/files/nginx.conf /etc/nginx/nginx.conf
COPY mainline/alpine/files/fastcgi_params /etc/nginx/fastcgi_params
COPY mainline/alpine/files/templates/ /etc/nginx/conf.d/
COPY mainline/alpine/files/naxsi.conf /etc/nginx/naxsi.conf
COPY mainline/alpine/files/ssl/* /etc/letsencrypt/

EXPOSE 80
EXPOSE 443

VOLUME /var/www/html
VOLUME /etc/letsencrypt
VOLUME /var/log/nginx
VOLUME /etc/nginx/conf.d/

HEALTHCHECK --interval=5s --timeout=5s CMD curl -I https://127.0.0.1/healthcheck || exit 1
STOPSIGNAL SIGQUIT

CMD ["/bin/sh", "-c", "while :; do sleep 30d & wait ${!}; nginx -s reload; done & nginx -g \"daemon off;\""]