# docker-nginx-quic

A small, hardened NGINX Docker image with HTTP/3 (QUIC), Brotli, headers-more,
and FastCGI cache-purge. HTTP/3 runs on **stock OpenSSL 3.5**, linked
dynamically against the distro package — no vendored TLS fork. Shipped as a
*toolbox*: the image gives you a sensible transport/runtime base plus a library
of include-able snippets — you bring your own sites in `/etc/nginx/conf.d/`
and any http-level config in `/etc/nginx/http.d/`.

**The base image is intentionally neutral about application/browser security
policy.** A bare container does not emit CSP, COOP, CORP, COEP,
X-Frame-Options, Permissions-Policy, Referrer-Policy, HSTS, or
X-Content-Type-Options. Those headers belong to each application because the
correct policy depends on its framing, OAuth, popup, asset-sharing and
cross-origin requirements. `headers-more` is available when a site needs
replacement/clearing semantics, but it is not used to invent a global policy.

## What's in the image

| Component               | Version / immutable ref                         | Notes                              |
|-------------------------|-------------------------------------------------|------------------------------------|
| NGINX                   | `1.31.6`                                       | source SHA256 verified             |
| Official base           | `nginx:1.31.6-alpine3.24-slim`                | pinned by OCI index digest         |
| Alpine                  | `3.24`                                          | from official slim image           |
| OpenSSL                 | `3.5.8-r0`                                      | build + runtime package pinned      |
| headers-more-nginx      | `0.40`                                           | tarball SHA256 verified            |
| ngx_brotli              | `a71f9312c2deb28875acc7bacfdd5695a111aa53`    | google/ngx_brotli                  |
| ngx_cache_purge         | `285354eddd5675c765ba2b79dac09f5d3065b22f`    | upstream lists tested through 1.29; this image runs a live purge smoke test |
| zstd (optional)         | `057a7d339af1111d04b5a9ac5ae9b0250d17cd94`    | tokers/zstd-nginx-module           |
| njs (optional)          | `1.0.1`                                          | security-fix release               |
| GeoIP2 (optional)       | `3.4`                                            | SHA256-verified release            |
| VTS (optional)          | `0.2.7`                                          | SHA256-verified release            |

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
unpatched OpenSSL advisories that nothing would report. Alpine packages remain
visible to SBOM/scanners, but this image intentionally pins both the official
base digest and the OpenSSL package revision. Security updates therefore require
an explicit pin bump and full local verification instead of silently changing
an existing build.

The build fails loudly rather than degrading: if the OpenSSL headers are older
than 3.5.1, nginx would silently fall back to its `NGX_QUIC_OPENSSL_COMPAT`
shim, so the Dockerfile compiles a version assertion before `./configure`.

Every external source is pinned to either an immutable git commit SHA or a
release tag whose tarball is SHA256-verified at build time — flip a version
and the matching `*_SHA256` ARG together when bumping.

For this release, the NGINX source tarball SHA256 is
`974ed5298a5e398e008704ed5db284e655fc270c596493dbccada452448fc9f1`.
The official base image index is pinned to
`sha256:80149a0e5bc9fa0b8beaff5b8a453f71ba8ba038895d418381297ffa5cd57782`.

### How this compares to the official `nginx:alpine`

Worth being precise, because the gap is narrower than it used to be. As of
1.31.6 the official image is *also* built with `--with-http_v3_module` against
OpenSSL 3.5.x — HTTP/3 is no longer a reason to leave it. This image now uses
the official `nginx:1.31.6-alpine3.24-slim` image itself as the immutable
runtime/build base, pinned to multi-arch digest
`sha256:80149a0e5bc9fa0b8beaff5b8a453f71ba8ba038895d418381297ffa5cd57782`.
What this image adds is the third-party module set and opinionated config:

| | official `nginx:alpine` | this image |
|---|---|---|
| nginx / OpenSSL | 1.31.6 / 3.5.x | 1.31.6 / 3.5.8 |
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

## Upgrading from earlier images

The NGINX 1.31.6 image changes one important ownership boundary: **application
security headers are no longer injected by the base image.**

Earlier revisions automatically included
`/etc/nginx/snippets/security-headers.conf` from the global `http {}` block.
That could collide with an upstream application's headers or with a site's own
`add_header`, producing duplicate values and breaking legitimate cross-origin
behaviour such as Microsoft Office Add-in framing or popup communication.

When upgrading:

1. Audit each site and move the security policy it actually needs into that
   site's own `server {}` / `location {}` configuration.
2. Do not assume the base image supplies HSTS, nosniff, XFO, COOP, CSP, or any
   other browser policy.
3. Remove workarounds that existed only to fight the old global policy.
4. If an upstream already owns a header, normally pass it through unchanged.
   Use `more_set_headers` when you intentionally want to replace its value and
   `more_clear_headers` when the application explicitly wants it removed.
5. `security-headers.conf` still ships as an **opt-in example only**. It is not
   loaded by `nginx.conf`, the entrypoint, the fallback vhost, or any other
   shipped snippet.

This release also pins NGINX, the official Alpine slim base digest, source
SHA256, and OpenSSL package revision together. Do not bump only the visible
NGINX version; use the atomic upgrade rule below and rerun the full local/CI
matrix.

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

### NGINX upgrade rule: change the pins atomically

Do **not** override only `NGINX_VERSION` at build time. An NGINX upgrade is one
atomic change and must update all of these together in the Dockerfile:

* `NGINX_VERSION`
* `NGINX_FROM_IMAGE`
* `NGINX_FROM_DIGEST`
* `NGINX_SHA256`

The builder immediately compares the pinned official image's `nginx -v` with
`NGINX_VERSION`, and the source tarball is checksum-verified before configure.
Changing only the visible version therefore fails deliberately instead of
quietly compiling modules for one NGINX while running another. If the Alpine
base's OpenSSL revision changes, update `OPENSSL_PACKAGE_VERSION` in the same
change and re-run the full local verification matrix.

The custom binary is tagged at compile time as
`nginx/<version> (docker-nginx-quic)`. The official base still contains Alpine
package metadata for nginx, so **do not run `apk upgrade nginx` or
`apk fix nginx` in a downstream image**: that can restore the package-owned
binary over the source-built binary while leaving these third-party modules in
place. The entrypoint checks the build marker and fails with a clear error if
that happens. Upgrade nginx by bumping the pins above and rebuilding this image;
site configs, snippets and other Alpine packages remain freely overridable.

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
│       ├── quic-bpf.conf           # regenerated at boot from capabilities
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
│   ├── validate-examples.sh        # nginx -t over all examples together
│   ├── snippet-coverage.conf       # forces every snippet to be parsed
│   └── http.d/                     # parse target for the http.d include
├── docker-compose.yml
└── .dockerignore
```

## Where config goes

Three directories, and the distinction is worth getting right because it is the
difference between "works" and "works regardless of filename".

| Path | Included | Put here |
|---|---|---|
| `/etc/nginx/http.d/*.conf` | inside `http {}`, **before** conf.d | `map`, `limit_req_zone`, `upstream`, `include snippets/real-ip.conf;`, zstd/geoip2/vts activation |
| `/etc/nginx/conf.d/*.conf` | inside `http {}`, after http.d | `server { }` blocks — your actual sites |
| `/etc/nginx/snippets/` | wherever you `include` them | shipped building blocks; read-only, part of the image |

`conf.d` is also inside `http {}`, so http-level directives there work too —
that is what everyone did before `http.d` existed, and it keeps working. The
catch is ordering: `conf.d/*.conf` loads alphabetically, so a `limit_req_zone`
in `50-zones.conf` is invisible to a vhost in `10-site.conf`. `http.d` loads
first, so nothing there is order-dependent.

Neither directory is required. An absent or empty one just matches no files.

```
your-deployment/
├── docker-compose.yml
├── http.d/          # optional: maps, zones, real-ip
│   └── 00-http.conf
├── conf.d/          # your vhosts
│   ├── 00-http-redirect.conf
│   └── 10-mysite.conf
└── www/             # web root
```

```yaml
    volumes:
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./http.d:/etc/nginx/http.d:ro     # optional
      - letsencrypt:/etc/letsencrypt
      - ./www:/var/www/html:ro
```

To change a base setting (worker counts, buffers, log format), bind-mount your
own `/etc/nginx/nginx.conf` — `http.d` is for *adding* config, and nginx rejects
a repeated `gzip_comp_level` in one context as a duplicate rather than letting
the later one win.

## Adding your own site

1. Copy any file under `examples/conf.d/` as a template.
2. Replace `example.com` with your domain.
3. Mount the directory at `/etc/nginx/conf.d/` (read-only).
4. Make sure **exactly one** of your `:443` server blocks carries
   `reuseport` on its `listen 443 quic` lines — typically your *first*
   TLS vhost. All others must just say `listen 443 quic;` without
   `reuseport`. See the comment in `10-example-static.conf`.
5. `docker exec nginx nginx -t && docker exec nginx nginx -s reload`.

## Application-owned security headers

The examples below are deliberately site configuration, not base-image
defaults. Native `add_header` is fine when the application owns the response
and there is no competing upstream value. Use `headers-more` when you need
explicit replacement or clearing semantics.

### Ordinary HTTPS website

A conventional site might choose a policy like this:

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name www.example.com;

    # Application-owned choices — review them for this site.
    more_set_headers "Strict-Transport-Security: max-age=31536000";
    more_set_headers "X-Content-Type-Options: nosniff";
    more_set_headers "X-Frame-Options: SAMEORIGIN";
    more_set_headers "Referrer-Policy: strict-origin-when-cross-origin";
    more_set_headers "Permissions-Policy: geolocation=(), microphone=(), camera=()";
    more_set_headers "Cross-Origin-Opener-Policy: same-origin";
    more_set_headers "Content-Security-Policy: frame-ancestors 'self'";

    # ...
}
```

That is an example, not a recommendation for every workload. A public asset
host, OAuth callback, iframe application or cross-origin app can require a
different policy.

### Microsoft Office Add-in / embeddable application

An Office Add-in can require cross-origin framing and popup communication. The
base image must not force XFO or a stricter COOP value:

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name addin.example.com;

    location /office-addin/ {
        # The application intentionally allows popup/opener communication.
        more_set_headers "Cross-Origin-Opener-Policy: unsafe-none";

        # Replace these example parent origins with the actual Office hosts
        # used by your deployment.
        more_set_headers "Content-Security-Policy: frame-ancestors 'self' https://office-parent.example";

        # Deliberately NO X-Frame-Options is set here.
        #
        # If the upstream application itself emits X-Frame-Options and this
        # embeddable route must remove it, the site may explicitly choose:
        # more_clear_headers "X-Frame-Options";

        proxy_pass http://office_addin_upstream;
    }
}
```

The same principle applies to Google/Microsoft login flows: the application
that knows how its popup, iframe and CSP model works owns those headers. The
base image does not silently override it.

## Snippet reference

| Snippet                          | Include where      | Purpose                                             |
|----------------------------------|--------------------|-----------------------------------------------------|
| `tls.conf`                       | inside `server {}` | TLS 1.2/1.3, modern ciphers, OCSP stapling          |
| `http3.conf`                     | inside `server {}` | `Alt-Svc`, `quic_retry` (`quic_gso` opt-in)         |
| `security-headers.conf`          | inside `http {}`  | **Opt-in only** example policy; never auto-loaded     |
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

* **Application security policy is intentionally absent by default.** The base
  image does not emit CSP, COOP, CORP, COEP, X-Frame-Options,
  Permissions-Policy, Referrer-Policy, HSTS, or X-Content-Type-Options. This
  prevents a transport/runtime image from breaking Office Add-ins, OAuth
  popups, iframes, public assets, or an upstream that already owns its policy.
* **`headers-more` is a tool, not a policy.** Applications may use
  `more_set_headers` to replace/set a response header and
  `more_clear_headers` to remove one. Native `add_header` also remains
  available. Because the base does not pre-populate these application headers,
  a site can choose either mechanism without fighting an invisible global
  default.
* **`security-headers.conf` is opt-in.** It is shipped only as a convenient
  example for applications that explicitly want that particular baseline. No
  base config, fallback vhost, entrypoint, or other snippet includes it.

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

For a release candidate, use the local release runner. It does **not** create a
Git tag, push an image, log in to Docker Hub, or invoke GitHub Actions:

```sh
bash ./tests/local-release-verify.sh
```

Before building, it verifies that the moving official
`NGINX_FROM_IMAGE` tag still resolves to the pinned immutable digest and
downloads the NGINX source tarball again to verify `NGINX_SHA256`. It also
rejects shipped configs that use `add_header` for security headers managed by
headers-more.

It then builds both `base` and `all` locally and writes reproducible evidence
under `.artifacts/nginx-verify-<UTC timestamp>/`: plain build logs,
`nginx -V`, `nginx -t`, runtime versions/module lists, smoke results,
example validation, upstream-pin evidence, and Docker image metadata. The smoke
suite includes a live ngx_cache_purge cycle (MISS → HIT → PURGE 200 → PURGE 412
→ MISS), because that module's upstream compatibility table has not yet marked
NGINX 1.31.x as tested.

For a quicker single-image iteration:

```sh
docker build -t my-nginx -f mainline/alpine/Dockerfile .

./tests/smoke.sh my-nginx             # boots it, asserts it actually serves
./tests/validate-examples.sh my-nginx # nginx -t over all examples together
```

CI exercises every `ENABLE_*` flavour. `nginx -t` alone only proves the
config parses — the smoke test also verifies the runtime `nginx -v` matches
`NGINX_VERSION`, mandatory dynamic modules exist and load, HTTP/2 and the QUIC
listener work, the bare image emits none of the application-policy headers,
`add_header` and `more_set_headers` each produce exactly one application
value, Office-style `COOP: unsafe-none` works without forced XFO, and
upstream-owned COOP/XFO pass through once without base-image duplication.

Useful manual acceptance checks after a local build:

```sh
docker run --rm --entrypoint nginx my-nginx -T 2>&1 \
  | grep -F 'include /etc/nginx/snippets/security-headers.conf;' \
  && echo 'ERROR: policy snippet is auto-loaded' || true

curl -skI https://127.0.0.1:<published-tls-port>/ \
  | grep -Ei '^(Strict-Transport-Security|X-Content-Type-Options|X-Frame-Options|Referrer-Policy|Permissions-Policy|Cross-Origin-Opener-Policy|Cross-Origin-Resource-Policy|Cross-Origin-Embedder-Policy|Content-Security-Policy):'
```

The second command must print nothing for a bare image.

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

* **matrix-build** — runs only when a release tag is pushed. It builds the
  `base`, `zstd`, `njs`, `njs-xml`, `geoip2`, `vts`, and `all` flavors
  on a single architecture, then runs `nginx -V`, `nginx -t`, smoke tests,
  and example/snippet validation. Ordinary branches, main pushes, and PRs do
  not spend CI.
* **release** — after that tag's matrix succeeds, builds the multi-arch
  (`linux/amd64`, `linux/arm64`) image with `provenance: mode=max` and
  `sbom: true`, then pushes to Docker Hub. Provenance + SBOM let downstream consumers verify
  the image with `docker buildx imagetools inspect --format "{{ json .SBOM }}"`.

Required repository secrets: `DOCKER_USERNAME`, `DOCKER_PASSWORD`.
