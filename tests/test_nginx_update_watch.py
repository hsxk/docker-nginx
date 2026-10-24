#!/usr/bin/env python3
"""Fast offline tests for the scheduled NGINX mainline version watcher."""
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / ".github/scripts/check_nginx_updates.py"
SPEC = importlib.util.spec_from_file_location("check_nginx_updates", SCRIPT)
WATCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WATCH)


class NginxVersionWatchTests(unittest.TestCase):
    def test_pinned_version_from_real_dockerfile(self):
        dockerfile = (Path(__file__).resolve().parents[1] / "mainline/alpine/Dockerfile").read_text()
        self.assertEqual(WATCH.current_version(dockerfile), (1, 31, 8))

    def test_fail_closed_if_version_missing(self):
        with self.assertRaises(ValueError):
            WATCH.current_version("FROM nginx:latest\n")

    def test_ignores_stable_draft_and_prerelease(self):
        releases = [
            {"tag_name": "release-1.30.99"},
            {"tag_name": "release-1.31.9", "prerelease": True},
            {"tag_name": "release-1.33.0", "draft": True},
            {"tag_name": "release-1.31.8"},
            {"tag_name": "not-an-nginx-release"},
        ]
        self.assertEqual(WATCH.latest_mainline(releases), (1, 31, 8))

    def test_newer_mainline_is_detected(self):
        releases = [{"tag_name": "release-1.31.8"}, {"tag_name": "release-1.33.1"}]
        self.assertEqual(WATCH.latest_mainline(releases), (1, 33, 1))

    def test_real_ip_snippet_has_loopback_only_as_default_trust(self):
        import re

        conf = (Path(__file__).resolve().parents[1] /
                "mainline/alpine/files/snippets/real-ip.conf").read_text()
        sources = re.findall(r"^set_real_ip_from\s+([^;]+);", conf, flags=re.MULTILINE)
        self.assertEqual(sources, ["127.0.0.1", "::1"])

    def test_release_can_dispatch_at_tag_and_verify_published_manifest(self):
        workflow = (Path(__file__).resolve().parents[1] /
                    ".github/workflows/docker-build.yml").read_text()
        self.assertIn("github.event_name == 'workflow_dispatch'", workflow)
        self.assertIn("startsWith(github.ref, 'refs/tags/')", workflow)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn("git diff --exit-code", workflow)
        self.assertIn("docker buildx imagetools inspect --raw", workflow)
        self.assertIn('index("amd64") != null and index("arm64") != null', workflow)
        self.assertIn("needs: ci-success", workflow)

    def test_errors_when_upstream_api_has_no_mainline_releases(self):
        with self.assertRaises(ValueError):
            WATCH.latest_mainline([{"tag_name": "release-1.30.8"}])


if __name__ == "__main__":
    unittest.main()
