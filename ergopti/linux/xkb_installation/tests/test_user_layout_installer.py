"""The user-level installer of registry layouts (no sudo).

The ErgoptiPlus daemon converts a registry .keylayout on the device and
installs the result in the user XKB tree that libxkbcommon reads first. These
tests run the real installer inside a sandbox tree with the real conversion
of Ergo-L and Ergopti: the files each layout owns, the ruleset that keeps the
system rules and binds each layout's key types, the picker registry, the
~/.XCompose block, the refusal to overwrite a file the user wrote, and a
clean uninstallation. When xkbcli >= 1.13 is installed, the installed layout
is compiled for real and must carry its key type.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

INSTALLATION_DIR = Path(__file__).resolve().parents[1]
GENERATION_DIR = INSTALLATION_DIR.parent / "xkb_generation"
sys.path.insert(0, str(INSTALLATION_DIR))
sys.path.insert(0, str(GENERATION_DIR))

import keylayout_to_xkb  # noqa: E402
import user_layout_installer as installer  # noqa: E402
from desktop_activation import libxkbcommon_version  # noqa: E402

STATIC_DIR = INSTALLATION_DIR.parents[2]
REGISTRY_DIR = STATIC_DIR / "layouts" / "registry"
KEYCODES = STATIC_DIR / "ergopti_plus" / "_shared" / "modules" / "layouts" / "mac_keycodes.json"


def convert(layout_id: str, out_dir: Path) -> None:
    """Converts a registry layout the way the daemon does."""
    index = json.loads((REGISTRY_DIR / "index.json").read_text(encoding="utf-8"))
    entry = next(item for item in index["layouts"] if item["id"] == layout_id)
    code = keylayout_to_xkb.main(
        [
            "--keylayout",
            str(REGISTRY_DIR / entry["file"]),
            "--keycodes",
            str(KEYCODES),
            "--convention",
            entry["keycode_convention"],
            "--layout-id",
            layout_id,
            "--display-name",
            entry["name"],
            "--index",
            str(REGISTRY_DIR / "index.json"),
            "--out",
            str(out_dir),
        ]
    )
    if code != 0:
        raise AssertionError("conversion of %s failed" % layout_id)


class UserInstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = Path(tempfile.mkdtemp(prefix="ergopti-user-xkb-"))
        self.root = self.scratch / "config" / "xkb"
        self.home = self.scratch / "home"
        self.home.mkdir()
        self.sources = {}
        for layout_id in ("ergol", "ergopti"):
            out = self.scratch / "converted" / layout_id
            convert(layout_id, out)
            self.sources[layout_id] = out

    def tearDown(self) -> None:
        shutil.rmtree(self.scratch, ignore_errors=True)

    def install(self, layout_id: str, name: str) -> dict:
        return installer.install(
            layout_id, name, self.sources[layout_id], ["fr", "en"], self.root, self.home
        )

    def test_a_layout_owns_its_symbols_types_and_compose_files(self) -> None:
        report = self.install("ergol", "French (Ergo-L)")
        self.assertTrue(report["ok"], report)
        symbols = (self.root / "symbols" / "ergol").read_text(encoding="utf-8")
        self.assertTrue(symbols.startswith(installer.FILE_MARKER + "ergol\n"))
        self.assertIn('xkb_symbols "default"', symbols)
        self.assertIn(
            installer.ERGOPTI_TYPE_NAME, (self.root / "types" / "ergol").read_text(encoding="utf-8")
        )
        self.assertTrue(
            (self.root / "compose" / "ergol.XCompose")
            .read_text(encoding="utf-8")
            .startswith('include "%L"')
        )

    def test_the_ruleset_keeps_the_system_rules_and_binds_each_layout(self) -> None:
        self.install("ergol", "French (Ergo-L)")
        self.install("ergopti", "Ergopti")
        rules = (self.root / "rules" / "evdev").read_text(encoding="utf-8")
        self.assertTrue(rules.startswith(installer.RULES_MARKER + "\n! include %S/evdev\n"))
        for layout_id in ("ergol", "ergopti"):
            self.assertIn("  %s\t=\t+%s\n" % (layout_id, layout_id), rules)
            self.assertIn("! layout[4]\t=\ttypes\n  %s" % layout_id, rules)
        registry = (self.root / "rules" / "evdev.xml").read_text(encoding="utf-8")
        self.assertIn("<name>ergol</name>", registry)
        self.assertIn("<description>French (Ergo-L)</description>", registry)
        self.assertIn("<iso639Id>fra</iso639Id>", registry)
        manifest = json.loads((self.root / installer.MANIFEST_NAME).read_text(encoding="utf-8"))
        self.assertEqual(sorted(manifest["layouts"]), ["ergol", "ergopti"])

    def test_the_xcompose_block_keeps_the_user_rules(self) -> None:
        (self.home / ".XCompose").write_text('<Multi_key> <a> <a> : "å"\n', encoding="utf-8")
        self.install("ergol", "French (Ergo-L)")
        content = (self.home / ".XCompose").read_text(encoding="utf-8")
        self.assertTrue(content.startswith('<Multi_key> <a> <a> : "å"\n'))
        self.assertIn(installer.XCOMPOSE_MARKER + "\n", content)
        include = installer.build_xcompose_block([self.root / "compose" / "ergol.XCompose"])[1]
        self.assertTrue(
            include.startswith('include "') and include.endswith('ergol.XCompose"'), include
        )
        self.assertIn(include, content.splitlines())
        installer.uninstall("ergol", self.root, self.home, deactivate=False)
        self.assertEqual(
            (self.home / ".XCompose").read_text(encoding="utf-8"), '<Multi_key> <a> <a> : "å"\n'
        )

    def test_a_file_the_user_wrote_is_never_replaced(self) -> None:
        own_rules = self.root / "rules" / "evdev"
        own_rules.parent.mkdir(parents=True)
        own_rules.write_text("! include %S/evdev\n// my own rules\n", encoding="utf-8")
        with self.assertRaises(installer.InstallError) as refusal:
            self.install("ergol", "French (Ergo-L)")
        self.assertEqual(refusal.exception.code, installer.EXIT_VALIDATION)
        self.assertEqual(refusal.exception.kind, "conflict", "the daemon tells a conflict apart")
        self.assertEqual(
            own_rules.read_text(encoding="utf-8"), "! include %S/evdev\n// my own rules\n"
        )
        self.assertFalse(
            (self.root / "symbols" / "ergol").exists(), "nothing is written after a refusal"
        )

        own_rules.unlink()
        own_symbols = self.root / "symbols" / "ergol"
        own_symbols.parent.mkdir(parents=True)
        own_symbols.write_text("my layout\n", encoding="utf-8")
        with self.assertRaises(installer.InstallError):
            self.install("ergol", "French (Ergo-L)")
        self.assertEqual(own_symbols.read_text(encoding="utf-8"), "my layout\n")

    def test_an_update_replaces_the_files_it_owns(self) -> None:
        self.install("ergol", "French (Ergo-L)")
        report = self.install("ergol", "French (Ergo-L)")
        self.assertTrue(report["ok"], report)

    def tree_files(self) -> dict:
        """Every file of the user tree and the home folder, with its content."""
        return {
            str(path.relative_to(self.scratch)): path.read_text(encoding="utf-8")
            for base in (self.root, self.home)
            if base.exists()
            for path in sorted(base.rglob("*"))
            if path.is_file()
        }

    def test_a_layout_that_does_not_compile_leaves_the_tree_as_it_was(self) -> None:
        # The desktop pickers read the tree: a layout that does not compile
        # must not stay registered there while the daemon reports a failure.
        self.install("ergopti", "Ergopti")
        self.install("ergol", "French (Ergo-L)")
        installed = self.tree_files()
        self.assertGreaterEqual(len(installed), 8, "the two layouts own files in the tree")
        changed = self.sources["ergol"] / "ergol.xkb"
        changed.write_text(
            changed.read_text(encoding="utf-8") + "// a newer conversion\n", encoding="utf-8"
        )
        compiles = installer.verify
        installer.verify = lambda root, layout_id: False
        try:
            update = self.install("ergol", "French (Ergo-L)")
            self.assertFalse(update["ok"], update)
            self.assertEqual(
                self.tree_files(),
                installed,
                "an update that does not compile restores the previous files",
            )

            installer.uninstall("ergopti", self.root, self.home, deactivate=False)
            without = self.tree_files()
            fresh = self.install("ergopti", "Ergopti")
            self.assertFalse(fresh["ok"], fresh)
            self.assertEqual(
                self.tree_files(), without, "a new layout that does not compile is removed again"
            )
        finally:
            installer.verify = compiles

    def test_uninstall_removes_everything_it_installed(self) -> None:
        self.install("ergol", "French (Ergo-L)")
        self.install("ergopti", "Ergopti")
        installer.uninstall("ergol", self.root, self.home, deactivate=False)
        self.assertFalse((self.root / "symbols" / "ergol").exists())
        self.assertFalse((self.root / "types" / "ergol").exists())
        self.assertNotIn("ergol\t", (self.root / "rules" / "evdev").read_text(encoding="utf-8"))
        installer.uninstall("ergopti", self.root, self.home, deactivate=False)
        remaining = sorted(
            str(path.relative_to(self.root)) for path in self.root.rglob("*") if path.is_file()
        )
        self.assertEqual(remaining, [], "the last uninstallation leaves no file behind")
        self.assertFalse((self.home / ".XCompose").exists())
        with self.assertRaises(installer.InstallError):
            installer.uninstall("ergopti", self.root, self.home, deactivate=False)

    def test_the_command_line_reports_json_and_refuses_a_bad_id(self) -> None:
        env = {
            "ERGOPTI_XKB_USER_ROOT": str(self.root),
            "ERGOPTI_XKB_USER_HOME": str(self.home),
            "PATH": "",
        }
        script = str(INSTALLATION_DIR / "user_layout_installer.py")
        bad = subprocess.run(
            [sys.executable, script, "uninstall", "--layout-id", "../evil"],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(bad.returncode, installer.EXIT_ARGUMENTS)
        self.assertFalse(json.loads(bad.stdout.strip().splitlines()[-1])["ok"])
        run = subprocess.run(
            [
                sys.executable,
                script,
                "install",
                "--layout-id",
                "ergol",
                "--display-name",
                "French (Ergo-L)",
                "--source-dir",
                str(self.sources["ergol"]),
                "--language",
                "fr",
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(run.returncode, 0, run.stderr)
        report = json.loads(run.stdout.strip().splitlines()[-1])
        self.assertTrue(report["ok"])
        self.assertIsNone(
            report["verified"], "without xkbcli on PATH the layout is reported unverified"
        )


@unittest.skipUnless(
    shutil.which("xkbcli") and (libxkbcommon_version() or (0,)) >= (1, 13, 0),
    "xkbcli >= 1.13 is not installed",
)
class UserTreeCompilationTests(unittest.TestCase):
    def test_an_installed_layout_compiles_with_its_key_type(self) -> None:
        scratch = Path(tempfile.mkdtemp(prefix="ergopti-user-xkb-compile-"))
        try:
            out = scratch / "ergol"
            convert("ergol", out)
            report = installer.install(
                "ergol", "French (Ergo-L)", out, ["fr"], scratch / "xkb", scratch
            )
            self.assertTrue(report["ok"], report)
            self.assertTrue(report["verified"], "the compiled keymap must carry the key type")
        finally:
            shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
