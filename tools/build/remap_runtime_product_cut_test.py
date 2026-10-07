"""Frozen literal product-currentness diagnostics; Linux host IO, no native proof."""

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "tools/build/remap_runtime_build.py"
spec = importlib.util.spec_from_file_location("actual_product_cut_before_subject", BUILDER)
B = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = B
exec(compile(BUILDER.read_bytes(), str(BUILDER), "exec"), B.__dict__)
FIELDS = {
    "schema",
    "seq",
    "event",
    "span",
    "parent",
    "stage",
    "phase",
    "mono_ns",
    "elapsed_ns",
    "sync_ns",
    "code",
}


class ProductCurrentnessCutControls(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.source = self.base / "source"
        self.source.mkdir(mode=0o700)
        self.owner = self.base / "owner"
        self.owner.mkdir(mode=0o700)
        self.leaf = self.source / "project.pbxproj"
        self.leaf.write_bytes(b"ORIGINAL")
        self.held = B.product_snapshot(self.leaf, self.source)

    def rows(self):
        data = (self.owner / "owned-compilation-boundaries.jsonl").read_bytes()
        self.assertLessEqual(len(data), 131072)
        rows = [json.loads(line) for line in data.splitlines()]
        self.assertLessEqual(len(rows), 512)
        for row in rows:
            self.assertEqual(set(row), FIELDS)
        self.assertNotIn(str(self.base).encode(), data)
        self.assertNotIn(b"SECRET", data)
        return rows

    def refused(self, reason, message):
        with self.assertRaises(B.BASE.NativeBuildError) as caught:
            with B._observe_compilation(self.owner):
                B.current_product(self.held, self.source)
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(caught.exception.args, (message,))
        rows = [r for r in self.rows() if r["event"] == "refused"]
        self.assertEqual(
            [(r["stage"], r["phase"], r["code"]) for r in rows],
            [("products", "", "source_identity"), ("products", "", reason)],
        )
        self.assertEqual([(r["span"], r["parent"]) for r in rows], [(1, 0), (1, 0)])

    def test_genuine_changed_held_product_has_closed_cut_after_original_refusal(self):
        self.leaf.write_bytes(b"CHANGED!")
        self.refused("held_product_changed", "Native product changed across a foreign phase")

    def test_genuine_preopen_replacement_has_opened_incarnation_cut(self):
        replacement = self.source / "replacement"
        replacement.write_bytes(b"ORIGINAL")
        original_open = B.os.open
        calls = []

        def opened(path, *args, **kwargs):
            if Path(path) == self.leaf:
                calls.append(path)
                os.replace(replacement, self.leaf)
            return original_open(path, *args, **kwargs)

        with patch.object(B.os, "open", side_effect=opened):
            self.refused(
                "opened_incarnation",
                "Actually opened input differs from selected filesystem incarnation",
            )
        self.assertEqual(len(calls), 1)

    def test_genuine_postread_mutation_has_read_currentness_cut(self):
        original_open, original_fstat = B.os.open, B.os.fstat
        active = []
        cuts = []

        def opened(path, *args, **kwargs):
            descriptor = original_open(path, *args, **kwargs)
            if Path(path) == self.leaf:
                active.append(descriptor)
            return descriptor

        def fstat(descriptor):
            if active and descriptor == active[-1]:
                cuts.append(descriptor)
                if len(cuts) == 2:
                    self.leaf.write_bytes(b"CHANGED!")
            return original_fstat(descriptor)

        with (
            patch.object(B.os, "open", side_effect=opened),
            patch.object(B.os, "fstat", side_effect=fstat),
        ):
            self.refused(
                "read_currentness", "Retained descriptor or selected input changed during read"
            )
        self.assertEqual(len(active), 1)
        self.assertEqual(len(cuts), 2)

    def test_unknown_private_and_nonexact_errors_do_not_select_product_reason(self):
        class Foreign(B.BASE.NativeBuildError):
            pass

        class PrivateString(str):
            def __eq__(self, other):
                raise AssertionError("Private comparison")

            __hash__ = str.__hash__

        cases = [
            B.BASE.NativeBuildError("source_identity", "SECRET /private unknown guard"),
            B.BASE.NativeBuildError("foreign", "Native product changed across a foreign phase"),
            Foreign("source_identity", "Native product changed across a foreign phase"),
            B.BASE.NativeBuildError(
                "source_identity", PrivateString("Native product changed across a foreign phase")
            ),
        ]
        for index, error in enumerate(cases):
            with self.subTest(index=index):
                owner = self.base / ("negative-owner-" + str(index))
                owner.mkdir(mode=0o700)
                with self.assertRaises(type(error)) as caught:
                    with B._observe_compilation(owner):
                        with B._observe_span("products"):
                            raise error
                self.assertIs(caught.exception, error)
                data = (owner / "owned-compilation-boundaries.jsonl").read_bytes()
                rows = [json.loads(x) for x in data.splitlines()]
                self.assertEqual(
                    [x["code"] for x in rows if x["event"] == "refused"],
                    [
                        "source_identity"
                        if index in (0, 3)
                        else "other_refusal"
                        if index == 1
                        else "unexpected"
                    ],
                )
                self.assertNotIn(b"SECRET", data)
                self.assertNotIn(b"/private", data)

    def test_success_preserves_existing_product_read_fences_and_no_reason(self):
        original_open, original_lstat, original_fstat = B.os.open, Path.lstat, B.os.fstat
        descriptors = []
        counts = {"open": 0, "lstat": 0, "fstat": 0}

        def opened(path, *args, **kwargs):
            result = original_open(path, *args, **kwargs)
            if Path(path) == self.leaf:
                counts["open"] += 1
                descriptors.append(result)
            return result

        def lstat(path, *args, **kwargs):
            if path == self.leaf:
                counts["lstat"] += 1
            return original_lstat(path, *args, **kwargs)

        def fstat(descriptor):
            if descriptors and descriptor == descriptors[-1]:
                counts["fstat"] += 1
            return original_fstat(descriptor)

        with (
            patch.object(B.os, "open", side_effect=opened),
            patch.object(Path, "lstat", lstat),
            patch.object(B.os, "fstat", side_effect=fstat),
        ):
            with B._observe_compilation(self.owner):
                self.assertIsNone(B.current_product(self.held, self.source))
        self.assertEqual(counts, {"open": 1, "lstat": 2, "fstat": 2})
        self.assertEqual(
            [r["event"] for r in self.rows()], ["writer_start", "enter", "complete", "writer_end"]
        )

    def test_collided_diagnostic_writer_never_changes_original_error(self):
        witness = self.owner / "owned-compilation-boundaries.jsonl"
        witness.write_bytes(b"FOREIGN unchanged")
        self.leaf.write_bytes(b"CHANGED!")
        with self.assertRaises(B.BASE.NativeBuildError) as caught:
            with B._observe_compilation(self.owner):
                B.current_product(self.held, self.source)
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(caught.exception.args, ("Native product changed across a foreign phase",))
        self.assertEqual(witness.read_bytes(), b"FOREIGN unchanged")


if __name__ == "__main__":
    unittest.main(verbosity=2)
