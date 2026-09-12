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
# `unittest.mock` is a submodule: `import unittest` alone does not bind it. This
# file used `unittest.mock.patch` and only worked when some other test module
# imported it first, so running this one on its own raised AttributeError.
import unittest.mock
import xml.etree.ElementTree as ET
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

    def install(self, variant="ergopti", ansi=False):
        suffix = "_plus" if variant == "ergopti_plus" else ""
        if ansi:
            suffix += "_ansi"
        return subprocess.run(
            [
                sys.executable,
                str(INSTALLER_DIR / "xkb_files_installer_clean.py"),
                "--xkb",
                str(LAYOUT_VERSION_DIR / f"Ergopti_v2_2_1{suffix}.xkb"),
                "--types",
                str(LAYOUT_VERSION_DIR / "xkb_types.txt"),
                "--variant",
                variant,
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

    def test_the_published_variant_resolves_and_carries_the_type(self):
        """The layout(variant) pair must be as real as the bare layout.

        The package advertises a named variant in its registry so pickers that
        only offer layout(variant) pairs can select it (issue #84 follow-up: the
        reporter could not keep Ergopti next to a Japanese input source because
        a layout with no variant was not offerable). An advertised spelling that
        does not resolve is worse than one that is not advertised: the picker
        lists it and the session gets a keymap with dead Shift and AltGr.
        """
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        variant_spec = LayoutSpec("ergopti", "ergopti")
        # Alone, and next to another layout: the indexed rules must bind the
        # custom type for the pair exactly as they do for the bare layout.
        for layouts in ([variant_spec], [variant_spec, US], [US, variant_spec]):
            with self.subTest(layouts=activation.describe_rmlvo(layouts)):
                compiled = self.compile(layouts)
                self.assertTrue(has_type(compiled), compiled.diagnostics)
                self.assertTrue(
                    usable(compiled, layouts.index(variant_spec) + 1), compiled.diagnostics
                )

    def test_issue_84_french_variant_preserves_layers_and_other_french_layouts(self):
        """French-only input-method pickers need fr(ergopti), not ergopti(ergopti)."""
        french = [LayoutSpec("fr"), LayoutSpec("fr", "oss"), LayoutSpec("fr", "bepo")]
        before = [self.compile([spec]) for spec in french]
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        spec = LayoutSpec("fr", "ergopti")
        for layouts in ([spec], [spec, US], [US, spec], [US, US, spec], [US, US, US, spec]):
            with self.subTest(layouts=activation.describe_rmlvo(layouts)):
                compiled = self.compile(layouts)
                self.assertTrue(usable(compiled, layouts.index(spec) + 1), compiled.diagnostics)
        for original, selection in zip(before, french):
            self.assertTrue(original.succeeded, original.diagnostics)
            self.assertEqual(original.keymap, self.compile([selection]).keymap)
        registry = ET.parse(self.extensions_root / "ergopti/rules/evdev.xml")
        registered = {
            (layout.findtext("configItem/name"), variant.findtext("configItem/name"))
            for layout in registry.findall(".//layout")
            for variant in layout.findall("variantList/variant")
        }
        self.assertIn(("fr", "ergopti"), registered)

    def test_issue_84_registry_discovers_both_french_variants(self):
        for variant in ("ergopti", "ergopti_plus"):
            with self.subTest(variant=variant):
                installed = self.install(variant)
                self.assertEqual(installed.returncode, 0, installed.stderr + installed.stdout)
                listing = subprocess.run(
                    [XKBCLI, "list"], capture_output=True, text=True, timeout=30,
                    env={**os.environ,
                         "XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH": str(self.extensions_root),
                         "XKB_CONFIG_VERSIONED_EXTENSIONS_PATH": ""},
                )
                self.assertEqual(listing.returncode, 0, listing.stderr)
                entries = re.split(r"(?m)^- layout:", listing.stdout)
                self.assertTrue(any(
                    re.match(r"\s*'fr'\s*$", entry.splitlines()[0])
                    and f"variant: '{variant}'" in entry for entry in entries if entry.strip()
                ), listing.stdout)

    def test_issue_84_both_variants_match_the_canonical_keys_in_every_group(self):
        for variant in ("ergopti", "ergopti_plus"):
            installed = self.install(variant)
            self.assertEqual(installed.returncode, 0, installed.stderr + installed.stdout)
            for group in range(1, 5):
                with self.subTest(variant=variant, group=group):
                    peers = [LayoutSpec("jp")] * (group - 1)
                    canonical = self.compile(peers + [LayoutSpec("ergopti", variant)])
                    french = self.compile(peers + [LayoutSpec("fr", variant)])
                    self.assertTrue(usable(canonical, group), canonical.diagnostics)
                    self.assertTrue(usable(french, group), french.diagnostics)
                    keys = re.findall(r"key\s+(<[^>]+>)", canonical.keymap)
                    self.assertGreater(len(keys), 30)
                    for key in keys:
                        self.assertEqual(
                            activation.keymap_key_block(canonical.keymap, key),
                            activation.keymap_key_block(french.keymap, key), key,
                        )

    def test_issue_84_missing_french_types_is_detected_even_when_compilation_succeeds(self):
        from layout_package import build_evdev_post

        installed = self.install()
        self.assertEqual(installed.returncode, 0, installed.stderr + installed.stdout)
        (self.extensions_root / "ergopti/rules/evdev.post").write_text(
            build_evdev_post("ergopti"), encoding="utf-8",
        )
        for layouts in ([LayoutSpec("fr", "ergopti")], [US, LayoutSpec("fr", "ergopti")]):
            compiled = self.compile(layouts)
            self.assertTrue(compiled.succeeded, compiled.diagnostics)
            self.assertFalse(usable(compiled, len(layouts)))

    def test_issue_84_ansi_variants_preserve_the_canonical_physical_keys(self):
        for variant in ("ergopti", "ergopti_plus"):
            with self.subTest(variant=variant):
                installed = self.install(variant, ansi=True)
                self.assertEqual(installed.returncode, 0, installed.stderr + installed.stdout)
                canonical = self.compile([LayoutSpec("ergopti", variant)])
                french = self.compile([LayoutSpec("fr", variant)])
                self.assertTrue(usable(canonical), canonical.diagnostics)
                self.assertTrue(usable(french), french.diagnostics)
                keys = re.findall(r"key\s+(<[^>]+>)", canonical.keymap)
                self.assertGreater(len(keys), 30)
                for key in keys:
                    self.assertEqual(activation.keymap_key_block(canonical.keymap, key),
                                     activation.keymap_key_block(french.keymap, key), key)

    def test_issue_84_reinstall_replaces_the_variant_and_uninstall_restores_discovery(self):
        # Fedora containers can expose gsettings without desktop schemas. This
        # package-only test must never depend on or mutate that host session.
        desktop_bin = self.sandbox / "desktop-bin"
        desktop_bin.mkdir()
        gsettings = desktop_bin / "gsettings"
        gsettings.write_text('#!/bin/sh\n: > "$0.called"\nexit 1\n', encoding="utf-8")
        gsettings.chmod(0o755)
        self.env["PATH"] = str(desktop_bin) + os.pathsep + self.env.get("PATH", "")
        original = self.compile([LayoutSpec("fr")])
        self.assertTrue(original.succeeded, original.diagnostics)
        for variant in ("ergopti", "ergopti_plus", "ergopti_plus", "ergopti"):
            installed = self.install(variant)
            self.assertEqual(installed.returncode, 0, installed.stderr + installed.stdout)
            self.assertTrue(usable(self.compile([LayoutSpec("fr", variant)])))
            retired = "ergopti_plus" if variant == "ergopti" else "ergopti"
            self.assertFalse(self.compile([LayoutSpec("fr", retired)]).succeeded)
        uninstalled = subprocess.run(
            [sys.executable, str(INSTALLER_DIR / "xkb_files_installer_clean.py"),
             "--uninstall", "--skip-activation"],
            env=self.env, capture_output=True, text=True, encoding="utf-8", timeout=30,
        )
        self.assertEqual(uninstalled.returncode, 0, uninstalled.stdout + uninstalled.stderr)
        self.assertFalse(gsettings.with_name("gsettings.called").exists(),
                         "a package-only round trip must not contact the host desktop")
        self.assertFalse((self.extensions_root / "ergopti").exists())
        self.assertEqual(original.keymap, self.compile([LayoutSpec("fr")]).keymap)
        self.assertFalse(self.compile([LayoutSpec("fr", "ergopti")]).succeeded)

    def test_issue_84_broken_french_alias_aborts_before_replacing_the_working_package(self):
        import xkb_files_installer_clean as clean

        installed = self.install()
        self.assertEqual(installed.returncode, 0, installed.stderr + installed.stdout)
        package = self.extensions_root / "ergopti"
        before = {path.relative_to(package): path.read_bytes()
                  for path in package.rglob("*") if path.is_file()}
        roots = InstallerRoots(
            extensions_root=self.extensions_root, system_root=self.system_root,
            cache_dir=self.sandbox / "cache", sandboxed=True,
        )
        with unittest.mock.patch.object(clean, "build_french_variant_symbols", return_value=(
            'default xkb_symbols "default" { include "%S/fr" };\n'
        )), unittest.mock.patch("builtins.print"):
            with self.assertRaises(SystemExit) as failure:
                clean.install_clean(
                    symbols_path=LAYOUT_VERSION_DIR / "Ergopti_v2_2_1_plus.xkb",
                    types_path=LAYOUT_VERSION_DIR / "xkb_types.txt",
                    xcompose_path=None, variant="ergopti_plus", roots=roots,
                )
        self.assertEqual(failure.exception.code, 3)
        after = {path.relative_to(package): path.read_bytes()
                 for path in package.rglob("*") if path.is_file()}
        self.assertEqual(before, after)
        self.assertTrue(usable(self.compile([LayoutSpec("fr", "ergopti")])))

    def test_the_variant_and_the_bare_layout_produce_the_same_keymap(self):
        """The alias is a second door onto one room, not a second room.

        If the two spellings ever diverged, half the users would silently get a
        different layout from the other half depending on which one their picker
        offered them.
        """
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        bare = self.compile([ERGOPTI])
        aliased = self.compile([LayoutSpec("ergopti", "ergopti")])
        self.assertTrue(has_type(bare))
        self.assertTrue(has_type(aliased))

        # Compare the bound keys, not the whole file: a keymap embeds the RMLVO
        # spelling it was built from, so the two differ by their own name and
        # nothing else. The key rows are what the user actually types on.
        def key_rows(compiled):
            rows = [line.strip() for line in compiled.keymap.splitlines()
                    if line.strip().startswith("key ")]
            self.assertGreater(len(rows), 30, "the keymap parse produced almost nothing")
            return rows

        self.assertEqual(
            key_rows(bare),
            key_rows(aliased),
            "ergopti and ergopti(ergopti) must bind exactly the same keys: the "
            "variant is a second door onto one room, not a second room",
        )

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
