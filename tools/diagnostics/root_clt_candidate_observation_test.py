"""Handwritten portable metadata controls; no native or root admission proof."""

from __future__ import annotations

import ast
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import root_clt_candidate_observation as subject


class CandidateControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clt-metadata-controls-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.clt = self.root / "CommandLineTools"
        self.system = self.root / "system-bin"
        self.system.mkdir()
        for name in ("xcrun", "xcode-select"):
            (self.system / name).write_bytes(b"metadata only; never executed\n")
            (self.system / name).chmod(0o755)
        (self.clt / "usr/bin").mkdir(parents=True)
        self.compiler = self.clt / "usr/bin/clang"
        self.compiler.write_bytes(b"metadata only; never executed\n")
        self.compiler.chmod(0o755)
        self.sdks = self.clt / "SDKs"
        self.sdks.mkdir()
        (self.sdks / "MacOSX15.5.sdk").mkdir()
        (self.sdks / "MacOSX.sdk").symlink_to("MacOSX15.5.sdk")
        self.layout = subject._Layout(self.clt, self.system)

    def observation(self):
        return subject._Observer(self.layout).observe()

    def row(self, report, role, version="default"):
        return next(
            row
            for row in report["rows"]
            if row["role"] == role and row["version"] == version and row["hop"] == 0
        )

    def test_actual_private_metadata_without_authority(self):
        report = self.observation()
        row = self.row(report, "compiler")
        info = self.compiler.lstat()
        self.assertEqual(row["uid"], info.st_uid)
        self.assertEqual(row["mode"], info.st_mode & 0o7777)
        self.assertEqual(row["kind"], "regular")
        self.assertTrue(row["current"])
        self.assertTrue(row["executable"])
        for flag in ("authority", "root_admission", "toolchain_selected"):
            self.assertIs(report[flag], False)
        self.assertEqual(report["native_verdict"], "unchanged")

    def test_missing_clt_blocks_descendants(self):
        shutil.rmtree(self.clt)
        report = self.observation()
        self.assertEqual(self.row(report, "clt")["state"], "missing")
        for role in ("clt_usr", "clt_bin", "compiler", "sdk_directory", "sdk"):
            self.assertEqual(self.row(report, role)["state"], "blocked")
        self.assertIs(report["toolchain_selected"], False)

    def test_missing_compiler_is_not_blocked_or_installed(self):
        self.compiler.unlink()
        report = self.observation()
        row = self.row(report, "compiler")
        self.assertEqual(row["state"], "missing")
        self.assertIsNone(row["uid"])
        self.assertFalse(row["executable"])

    def test_relative_sdk_alias_retains_separate_target(self):
        report = self.observation()
        alias = self.row(report, "sdk")
        targets = [row for row in report["rows"] if row["role"] == "sdk_target"]
        self.assertEqual(alias["kind"], "symlink")
        self.assertEqual(alias["alias"], "within_clt")
        self.assertEqual(len(targets), 1)
        self.assertEqual(targets[0]["version"], "15.5")
        self.assertEqual(targets[0]["kind"], "directory")
        self.assertTrue(targets[0]["current"])

    def test_foreign_alias_refuses_before_target_access(self):
        foreign = self.root / "private-external.sdk"
        foreign.mkdir()
        (self.sdks / "MacOSX.sdk").unlink()
        (self.sdks / "MacOSX.sdk").symlink_to(foreign)
        original = os.lstat
        touched = []
        parent_info = foreign.parent.stat()

        def checked(path, *args, **kwargs):
            descriptor = kwargs.get("dir_fd")
            relative_foreign = False
            if descriptor is not None and Path(path) == Path(foreign.name):
                info = os.fstat(descriptor)
                relative_foreign = (info.st_dev, info.st_ino) == (
                    parent_info.st_dev,
                    parent_info.st_ino,
                )
            if Path(path) == foreign or relative_foreign:
                touched.append(path)
            return original(path, *args, **kwargs)

        with patch.object(subject.os, "lstat", checked):
            with self.assertRaisesRegex(subject.ObservationRefused, "alias_namespace"):
                self.observation()
        self.assertEqual(touched, [])

    def test_alias_cycle_refuses(self):
        (self.sdks / "MacOSX15.5.sdk").rmdir()
        (self.sdks / "MacOSX15.5.sdk").symlink_to("MacOSX.sdk")
        with self.assertRaisesRegex(subject.ObservationRefused, "alias_cycle"):
            self.observation()

    def test_alias_hop_bound_refuses(self):
        (self.sdks / "MacOSX.sdk").unlink()
        (self.sdks / "MacOSX.sdk").symlink_to("MacOSX1.sdk")
        for index in range(1, 10):
            (self.sdks / f"MacOSX{index}.sdk").symlink_to(
                f"MacOSX{index + 1}.sdk" if index < 9 else "MacOSX15.5.sdk"
            )
        with self.assertRaisesRegex(subject.ObservationRefused, "alias_hops"):
            self.observation()

    def test_actual_owner_and_writable_mode_are_observed_only(self):
        self.compiler.chmod(0o777)
        row = self.row(self.observation(), "compiler")
        self.assertEqual(row["uid"], os.getuid())
        self.assertEqual(row["mode"], 0o777)
        self.assertEqual(self.compiler.stat().st_mode & 0o7777, 0o777)

    def test_same_bytes_named_replacement_refuses(self):
        original = subject._Observer._validate

        def changed(observer):
            replacement = self.compiler.with_name("replacement")
            replacement.write_bytes(self.compiler.read_bytes())
            replacement.chmod(0o755)
            replacement.replace(self.compiler)
            return original(observer)

        with patch.object(subject._Observer, "_validate", changed):
            with self.assertRaisesRegex(subject.ObservationRefused, "currentness"):
                self.observation()

    def test_retained_ancestor_replacement_refuses(self):
        original = subject._Observer._validate

        def changed(observer):
            self.sdks.rename(self.clt / "retired-sdk-directory")
            self.sdks.mkdir()
            return original(observer)

        with patch.object(subject._Observer, "_validate", changed):
            with self.assertRaisesRegex(subject.ObservationRefused, "currentness"):
                self.observation()

    def test_reused_descriptor_is_not_closed_as_owned(self):
        original = subject._Observer._validate
        retained = []
        foreign = self.root / "foreign-descriptor"
        foreign.write_bytes(b"foreign")

        def changed(observer):
            descriptor, _ = observer._held[self.compiler]
            source = os.open(foreign, os.O_RDONLY)
            try:
                os.dup2(source, descriptor)
            finally:
                os.close(source)
            retained.append(descriptor)
            return original(observer)

        try:
            with patch.object(subject._Observer, "_validate", changed):
                with self.assertRaisesRegex(subject.ObservationRefused, "currentness"):
                    self.observation()
            self.assertEqual(len(retained), 1)
            self.assertEqual(os.fstat(retained[0]).st_ino, foreign.stat().st_ino)
        finally:
            for descriptor in retained:
                os.close(descriptor)

    def test_ambiguous_close_is_never_retried(self):
        original = os.close
        counts = {}

        def changed(descriptor):
            counts[descriptor] = counts.get(descriptor, 0) + 1
            original(descriptor)
            if len(counts) == 1:
                raise OSError("private exception must not be printed")

        with patch.object(subject.os, "close", changed):
            with self.assertRaisesRegex(subject.ObservationRefused, "close"):
                self.observation()
        self.assertTrue(counts)
        self.assertEqual(set(counts.values()), {1})

    def test_sdk_count_bound_refuses_not_truncates(self):
        for index in range(16):
            (self.sdks / f"MacOSX{index}.sdk").mkdir()
        with self.assertRaisesRegex(subject.ObservationRefused, "sdk_entries"):
            self.observation()

    def test_row_bound_refuses_not_truncates(self):
        observer = subject._Observer(self.layout)
        row = {
            "role": "sdk",
            "version": "15.5",
            "hop": 0,
            "state": "missing",
            "kind": "missing",
            "uid": None,
            "mode": None,
            "executable": False,
            "alias": "none",
            "current": True,
        }
        for _ in range(32):
            observer._append(dict(row))
        with self.assertRaisesRegex(subject.ObservationRefused, "rows"):
            observer._append(dict(row))

    def test_closed_serializer_refuses_private_or_false_authority(self):
        for key, value in (
            ("authority", True),
            ("toolchain_selected", True),
            ("native_verdict", str(self.root)),
        ):
            report = self.observation()
            report[key] = value
            with self.assertRaisesRegex(subject.ObservationRefused, "schema"):
                subject._encode(report)
        report = self.observation()
        report["rows"][0]["role"] = str(self.root)
        with self.assertRaisesRegex(subject.ObservationRefused, "schema"):
            subject._encode(report)

    def test_output_bound_refuses_without_emitting(self):
        report = self.observation()
        with patch.object(subject.json, "dumps", return_value="x" * 8193):
            with self.assertRaisesRegex(subject.ObservationRefused, "output_bytes"):
                subject._encode(report)

    def test_no_external_execution_and_no_cli_path_override(self):
        source = Path(subject.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        forbidden = {"subprocess", "ctypes", "pexpect", "multiprocessing"}
        for node in ast.walk(tree):
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                names = (
                    [item.name for item in node.names]
                    if isinstance(node, ast.Import)
                    else [node.module or ""]
                )
                self.assertFalse(any(name.split(".")[0] in forbidden for name in names))
            if isinstance(node, ast.Call):
                name = getattr(node.func, "attr", getattr(node.func, "id", ""))
                self.assertNotIn(
                    name, {"system", "popen", "Popen", "fork", "exec", "eval", "chown"}
                )
                self.assertFalse(name.startswith(("execv", "spawn")))
        with (
            patch.object(subject.os, "system", side_effect=AssertionError("external execution")),
            patch.object(subject.os, "popen", side_effect=AssertionError("external execution")),
        ):
            self.observation()
        with contextlib.redirect_stderr(io.StringIO()) as output:
            self.assertEqual(subject.main([str(self.root)]), 64)
        self.assertNotIn(str(self.root), output.getvalue())

    def test_refusal_reason_is_closed_and_private(self):
        with (
            patch.object(subject.sys, "platform", "darwin"),
            patch.object(subject._Observer, "observe", side_effect=OSError(str(self.root))),
            contextlib.redirect_stderr(io.StringIO()) as output,
        ):
            self.assertEqual(subject.main([]), 1)
        self.assertEqual(output.getvalue(), "CLT_CANDIDATE_OBSERVATION_REFUSED io\n")
        self.assertLessEqual(len(output.getvalue().encode()), 512)

    def test_actual_default_native_and_portable_registration(self):
        swift = (
            Path(__file__).parents[2]
            / "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274CommandLineToolsCandidateObservationTests.swift"
        )
        text = swift.read_text(encoding="utf-8")
        self.assertIn("func testActualCommandLineToolsCandidateMetadataObservation()", text)
        self.assertIn("func testPortableCommandLineToolsCandidateMetadataControls()", text)
        self.assertEqual(text.count("let parent = try compilationEvidenceParent()"), 2)
        self.assertEqual(text.count("try fixture(parent: parent)"), 2)
        self.assertIn('[[], ["-O"]]', text)
        self.assertIn('source("root_clt_candidate_observation.py")', text)
        self.assertIn('source("root_clt_candidate_observation_test.py")', text)
        self.assertIn(
            'let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n'
            '\t\t\t\t["python3", source("root_clt_candidate_observation.py").path], root: root)',
            text,
        )
        self.assertIn(
            'let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n'
            '\t\t\t\t\t["python3"] + flags + [source("root_clt_candidate_observation_test.py").path], root: root)',
            text,
        )
        self.assertIn('XCTAssertEqual(result["tests"] as? Int, 20)', text)
        self.assertIn('XCTAssertEqual(result["executed"] as? Int, 20)', text)
        self.assertIn('XCTAssertEqual(result["skipped"] as? Int, 0)', text)
        tree = ast.parse(Path(__file__).read_text(encoding="utf-8"))
        registration = next(
            node
            for node in tree.body
            if isinstance(node, ast.If) and isinstance(node.test, ast.Compare)
        )
        self.assertTrue(
            any(
                isinstance(node, ast.Call) and getattr(node.func, "id", "") == "main"
                for node in ast.walk(registration)
            )
        )

    def test_final_alias_read_refuses_late_retained_ancestor_replacement(self):
        original = subject._Observer._readlink
        alias = self.sdks / "MacOSX.sdk"
        returned = []
        changed = []

        def late(observer, path):
            raw = original(observer, path)
            if path == alias:
                returned.append(raw)
                if len(returned) == 2:
                    # Real filesystem replacement after the original final alias read.
                    self.sdks.rename(self.clt / "retired-sdk-directory")
                    self.sdks.mkdir()
                    changed.append(True)
            return raw

        with patch.object(subject._Observer, "_readlink", late):
            with self.assertRaisesRegex(subject.ObservationRefused, "currentness"):
                self.observation()
        self.assertEqual(returned, ["MacOSX15.5.sdk", "MacOSX15.5.sdk"])
        self.assertEqual(changed, [True])


def main():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(CandidateControls)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    report = {
        "schema": 1,
        "tests": result.testsRun,
        "executed": result.testsRun - len(result.skipped),
        "skipped": len(result.skipped),
        "failures": len(result.failures),
        "errors": len(result.errors),
        "native": "unexecuted",
    }
    print(json.dumps(report, sort_keys=True))
    return 0 if result.wasSuccessful() and result.testsRun == 20 and not result.skipped else 1


if __name__ == "__main__":
    raise SystemExit(main())
