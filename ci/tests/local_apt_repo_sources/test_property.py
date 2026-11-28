#!/usr/bin/python3 -Bsu

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

"""
Regression tests for the local_apt_repo_sources_stanza bash generator.

The generator auto-detects apt components by scanning
``<repo_path>/dists/<suite>/*/binary-<arch>/Packages``. The on-disk repo
path can differ from the chroot-side ``file:`` URI, so the caller must pass
the host repo path explicitly (arg 3). A regression once called it with the
chroot URI only, so the scan hit a non-existent host path, found nothing, and
silently emitted ``Components: main`` -- dropping contrib/non-free and failing
a later ``apt install`` of a non-free package with a cryptic "Unable to locate
package". These tests pin the fixed behaviour and the fail-loud guard.
"""

import pathlib
import subprocess
import tempfile
import unittest

_HERE = pathlib.Path(__file__).resolve()
## ci/tests/local_apt_repo_sources/test_property.py -> repo root is 3 levels up.
_REPO_ROOT = _HERE.parents[3]
_BSH = _REPO_ROOT / "usr/libexec/helper-scripts/local-apt-repo-sources.bsh"

_CHROOT_URI = "file:/mnt/local-apt-repo/kicksecure"
_SUITE = "local"
_ARCH = "amd64"


def _make_repo(tmp: pathlib.Path, components: dict[str, str]) -> pathlib.Path:
    """
    Build a minimal exported reprepro tree under tmp and return the repo root.

    components maps component name -> Packages index content; an empty string
    writes an empty (0-byte) Packages file, which the generator must skip.
    """
    repo = tmp / "aptrepo_local" / "kicksecure"
    for component, content in components.items():
        binary_dir = repo / "dists" / _SUITE / component / f"binary-{_ARCH}"
        binary_dir.mkdir(parents=True, exist_ok=True)
        (binary_dir / "Packages").write_text(content, encoding="utf-8")
    return repo


def _run_stanza(uri: str, suite: str, repo_path: str, arch: str):
    """Source the generator and invoke it; return (returncode, stdout, stderr)."""
    ## Pass every value as a positional arg ($1..$5), never interpolated into
    ## the script text, so a value cannot inject shell into the bash -c program.
    script = (
        'source -- "$1"\n'
        'local_apt_repo_sources_stanza "$2" "$3" "$4" "$5"\n'
    )
    proc = subprocess.run(
        ["bash", "-c", script, "bash", str(_BSH), uri, suite, repo_path, arch],
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode, proc.stdout, proc.stderr


def _components(stdout: str) -> list[str]:
    """Extract the component list from a stanza's Components: line."""
    for line in stdout.splitlines():
        if line.startswith("Components:"):
            return line.split(":", 1)[1].split()
    return []


class TestLocalAptRepoSourcesStanza(unittest.TestCase):
    """Behaviour of local_apt_repo_sources_stanza()."""

    def test_fix_includes_nonfree(self) -> None:
        """Host repo_path scan must surface non-free; empty component skipped."""
        with tempfile.TemporaryDirectory() as tmp_name:
            repo = _make_repo(
                pathlib.Path(tmp_name),
                {
                    "main": "Package: kicksecure-baremetal-gui-lxqt\n",
                    "contrib": "",
                    "non-free": "Package: firmware-nonfreedom-noarch\n",
                },
            )
            rc, out, err = _run_stanza(_CHROOT_URI, _SUITE, str(repo), _ARCH)
            self.assertEqual(rc, 0, msg=err)
            components = _components(out)
            self.assertIn("main", components)
            self.assertIn("non-free", components)
            ## Empty Packages index means the component carries nothing for this
            ## arch; apt would fail to fetch it, so it must be excluded.
            self.assertNotIn("contrib", components)

    def test_uri_path_is_not_scanned(self) -> None:
        """
        The emitted URI stays the chroot path while components come from the
        host repo_path -- the exact split that the regression got wrong.
        """
        with tempfile.TemporaryDirectory() as tmp_name:
            repo = _make_repo(
                pathlib.Path(tmp_name),
                {"non-free": "Package: firmware-nonfreedom\n"},
            )
            rc, out, err = _run_stanza(_CHROOT_URI, _SUITE, str(repo), _ARCH)
            self.assertEqual(rc, 0, msg=err)
            self.assertIn(f"URIs: {_CHROOT_URI}", out)
            self.assertEqual(_components(out), ["non-free"])

    def test_canary_missing_scan_dir_fails_loud(self) -> None:
        """
        A scan path with no exported dists must fail loudly (non-zero, no
        stanza) rather than emit a plausible-but-wrong Components: main.
        This is the canary: the pre-fix generator printed Components: main
        and exited 0 here.
        """
        with tempfile.TemporaryDirectory() as tmp_name:
            missing = pathlib.Path(tmp_name) / "does-not-exist"
            rc, out, err = _run_stanza(
                _CHROOT_URI, _SUITE, str(missing), _ARCH
            )
            self.assertNotEqual(rc, 0)
            self.assertNotIn("Components:", out)
            self.assertIn("refusing to emit", err)

    def test_single_main_component(self) -> None:
        """A repo with only a populated main still works and emits just main."""
        with tempfile.TemporaryDirectory() as tmp_name:
            repo = _make_repo(
                pathlib.Path(tmp_name),
                {"main": "Package: dist-base-files\n"},
            )
            rc, out, err = _run_stanza(_CHROOT_URI, _SUITE, str(repo), _ARCH)
            self.assertEqual(rc, 0, msg=err)
            self.assertEqual(_components(out), ["main"])

    def test_malicious_component_name_not_injected(self) -> None:
        """
        A component directory whose name embeds a newline + a forged deb822
        field must be skipped, not copied verbatim into the Trusted stanza
        (which would let it override Suites: and point apt elsewhere).
        """
        with tempfile.TemporaryDirectory() as tmp_name:
            repo = _make_repo(
                pathlib.Path(tmp_name),
                {
                    "main": "Package: dist-base-files\n",
                    "evil\nSuites: trixie": "Package: pwned\n",
                },
            )
            rc, out, err = _run_stanza(_CHROOT_URI, _SUITE, str(repo), _ARCH)
            self.assertEqual(rc, 0, msg=err)
            self.assertEqual(_components(out), ["main"])
            ## Exactly one Suites field, still the requested suite.
            suites = [
                ln for ln in out.splitlines() if ln.startswith("Suites:")
            ]
            self.assertEqual(suites, [f"Suites: {_SUITE}"])
            self.assertNotIn("trixie", out)


if __name__ == "__main__":
    unittest.main()
