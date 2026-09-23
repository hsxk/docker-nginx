# Security Policy

## Supported versions

Security fixes are applied to the current `main` branch and the most recent
published image. Older image tags should be treated as immutable historical
releases rather than continuously patched channels.

## Reporting a vulnerability

Please do **not** open a public issue containing exploit details, credentials,
tokens, private keys, or other sensitive material.

If GitHub shows **Security → Report a vulnerability** for this repository, use
that private channel. If private vulnerability reporting is unavailable, open
a minimal public issue asking the maintainer for a private contact path without
including the vulnerability details.

For an upstream NGINX, OpenSSL, Alpine, or third-party module vulnerability,
report it upstream as appropriate as well. If this image's pinned dependency,
configuration, entrypoint, or release process makes the issue exploitable here,
please also report that impact to this repository.

Useful reports include the affected image tag/digest, architecture, relevant
configuration, reproduction conditions, and whether the issue affects the
default configuration or only an opt-in module/snippet.
