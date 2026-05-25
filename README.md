# docker-nginx-quic

A small, hardened NGINX Docker image with HTTP/3 (QUIC), Brotli, headers-more,
and FastCGI cache-purge. Built from source against **BoringSSL** for QUIC
support, and shipped as a *toolbox*: the image gives you a sensible base
config plus a library of include-able snippets — you bring your own site
files in `/etc/nginx/conf.d/`.

## What's in the image

| Component               | Version (default)                | Notes                              |
|-------------------------|----------------------------------|------------------------------------|
| NGINX                   | `1.31.1`                         | tarball SHA256 verified            |
| Alpine                  | `3.20`                           |                                    |
| BoringSSL               | pinned commit (see Dockerfile)   | for HTTP/3                         |
| ngx_brotli              | `google/ngx_brotli` @ pinned SHA | upstream, last update 2024-05      |
| ngx_cache_purge         | `nginx-modules/ngx_cache_purge`  | active fork; nginx ≥1.25 compat    |
| headers-more-nginx      | `0.34`                           | tarball SHA256 verified            |

Every external source is pinned to either an immutable git commit SHA or a
release tag whose tarball is SHA256-verified at build time — flip a version
and the matching `*_SHA256` ARG together when bumping.

Modules removed vs. the previous image:
* `--with-http_image_filter_module` — pulled in `gd-dev` + `libpng-dev`, almost never used.
* `--with-http_xslt_module` — never used here.
* `--with-http_perl_module` — heavy perl runtime, never used.
* `--with-http_geoip_module` — MaxMind has EOL'd the GeoIP1 DB format. Use the
  optional `ENABLE_GEOIP2` (see below) for the modern GeoIP2 / libmaxminddb path.

## Optional modules

Off by default. Flip the build-arg to `1` to include them — runtime libraries
are also pulled in automatically.

| Build arg          | Module                                              | When to enable                                            |
|--------------------|-----------------------------------------------------|-----------------------------------------------------------|
| `ENABLE_ZSTD=1`    | [tokers/zstd-nginx-module](https://github.com/tokers/zstd-nginx-module) | API / JSON-heavy traffic — Chrome ≥123, Firefox ≥126 negotiate `Accept-Encoding: zstd` and zstd is ~2–3× faster than brotli at the same ratio. |
| `ENABLE_NJS=1`     | [nginx/njs](https://nginx.org/en/docs/njs/)         | Replace evil `if` chains with JS-based routing / header rewrites. |
| `ENABLE_GEOIP2=1`  | [leev/ngx_http_geoip2_module](https://github.com/leev/ngx_http_geoip2_module) | GeoIP-based routing / rate limiting / logging.            |
| `ENABLE_VTS=1`     | [vozlt/nginx-module-vts](https://github.com/vozlt/nginx-module-vts) | Prometheus-friendly `/status` (QPS, status, upstreams, cache). |

Example — build with everything on:
```sh
docker build -t my-nginx \
  --build-arg ENABLE_ZSTD=1 \
  --build-arg ENABLE_NJS=1 \
  --build-arg ENABLE_GEOIP2=1 \
  --build-arg ENABLE_VTS=1 \
  -f mainline/alpine/Dockerfile .
```

Activation snippets ship with the image but are NOT auto-included (a build
without the module would otherwise fail `nginx -t`):

* `/etc/nginx/snippets/zstd.conf` — add `include /etc/nginx/snippets/zstd.conf;` inside `http {}` of nginx.conf.
* `/etc/nginx/snippets/geoip2.conf` — same, plus mount your GeoLite2 DB at `/etc/nginx/geoip2/`.
* `/etc/nginx/snippets/vts-status.conf` — add the `vhost_traffic_status_zone shared:vts:10m;` directive in `http {}`, then drop the snippet into `conf.d/`.

All versions are `ARG`s — override at build time:
```sh
docker build \
  --build-arg NGINX_VERSION=1.31.2 \
  -t my-nginx -f mainline/alpine/Dockerfile .
```

## Quick start

The image is self-bootstrapping — `docker run` with **zero configuration**
gives you a working HTTP/3 server on a self-signed cert:

```sh
docker build -t my-nginx -f mainline/alpine/Dockerfile .

docker run -d --name nginx \
  -p 80:80/tcp -p 443:443/tcp -p 443:443/udp \
  my-nginx
# → https://localhost/  shows "It works."   (browser will warn — self-signed)
# → https://localhost/healthz  returns 200 ok
```

What happens on first boot:
1. The entrypoint sees `/etc/nginx/conf.d/` is empty and copies the built-in
   `default.conf` from `/usr/share/nginx-defaults/` into place.
2. No cert at `/etc/letsencrypt/_default/` → entrypoint generates a self-signed
   pair (`fullchain.pem` + `privkey.pem`, CN=localhost).
3. `nginx -t` validates → `nginx -g 'daemon off;'` launches.

To serve **your own sites**, mount a directory of `*.conf` files:

```sh
docker run -d --name nginx \
  -p 80:80 -p 443:443/tcp -p 443:443/udp \
  -v $PWD/my-conf.d:/etc/nginx/conf.d:ro \
  -v letsencrypt:/etc/letsencrypt \
  my-nginx
```

The moment you mount anything into `conf.d/`, the built-in default is
**not** installed — your configs take over completely. Use the files in
[`examples/conf.d/`](./examples/conf.d) as starting points (edit
`server_name` and the `ssl_certificate*` paths).

…or with the supplied compose file:
```sh
docker compose up -d   # boots into the "It works." fallback
```

## Layout

```
docker-nginx/
├── mainline/alpine/
│   ├── Dockerfile                  # multi-stage builder + slim runtime
│   ├── docker-entrypoint.sh        # generates fallback self-signed cert
│   └── files/
│       ├── nginx.conf              # http {} defaults — installed at /etc/nginx/
│       ├── fastcgi_params
│       └── snippets/               # reusable building blocks
│           ├── tls.conf
│           ├── http3.conf
│           ├── security-headers.conf
│           ├── acme-challenge.conf
│           ├── proxy-defaults.conf
│           ├── websocket.conf
│           ├── static-cache.conf
│           ├── fastcgi.conf
│           ├── fastcgi-cache.conf
│           ├── fastcgi-cache-purge.conf
│           ├── healthz.conf
│           ├── error-pages.conf       # opt-in branded 4xx/5xx pages
│           ├── zstd.conf              # opt-in, needs ENABLE_ZSTD=1
│           ├── geoip2.conf            # opt-in, needs ENABLE_GEOIP2=1
│           └── vts-status.conf        # opt-in, needs ENABLE_VTS=1
├── examples/
│   └── conf.d/                     # drop these into /etc/nginx/conf.d/
│       ├── 00-http-redirect.conf   # :80 → :443 + ACME + healthz
│       ├── 05-default-deny.conf    # catch-all for unknown Host → 444
│       ├── 10-example-static.conf  # static site + HTTP/3 (reuseport)
│       ├── 20-reverse-proxy.conf   # WebSocket + per-route auth rate limit
│       └── 30-wordpress.conf       # WP + PHP-FPM + micro-cache
├── docker-compose.yml
└── .dockerignore
```

## Adding your own site

1. Copy any file under `examples/conf.d/` as a template.
2. Replace `example.com` with your domain.
3. Mount the directory at `/etc/nginx/conf.d/` (read-only).
4. Make sure **exactly one** of your `:443` server blocks carries
   `reuseport` on its `listen 443 quic` lines — typically your *first*
   TLS vhost. All others must just say `listen 443 quic;` without
   `reuseport`. See the comment in `10-example-static.conf`.
5. `docker exec nginx nginx -t && docker exec nginx nginx -s reload`.

## Snippet reference

| Snippet                          | Include where      | Purpose                                             |
|----------------------------------|--------------------|-----------------------------------------------------|
| `tls.conf`                       | inside `server {}` | TLS 1.2/1.3, modern ciphers, OCSP stapling          |
| `http3.conf`                     | inside `server {}` | `Alt-Svc`, `quic_retry`, `quic_gso`                 |
| `security-headers.conf`          | (auto, http {})    | CSP-friendly default headers                        |
| `acme-challenge.conf`            | inside any server  | `/.well-known/acme-challenge/` for Let's Encrypt    |
| `proxy-defaults.conf`            | inside `location`  | Standard proxy headers + keepalive                  |
| `websocket.conf`                 | inside `location`  | `Upgrade`/`Connection` + 1h timeout                 |
| `static-cache.conf`              | inside `server {}` | 30-day cache for assets + dotfile deny              |
| `fastcgi.conf`                   | inside `\.php$`    | PHP-FPM defaults (set `$fpm_upstream` first)        |
| `fastcgi-cache.conf`             | inside `\.php$`    | Micro-cache PHP responses                           |
| `fastcgi-cache-purge.conf`       | inside `server {}` | `/fcache-purge/*` endpoint (IP-restricted)          |
| `healthz.conf`                   | inside `server {}` | `GET /healthz → 200 ok` for HEALTHCHECK             |
| `error-pages.conf`               | inside `server {}` | Branded 404 / 429 / 5xx pages from `/var/www/html/errors/` |
| `zstd.conf`                      | inside `http {}`   | zstd compression (needs `ENABLE_ZSTD=1`)            |
| `geoip2.conf`                    | inside `http {}`   | MaxMind GeoIP2 lookup (needs `ENABLE_GEOIP2=1`)     |
| `vts-status.conf`                | inside `conf.d/`   | Prometheus metrics on :9145 (needs `ENABLE_VTS=1`)  |

## Logs, rate-limit zones, default deny

* **Logs go to stdout/stderr.** `access.log` and `error.log` are symlinked
  to `/dev/stdout` and `/dev/stderr` in the runtime image — `docker logs
  nginx` Just Works, and `-v ./logs:/var/log/nginx` is no longer needed.
* **Two rate-limit zones are pre-declared** in `nginx.conf`:
  * `req_per_ip` (100r/s) — generic, apply broadly with `limit_req zone=req_per_ip burst=20 nodelay;`
  * `auth` (1r/s) — strict, apply to `/login`, `/oauth/token`, OTP endpoints. See `examples/conf.d/20-reverse-proxy.conf`.
* **Default-deny vhost** — `examples/conf.d/05-default-deny.conf` returns
  `444` for any request whose `Host` header doesn't match a real vhost.
  Prevents IP-scan leakage. Loaded before site configs via the `05-` prefix.

## Verifying HTTP/3

The image is built with `--with-http_v3_module` against BoringSSL — HTTP/3
support is compiled in. To verify it works **end-to-end**:

### 1. NGINX side

```sh
$ docker exec nginx nginx -V 2>&1 | tr ' ' '\n' | grep -E 'v3|module'
--with-http_v3_module
…
$ docker exec nginx nginx -T 2>/dev/null | grep -E 'listen .*quic|Alt-Svc'
listen      443 quic reuseport;
listen [::]:443 quic reuseport;
add_header Alt-Svc 'h3=":443"; ma=86400' always;
```

You should see **exactly one** `reuseport` per address family across all
your server blocks. NGINX will warn on startup if you have zero or more
than one.

### 2. Network side

QUIC runs over UDP/443. Verify the port is bound and reachable:

```sh
$ docker exec nginx ss -lnup | grep :443
UNCONN 0  0  0.0.0.0:443  0.0.0.0:*
UNCONN 0  0     [::]:443     [*]:*

# From the outside (open UDP/443 in your firewall first!):
$ nc -uvz example.com 443     # rough reachability check
```

### 3. Client side — three independent tools

```sh
# (a) curl 8.x with the HTTP/3 build:
$ curl --http3-only -I https://example.com/
HTTP/3 200
alt-svc: h3=":443"; ma=86400
server: nginx
…

# (b) Chrome / Edge / Firefox DevTools → Network panel → "Protocol" column
#     should show "h3" after the second visit (first visit gets the
#     Alt-Svc hint over h2 and switches on the next request).

# (c) Online: https://http3check.net/?host=example.com
```

If `curl --http3-only` returns `200` and DevTools shows `h3`, HTTP/3 is
correctly enabled.

### Common HTTP/3 gotchas

| Symptom                                    | Cause                                                  |
|--------------------------------------------|--------------------------------------------------------|
| `curl --http3` times out, `--http2` works  | UDP/443 not mapped (`-p 443:443/udp`) or firewall block|
| Browsers never switch to h3                | Missing `Alt-Svc` header (forgot `http3.conf` include) |
| NGINX startup warning "duplicate listen options for [::]:443" | Two server blocks both have `reuseport`         |
| Only h2, never h3, even with Alt-Svc       | `listen 443 quic;` missing on that vhost               |
| HTTP/3 works for the first hostname only   | `reuseport` is on a non-first vhost — move it up       |
| `curl --http3` returns `400` "no QUIC support" | Your curl was built against OpenSSL ≤3.4 without QUIC; install the curl-quic build |

## TLS certificate workflow

The image ships with `docker-entrypoint.sh` that creates a throw-away
self-signed cert (`/etc/letsencrypt/default.{crt,key}`) on first boot so
NGINX can start out of the box.

For real certs use [certbot](https://certbot.eff.org/) on the host with
`--webroot -w /var/www/html`, then reload:

```sh
docker exec nginx nginx -s reload
```

The recommended pattern is to add a `--deploy-hook` to your certbot
config so reload happens automatically on renewal:

```sh
certbot certonly --webroot -w /var/www/html -d example.com \
    --deploy-hook 'docker exec nginx nginx -s reload'
```

The previous image baked in a 30-day reload-loop hack inside the
container. We removed it because:
* It masked crashes (entrypoint had two foreground processes).
* It reloaded even when no cert had changed.
* It was orthogonal to nginx's job.

## License

GPL-3.0-or-later.

## Performance defaults

The base config opts into every cheap-to-enable win nginx ships:

| Tuning                                 | Where                          | Why                                         |
|----------------------------------------|--------------------------------|---------------------------------------------|
| `pcre_jit on`                          | main scope                     | JIT-compile every regex (locations, server_name). Built with `--with-pcre-jit`. |
| `aio threads=default` + `aio_write on` | http {}                        | Offload blocking disk I/O to a 32-thread pool. Built with `--with-threads --with-file-aio`. |
| `thread_pool default threads=32 max_queue=65536` | main scope            | Backs the `aio` directive.                  |
| `sendfile_max_chunk 2m`                | http {}                        | One slow client can't starve a worker.      |
| `reset_timedout_connection on`         | http {}                        | Frees memory faster when peers vanish.      |
| `ssl_buffer_size 4k`                   | snippets/tls.conf              | Halves TLS-record TTFB for small responses. |
| `directio 4m` + `output_buffers 2 1m`  | snippets/static-cache.conf     | Stream large media without polluting page cache. |
| `fastcgi_cache_background_update on`   | snippets/fastcgi-cache.conf    | Stale-while-revalidate — serves cached page instantly while one worker refreshes in background. |
| `proxy_socket_keepalive on`            | snippets/proxy-defaults.conf   | Keeps NAT/LB state warm to upstream.        |
| `gzip` + `brotli` at level 5           | http {}                        | CPU/ratio sweet spot. Enable zstd at level 5 (Chrome ≥123) by mounting `snippets/zstd.conf`. |
| `keepalive_requests 1000`              | http {} + upstream             | Reuse each connection 1000× before recycle. |
| `open_file_cache max=10000 inactive=60s` | http {}                      | Eliminates `open()` syscalls on hot static files. |

Things nginx can't tune from inside the container — set on the **host**:

```sh
# QUIC needs bigger UDP buffers — without these, big packets get dropped at the kernel.
sysctl -w net.core.rmem_max=2500000
sysctl -w net.core.wmem_max=2500000

# Optional: enable TCP Fast Open on the listener side (kernel ≥3.7).
sysctl -w net.ipv4.tcp_fastopen=3

# Optional: BBR congestion control — meaningfully better throughput on lossy links.
modprobe tcp_bbr
sysctl -w net.ipv4.tcp_congestion_control=bbr
sysctl -w net.core.default_qdisc=fq
```

Pre-compress static assets at build time so brotli/gzip/zstd `_static on`
serves the disk file directly (zero CPU at request time):

```sh
brotli -k -q 11 dist/**/*.{html,css,js,svg}
gzip  -k -9    dist/**/*.{html,css,js,svg}
# If your build pipeline supports it:
zstd  -k -19   dist/**/*.{html,css,js,svg}
```

## Continuous integration

`.github/workflows/docker-build.yml` runs in two stages:

* **matrix-build** — on every PR + push, builds 6 image flavors
  (`base`, `zstd`, `njs`, `geoip2`, `vts`, `all`) on a single arch, runs
  `nginx -V` and `nginx -t` inside each image. No registry push. Uses GitHub
  Actions cache per-flavor so re-runs are fast.
* **release** — on tag pushes only, builds the multi-arch (`linux/amd64`,
  `linux/arm64`) image with `provenance: mode=max` and `sbom: true`, then
  pushes to Docker Hub. Provenance + SBOM let downstream consumers verify
  the image with `docker buildx imagetools inspect --format "{{ json .SBOM }}"`.

Required repository secrets: `DOCKER_USERNAME`, `DOCKER_PASSWORD`.
