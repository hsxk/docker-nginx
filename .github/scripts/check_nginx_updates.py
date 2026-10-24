#!/usr/bin/env python3
"""Report newer NGINX mainline releases without changing release pins.

Executed by a weekly scheduled GitHub Actions workflow, with manual dispatch.
If upstream is newer, create one GitHub issue per release; no unreviewed
dependency updates, tags, image pushes, or production deployments are made.
"""

import json
import os
import re
from pathlib import Path
from urllib.request import Request, urlopen

RELEASES_URL = "https://api.github.com/repos/nginx/nginx/releases?per_page=100"
VERSION_PATTERN = re.compile(r"^release-(\d+)\.(\d+)\.(\d+)$")
CURRENT_PATTERN = re.compile(r"^ARG NGINX_VERSION=(\d+)\.(\d+)\.(\d+)\s*$", re.MULTILINE)


def current_version(dockerfile: str) -> tuple[int, int, int]:
    match = CURRENT_PATTERN.search(dockerfile)
    if match is None:
        raise ValueError("Could not locate NGINX_VERSION ARG in Dockerfile")
    return tuple(map(int, match.groups()))


def latest_mainline(releases: list[dict]) -> tuple[int, int, int]:
    versions = []
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        match = VERSION_PATTERN.fullmatch(release.get("tag_name", ""))
        if match:
            v = tuple(map(int, match.groups()))
            # NGINX uses odd minor versions for mainline and even for stable.
            if v[1] % 2 == 1:
                versions.append(v)
    if not versions:
        raise ValueError("No official mainline releases in the GitHub API response")
    return max(versions)


def version_string(version: tuple[int, int, int]) -> str:
    return ".".join(map(str, version))


def github_json(url: str, token: str, body: dict | None = None):
    request = Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "hsxk-docker-nginx-version-watch",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        data=json.dumps(body).encode("utf-8") if body is not None else None,
        method="POST" if body is not None else "GET",
    )
    with urlopen(request, timeout=20) as response:
        return json.load(response)


def main() -> None:
    token = os.environ["GH_TOKEN"]
    repository = os.environ["GITHUB_REPOSITORY"]
    dockerfile = Path("mainline/alpine/Dockerfile").read_text(encoding="utf-8")
    current = current_version(dockerfile)
    upstream = latest_mainline(github_json(RELEASES_URL, token))

    if upstream <= current:
        print(f"NGINX mainline current: {version_string(current)}; upstream: {version_string(upstream)}. No update.")
        return

    new_version = version_string(upstream)
    current_label = version_string(current)
    issue_title = f"NGINX mainline update available: {new_version}"
    api_base = f"https://api.github.com/repos/{repository}"

    # GitHub /issues returns both issues and PRs; title comparison is sufficient.
    # Check pages to prevent recurring duplicate notifications.
    for page in range(1, 11):
        existing = github_json(f"{api_base}/issues?state=open&per_page=100&page={page}", token)
        if any(issue.get("title") == issue_title for issue in existing):
            print(f"Existing open issue found for NGINX {new_version}; nothing to create.")
            return
        if len(existing) < 100:
            break

    body = (
        f"Upstream NGINX mainline **{new_version}** is newer than this repository's "
        f"pinned **{current_label}**.\n\n"
        f"Official release: https://github.com/nginx/nginx/releases/tag/release-{new_version}\n"
        f"News: https://nginx.org/news.html\n\n"
        "### Upgrade checklist\n"
        "- Review upstream security advisories and change notes.\n"
        "- Update NGINX_VERSION, NGINX_FROM_IMAGE, NGINX_FROM_DIGEST, and NGINX_SHA256 **together**, verifying official digests/checksums.\n"
        "- Review the Alpine/OpenSSL package revisions and third-party module ABI.\n"
        "- Run the full seven-flavor CI, nginx config/smoke tests, and Trivy HIGH/CRITICAL gate.\n"
        "- Merge only when green, then explicitly tag/release and verify amd64/arm64 image digests.\n\n"
        "**This issue was opened automatically. No source pins, tags, images, or deployments were changed.**"
    )
    issue = github_json(f"{api_base}/issues", token, {"title": issue_title, "body": body})
    print(f"Opened NGINX update issue: {issue['html_url']}")


if __name__ == "__main__":
    main()
