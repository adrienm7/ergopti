"""Independent closed equality axes; genuine portable IO, no Darwin proof."""

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
spec = importlib.util.spec_from_file_location("product_axes_private_subject", BUILDER)
B = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = B
exec(compile(BUILDER.read_bytes(), str(BUILDER), "exec"), B.__dict__)
AXES = ("dev", "ino", "uid", "mode", "nlink", "size", "mtime", "ctime")
MESSAGE = "Native product changed across a foreign phase"


class ProductEqualityAxisControls(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.source = self.base / "source"
        self.source.mkdir(mode=0o700)
        self.owner = self.base / "owner"
        self.owner.mkdir(mode=0o700)
        self.leaf = self.source / "SECRET-private-project.pbxproj"
        self.leaf.write_bytes(b"SECRET-ORIGINAL")
        self.held = B.product_snapshot(self.leaf, self.source)

    def rows(self):
        data = (self.owner / "owned-compilation-boundaries.jsonl").read_bytes()
        self.assertNotIn(b"SECRET", data)
        self.assertNotIn(str(self.base).encode(), data)
        rows = [json.loads(line) for line in data.splitlines()]
        self.assertLessEqual(len(rows), 512)
        self.assertLessEqual(len(data), 131072)
        for row in rows:
            self.assertEqual(
                set(row),
                {
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
                },
            )
        return rows

    def pure(self, identity=None, data=None, path=None):
        old = B.InputFile("private-path", (1, 2, 3, 4, 5, 6, 7, 8), b"private-data")
        new = B.InputFile(
            old.path if path is None else path,
            old.identity if identity is None else identity,
            old.data if data is None else data,
        )
        return old, new

    def test_literal_each_identity_axis_and_whole_closed_order(self):
        old, new = self.pure()
        self.assertEqual(B._product_difference_axes(old, new), ())
        for index, axis in enumerate(AXES):
            identity = list(old.identity)
            identity[index] += 11
            with self.subTest(axis=axis):
                self.assertEqual(
                    B._product_difference_axes(
                        old, B.InputFile(old.path, tuple(identity), old.data)
                    ),
                    (axis,),
                )
        self.assertEqual(
            B._product_difference_axes(
                old, B.InputFile("other", tuple(x + 11 for x in old.identity), b"other")
            ),
            AXES + ("data", "path"),
        )

    def test_literal_data_and_path_axes_only(self):
        old, new = self.pure(data=b"changed")
        self.assertEqual(B._product_difference_axes(old, new), ("data",))
        old, new = self.pure(path="changed")
        self.assertEqual(B._product_difference_axes(old, new), ("path",))

    def test_strict_types_never_invoke_private_comparison(self):
        class Poison(str):
            def __eq__(self, other):
                raise AssertionError("private comparison")

            __hash__ = str.__hash__

        class Foreign(B.InputFile):
            pass

        old, _ = self.pure()
        cases = [
            None,
            object(),
            Foreign(old.path, old.identity, old.data),
            B.InputFile(Poison("secret"), old.identity, old.data),
            B.InputFile(old.path, list(old.identity), old.data),
            B.InputFile(old.path, old.identity[:-1], old.data),
            B.InputFile(old.path, (True,) + old.identity[1:], old.data),
            B.InputFile(old.path, old.identity, bytearray(old.data)),
        ]
        for new in cases:
            with self.subTest(kind=type(new).__name__):
                self.assertEqual(B._product_difference_axes(old, new), ())
                self.assertEqual(B._product_difference_axes(new, old), ())

    def fail_product(self, expected=None):
        error = None
        original_require = B._REQUIRE
        captured = []

        def require(value, code, message):
            try:
                return original_require(value, code, message)
            except B.BASE.NativeBuildError as refused:
                if message == MESSAGE:
                    captured.append(refused)
                raise

        with patch.object(B, "_REQUIRE", side_effect=require):
            with self.assertRaises(B.BASE.NativeBuildError) as caught:
                with B._observe_compilation(self.owner):
                    B.current_product(self.held, self.source)
            error = caught.exception
        self.assertEqual(len(captured), 1)
        self.assertIs(error, captured[0])
        self.assertIs(type(error), B.BASE.NativeBuildError)
        self.assertEqual(error.code, "source_identity")
        self.assertEqual(error.args, (MESSAGE,))
        rows = self.rows()
        refused = [r for r in rows if r["event"] == "refused"]
        self.assertEqual([r["code"] for r in refused], ["source_identity", "held_product_changed"])
        difference = [r for r in rows if r["event"] == "product_difference"]
        self.assertTrue(difference)
        self.assertGreater(min(r["seq"] for r in difference), max(r["seq"] for r in refused))
        self.assertEqual(tuple(r["code"] for r in difference), expected)
        self.assertTrue(
            all(
                r["span"] == 0
                and r["parent"] == 0
                and r["stage"] == "products"
                and r["phase"] == ""
                for r in difference
            )
        )

    def actual_axes(self):
        info = self.leaf.lstat()
        stamp = (
            info.st_dev,
            info.st_ino,
            info.st_uid,
            info.st_mode,
            info.st_nlink,
            info.st_size,
            info.st_mtime_ns,
            info.st_ctime_ns,
        )
        axes = tuple(name for name, old, new in zip(AXES, self.held.identity, stamp) if old != new)
        if self.held.data != self.leaf.read_bytes():
            axes += ("data",)
        return axes

    def test_genuine_same_bytes_chmod_reports_actual_mode_and_time_axes(self):
        original = self.leaf.lstat()
        self.leaf.chmod(0o600 if original.st_mode & 0o777 != 0o600 else 0o640)
        axes = self.actual_axes()
        self.assertIn("mode", axes)
        self.assertNotIn("data", axes)
        self.fail_product(axes)

    def test_genuine_same_bytes_utime_reports_actual_mtime_axes(self):
        info = self.leaf.lstat()
        os.utime(self.leaf, ns=(info.st_atime_ns, info.st_mtime_ns - 1000000000))
        axes = self.actual_axes()
        self.assertIn("mtime", axes)
        self.assertNotIn("data", axes)
        self.fail_product(axes)

    def test_genuine_same_bytes_replacement_reports_actual_inode_axes(self):
        replacement = self.source / "replacement"
        replacement.write_bytes(self.held.data)
        os.replace(replacement, self.leaf)
        axes = self.actual_axes()
        self.assertIn("ino", axes)
        self.assertNotIn("data", axes)
        self.fail_product(axes)

    def test_genuine_content_mutation_reports_data(self):
        self.leaf.write_bytes(b"SECRET-CHANGED!")
        axes = self.actual_axes()
        self.assertIn("data", axes)
        self.fail_product(axes)

    def test_unchanged_read_count_and_no_axis_helper_on_success(self):
        original_open, original_lstat, original_fstat = (
            B.os.open,
            Path.lstat,
            B.os.fstat,
        )
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
            patch.object(
                B,
                "_product_difference_axes",
                side_effect=AssertionError("success observer"),
            ) as axes,
        ):
            with B._observe_compilation(self.owner):
                B.current_product(self.held, self.source)
        axes.assert_not_called()
        self.assertEqual(counts, {"open": 1, "lstat": 2, "fstat": 2})
        self.assertEqual(
            [r["event"] for r in self.rows()],
            ["writer_start", "enter", "complete", "writer_end"],
        )

    def test_observer_failure_preserves_original_instance(self):
        self.leaf.write_bytes(b"SECRET-CHANGED!")
        original_require = B._REQUIRE
        errors = []

        def require(value, code, message):
            try:
                return original_require(value, code, message)
            except B.BASE.NativeBuildError as error:
                if message == MESSAGE:
                    errors.append(error)
                raise

        with (
            patch.object(B, "_REQUIRE", side_effect=require),
            patch.object(
                B,
                "_product_difference_axes",
                side_effect=RuntimeError("SECRET observer"),
            ),
        ):
            with self.assertRaises(B.BASE.NativeBuildError) as caught:
                with B._observe_compilation(self.owner):
                    B.current_product(self.held, self.source)
        self.assertIs(caught.exception, errors[0])
        self.assertEqual(caught.exception.args, (MESSAGE,))
        self.assertFalse([r for r in self.rows() if r["event"] == "product_difference"])

    def test_collided_writer_cannot_change_original_error_or_foreign_bytes(self):
        leaf = self.owner / "owned-compilation-boundaries.jsonl"
        leaf.write_bytes(b"FOREIGN PRIVATE")
        self.leaf.write_bytes(b"SECRET-CHANGED!")
        with self.assertRaises(B.BASE.NativeBuildError) as caught:
            with B._observe_compilation(self.owner):
                B.current_product(self.held, self.source)
        self.assertEqual(caught.exception.args, (MESSAGE,))
        self.assertEqual(leaf.read_bytes(), b"FOREIGN PRIVATE")


if __name__ == "__main__":
    unittest.main(verbosity=2)
