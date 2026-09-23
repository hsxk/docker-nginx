# Contributing

Thanks for improving `docker-nginx`.

## Development model

The default branch is `main`. Keep changes focused and avoid mixing unrelated
runtime, module, and documentation changes in one pull request.

The image deliberately separates **transport/runtime defaults** from
**application security policy**. Do not add global CSP, COOP, CORP, COEP,
X-Frame-Options, Permissions-Policy, Referrer-Policy, HSTS, or
X-Content-Type-Options to the base configuration. Application-specific policy
belongs in the consuming site's `server`/`location` configuration or an
explicit opt-in snippet.

## Before opening a pull request

For a quick iteration:

```sh
docker build -t my-nginx -f mainline/alpine/Dockerfile .
./tests/smoke.sh my-nginx
./tests/validate-examples.sh my-nginx
```

For a release-grade local verification:

```sh
bash ./tests/local-release-verify.sh
```

That runner verifies the pinned official-image digest and NGINX source SHA256,
builds the base and all-module variants, checks the custom binary/module ABI,
runs the live smoke suite, and validates the shipped examples/snippets.

Pull requests also run the full seven-flavor GitHub Actions matrix.

## Dependency and NGINX upgrades

An NGINX upgrade is atomic. Update `NGINX_VERSION`, `NGINX_FROM_IMAGE`,
`NGINX_FROM_DIGEST`, `NGINX_SHA256`, and the pinned OpenSSL package revision
when required. Do not bump only the visible version.

Third-party source inputs must remain pinned to immutable commits or
checksum-verified release tarballs. GitHub Actions must remain pinned to full
commit SHAs.

## Releases

Maintainers publish releases by pushing a version tag. CI must pass before the
multi-arch Docker Hub image is published. Do not manually overwrite a released
version tag with a different image.
