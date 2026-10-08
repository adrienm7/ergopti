# tools/diagnostics/hs274_builder_image_size_test.py
"""Frozen actual fixed-source admission controls, no native authority."""

import hashlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

CANDIDATE = Path(__file__).resolve().parents[2]
SOURCE = CANDIDATE / "tools/diagnostics/hs274_native_build_observation.py"
spec = importlib.util.spec_from_file_location("fixed_builder_image_control", SOURCE)
SUBJECT = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = SUBJECT
exec(compile(SOURCE.read_bytes(), str(SOURCE), "exec"), SUBJECT.__dict__)
BUILDER = CANDIDATE / "tools/build/remap_runtime_build.py"
FIXED = "9f1a9890de1588b2b02cc74a107538187407a0901e3e42f1a41c8d6f534bbdc4"
EXACT_BYTES = 134324


class FixedSourceAdmission(unittest.TestCase):
    def image(self, path, wanted):
        sources = []
        try:
            return SUBJECT.source_image(path, wanted, sources)
        finally:
            for _, fd, _ in sources:
                SUBJECT.os.close(fd)

    def test_actual_pinned_builder_loads_without_executing_engine(self):
        self.assertEqual(BUILDER.stat().st_size, EXACT_BYTES)
        self.assertEqual(hashlib.sha256(BUILDER.read_bytes()).hexdigest(), FIXED)
        projection = SUBJECT.load_builder()
        try:
            self.assertEqual(len(projection.BASELINE_PHASES), 19)
            projection.current()
        finally:
            projection.close()

    def test_pinned_builder_must_have_exact_size_before_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp).resolve() / "fixed.py"
            for count in (1, 131072, EXACT_BYTES - 1, EXACT_BYTES + 1):
                path.write_bytes(b"x" * count)
                path.chmod(0o600)
                sources = []
                try:
                    with self.assertRaises(SUBJECT.UnsupportedObservation):
                        SUBJECT.source_image(path, FIXED, sources)
                    self.assertEqual(sources, [], "Wrong-sized pinned image opened before refusal")
                finally:
                    for _, fd, _ in sources:
                        SUBJECT.os.close(fd)

    def test_same_size_wrong_hash_cannot_gain_source_admission(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp).resolve() / "fixed.py"
            path.write_bytes(b"x" * EXACT_BYTES)
            path.chmod(0o600)
            with self.assertRaises(SUBJECT.UnsupportedObservation):
                self.image(path, FIXED)

    def test_every_other_source_retains_original_128k_bound(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp).resolve() / "ordinary.py"
            for count in (131073, EXACT_BYTES, EXACT_BYTES + 1):
                data = b"x" * count
                path.write_bytes(data)
                path.chmod(0o600)
                sources = []
                with self.assertRaises(SUBJECT.UnsupportedObservation):
                    SUBJECT.source_image(path, hashlib.sha256(data).hexdigest(), sources)
                self.assertEqual(sources, [])

    def test_ordinary_exact_128k_image_still_loads(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp).resolve() / "ordinary.py"
            data = b"x" * 131072
            path.write_bytes(data)
            path.chmod(0o600)
            self.assertEqual(self.image(path, hashlib.sha256(data).hexdigest()), data)


if __name__ == "__main__":
    unittest.main(verbosity=2)
