# tools/diagnostics/hs274_native_build_observation_test.py
"""Independent fixed controls for passive retired-baseline observations."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

PATH = Path(__file__).with_name("hs274_native_build_observation.py")
SPEC = importlib.util.spec_from_file_location("baseline_observation_controls", PATH)
OBS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OBS)
# Frozen before implementation; the production reader imports the one canonical roster.
EXPECTED_PHASES = (
    "xcode_version",
    "xcodegen_acquisition",
    "xcodegen_version",
    "sdk_path",
    "acquisition",
    "checkout",
    "submodules",
    "identity_upstream",
    "identity_cpm",
    "identity_vhd",
    "source_clean",
    "version",
    "instrumentation",
    "duktape_generate",
    "duktape_build",
    "core_generate",
    "core_build",
    "cli_generate",
    "cli_build",
)
UNSUPPORTED = (
    '{"authority":false,"kind":"baseline_phase_observations",'
    '"last_recorded_phase":null,"native_verdict":"unchanged","rows":[],"schema":1,'
    '"status":"unsupported"}\n'
)


class ObservationControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.owner = Path(self.temporary.name).resolve() / "baseline"
        self.owner.mkdir(mode=0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, name, data):
        path = self.owner / name
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        return path

    def record(self, name, value):
        return self.write(name, json.dumps(value, allow_nan=False).encode())

    def phase(self, name, status="passed", exit_status=0, elapsed=1.25):
        self.record(name + ".begin.json", {"schema": 1, "phase": name, "status": "pending"})
        row = {"schema": 1, "phase": name, "status": status, "elapsed_seconds": elapsed}
        if name == "xcodegen_acquisition":
            if status == "passed":
                row.update(
                    operation="verified-HTTPS-download-and-ordinary-extraction",
                    child_process_executed=False,
                )
            else:
                row.update(code="xcodegen_transport", acquisition_stage="metadata")
        elif status != "launch_refused":
            row["exit_status"] = exit_status
        self.record(name + ".receipt.json", row)
        if name != "xcodegen_acquisition":
            self.write(name + ".stdout", b"")
            self.write(name + ".stderr", b"")

    def prefix(self, count):
        for name in EXPECTED_PHASES[:count]:
            self.phase(name)

    def refused(self):
        with self.assertRaises(OBS.UnsupportedObservation):
            OBS.observe(self.owner)

    def cli(self, owner=None, status="124", script=PATH):
        environment = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
        flags = ["-O"] if sys.flags.optimize else []
        return subprocess.run(
            [sys.executable, *flags, str(script), str(owner or self.owner), status],
            capture_output=True,
            timeout=10,
            env=environment,
        )

    def test_01_healthy19(self):
        self.prefix(19)
        value = OBS.observe(self.owner)
        expected = [
            [
                name,
                "passed",
                *(["not-produced", "not-produced"] if name == "xcodegen_acquisition" else [0, 0]),
            ]
            for name in EXPECTED_PHASES
        ]
        self.assertEqual(value["rows"], expected)
        self.assertEqual(value["last_recorded_phase"], "cli_build")
        self.assertIs(value["authority"], False)
        self.assertEqual(value["native_verdict"], "unchanged")
        child = self.cli()
        self.assertEqual(child.returncode, 0)
        self.assertEqual(child.stderr, b"")
        self.assertEqual(json.loads(child.stdout), value)

    def test_02_all_missing(self):
        value = OBS.observe(self.owner)
        self.assertIsNone(value["last_recorded_phase"])
        self.assertEqual(
            value["rows"],
            [
                [
                    name,
                    "absent",
                    *(
                        ["not-produced", "not-produced"]
                        if name == "xcodegen_acquisition"
                        else ["missing", "missing"]
                    ),
                ]
                for name in EXPECTED_PHASES
            ],
        )

    def test_03_prefix_then_unfinished(self):
        self.prefix(1)
        self.record(
            "xcodegen_acquisition.begin.json",
            {"schema": 1, "phase": "xcodegen_acquisition", "status": "pending"},
        )
        value = OBS.observe(self.owner)
        self.assertEqual(value["last_recorded_phase"], "xcodegen_acquisition")
        self.assertEqual(
            value["rows"][1], ["xcodegen_acquisition", "begun", "not-produced", "not-produced"]
        )

    def test_04_unfinished_process_capture(self):
        self.prefix(4)
        self.record(
            "acquisition.begin.json", {"schema": 1, "phase": "acquisition", "status": "pending"}
        )
        self.write("acquisition.stdout", b"SECRET")
        self.write("acquisition.stderr", b"opaque")
        value = OBS.observe(self.owner)
        self.assertEqual(value["rows"][4], ["acquisition", "begun", 6, 6])
        self.assertEqual(value["last_recorded_phase"], "acquisition")

    def test_05_process_failure(self):
        self.prefix(5)
        self.phase("checkout", "failed", 7)
        value = OBS.observe(self.owner)
        self.assertEqual(value["rows"][5], ["checkout", "failed", 0, 0])
        self.assertEqual(value["last_recorded_phase"], "checkout")

    def test_06_deadline_refused(self):
        self.prefix(5)
        self.phase("checkout", "refused", 0, 301.25)
        value = OBS.observe(self.owner)
        self.assertEqual(value["rows"][5], ["checkout", "refused", 0, 0])
        self.assertNotIn("301.25", OBS.render(value))

    def test_07_launch_refused(self):
        self.prefix(5)
        self.phase("checkout", "launch_refused")
        (self.owner / "checkout.stderr").unlink()
        value = OBS.observe(self.owner)
        self.assertEqual(value["rows"][5], ["checkout", "launch_refused", 0, "missing"])

    def test_08_tool_refused(self):
        self.prefix(1)
        self.phase("xcodegen_acquisition", "refused")
        path = self.owner / "xcodegen_acquisition.receipt.json"
        record = json.loads(path.read_bytes())
        record["transport_diagnostic"] = {"kind": "tls_certificate_verification", "verify_code": 7}
        path.write_text(json.dumps(record))
        value = OBS.observe(self.owner)
        self.assertEqual(
            value["rows"][1], ["xcodegen_acquisition", "refused", "not-produced", "not-produced"]
        )
        self.assertNotIn("verify_code", OBS.render(value))
        self.assertNotIn("xcodegen_transport", OBS.render(value))

    def test_09_empty_capture(self):
        self.phase("xcode_version")
        value = OBS.observe(self.owner)
        self.assertEqual(value["rows"][0][2:], [0, 0])
        (self.owner / "xcode_version.stderr").unlink()
        self.refused()

    def test_10_capture_limit(self):
        self.phase("xcode_version")
        path = self.owner / "xcode_version.stdout"
        with path.open("r+b") as stream:
            stream.truncate(33554432)
        self.assertEqual(OBS.observe(self.owner)["rows"][0][2], 33554432)
        with path.open("r+b") as stream:
            stream.truncate(33554433)
        self.refused()

    def test_11_metadata_limit(self):
        self.phase("xcode_version")
        path = self.owner / "xcode_version.begin.json"
        body = path.read_bytes()
        path.write_bytes(body + b" " * (4096 - len(body)))
        self.assertEqual(OBS.observe(self.owner)["rows"][0][1], "passed")
        path.write_bytes(path.read_bytes() + b" ")
        self.refused()

    def test_12_nonfinite_elapsed(self):
        self.phase("xcode_version")
        path = self.owner / "xcode_version.receipt.json"
        original = path.read_bytes()
        for token in [b"NaN", b"Infinity", b"-1", b"true"]:
            with self.subTest(token=token):
                path.write_bytes(original.replace(b"1.25", token))
                self.refused()
        path.write_bytes(b"\xff")
        with self.assertRaises(UnicodeDecodeError):
            OBS.observe(self.owner)
        result = self.cli()
        self.assertEqual(result.stdout.decode(), UNSUPPORTED)
        self.assertEqual(result.stderr, b"")

    def test_13_bad_integer(self):
        self.phase("xcode_version")
        path = self.owner / "xcode_version.receipt.json"
        original = json.loads(path.read_bytes())
        for key, values in [("schema", [True, 1.0]), ("exit_status", [True, 0.0, 7, 2**31])]:
            for value in values:
                with self.subTest(key=key, value=value):
                    record = {**original, key: value}
                    path.write_text(json.dumps(record))
                    self.refused()

    def test_14_duplicate_key(self):
        self.phase("xcode_version")
        path = self.owner / "xcode_version.begin.json"
        samples = [
            b'{"schema":1,"phase":"xcode_version","status":"pending","status":"pending"}',
            b'{"schema":1,"phase":"xcode_version","status":"pending","sta\\u0074us":"pending"}',
            b'{"schema":1,"phase":"foreign","status":"pending"}',
            b'{"schema":1,"phase":"xcode_version","status":"foreign"}',
            b'{"schema":1,"phase":"xcode_version","status":"pending","unknown":1}',
        ]
        for data in samples:
            path.write_bytes(data)
            self.refused()
        path.write_bytes(b'{"schema":1,"phase":"xcode_version","status":"pending"}x')
        with self.assertRaises(ValueError):
            OBS.observe(self.owner)

    def test_15_gap_or_receipt_no_begin(self):
        self.phase("checkout")
        self.refused()
        shutil.rmtree(self.owner)
        self.owner.mkdir(mode=0o700)
        self.phase("xcode_version")
        (self.owner / "xcode_version.begin.json").unlink()
        self.refused()

    def test_16_suffix_after_failure(self):
        self.phase("xcode_version", "failed", 7)
        self.phase("xcodegen_acquisition")
        self.refused()

    def test_17_symlink_or_special(self):
        self.phase("xcode_version")
        path = self.owner / "xcode_version.stdout"
        path.unlink()
        path.symlink_to("xcode_version.stderr")
        self.refused()
        path.unlink()
        os.mkfifo(path, 0o600)
        self.refused()
        path.unlink()
        os.link(self.owner / "xcode_version.stderr", path)
        self.refused()
        path.unlink()
        (self.owner / "xcode_version.stderr").chmod(0o644)
        self.refused()
        alias = self.owner.parent / "alias"
        alias.symlink_to(self.owner, target_is_directory=True)
        with self.assertRaises(OBS.UnsupportedObservation):
            OBS.observe(alias)

    def test_18_file_race(self):
        self.phase("xcode_version")
        actual_open = os.open
        target = self.owner / "xcode_version.begin.json"
        fired = False

        def opened(name, flags, *args, **kwargs):
            nonlocal fired
            descriptor = actual_open(name, flags, *args, **kwargs)
            if name == "xcode_version.begin.json" and not fired:
                fired = True
                target.write_bytes(target.read_bytes() + b" ")
            return descriptor

        with mock.patch.object(OBS.os, "open", side_effect=opened):
            self.refused()
        self.assertTrue(fired)
        # A later phase cannot hide replacement of an already sampled capture.
        original_leaf = OBS.leaf
        fired = False

        def sampled(directory, name, capture, retained):
            nonlocal fired
            result = original_leaf(directory, name, capture, retained)
            if name == "xcodegen_acquisition.begin.json" and not fired:
                fired = True
                path = self.owner / "xcode_version.stdout"
                path.unlink()
                self.write(path.name, b"late")
            return result

        with mock.patch.object(OBS, "leaf", side_effect=sampled):
            self.refused()
        self.assertTrue(fired)

    def test_19_directory_race(self):
        self.phase("xcode_version")
        original_leaf = OBS.leaf
        fired = False

        def sampled(directory, name, capture, retained):
            nonlocal fired
            result = original_leaf(directory, name, capture, retained)
            if name == "cli_build.stderr" and not fired:
                fired = True
                self.owner.rename(self.owner.parent / "old")
                self.owner.mkdir(mode=0o700)
            return result

        with mock.patch.object(OBS, "leaf", side_effect=sampled):
            self.refused()
        self.assertTrue(fired)

    def test_20_no_exit_ack(self):
        read = mock.Mock(side_effect=AssertionError("must not read without retirement"))
        self.assertEqual(OBS.retired_failure(124, False, read), (124, None))
        read.assert_not_called()
        result = self.cli(status="unretired")
        self.assertEqual(result.stdout.decode(), UNSUPPORTED)
        self.assertEqual(result.stderr, b"")

    def test_21_reader_refusal(self):
        result = self.cli(status="True")
        self.assertEqual(result.stdout.decode(), UNSUPPORTED)
        self.assertEqual(result.stderr, b"")
        repository = Path(__file__).resolve().parents[2]
        private = self.owner.parent / "reader-source"
        for relative in [
            "tools/diagnostics/hs274_native_build_observation.py",
            "tools/diagnostics/hs274_native_build.py",
            "tools/build/remap_runtime_build.py",
        ]:
            destination = private / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(repository / relative, destination)
            destination.chmod(0o600)
        builder = private / "tools/build/remap_runtime_build.py"
        builder.write_bytes(builder.read_bytes() + b"\n# changed before passive source admission\n")
        result = self.cli(script=private / "tools/diagnostics/hs274_native_build_observation.py")
        self.assertEqual(result.stdout.decode(), UNSUPPORTED)
        self.assertEqual(result.stderr, b"")

        # Only literal pinned data are consumed. Even the accepted helper may
        # not execute engine/backend code while observing an empty owner.
        with mock.patch("builtins.exec", side_effect=AssertionError("engine executed")) as executed:
            self.assertEqual(OBS.observe(self.owner)["status"], "observed")
            executed.assert_not_called()
        shutil.copyfile(repository / "tools/build/remap_runtime_build.py", builder)
        backend = private / "tools/diagnostics/hs274_native_build.py"
        before_backend = backend.read_bytes()
        source_image = OBS.source_image

        def changed_after_read(path, wanted, sources):
            data = source_image(path, wanted, sources)
            if path.name == "hs274_native_build.py":
                path.write_bytes(data + b"\n# changed after admitted source buffer\n")
            return data

        with mock.patch.object(
            OBS, "__file__", str(private / "tools/diagnostics/hs274_native_build_observation.py")
        ):
            with mock.patch.object(OBS, "source_image", side_effect=changed_after_read):
                self.refused()
            backend.write_bytes(before_backend)
            original_leaf = OBS.leaf
            fired = False

            def changed_during_sample(directory, name, capture, retained):
                nonlocal fired
                result = original_leaf(directory, name, capture, retained)
                if not fired:
                    fired = True
                    builder.write_bytes(
                        builder.read_bytes() + b"\n# changed during metadata observation\n"
                    )
                return result

            with mock.patch.object(OBS, "leaf", side_effect=changed_during_sample):
                self.refused()
            self.assertTrue(fired)

    def test_22_secrets_reflection(self):
        self.phase("xcode_version")
        path = self.owner / "xcode_version.stdout"
        path.write_bytes(b"SECRET_TOKEN=must-never-leave-private-capture /private/path 123456")
        capture_inodes = {path.stat().st_ino, (self.owner / "xcode_version.stderr").stat().st_ino}
        actual_read = os.read

        def read(descriptor, size):
            self.assertNotIn(os.fstat(descriptor).st_ino, capture_inodes)
            return actual_read(descriptor, size)

        with mock.patch.object(OBS.os, "read", side_effect=read):
            body = OBS.render(OBS.observe(self.owner))
        for value in ["SECRET", "/private/path", "123456", "elapsed", "stdout"]:
            self.assertNotIn(value, body)
        self.write("arbitrary.SECRET", b"not observed")
        self.assertEqual(body, OBS.render(OBS.observe(self.owner)))

    def test_23_public_bound(self):
        self.prefix(19)
        for phase in EXPECTED_PHASES:
            if phase != "xcodegen_acquisition":
                for channel in ["stdout", "stderr"]:
                    with (self.owner / (phase + "." + channel)).open("r+b") as stream:
                        stream.truncate(33554432)
        body = OBS.render(OBS.observe(self.owner))
        self.assertLessEqual(len(body.encode()), 2048)
        self.assertEqual(len(json.loads(body)["rows"]), 19)
        with self.assertRaises(OBS.UnsupportedObservation):
            OBS.render({"unexpected": "x" * 2048})

    def test_24_healthy_path_conservation(self):
        read = mock.Mock(side_effect=AssertionError("healthy baseline must not observe"))
        self.assertEqual(OBS.retired_failure(0, True, read), (0, None))
        read.assert_not_called()
        result = self.cli(status="0")
        self.assertEqual(result.stdout.decode(), UNSUPPORTED)

    def test_25_nonzero_guard_conservation(self):
        for status in [124, 7]:
            unchanged, summary = OBS.retired_failure(status, True, lambda: OBS.observe(self.owner))
            self.assertEqual(unchanged, status)
            self.assertEqual(json.loads(summary)["native_verdict"], "unchanged")
            unchanged, summary = OBS.retired_failure(
                status, True, mock.Mock(side_effect=RuntimeError("SECRET"))
            )
            self.assertEqual(unchanged, status)
            self.assertEqual(summary, UNSUPPORTED)
        swift = Path(__file__).resolve().parents[2] / (
            "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274OwnedRuntimeCompilationTests.swift"
        )
        body = swift.read_text()
        returned = body.index("let baselineReceipt = try runSourceCompilation(")
        status_assert = body.index("XCTAssertEqual(baselineReceipt.status, 0,", returned)
        stderr_assert = body.index("XCTAssertTrue(baselineReceipt.stderr.isEmpty)", status_assert)
        branch = body.index("if baselineReceipt.status != 0 {", stderr_assert)
        call = body.index("String(baselineReceipt.status)", branch)
        guard = body.index(
            "guard baselineReceipt.status == 0, baselineReceipt.stderr.isEmpty else { return }",
            call,
        )
        owned = body.index("let compiled = try runOwnedRuntimeCompilation(", guard)
        self.assertLess(returned, status_assert)
        self.assertLess(stderr_assert, branch)
        self.assertLess(call, guard)
        self.assertLess(guard, owned)
        self.assertIn(
            "let admitted = admittedBaselineSummary(observation.stdout)", body[call:guard]
        )
        self.assertNotIn("print(observation.stdout", body[call:guard])
        self.assertIn("canonical + Data([10]) == data", body)
        self.assertIn("XCTAssertNil(admittedBaselineSummary", body)
        self.assertNotIn("hasPrefix", body)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ObservationControls)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.testsRun != 25 or result.failures or result.errors or result.skipped:
        raise SystemExit(1)
    print("PASS portable baseline observation tests=25 failures=0 errors=0 skipped=0")
