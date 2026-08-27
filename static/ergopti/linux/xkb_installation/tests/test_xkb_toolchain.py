"""Real-compiler tests for both installation methods.

These run only where libxkbcommon's ``xkbcli`` (>= 1.13 for the clean method)
and optionally Xorg's ``xkbcomp`` are installed, and skip otherwise. They are
the strongest signal available: a keymap that compiles *without* the custom
type is exactly what users experience as dead Shift and AltGr layers, and
neither compiler reports it as an error.

Two regressions are reproduced on purpose, so the assertions are known to be
able to fail:

- a ``rules/evdev.post`` with only the unindexed rule loses the type as soon
  as a second layout is configured;
- a type block appended after the ``xkb_types`` section is dropped by
  libxkbcommon and rejected by xkbcomp.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

INSTALLER_DIR = Path(__file__).resolve().parents[1]
LAYOUT_VERSION_DIR = INSTALLER_DIR.parent / "v2_2_1"
sys.path.insert(0, str(INSTALLER_DIR))

import desktop_activation as activation  # noqa: E402
import xkb_files_installer_legacy as legacy  # noqa: E402
from layout_package import ERGOPTI_TYPE_NAME, InstallerRoots, LayoutSpec  # noqa: E402

XKBCLI = shutil.which("xkbcli")
XKBCOMP = shutil.which("xkbcomp")
SYSTEM_XKB = Path("/usr/share/X11/xkb")
ERGOPTI = LayoutSpec("ergopti")
LEGACY = LayoutSpec("fr", "Ergopti_v2_2_1")
US = LayoutSpec("us")


def xkbcli_version() -> tuple[int, ...]:
    if not XKBCLI:
        return ()
    try:
        output = subprocess.run([XKBCLI, "--version"], capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ()
    match = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", output)
    return tuple(int(part or 0) for part in match.groups()) if match else ()


HAVE_EXTENSIONS = xkbcli_version() >= (1, 13, 0)
HAVE_SYSTEM_TREE = SYSTEM_XKB.is_dir() and (SYSTEM_XKB / "types" / "extra").is_file()


def has_type(result) -> bool:
    keymap = result.keymap if isinstance(result, activation.CompileResult) else result
    return keymap is not None and activation.keymap_has_type(keymap, ERGOPTI_TYPE_NAME)


def usable(result, group: int = 1) -> bool:
    """The strong form of ``has_type``: the probe key really binds the type."""
    return result.succeeded and not activation.inspect_keymap(result.keymap, ERGOPTI_TYPE_NAME, group=group)


@unittest.skipUnless(HAVE_EXTENSIONS, "xkbcli >= 1.13 (XKB extensions directories) not installed")
class CleanPackageCompilationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.sandbox = Path(self._tmp.name)
        self.extensions_root = self.sandbox / "xkeyboard-config.d"
        self.system_root = self.sandbox / "X11" / "xkb"
        (self.system_root / "rules").mkdir(parents=True)
        (self.system_root / "symbols").mkdir()
        self.env = {
            **os.environ,
            "ERGOPTI_XKB_EXTENSIONS_ROOT": str(self.extensions_root),
            "ERGOPTI_XKB_SYSTEM_ROOT": str(self.system_root),
            "ERGOPTI_XKB_CACHE_DIR": str(self.sandbox / "cache"),
            "ERGOPTI_XKB_USER_HOME": str(self.sandbox / "home"),
            "PYTHONIOENCODING": "utf-8",
        }

    def tearDown(self):
        self._tmp.cleanup()

    def install(self):
        return subprocess.run(
            [
                sys.executable,
                str(INSTALLER_DIR / "xkb_files_installer_clean.py"),
                "--xkb",
                str(LAYOUT_VERSION_DIR / "Ergopti_v2_2_1.xkb"),
                "--types",
                str(LAYOUT_VERSION_DIR / "xkb_types.txt"),
                "--variant",
                "ergopti",
                "--skip-activation",
            ],
            env=self.env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )

    def compile(self, layouts):
        return activation.compile_rmlvo(XKBCLI, layouts, extensions_root=self.extensions_root)

    def test_installed_package_carries_the_type_alone_and_beside_another_layout(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("Keymap vérifiée", result.stdout)
        for layouts in ([ERGOPTI], [ERGOPTI, US], [US, ERGOPTI], [US, LayoutSpec("fr"), ERGOPTI]):
            with self.subTest(layouts=activation.describe_rmlvo(layouts)):
                result = self.compile(layouts)
                self.assertTrue(has_type(result))
                self.assertTrue(usable(result, layouts.index(ERGOPTI) + 1), result.diagnostics)
        # The installed package must be readable by every session, whatever
        # the umask of the privileged process was.
        package = self.extensions_root / "ergopti"
        self.assertEqual(package.stat().st_mode & 0o777, 0o755)
        self.assertEqual((package / "symbols" / "ergopti").stat().st_mode & 0o777, 0o644)

    def test_unindexed_rules_lose_the_type_in_multi_layout_configurations(self):
        """Reproduces issue #84 for the clean method, proving the fence can fail."""
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        post = self.extensions_root / "ergopti" / "rules" / "evdev.post"
        post.write_text("! layout\t=\ttypes\n  ergopti\t=\t+ergopti\n", encoding="utf-8")
        self.assertTrue(has_type(self.compile([ERGOPTI])))
        self.assertFalse(has_type(self.compile([ERGOPTI, US])))
        self.assertFalse(has_type(self.compile([US, ERGOPTI])))
        # The dead keymap still compiles: only the probe reveals the fallback.
        dead = self.compile([ERGOPTI, US])
        self.assertTrue(dead.succeeded)
        self.assertFalse(usable(dead))

    def test_verify_keymap_reports_the_multi_layout_regression(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        post = self.extensions_root / "ergopti" / "rules" / "evdev.post"
        post.write_text("! layout\t=\ttypes\n  ergopti\t=\t+ergopti\n", encoding="utf-8")
        with unittest.mock.patch("builtins.print"):
            self.assertFalse(
                activation.verify_keymap(ERGOPTI, ERGOPTI_TYPE_NAME, extensions_root=self.extensions_root)
            )


@unittest.skipUnless(XKBCLI and HAVE_SYSTEM_TREE, "xkbcli and a system XKB tree are required")
class LegacyTreeCompilationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.sandbox = Path(self._tmp.name)
        self.system_root = self.sandbox / "xkb"
        # Materialise the real files rather than link to them, so nothing the
        # sandbox writes can reach the host tree. openSUSE Tumbleweed ships
        # `compiled` as a symlink to a cache directory that a container never
        # creates, and following a dangling link aborts the whole copy: skip
        # those, they carry no keymap data.
        shutil.copytree(
            SYSTEM_XKB.resolve(),
            self.system_root,
            symlinks=False,
            ignore_dangling_symlinks=True,
        )
        self.env = {
            **os.environ,
            "ERGOPTI_XKB_EXTENSIONS_ROOT": str(self.sandbox / "xkeyboard-config.d"),
            "ERGOPTI_XKB_SYSTEM_ROOT": str(self.system_root),
            "ERGOPTI_XKB_CACHE_DIR": str(self.sandbox / "cache"),
            "ERGOPTI_XKB_USER_HOME": str(self.sandbox / "home"),
            "PYTHONIOENCODING": "utf-8",
        }

    def tearDown(self):
        self._tmp.cleanup()

    def roots(self):
        return InstallerRoots(
            extensions_root=self.sandbox / "xkeyboard-config.d",
            system_root=self.system_root,
            cache_dir=self.sandbox / "cache",
            sandboxed=True,
        )

    def compile(self, layouts):
        return activation.compile_rmlvo(XKBCLI, layouts, include_roots=[self.system_root])

    def test_legacy_install_compiles_with_the_type_on_a_real_tree(self):
        result = subprocess.run(
            [
                sys.executable,
                str(INSTALLER_DIR / "xkb_files_installer_legacy.py"),
                "--xkb",
                str(LAYOUT_VERSION_DIR / "Ergopti_v2_2_1.xkb"),
                "--types",
                str(LAYOUT_VERSION_DIR / "xkb_types.txt"),
                "--skip-activation",
            ],
            env=self.env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertNotIn("could not be verified", result.stderr)
        for layouts in ([LEGACY], [LEGACY, US], [US, LEGACY]):
            with self.subTest(layouts=activation.describe_rmlvo(layouts)):
                result = self.compile(layouts)
                self.assertTrue(has_type(result))
                self.assertTrue(usable(result, layouts.index(LEGACY) + 1), result.diagnostics)
        if XKBCOMP:
            self.assertTrue(legacy.xkbcomp_check(self.roots(), LEGACY))

    def test_a_type_appended_after_the_section_is_dropped(self):
        """Reproduces the historical legacy edit, proving the fence can fail."""
        extra = self.system_root / "types" / "extra"
        source = (LAYOUT_VERSION_DIR / "xkb_types.txt").read_text(encoding="utf-8")
        block = re.search(r'type ".*?" \{.*?\};', source, re.DOTALL).group(0)
        extra.write_text(extra.read_text(encoding="utf-8").rstrip() + "\n\n" + block + "\n", encoding="utf-8")
        legacy.update_xkb_symbols_file(
            LAYOUT_VERSION_DIR / "Ergopti_v2_2_1.xkb", "Ergopti_v2_2_1", self.system_root / "symbols" / "fr"
        )
        self.assertFalse(has_type(self.compile([LEGACY])))
        if XKBCOMP:
            with unittest.mock.patch.object(legacy.logging, "error"):
                self.assertFalse(legacy.xkbcomp_check(self.roots(), LEGACY))


if __name__ == "__main__":
    unittest.main()
