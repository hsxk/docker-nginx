# docker-nginx-quic

A small, hardened NGINX Docker image with HTTP/3 (QUIC), Brotli, headers-more,
and FastCGI cache-purge. HTTP/3 runs on **stock OpenSSL 3.5**, linked
dynamically against the distro package — no vendored TLS fork. Shipped as a
*toolbox*: the image gives you a sensible base config plus a library of
include-able snippets — you bring your own site files in `/etc/nginx/conf.d/`.

## What's in the image

| Component               | Version (default)                | Notes                              |
|-------------------------|----------------------------------|------------------------------------|
| NGINX                   | `1.31.3`                         | tarball SHA256 verified            |
| Alpine                  | `3.22` (pinned by digest)        | oldest branch shipping OpenSSL 3.5 |
| OpenSSL                 | `3.5.x` (Alpine package)         | for HTTP/3 — see below             |
| ngx_brotli              | `google/ngx_brotli` @ pinned SHA | upstream, last update 2023-10      |
| ngx_cache_purge         | `nginx-modules/ngx_cache_purge`  | active fork; nginx ≥1.25 compat    |
| headers-more-nginx      | `0.40`                           | tarball SHA256 verified            |

### Why the QUIC backend is plain OpenSSL now

Serving HTTP/3 used to require a patched TLS library, because upstream OpenSSL
had no server-side QUIC API. That is over: OpenSSL 3.5 ships one
(`SSL_set_quic_tls_cbs`), and nginx picks it automatically — the selection in
`src/event/quic/ngx_event_quic.h` is a plain `OPENSSL_VERSION_NUMBER >= 3.5.1`
check.

That matters for more than tidiness. A vendored TLS stack is **frozen at the
version you pinned and invisible to everything that looks for CVEs**: it is not
an `apk` package, so it does not appear in the image SBOM and scanners cannot
see it. quictls' last QUIC release is based on OpenSSL 3.3.0 (April 2024) and
the project wound down once OpenSSL 3.5 LTS landed, so that pin was accumulating
unpatched OpenSSL advisories that nothing would report. Linking the distro
package means a base-image rebuild picks up Alpine's security updates.

The build fails loudly rather than degrading: if the OpenSSL headers are older
than 3.5.1, nginx would silently fall back to its `NGX_QUIC_OPENSSL_COMPAT`
shim, so the Dockerfile compiles a version assertion before `./configure`.

Every external source is pinned to either an immutable git commit SHA or a
release tag whose tarball is SHA256-verified at build time — flip a version
and the matching `*_SHA256` ARG together when bumping.

### How this compares to the official `nginx:alpine`

Worth being precise, because the gap is narrower than it used to be. As of
1.31.3 the official image is *also* built with `--with-http_v3_module` against
OpenSSL 3.5.7 — HTTP/3 is no longer a reason to leave it. What this image adds
is the third-party module set, which official does not ship in any form:

| | official `nginx:alpine` | this image |
|---|---|---|
| nginx / OpenSSL | 1.31.3 / 3.5.7 | 1.31.3 / 3.5.7 |
| HTTP/3 (QUIC) | yes | yes |
| Brotli | — | `ngx_brotli` |
| `headers-more` | — | yes |
| cache purge | — | `ngx_cache_purge` |
| zstd / njs / GeoIP2 / VTS | — | opt-in build args |
| mail proxy | yes | **no** (see below) |
| config + snippet toolbox | bare default vhost | the point of this image |

`--with-mail` / `--with-mail_ssl_module` are the one thing official has that this
does not, deliberately: an SMTP/IMAP/POP3 proxy is a different daemon role,
nothing in this image's config or snippets addresses it, and leaving it out
keeps a protocol parser off the attack surface. Open an issue if you need it.

Modules removed vs. the previous image:
* `--with-http_image_filter_module` — pulled in `gd-dev` + `libpng-dev`, almost never used.
* `--with-http_xslt_module` — never used here.
* `--with-http_perl_module` — heavy perl runtime, never used.
* `--with-http_geoip_module` — MaxMind has EOL'd the GeoIP1 DB format. Use the
  optional `ENABLE_GEOIP2` (see below) for the modern GeoIP2 / libmaxminddb path.

## Upgrading from 1.31.1 or earlier

Most of this release is bug fixes, but some defaults changed in ways that can
change what your sites serve. In rough order of "will bite you".

**Override security headers with `more_set_headers`, not `add_header`.** They
moved out of `add_header` (see [Behaviour worth knowing about](#behaviour-worth-knowing-about)
for why). The families do not see each other, so a vhost doing
`add_header X-Frame-Options "DENY" always;` no longer replaces the default —
the response now carries both `SAMEORIGIN` and `DENY`, which browsers treat as
conflicting and may ignore outright. Grep your configs for `add_header` naming
any of: `Strict-Transport-Security`, `X-Content-Type-Options`, `X-Frame-Options`,
`Referrer-Policy`, `Permissions-Policy`, `Cross-Origin-Opener-Policy` — and
switch those lines to `more_set_headers "Name: value";`.

**HSTS lost `includeSubDomains`.** If you were relying on it, set it explicitly
per site. Browsers that already cached the old directive keep honouring it until
its max-age expires.

**OCSP stapling is off.** Re-enable in `snippets/tls.conf` if your CA publishes
OCSP responder URLs (Let's Encrypt no longer does).

**TLS session tickets are on.** If you deliberately disabled resumption for
forward-secrecy reasons, set `ssl_session_tickets off;` again — but read the
note in `snippets/tls.conf` first, because on TLS 1.3 that disables resumption
entirely rather than hardening it.

**The FastCGI micro-cache no longer stores responses carrying `Set-Cookie`.**
Expect a lower hit rate on apps that set cookies on otherwise-cacheable pages;
this is deliberate, since the old behaviour could replay one visitor's cookie to
everyone. See `snippets/fastcgi-cache.conf` to opt back in knowingly.

**`ENABLE_NJS=1` no longer builds njs's `xml` module.** Add `ENABLE_NJS_XML=1`
if your njs scripts parse XML. njs itself also jumped 0.8.7 → 1.0.0; check your
scripts against its changelog.

**`resolver` is derived from the container's DNS** instead of hardcoded public
servers. If you depended on nginx resolving via 1.1.1.1 specifically, mount your
own `/etc/nginx/resolver.conf`.

**No more `VOLUME` declarations.** They created anonymous volumes on every
`docker run` — one of which shadowed the `/dev/stdout` log symlinks. Mount
`/etc/letsencrypt`, `/var/www/html` explicitly (the compose file does).

## Optional modules

Off by default. Flip the build-arg to `1` to include them — runtime libraries
are also pulled in automatically.

| Build arg          | Module                                              | When to enable                                            |
|--------------------|-----------------------------------------------------|-----------------------------------------------------------|
| `ENABLE_ZSTD=1`    | [tokers/zstd-nginx-module](https://github.com/tokers/zstd-nginx-module) | API / JSON-heavy traffic — Chrome ≥123, Firefox ≥126 negotiate `Accept-Encoding: zstd` and zstd is ~2–3× faster than brotli at the same ratio. |
| `ENABLE_NJS=1`     | [nginx/njs](https://nginx.org/en/docs/njs/)         | Replace evil `if` chains with JS-based routing / header rewrites. |
| `ENABLE_NJS_XML=1` | njs `xml` module                                    | Only if you parse XML *inside* njs. njs defaults `NJS_LIBXSLT=YES`, which makes nginx demand libxml2 + libxslt; we default it off rather than carry libxml2's CVE stream in the runtime for a feature few njs users want. |
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

Note you do **not** have to edit `nginx.conf` to do this, even though these are
`http {}`-context directives. `/etc/nginx/conf.d/*.conf` is included from
*inside* `http {}`, so a file you mount there can carry http-context config —
`map`, `limit_req_zone`, `include snippets/real-ip.conf;`, any of the below.
Name it `00-…` so it loads before the vhosts that use it.

* `/etc/nginx/snippets/zstd.conf` — `include /etc/nginx/snippets/zstd.conf;` at the top of a `conf.d/00-http.conf`.
* `/etc/nginx/snippets/geoip2.conf` — same, plus mount your GeoLite2 DB at `/etc/nginx/geoip2/`.
* `/etc/nginx/snippets/vts-status.conf` — put `vhost_traffic_status_zone shared:vts:10m;` in that same `conf.d/00-http.conf`, then drop the snippet into `conf.d/` too.

If you genuinely need to change a base setting (worker counts, buffers, the log
format), bind-mount your own file over `/etc/nginx/nginx.conf` — but start from
the one in this repo, because the image's snippets assume the zones, maps and
resolver it declares.

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
│   ├── docker-entrypoint.sh        # fallback cert + vhost + resolver
│   └── files/
│       ├── nginx.conf              # http {} defaults — installed at /etc/nginx/
│       ├── resolver.conf           # regenerated at boot from /etc/resolv.conf
│       ├── fastcgi_params
│       └── snippets/               # reusable building blocks
│           ├── tls.conf
│           ├── http3.conf
│           ├── security-headers.conf
│           ├── real-ip.conf            # opt-in, trust a proxy/CDN's XFF
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
├── tests/
│   ├── smoke.sh                    # boot the image, assert it serves
│   └── validate-examples.sh        # nginx -t over all examples together
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
| `http3.conf`                     | inside `server {}` | `Alt-Svc`, `quic_retry` (`quic_gso` opt-in)         |
| `security-headers.conf`          | (auto, http {})    | Default headers via `more_set_headers` — see below  |
| `real-ip.conf`                   | inside `http {}`   | Recover client IP behind a proxy/CDN (opt-in)       |
| `acme-challenge.conf`            | inside any server  | `/.well-known/acme-challenge/` for Let's Encrypt    |
| `proxy-defaults.conf`            | inside `location`  | Standard proxy headers + keepalive                  |
| `websocket.conf`                 | inside `location`  | `Upgrade`/`Connection` + 1h timeout                 |
| `static-cache.conf`              | inside `server {}` | 30-day cache for assets + dotfile 404               |
| `fastcgi.conf`                   | inside `\.php$`    | PHP-FPM defaults (set `$fpm_upstream` first)        |
| `fastcgi-cache.conf`             | inside `\.php$`    | Micro-cache PHP responses                           |
| `fastcgi-cache-purge.conf`       | inside `server {}` | `/fcache-purge/*` endpoint (IP-restricted)          |
| `healthz.conf`                   | inside `server {}` | `GET /healthz → 200 ok` for *external* probes       |
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
  `444` for any request whose `Host` header doesn't match a real vhost, over
  both TLS and QUIC. Prevents IP-scan leakage. Loaded before site configs via
  the `05-` prefix. It covers `:443` only — `00-http-redirect.conf` owns `:80`,
  because nginx permits one `default_server` per listen address and because a
  `444` on port 80 would black-hole ACME HTTP-01 validation.

## Behaviour worth knowing about

* **Security headers use `more_set_headers`, not `add_header`.** `add_header`
  does not accumulate: any `server`/`location` block declaring one of its own
  discards every `add_header` it inherited. Several shipped snippets do exactly
  that (`http3.conf` sets `Alt-Svc`, `static-cache.conf` sets `Cache-Control`),
  which silently stripped the whole security-header set from TLS vhosts and
  from every static asset. headers-more lives in a separate directive family,
  so a downstream `add_header` can no longer clobber it — and it merges
  properly: a `server`/`location` block declaring its own `more_set_headers`
  gets the inherited set *plus* its own, its own applied last. Overriding one
  header for one site is a one-liner and the rest still applies.
* **HSTS is scoped to HTTPS and omits `includeSubDomains`.** A `map` on
  `$https` means the header never goes out over plaintext. `includeSubDomains`
  is a one-way door — it takes down every subdomain that is not HTTPS, for the
  full `max-age`, with no remote undo — so it is opt-in per site. See
  `snippets/security-headers.conf`.
* **`resolver` is generated at boot** from the container's own
  `/etc/resolv.conf` into `/etc/nginx/resolver.conf`. Under Docker that is the
  embedded DNS at `127.0.0.11`, which is what makes `proxy_pass` to a variable
  upstream resolve compose service names. Mount your own file over
  `/etc/nginx/resolver.conf` to pin it; the entrypoint leaves non-writable
  files alone.
* **The HEALTHCHECK does not depend on your config.** It probes a loopback-only
  listener on `127.0.0.1:8081` declared in `nginx.conf`, so mounting your own
  `conf.d/` cannot make the container report unhealthy. `snippets/healthz.conf`
  is only for external probes (a load balancer, an uptime monitor).
* **TLS session tickets are ON.** TLS 1.3 has no session-ID resumption, so the
  widely copied `ssl_session_tickets off;` does not harden it — it disables
  resumption outright and every modern browser pays a full handshake. See the
  reasoning and how to revert in `snippets/tls.conf`.
* **HTTP/3 connection migration needs two capabilities.** With `reuseport`,
  QUIC's UDP traffic is spread over one socket per worker by 4-tuple — on a
  10-core host, 10 sockets. When a phone switches Wi-Fi → cellular the tuple
  changes and its packets land on a worker with no state for that connection,
  which stalls until the client gives up. nginx's `quic_bpf` routes by QUIC
  connection ID instead and fixes it, but needs `CAP_BPF` (or `CAP_SYS_ADMIN`)
  plus `CAP_NET_ADMIN`, which Docker does not grant by default — and nginx
  *refuses to start* without them rather than degrading. The entrypoint
  therefore probes the container's effective capabilities and writes
  `/etc/nginx/quic-bpf.conf` accordingly. Grant them with
  `docker run --cap-add BPF --cap-add NET_ADMIN` (see `cap_add` in
  `docker-compose.yml`); force the decision with `QUIC_BPF=on|off`.
* **OCSP stapling is off by default.** Let's Encrypt stopped publishing OCSP
  responder URLs in 2025, so stapling is a no-op for the certificates this
  image mostly serves — while still logging a warning per certificate on every
  start and reload. Turn it back on in `snippets/tls.conf` if your CA publishes
  OCSP.
* **`quic_gso` is off by default.** UDP segmentation offload is broken on a
  number of virtual NICs, where the failure mode is not an error but silently
  dropped oversized datagrams — HTTP/3 stalls while HTTP/2 keeps working.
  Turn it on in `snippets/http3.conf` after verifying h3 on your host.
* **Client IP behind a proxy/CDN needs `snippets/real-ip.conf`.** Without it
  `limit_req`/`limit_conn` key every request in the world to the proxy's single
  address. It is opt-in because `set_real_ip_from` is a trust declaration:
  listing an address you do not control hands out IP spoofing.

## Testing

```sh
docker build -t my-nginx -f mainline/alpine/Dockerfile .

./tests/smoke.sh my-nginx             # boots it, asserts it actually serves
./tests/validate-examples.sh my-nginx # nginx -t over all examples together
```

CI runs both against every `ENABLE_*` flavour. `nginx -t` alone only proves the
config parses — the smoke test checks the things that have regressed silently
here before (security headers surviving snippet includes, no HSTS on plaintext,
the QUIC listener actually bound, OpenSSL new enough for the native QUIC API).

## Verifying HTTP/3

The image is built with `--with-http_v3_module` against OpenSSL 3.5 — HTTP/3
support is compiled in, and the build refuses to proceed on an OpenSSL too old
to serve it. To verify it works **end-to-end**:

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
