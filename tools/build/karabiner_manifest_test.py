# tools/build/karabiner_manifest_test.py
"""Keep packaged and direct-Hammerspoon dependency bytes under one pinned identity."""

import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
from tempfile import TemporaryDirectory
import unittest


class PackageBuildTests(unittest.TestCase):
    def run_cached_package(self, valid, legacy_extraction=False):
        source = Path(__file__).with_name("build_macos_app.sh").read_text(encoding="utf-8")
        function = re.search(r"(?ms)^download_karabiner\(\) \{\n.*?^\}", source)
        self.assertIsNotNone(function, "The actual package acquisition function must be exercised")
        with TemporaryDirectory(prefix="ergopti package ") as directory:
            root = Path(directory)
            (root / "cache").mkdir()
            (root / "cache/Karabiner-Elements-test.dmg").write_bytes(b"cached package")
            expected = "a" * 64
            extracted = "Karabiner-Elements" if legacy_extraction else "Karabiner-Elements-" + expected
            (root / extracted).mkdir()
            observed = expected if valid else "b" * 64
            script = "\n".join(("set -euo pipefail", "BUILD_DIR=" + shlex.quote(root.as_posix()),
                "KARABINER_VERSION=test", "KARABINER_FILE_NAME=Karabiner-Elements-test.dmg",
                "KARABINER_SHA256=" + expected, "KARABINER_SOURCE_URL=https://example.invalid/test.dmg",
                "log() { :; }", 'fail() { printf "%s\\n" "$1" >&2; exit 19; }',
                'shasum() { printf "%s  fixture\\n" ' + observed + '; }',
                "hdiutil() { return 23; }", function.group(), "download_karabiner"))
            return subprocess.run([shutil.which("bash") or "/bin/bash", "-c", script],
                                  capture_output=True, text=True, timeout=10)

    def test_cached_package_is_verified_even_if_extraction_already_exists(self):
        result = self.run_cached_package(False)
        self.assertEqual(result.returncode, 19, result.stdout + result.stderr)
        self.assertIn("checksum mismatch", result.stderr)

    def test_verified_cached_package_is_reused(self):
        result = self.run_cached_package(True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(result.stdout.strip().endswith("Karabiner-Elements-" + "a" * 64))

    def test_unkeyed_extraction_cannot_bypass_the_selected_package(self):
        result = self.run_cached_package(True, legacy_extraction=True)
        self.assertEqual(result.returncode, 19, result.stdout + result.stderr)
        self.assertIn("hdiutil attach failed", result.stderr)


class ManifestTests(unittest.TestCase):
    def test_shared_manifest_rejects_unsafe_or_unpinned_identity(self):
        from karabiner_manifest import read_manifest
        good = read_manifest()
        with TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            for field, value in (("version", "TODO"), ("file_name", "../escape.dmg"),
                                 ("sha256", "a" * 63), ("source_url", "http://example.invalid/test.dmg"),
                                 ("source_url", "https://example.invalid/other.dmg"), ("version", "1.2.3\tbad")):
                path.write_text(json.dumps(dict(good, **{field: value})), encoding="utf-8")
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    read_manifest(path)
            path.write_text(json.dumps(good), encoding="utf-8")
            self.assertEqual(read_manifest(path), good)


if __name__ == "__main__":
    unittest.main()
