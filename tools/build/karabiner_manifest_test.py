# tools/build/karabiner_manifest_test.py
"""Keep the Karabiner package onboarding downloads under one pinned, safe identity."""

import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest


class ManifestTests(unittest.TestCase):
    def test_shared_manifest_rejects_unsafe_or_unpinned_identity(self):
        from karabiner_manifest import read_manifest

        good = read_manifest()
        with TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            for field, value in (
                ("version", "TODO"),
                ("file_name", "../escape.dmg"),
                ("sha256", "a" * 63),
                ("source_url", "http://example.invalid/test.dmg"),
                ("source_url", "https://example.invalid/other.dmg"),
                ("version", "1.2.3\tbad"),
            ):
                path.write_text(json.dumps(dict(good, **{field: value})), encoding="utf-8")
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    read_manifest(path)
            path.write_text(json.dumps(good), encoding="utf-8")
            self.assertEqual(read_manifest(path), good)


if __name__ == "__main__":
    unittest.main()
