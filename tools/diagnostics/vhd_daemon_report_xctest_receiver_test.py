"""Portable negative controls for the daemon-report receiver, never native credit."""

import copy
import hashlib
import importlib.util
import importlib.machinery
import json
import os
import py_compile
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


PATH = Path(__file__).with_name("vhd_daemon_report_xctest_receiver.py")
SPEC = importlib.util.spec_from_file_location("vhd_report_receiver_controls", PATH)
RECEIVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RECEIVER)
CATALOGUE = PATH.parent / "fixtures/vhd-daemon-report-xctest-cases.json"
FROZEN_ORIGINAL_SHA = "8af2825efae3d744eb2c967979af8f2a5d64b89a9ac4c62f8cca80598a23c3cc"
SHA = "a" * 40


def model_frame():
    """Explicit modeled metadata only; no Git or source-authentication stub runs."""
    names = [
        RECEIVER.SELF,
        RECEIVER.SUPERVISOR,
        RECEIVER.CATALOGUE,
        RECEIVER.PACKAGE + "/Package.swift",
    ]
    names += [
        RECEIVER.PACKAGE + "/Tests/ErgoptiPlusTests/" + name
        for name in (
            "OwnedVirtualHIDDaemonReportTests.swift",
            "OwnedVirtualHIDDaemonReportWorkerTests.swift",
            "OwnedVirtualHIDDaemonReportMainOperationTests.swift",
        )
    ]
    names += list(RECEIVER.EXTERNAL_COMPILER_HEADERS)
    return {
        "head": SHA,
        "files": [{"path": name, "blob": "b" * 40, "sha256": "c" * 64} for name in names],
    }


def transcript(names, *, brackets=False):
    """Construct controlled XCTest rows from the frozen case requirement catalogue."""
    lines = ["Test Suite 'Selected tests' started at 2026-10-15 00:00:00.000."]
    for name in names:
        classname, method = name.split(".")
        identity = (
            "-[ErgoptiPlusTests." + classname + " " + method + "]"
            if brackets
            else "ErgoptiPlusTests." + name
        )
        lines += [
            "Test Case '" + identity + "' started.",
            "Test Case '" + identity + "' passed (0.001 seconds).",
        ]
    lines += [
        "Test Suite 'Selected tests' passed at 2026-10-15 00:00:00.032.",
        "Executed "
        + str(len(names))
        + " tests, with 0 failures (0 unexpected) in 0.032 (0.033) seconds",
    ]
    return ("\n".join(lines) + "\n").encode()


class ReceiverJudgeControls(unittest.TestCase):
    def setUp(self):
        self.value = json.loads(CATALOGUE.read_bytes())
        self.names = tuple(self.value["original_cases"] + self.value["additional_cases"])
        frame = model_frame()
        self.metadata = dict(
            swift_status=0,
            capture_status=0,
            retired=True,
            requested_sha=SHA,
            before=frame,
            after=copy.deepcopy(frame),
            architecture="arm64",
            observed_architecture="arm64",
        )

    def judge(self, log=None, **changes):
        return RECEIVER.judge(
            transcript(self.names) if log is None else log,
            self.names,
            **{**self.metadata, **changes},
        )

    def test_original_32_oracle_is_whole_and_four_classes_are_enrolled(self):
        encoded = json.dumps(self.value["original_cases"], separators=(",", ":")).encode()
        self.assertEqual(hashlib.sha256(encoded).hexdigest(), FROZEN_ORIGINAL_SHA)
        self.assertEqual(len(self.value["original_cases"]), 32)
        self.assertEqual(set(name.split(".")[0] for name in self.names), set(RECEIVER.CLASSES))
        self.assertEqual(RECEIVER.catalogue(CATALOGUE.read_bytes()), self.names)

    def test_complete_pairing_with_real_spelling_variants_and_crlf(self):
        for brackets in (False, True):
            with self.subTest(brackets=brackets):
                log = transcript(tuple(reversed(self.names)), brackets=brackets).replace(
                    b"\n", b"\r\n"
                )
                verdict = self.judge(log)
                self.assertTrue(verdict["passed"])
                self.assertEqual(verdict["received_count"], len(self.names))
                self.assertFalse(verdict["helper_product_qualified"])
                self.assertFalse(verdict["sdk_qualified"])
                self.assertFalse(verdict["physical_qualified"])
                self.assertFalse(verdict["wrapper_used"])

    def test_missing_case_refuses_even_if_summary_claims_full_count(self):
        log = transcript(self.names[1:]).replace(
            ("Executed " + str(len(self.names) - 1)).encode(),
            ("Executed " + str(len(self.names))).encode(),
        )
        self.assertFalse(self.judge(log)["passed"])

    def test_duplicate_case_cannot_supply_missing_case(self):
        self.assertFalse(self.judge(transcript((self.names[0],) + self.names[:-1]))["passed"])

    def test_extra_foreign_and_same_class_unknown_cases_refuse(self):
        for extra in ("ForeignTests.testForeign", RECEIVER.CLASSES[0] + ".testUnenrolled"):
            with self.subTest(extra=extra):
                self.assertFalse(self.judge(transcript(self.names + (extra,)))["passed"])

    def test_skip_and_failed_terminal_refuse(self):
        for state in (b"skipped", b"failed"):
            with self.subTest(state=state):
                log = transcript(self.names).replace(
                    b"passed (0.001 seconds).", state + b" (0.001 seconds).", 1
                )
                self.assertFalse(self.judge(log)["passed"])

    def test_missing_unpaired_or_reordered_start_terminal_refuse(self):
        lines = transcript(self.names).splitlines(keepends=True)
        for changed in (
            lines[:1] + lines[2:],
            lines[:2] + lines[3:],
            lines[:1] + [lines[2], lines[1]] + lines[3:],
        ):
            with self.subTest(first=changed[1]):
                self.assertFalse(self.judge(b"".join(changed))["passed"])

    def test_truncation_missing_summary_and_duplicate_root_refuse(self):
        log = transcript(self.names)
        lines = log.splitlines(keepends=True)
        for changed in (log[:-1], b"".join(lines[:-1]), b"".join(lines[:-2]), log + log):
            with self.subTest(length=len(changed)):
                self.assertFalse(self.judge(changed)["passed"])

    def test_native_status_and_capture_are_mandatory_independent_inputs(self):
        for field in ("swift_status", "capture_status"):
            for bad in (None, 1, -9, "0", False):
                with self.subTest(field=field, bad=bad):
                    self.assertFalse(self.judge(**{field: bad})["passed"])

    def test_retirement_cannot_be_inferred_from_complete_transcript(self):
        for retired in (False, None, 1):
            with self.subTest(retired=retired):
                self.assertFalse(self.judge(retired=retired)["passed"])

    def test_wrong_source_or_any_source_drift_refuses(self):
        after = copy.deepcopy(self.metadata["after"])
        after["files"][0]["sha256"] = "d" * 64
        self.assertFalse(self.judge(after=after)["passed"])
        self.assertFalse(self.judge(requested_sha="e" * 40)["passed"])
        self.assertFalse(self.judge(after=None)["passed"])

    def test_empty_or_counter_only_source_frame_refuses(self):
        for frame in ({"head": SHA, "files": []}, {"head": SHA, "files": [1, 2, 3, 4]}):
            with self.subTest(frame=frame):
                self.assertFalse(self.judge(before=frame, after=frame)["passed"])

    def test_wrong_native_architecture_refuses(self):
        self.assertFalse(self.judge(observed_architecture="x86_64")["passed"])
        self.assertFalse(self.judge(architecture="amd64", observed_architecture="amd64")["passed"])
        self.assertTrue(self.judge(architecture="x86_64", observed_architecture="x86_64")["passed"])

    def test_foreign_module_and_malformed_test_row_refuse(self):
        log = transcript(self.names)
        self.assertFalse(
            self.judge(log.replace(b"ErgoptiPlusTests.", b"ForeignModule.", 1))["passed"]
        )
        self.assertFalse(self.judge(log.replace(b"started.", b"unknown.", 1))["passed"])

    def test_corrupt_or_over_budget_capture_refuses(self):
        for log in (
            b"\xff\n",
            b"\x1b" + transcript(self.names),
            b"x" * (RECEIVER.MAX_LOG_BYTES + 1),
        ):
            with self.subTest(size=len(log)):
                self.assertFalse(self.judge(log)["passed"])

    def test_only_explicit_reviewable_additional_catalogue_entries_can_enroll(self):
        value = copy.deepcopy(self.value)
        value["additional_cases"].append(RECEIVER.CLASSES[0] + ".testSeparatelyReviewedAddition")
        names = RECEIVER.catalogue(json.dumps(value))
        verdict = RECEIVER.judge(transcript(names), names, **self.metadata)
        self.assertTrue(verdict["passed"])
        self.assertFalse(RECEIVER.judge(transcript(self.names), names, **self.metadata)["passed"])

    def test_original_oracle_edits_duplicate_and_foreign_additions_refuse(self):
        for field, name in (
            ("original_cases", "changed"),
            ("additional_cases", self.names[0]),
            ("additional_cases", "ForeignTests.testNotOwned"),
        ):
            value = copy.deepcopy(self.value)
            value[field].append(name)
            with self.subTest(field=field, name=name), self.assertRaises(ValueError):
                RECEIVER.catalogue(json.dumps(value))

    def test_real_quoted_external_header_chain_is_followed_or_refused(self):
        start = RECEIVER.PACKAGE + "/Sources/CPOSIXCompatibility/OwnedInstalledConfiguration.cpp"
        sources = {
            start: b'#include "../../../../../../tools/build/InstalledUserConfiguration.hpp"\n'
        }
        headers = {
            "tools/build/InstalledUserConfiguration.hpp": b'#include "InstalledRuntimePublisher.hpp"\n',
            "tools/build/InstalledRuntimePublisher.hpp": b"#include <memory>\n",
        }

        def read(name):
            if name not in headers:
                raise FileNotFoundError(name)
            return headers[name]

        actual = RECEIVER.quoted_include_closure(sources, read)
        self.assertEqual(set(actual), {start, *headers})
        del headers["tools/build/InstalledRuntimePublisher.hpp"]
        with self.assertRaises(ValueError):
            RECEIVER.quoted_include_closure(sources, read)
        with self.assertRaises(ValueError):
            RECEIVER.quoted_include_closure({"header.h": b'#include "../outside.h"\n'}, read)

    def test_missing_or_changed_external_compiler_header_refuses(self):
        before = copy.deepcopy(self.metadata["before"])
        before["files"] = [
            row
            for row in before["files"]
            if row["path"] != "tools/build/InstalledRuntimePublisher.hpp"
        ]
        self.assertFalse(self.judge(before=before, after=before)["passed"])
        after = copy.deepcopy(self.metadata["after"])
        for row in after["files"]:
            if row["path"] == "tools/build/InstalledUserConfiguration.hpp":
                row["sha256"] = "f" * 64
        self.assertFalse(self.judge(after=after)["passed"])

    def modeled_debt_receiving(self, reservation_lost):
        """Exercise actual receiver ordering with an explicit fake owner and inert pipe.

        This does not authenticate Git, WNOWAIT, a native child or physical reap.
        The fake's third settlement represents eventual closure solely so the
        finite portable control can observe the following admission boundary.
        """
        reader, writer = os.pipe()
        os.close(writer)
        pipe = os.fdopen(reader, "rb")
        owner = SimpleNamespace(
            reaped=False,
            reservation_lost=reservation_lost,
            attempts=0,
            process=SimpleNamespace(stdout=pipe, returncode=None),
        )

        def settle(timeout=1):
            owner.attempts += 1
            if owner.attempts < 3:
                return False
            owner.reaped = True
            owner.process.returncode = 0
            return True

        owner.settle = settle
        owner.observe_exit = lambda: object()

        def acquire(command, native, register, **options):
            self.assertEqual(command[0:2], ["/usr/bin/swift", "test"])
            self.assertNotIn("--skip", command)
            register(owner)
            return owner

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            catalogue = root / RECEIVER.CATALOGUE
            catalogue.parent.mkdir(parents=True)
            catalogue.write_bytes(CATALOGUE.read_bytes())
            output = root / "evidence"
            calls = []

            def source(sha):
                self.assertEqual(sha, SHA)
                if calls:
                    self.assertTrue(owner.reaped, "source subprocess cannot precede original reap")
                calls.append("source")
                return copy.deepcopy(self.metadata["before"])

            def pending_pause(seconds):
                self.assertEqual(seconds, 0.05)
                self.assertFalse(owner.reaped)
                self.assertEqual(calls, ["source"])
                self.assertFalse((output / "verdict.json").exists())
                debt = json.loads((output / "pending-retirement.json").read_text())
                self.assertEqual(
                    debt,
                    {
                        "schema": 1,
                        "passed": False,
                        "reason": "native-retirement-debt",
                        "controller_retains_capabilities": True,
                    },
                )

            ownership = SimpleNamespace(
                NativeProcessGroups=lambda: object(),
                OwnedProcessInterrupted=RuntimeError,
                acquire_owned=acquire,
            )
            try:
                with (
                    mock.patch.object(RECEIVER, "ROOT", root),
                    mock.patch.object(RECEIVER, "source_frame", side_effect=source),
                    mock.patch.object(RECEIVER.sys, "platform", "darwin"),
                    mock.patch.object(RECEIVER.platform, "machine", return_value="arm64"),
                    mock.patch.object(RECEIVER.time, "sleep", side_effect=pending_pause),
                    mock.patch.object(RECEIVER, "ownership_module", return_value=ownership),
                    mock.patch.dict(RECEIVER.os.environ, {}, clear=True),
                ):
                    result = RECEIVER.receive(SHA, "arm64", output)
            finally:
                pipe.close()
            self.assertEqual(calls, ["source", "source"])
            self.assertTrue(owner.reaped)
            self.assertEqual(owner.attempts, 3)
            self.assertFalse(result["passed"])
            self.assertTrue(result["retired"])
            self.assertTrue(result["retirement_refused"])
            self.assertIsNone(result["capture_status"])
            self.assertTrue((output / "pending-retirement.json").exists())

    def test_original_owner_debt_blocks_source_children_until_modeled_reap(self):
        self.modeled_debt_receiving(False)

    def test_reservation_lost_debt_never_becomes_a_clean_receipt(self):
        self.modeled_debt_receiving(True)

    def supervisor_fixture(self, directory):
        """Use genuine supervisor bytes; metadata is an explicitly modeled Git frame."""
        root = Path(directory)
        path = root / RECEIVER.SUPERVISOR
        path.parent.mkdir(parents=True)
        data = (RECEIVER.ROOT / RECEIVER.SUPERVISOR).read_bytes()
        path.write_bytes(data)
        frame = {
            "head": SHA,
            "files": [
                {
                    "path": RECEIVER.SUPERVISOR,
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "blob": hashlib.sha1(
                        b"blob " + str(len(data)).encode() + b"\0" + data
                    ).hexdigest(),
                }
            ],
        }
        return root, path, data, frame

    def test_authenticated_loader_ignores_genuinely_valid_poisoned_pyc(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path, genuine, frame = self.supervisor_fixture(directory)
            poison = b'raise RuntimeError("controlled poisoned supervisor cache")\n'
            self.assertGreater(len(genuine), len(poison))
            path.write_bytes(poison + b" " * (len(genuine) - len(poison)))
            stamp = 1_700_000_000
            os.utime(path, (stamp, stamp))
            py_compile.compile(
                str(path), doraise=True, invalidation_mode=py_compile.PycInvalidationMode.TIMESTAMP
            )
            path.write_bytes(genuine)
            os.utime(path, (stamp, stamp))
            legacy = importlib.machinery.SourceFileLoader("controlled_cached_supervisor", str(path))
            # Causal witness: the ordinary loader actually selects the matching poison cache.
            with self.assertRaisesRegex(RuntimeError, "controlled poisoned supervisor cache"):
                exec(legacy.get_code("controlled_cached_supervisor"), {})
            with mock.patch.object(RECEIVER, "ROOT", root):
                loaded = RECEIVER.ownership_module(frame)
            self.assertTrue(callable(loaded.acquire_owned))
            self.assertEqual(loaded.acquire_owned.__code__.co_filename, str(path))
            self.assertEqual(loaded.__name__, "_daemon_report_authenticated_ownership")

    def test_authenticated_loader_does_not_adopt_preloaded_sys_modules(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path, genuine, frame = self.supervisor_fixture(directory)
            poison = SimpleNamespace(acquire_owned="controlled foreign cached capability")
            with (
                mock.patch.object(RECEIVER, "ROOT", root),
                mock.patch.dict(RECEIVER.sys.modules, {"macos_owned_process": poison}),
            ):
                loaded = RECEIVER.ownership_module(frame)
                self.assertIs(RECEIVER.sys.modules["macos_owned_process"], poison)
            self.assertIsNot(loaded, poison)
            self.assertTrue(callable(loaded.acquire_owned))
            self.assertEqual(loaded.acquire_owned.__code__.co_filename, str(path))

    def test_authenticated_loader_refuses_tampered_source_before_compile(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path, genuine, frame = self.supervisor_fixture(directory)
            path.write_bytes(genuine + b"\n")
            with (
                mock.patch.object(RECEIVER, "ROOT", root),
                mock.patch("builtins.compile") as compiled,
                self.assertRaises(ValueError),
            ):
                RECEIVER.ownership_module(frame)
            compiled.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
