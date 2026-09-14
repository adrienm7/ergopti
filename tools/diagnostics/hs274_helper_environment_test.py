# tools/diagnostics/hs274_helper_environment_test.py
"""A retained helper must match both its archive bytes and the current sources."""

import copy
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import hs274_helper_environment as probe


class HelperArtifactTests(unittest.TestCase):
    def test_authentication_rejects_tampering_duplicate_artifacts_and_stale_sources(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "ErgoptiPlus.app.zip"
            archive.write_bytes(b"verified helper archive")
            identity = {"archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                        "archive_bytes": archive.stat().st_size, "sources": {"source.swift": "current"}}
            receipt = root / "native-helper.json"
            receipt.write_text(json.dumps(identity), encoding="utf-8")
            with patch.object(probe, "selection", return_value={"identity": identity}), \
                    patch.object(probe, "source_identity", return_value=copy.deepcopy(identity["sources"])) as sources:
                self.assertEqual(probe.authenticate(root), archive)
                archive.write_bytes(b"unverified replacement")
                with self.assertRaisesRegex(ValueError, "integrity"):
                    probe.authenticate(root)
                archive.write_bytes(b"verified helper archive")
                sources.return_value = {"source.swift": "changed"}
                with self.assertRaisesRegex(ValueError, "sources differ"):
                    probe.authenticate(root)
                sources.return_value = identity["sources"]
                duplicate = root / "duplicate"
                duplicate.mkdir()
                (duplicate / archive.name).write_bytes(archive.read_bytes())
                with self.assertRaisesRegex(ValueError, "exactly one"):
                    probe.authenticate(root)


if __name__ == "__main__":
    unittest.main()
