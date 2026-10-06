# tools/diagnostics/hs274_native_build_transport_observation_test.py
"""Portable controls for closed transport metadata; native transport is unexecuted."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "baseline_original_controls", HERE / "hs274_native_build_observation_test.py"
)
OLD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OLD)
OBS = OLD.OBS
KINDS = (
    "http_status",
    "tls_certificate_verification",
    "os_error",
    "tls_error",
    "timeout",
    "dns_resolution",
    "connection_refused",
    "connection_reset",
    "connection_error",
    "protocol_error",
    "other_transport",
    "deadline",
)
KEYS = {
    "schema",
    "kind",
    "status",
    "native_verdict",
    "authority",
    "acquisition_stage",
    "transport_kind",
    "http_status",
    "verify_code",
    "errno",
}
UNSUPPORTED = {
    "schema": 1,
    "kind": "xcodegen_transport_observation",
    "status": "unsupported",
    "native_verdict": "unchanged",
    "authority": False,
    "acquisition_stage": None,
    "transport_kind": None,
    "http_status": None,
    "verify_code": None,
    "errno": None,
}


class TransportControls(unittest.TestCase):
    def setUp(self):
        self.fixture = OLD.ObservationControls()
        self.fixture.setUp()
        self.owner = self.fixture.owner

    def tearDown(self):
        self.fixture.tearDown()

    def refusal(self, diagnostic=None, stage="metadata"):
        if not (self.owner / "xcode_version.begin.json").exists():
            self.fixture.prefix(1)
            self.fixture.phase("xcodegen_acquisition", "refused")
        path = self.owner / "xcodegen_acquisition.receipt.json"
        record = json.loads(path.read_bytes())
        record["acquisition_stage"] = stage
        if diagnostic is not None:
            record["transport_diagnostic"] = diagnostic
        path.write_text(json.dumps(record))
        return path

    def expected(self, kind, stage="metadata", **values):
        return {
            **UNSUPPORTED,
            "status": "observed",
            "acquisition_stage": stage,
            "transport_kind": kind,
            **values,
        }

    def sibling(self):
        return OBS.observe(self.owner, transport_only=True)

    def refused(self):
        with self.assertRaises(OBS.UnsupportedObservation):
            self.sibling()

    def cli(self, status="124", mode="--transport", script=None):
        flags = ["-O"] if sys.flags.optimize else []
        return subprocess.run(
            [sys.executable, *flags, str(script or OLD.PATH), str(self.owner), status, mode],
            capture_output=True,
            timeout=10,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )

    def test_01_default_schema_unchanged(self):
        self.refusal({"kind": "http_status", "http_status": 403})
        value = OBS.observe(self.owner)
        self.assertEqual(
            set(value),
            {
                "schema",
                "kind",
                "status",
                "native_verdict",
                "authority",
                "last_recorded_phase",
                "rows",
            },
        )
        self.assertNotIn("403", OBS.render(value))
        self.assertNotIn("transport", OBS.render(value))

    def test_02_http_literal(self):
        self.refusal({"kind": "http_status", "http_status": 403})
        self.assertEqual(self.sibling(), self.expected("http_status", http_status=403))

    def test_03_tls_literal(self):
        self.refusal({"kind": "tls_certificate_verification", "verify_code": 7}, "archive")
        self.assertEqual(
            self.sibling(), self.expected("tls_certificate_verification", "archive", verify_code=7)
        )

    def test_04_errno_literal(self):
        self.refusal({"kind": "os_error", "errno": 113})
        self.assertEqual(self.sibling(), self.expected("os_error", errno=113))

    def test_05_kind_only(self):
        for kind in KINDS:
            with self.subTest(kind=kind):
                self.refusal({"kind": kind})
                self.assertEqual(self.sibling(), self.expected(kind))

    def test_06_inclusive_bounds(self):
        for kind, key, values in [
            ("http_status", "http_status", (100, 599)),
            ("tls_certificate_verification", "verify_code", (0, 2147483647)),
            ("os_error", "errno", (1, 4095)),
        ]:
            for number in values:
                with self.subTest(kind=kind, number=number):
                    self.refusal({"kind": kind, key: number})
                    self.assertEqual(self.sibling(), self.expected(kind, **{key: number}))

    def test_07_numeric_types_and_range(self):
        for kind, key, values in [
            ("http_status", "http_status", (True, 403.0, 99, 600, None)),
            ("tls_certificate_verification", "verify_code", (False, 7.0, -1, 2147483648, None)),
            ("os_error", "errno", (True, 113.0, 0, 4096, None)),
        ]:
            for number in values:
                with self.subTest(kind=kind, number=number):
                    self.refusal({"kind": kind, key: number})
                    self.refused()

    def test_08_cross_kind_and_private_fields(self):
        for value in [
            {"kind": "timeout", "errno": 7},
            {"kind": "http_status", "verify_code": 7},
            {"kind": "http_status", "http_status": 403, "url": "https://PRIVATE"},
            {"kind": "os_error", "errno": 7, "message": "SECRET"},
        ]:
            self.refusal(value)
            self.refused()

    def test_09_unknown_kind(self):
        for value in [{"kind": "unknown"}, {"kind": True}, {"kind": None}, {"kind": []}]:
            self.refusal(value)
            with self.assertRaises((OBS.UnsupportedObservation, TypeError)):
                self.sibling()
            self.assertEqual(json.loads(self.cli().stdout), UNSUPPORTED)

    def test_10_duplicate_key(self):
        path = self.refusal({"kind": "http_status", "http_status": 403})
        data = path.read_bytes()
        path.write_bytes(
            data.replace(b'"http_status": 403', b'"http_status": 403, "http_status": 403')
        )
        self.refused()

    def test_11_missing_diagnostic(self):
        self.refusal()
        self.assertEqual(self.sibling(), UNSUPPORTED)

    def test_12_passed_not_transport_failure(self):
        self.fixture.prefix(2)
        self.assertEqual(self.sibling(), UNSUPPORTED)

    def test_13_pending_not_transport_failure(self):
        self.fixture.prefix(1)
        self.fixture.record(
            "xcodegen_acquisition.begin.json",
            {"schema": 1, "phase": "xcodegen_acquisition", "status": "pending"},
        )
        self.assertEqual(self.sibling(), UNSUPPORTED)

    def test_14_missing_not_transport_failure(self):
        self.assertEqual(self.sibling(), UNSUPPORTED)

    def test_15_suffix_refused(self):
        self.refusal({"kind": "timeout"})
        self.fixture.phase("xcodegen_version")
        self.refused()

    def test_16_symlink_refused(self):
        path = self.refusal({"kind": "timeout"})
        path.rename(self.owner / "saved")
        path.symlink_to("saved")
        self.refused()

    def test_17_late_record_recut(self):
        path = self.refusal({"kind": "http_status", "http_status": 403})
        actual_leaf = OBS.leaf
        facts = []

        def sampled(directory, name, capture, retained):
            value = actual_leaf(directory, name, capture, retained)
            if name == "cli_build.stderr":
                path.write_bytes(path.read_bytes() + b" ")
                facts.append(True)
            return value

        with mock.patch.object(OBS, "leaf", side_effect=sampled):
            self.refused()
        self.assertEqual(facts, [True])

    def test_18_no_capture_read_or_reflection(self):
        self.refusal({"kind": "http_status", "http_status": 403})
        path = self.owner / "xcode_version.stdout"
        path.write_bytes(b"SECRET_TOKEN /private/path https://PRIVATE")
        inode = path.stat().st_ino
        actual_read = os.read
        reads = []

        def read(descriptor, size):
            reads.append(os.fstat(descriptor).st_ino)
            return actual_read(descriptor, size)

        with mock.patch.object(OBS.os, "read", side_effect=read):
            body = OBS.render(self.sibling())
        self.assertNotIn(inode, reads)
        self.assertNotIn("SECRET", body)
        self.assertNotIn("private", body)
        self.assertNotIn("https", body)

    def test_19_cli_observed(self):
        self.refusal({"kind": "http_status", "http_status": 403})
        result = self.cli()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(json.loads(result.stdout), self.expected("http_status", http_status=403))

    def test_20_cli_invalid_or_success_status(self):
        self.refusal({"kind": "http_status", "http_status": 403})
        for status in ["0", "True", "01", "2147483648"]:
            result = self.cli(status=status)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stderr, b"")
            self.assertEqual(json.loads(result.stdout), UNSUPPORTED)

    def test_21_unknown_mode_original_unsupported(self):
        result = self.cli(mode="--foreign")
        self.assertEqual(result.stdout.decode(), OLD.UNSUPPORTED)
        self.assertEqual(result.stderr, b"")

    def test_22_changed_source_refused(self):
        self.refusal({"kind": "timeout"})
        repository = HERE.parents[1]
        private = self.owner.parent / "reader"
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
        builder.write_bytes(builder.read_bytes() + b"\n# independently changed source\n")
        result = self.cli(script=private / "tools/diagnostics/hs274_native_build_observation.py")
        self.assertEqual(json.loads(result.stdout), UNSUPPORTED)
        self.assertEqual(result.stderr, b"")

    def test_23_no_read_without_retirement(self):
        read = mock.Mock(side_effect=AssertionError("unretired must not read"))
        self.assertEqual(OBS.retired_failure(124, False, read), (124, None))
        self.assertEqual(OBS.retired_failure(0, True, read), (0, None))
        read.assert_not_called()

    def test_24_closed_and_bounded(self):
        self.refusal({"kind": "tls_certificate_verification", "verify_code": 2147483647})
        value = self.sibling()
        self.assertEqual(set(value), KEYS)
        self.assertIs(value["authority"], False)
        self.assertEqual(value["native_verdict"], "unchanged")
        self.assertLessEqual(len(OBS.render(value).encode("ascii")), 2048)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TransportControls)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.testsRun == 24 and result.wasSuccessful() and not result.skipped:
        print("PASS portable transport observation tests=24 failures=0 errors=0 skipped=0")
    else:
        raise SystemExit(1)
