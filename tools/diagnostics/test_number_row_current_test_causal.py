"""Controlled current-fixture contracts; no native transcript or approval is issued."""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPOSITORY = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY / "tools/diagnostics"))
import number_row_current_test_causal as subject
import number_row_current_network_causal as network
import number_row_native_causal as core

TEST_SHA = "105820510cbe3c5c13dee94d30d7ef1ea738fa9131907ae3cc12278dc10a96f7"
TEST_BLOB = "e1879c6e7985d044c41dd0dc5af6329cb0b37be6"
BASE = REPOSITORY / "tools/diagnostics/fixtures/number-row-native-causal"
NETWORK = REPOSITORY / "tools/diagnostics/fixtures/number-row-current-network"
BASE_SHA = "47b2dc03e558db6418234ab6c69a279cc91fd9c29bc587505e13ea0989764549"
NETWORK_SHA = "6f313f6afb2f6bee59a9c8e5a728c0d12b8f765dd8af9bff029595faea4aef6c"


def controlled_log():
    """Build only an explicitly synthetic parser vector, never native evidence."""
    lines = ["Test Suite 'Selected tests' started at CONTROLLED"]
    for method in core.METHODS:
        identity = f"ErgoptiPlusTests.NumberRowSourceProbeTests.{method}"
        lines.append(f"Test Case '{identity}' started.")
        if method == core.TARGET:
            lines.append(
                f"CONTROLLED/NumberRowSourceProbeTests.swift:435: error: {identity} : "
                "XCTAssertThrowsError failed: did not throw error"
            )
        result = "failed" if method == core.TARGET else "passed"
        lines.append(f"Test Case '{identity}' {result} (0.001 seconds).")
    lines += [
        "Test Suite 'Selected tests' failed at CONTROLLED",
        "Executed 12 tests, with 1 failure (0 unexpected) in 0.012 seconds",
    ]
    return "\n".join(lines) + "\n"


class CurrentFixtureControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tests = (REPOSITORY / subject.TEST_PATH).read_bytes()
        if hashlib.sha256(cls.tests).hexdigest() != TEST_SHA:
            raise ValueError("independently reviewed current test image unavailable")
        cls.original = (
            REPOSITORY
            / "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/NumberRowSourceProbe.swift"
        ).read_bytes()
        if hashlib.sha256(cls.original).hexdigest() != core.PRODUCER_SHA:
            raise ValueError("independent original producer unavailable")
        cls.historical = (BASE / "NumberRowSourceProbeTests.original.swift.raw").read_bytes()
        if hashlib.sha256(cls.historical).hexdigest() != core.TEST_SHA:
            raise ValueError("immutable historical test source unavailable")

    def setUp(self):
        self.owned = tempfile.TemporaryDirectory(dir=RECEIVING)
        self.addCleanup(self.owned.cleanup)
        self.root = Path(self.owned.name)
        self.log = controlled_log()
        self.tis = {
            "complete": True,
            "count": 7,
            "methods": sorted(core.METHODS[:6] + (core.TARGET,)),
        }
        legacy = json.loads((BASE / "projection-manifest.original-c15.json.raw").read_bytes())
        old = next(row for row in legacy["paths"] if row["path"] == subject.TEST_PATH)
        # This finite negative/control record is not independently issued approval.
        # Real source authority additionally requires committed ancestry and bytes.
        self.record = {
            "schema": 1,
            "role": "independently-reviewed-current-number-row-test",
            "path": subject.TEST_PATH,
            "original_git_blob": old["git_blob"],
            "original_sha256": core.TEST_SHA,
            "published_source_commit": "c" * 40,
            "git_blob": TEST_BLOB,
            "sha256": TEST_SHA,
            "source_review_sha256": "d" * 64,
            "causal_method": core.TARGET,
            "causal_assertion_line": 435,
        }

    def evaluate(self, log=None, **changes):
        arguments = dict(
            tests=self.tests,
            log=self.log if log is None else log,
            swift_exit=1,
            capture_exit=0,
            tis=self.tis,
            tis_exit=0,
        )
        arguments.update(changes)
        return subject.evaluate(core, **arguments)

    def contract(self, record=None, composition=None):
        path = self.root / "controlled-approval.json"
        data = json.dumps(self.record if record is None else record).encode()
        path.write_bytes(data)
        return subject.current_test_contract(
            core,
            network,
            (
                BASE / "projection-manifest.original-c15.json.raw",
                BASE / "g5-source-approvals.json.raw",
                BASE_SHA,
                NETWORK / "http-source-approvals.json.raw",
                NETWORK_SHA,
            ),
            path,
            hashlib.sha256(data).hexdigest(),
            composition,
        )

    def build_contract(self, record=None, composition=None):
        self.contract()
        test_path = self.root / "controlled-approval.json"
        test_sha = hashlib.sha256(test_path.read_bytes()).hexdigest()
        received = {
            "schema": 1,
            "role": "independently-reviewed-complete-current-carbon-local-inputs",
            "roster_sha256": "b34a6f3efec6b31c1b3b8ffd438aeb73b38aa3b8265bd383054bbc1353393492",
            "published_source_commit": "c" * 40,
            "source_review_sha256": "e" * 64,
            "test_source_approval_sha256": test_sha,
            "base_source_approval_sha256": BASE_SHA,
            "network_source_approval_sha256": NETWORK_SHA,
        }
        if record:
            received.update(record)
        build_path = self.root / "controlled-complete-build-approval.json"
        data = json.dumps(received).encode()
        build_path.write_bytes(data)
        return subject.current_build_contract(
            core,
            network,
            (
                BASE / "projection-manifest.original-c15.json.raw",
                BASE / "g5-source-approvals.json.raw",
                BASE_SHA,
                NETWORK / "http-source-approvals.json.raw",
                NETWORK_SHA,
            ),
            test_path,
            test_sha,
            build_path,
            hashlib.sha256(data).hexdigest(),
            composition,
        )

    def test_current_parser_receives_only_controlled_expected_red(self):
        result = self.evaluate()
        self.assertIs(result["expected_red_received"], True)
        self.assertIs(result["canonical_product_source_qualified"], False)
        self.assertIs(result["physical_keyboard_qualified"], False)
        self.assertEqual(result["original_positive_receipt"]["source_sha"], TEST_SHA)
        self.assertEqual(result["original_positive_receipt"]["failures"], [core.TARGET])

    def test_historical_api_still_refuses_current_fixture(self):
        with self.assertRaisesRegex(ValueError, "original test source changed"):
            core.evaluate(self.tests, self.log, 1, 0, self.tis, 0)
        with self.assertRaises(ValueError):
            core.verify_mutation(
                self.original, self.original.replace(core.NEEDLE, b"true", 1), self.tests
            )

    def test_current_api_refuses_historical_and_edited_fixture(self):
        for tests in (self.historical, self.tests + b"\n// CONTROLLED source change\n"):
            with (
                self.subTest(source=hashlib.sha256(tests).hexdigest()),
                self.assertRaises(ValueError),
            ):
                self.evaluate(tests=tests)

    def test_exact_current_producer_omission_is_separate_from_historical_test(self):
        mutated = self.original.replace(core.NEEDLE, b"true", 1)
        proof = subject.verify_current_mutation(core, self.original, mutated, self.tests)
        self.assertEqual(proof["test_sha256"], TEST_SHA)
        self.assertEqual(proof["historical_test_sha256"], core.TEST_SHA)
        for bad in (
            self.original,
            mutated + b"\n",
            mutated.replace(b"import Carbon", b"import Foundation", 1),
        ):
            with self.subTest(image=hashlib.sha256(bad).hexdigest()), self.assertRaises(ValueError):
                subject.verify_current_mutation(core, self.original, bad, self.tests)

    def test_old_or_foreign_assertion_line_refuses(self):
        for line in (321, 434, 436):
            with self.subTest(line=line), self.assertRaises(ValueError):
                self.evaluate(self.log.replace(".swift:435:", f".swift:{line}:"))

    def test_extra_assertion_or_compiler_error_refuses(self):
        for suffix in ("error: CONTROLLED compiler refusal\n", "XCTAssertEqual failed\n"):
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                self.evaluate(self.log + suffix)

    def test_missing_duplicate_skipped_or_overlapping_case_refuses(self):
        start = (
            f"Test Case 'ErgoptiPlusTests.NumberRowSourceProbeTests.{core.METHODS[0]}' started.\n"
        )
        for changed in (
            self.log.replace(start, "", 1),
            self.log.replace(start, start + start, 1),
            self.log.replace("passed (", "skipped (", 1),
        ):
            with self.subTest(log=changed[:120]), self.assertRaises(ValueError):
                self.evaluate(changed)

    def test_successful_or_incoherent_summary_refuses(self):
        for changed in (
            self.log.replace("12 tests", "11 tests"),
            self.log.replace("1 failure", "2 failures"),
            self.log + "Test Suite 'Selected tests' passed at CONTROLLED\n",
        ):
            with self.subTest(log=changed[-150:]), self.assertRaises(ValueError):
                self.evaluate(changed)

    def test_native_exit_domains_remain_exact(self):
        for field, values in (
            ("swift_exit", (0, True, 1.0, 256)),
            ("capture_exit", (1, False, 0.0)),
            ("tis_exit", (1, False, 0.0)),
        ):
            for value in values:
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    self.evaluate(**{field: value})

    def test_missing_foreign_duplicate_and_noninteger_tis_closures_refuse(self):
        for mutate in (
            lambda d: d.update(complete=False),
            lambda d: d.update(count=True),
            lambda d: d.update(count=6),
            lambda d: d["methods"].pop(),
            lambda d: d["methods"].append(core.TARGET),
        ):
            changed = copy.deepcopy(self.tis)
            mutate(changed)
            with self.subTest(tis=changed), self.assertRaises(ValueError):
                self.evaluate(tis=changed)

    def test_exact_seven_role_contract_keeps_ninety_nine_paths(self):
        legacy, approved, composition = self.contract()
        self.assertEqual(len(approved["approvals"]), 7)
        self.assertEqual(len(composition["paths"]), 99)
        self.assertEqual(len({row["path"] for row in composition["paths"]}), 99)
        previous = {row["path"]: row for row in legacy["paths"]}
        changed = [row for row in composition["paths"] if row != previous[row["path"]]]
        self.assertEqual(len(changed), 7)

    def test_wrong_current_role_predecessor_tuple_or_location_refuses(self):
        for field, value in (
            ("schema", True),
            ("role", "auxiliary"),
            ("path", "foreign.swift"),
            ("original_git_blob", "0" * 40),
            ("original_sha256", "0" * 64),
            ("git_blob", "0" * 40),
            ("sha256", core.TEST_SHA),
            ("causal_method", core.METHODS[0]),
            ("causal_assertion_line", 321),
            ("published_source_commit", "CONTROLLED"),
            ("source_review_sha256", ""),
        ):
            record = {**self.record, field: value}
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.contract(record)

    def test_extra_or_missing_approval_field_refuses(self):
        missing = dict(self.record)
        del missing["source_review_sha256"]
        for record in (missing, {**self.record, "native_qualified": True}):
            with self.subTest(keys=sorted(record)), self.assertRaises(ValueError):
                self.contract(record)

    def test_changed_composition_refuses(self):
        _, _, expected = self.contract()
        for mutate in (
            lambda d: d.update(schema=True),
            lambda d: d["paths"].pop(),
            lambda d: d["paths"].append(copy.deepcopy(d["paths"][0])),
            lambda d: d.update(test_source_approval_sha256="0" * 64),
        ):
            changed = copy.deepcopy(expected)
            mutate(changed)
            with self.subTest(composition=changed["schema"]), self.assertRaises(ValueError):
                self.contract(composition=changed)

    def test_complete_current_roster_includes_new_targets_and_runtime_corpus(self):
        legacy, approved, record, composition = self.build_contract()
        rows = composition["paths"]
        self.assertEqual(
            (len(rows), len(legacy["paths"]), len(approved["approvals"])), (145, 99, 7)
        )
        self.assertEqual(sum(row["input_kind"] == "target-input" for row in rows), 140)
        self.assertEqual(sum(not row["historical_roster_member"] for row in rows), 46)
        corpus = next(row for row in rows if row["input_kind"] == "selected-test-runtime-fixture")
        self.assertEqual(
            corpus["path"],
            "static/ergopti_plus/_shared/tests/corpus/layouts/number_row_levels.json",
        )
        self.assertEqual(
            corpus["sha256"], "cec09a9901f2b3b647af1bb46d51c3bccfed5e11c315b14115058db8b09e81b2"
        )
        self.assertIsNone(corpus["historical_git_blob"])
        self.assertIsNone(composition["qualification_profile"])

    def test_partial_or_changed_complete_composition_refuses(self):
        _, _, _, expected = self.build_contract()
        for kind in (
            "target-input",
            "package-manifest",
            "dependency-lock",
            "qualification-policy",
            "selected-test-runtime-fixture",
        ):
            changed = copy.deepcopy(expected)
            changed["paths"].remove(
                next(row for row in changed["paths"] if row["input_kind"] == kind)
            )
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                self.build_contract(composition=changed)
        for mutate in (
            lambda d: d.update(schema=3),
            lambda d: d.update(schema=4.0),
            lambda d: d.update(local_input_count=99),
            lambda d: d.update(local_input_count=145.0),
            lambda d: d.update(target_input_count=140.0),
            lambda d: d["paths"][0].update(historical_roster_member=1),
            lambda d: d["paths"].append(copy.deepcopy(d["paths"][0])),
            lambda d: d["paths"][0].update(sha256="0" * 64),
        ):
            changed = copy.deepcopy(expected)
            mutate(changed)
            with self.subTest(change=changed["schema"]), self.assertRaises(ValueError):
                self.build_contract(composition=changed)

    def test_missing_foreign_or_unbound_complete_build_approval_refuses(self):
        for field, value in (
            ("schema", True),
            ("roster_sha256", "0" * 64),
            ("test_source_approval_sha256", "0" * 64),
            ("published_source_commit", "CONTROLLED"),
            ("source_review_sha256", ""),
            ("native_qualified", True),
        ):
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.build_contract(record={field: value})

    def test_current_selected_receiving_refuses_release_exclusion_profile(self):
        with patch.dict(
            os.environ,
            {"ERGOPTI_DEV_QUALIFICATION_PROFILE": "dev-release-20261009-diagnostic-prerelease"},
        ):
            with self.assertRaisesRegex(ValueError, "no qualification profile"):
                self.build_contract()

    def test_genuine_git_batch_reads_package_and_runtime_fixture(self):
        head = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=REPOSITORY, text=True
        ).strip()
        paths = [
            "static/ergopti_plus/macos/launcher/Package.swift",
            "static/ergopti_plus/_shared/tests/corpus/layouts/number_row_levels.json",
        ]
        images = subject.git_inputs(REPOSITORY, head, paths)
        self.assertEqual(set(images), set(paths))
        self.assertEqual(
            hashlib.sha256(images[paths[0]][0]).hexdigest(),
            "34861f7e4a3520342f911ded13896941fa5e227c0a171b9258f38eebc8ac5b3f",
        )
        self.assertEqual(images[paths[1]][1], "10f822f3630a396bca4e5cc3cfc21e43a768158b")
        self.assertTrue(all(row[2] == "100644" for row in images.values()))
        with self.assertRaisesRegex(ValueError, "membership"):
            subject.git_inputs(REPOSITORY, head, paths + ["CONTROLLED-uncommitted.swift"])

    def test_positive_receiving_uses_unchanged_positive_receiver(self):
        assertion = next(line for line in self.log.splitlines(True) if ".swift:435:" in line)
        positive_log = (
            self.log.replace(assertion, "")
            .replace("failed at", "passed at")
            .replace("failed (", "passed (")
            .replace("1 failure", "0 failures")
        )
        result = subject.evaluate_positive(core, self.tests, positive_log, 0, 0, self.tis, 0)
        self.assertIs(result["positive_received"], True)
        self.assertEqual(result["passed_case_count"], 12)
        self.assertIs(result["application_launch_qualified"], False)
        with self.assertRaises(ValueError):
            subject.evaluate_positive(core, self.tests, self.log, 0, 0, self.tis, 0)
        with self.assertRaises(ValueError):
            subject.evaluate_positive(core, self.tests, positive_log, True, 0, self.tis, 0)
        first_start = (
            f"Test Case 'ErgoptiPlusTests.NumberRowSourceProbeTests.{core.METHODS[0]}' started."
        )
        second_start = (
            f"Test Case 'ErgoptiPlusTests.NumberRowSourceProbeTests.{core.METHODS[1]}' started."
        )
        swapped = (
            positive_log.replace(first_start, "CONTROLLED_START_PLACEHOLDER")
            .replace(second_start, first_start)
            .replace("CONTROLLED_START_PLACEHOLDER", second_start)
        )
        for bad in (
            positive_log + "error: CONTROLLED compiler refusal\n",
            positive_log + "XCTAssertEqual failed\n",
            positive_log.replace("0 failures", "1 failure"),
            positive_log.replace("0 unexpected", "1 unexpected"),
            positive_log + "Test Suite 'Selected tests' failed at CONTROLLED\n",
            swapped,
        ):
            with self.subTest(transcript=bad[-120:]), self.assertRaises(ValueError):
                subject.evaluate_positive(core, self.tests, bad, 0, 0, self.tis, 0)

    def test_compiler_source_context_does_not_refuse_either_leg(self):
        assertion = next(line for line in self.log.splitlines(True) if ".swift:435:" in line)
        positive = (
            self.log.replace(assertion, "")
            .replace("failed at", "passed at")
            .replace("failed (", "passed (")
            .replace("1 failure", "0 failures")
        )
        contexts = (
            "111 | \t\t\tvar error: NSDictionary?; let returned = "
            "script.executeAndReturnError(&error)\n",
            '111 | let text = "file.swift:12: error: example"\n',
            '111 | let text = "XCTAssertEqual failed"\n',
        )
        for context in contexts:
            context = "warning: unused variable 'error'\n" + context
            for leg, transcript in (("positive", positive), ("counterfactual", self.log)):
                active_start = next(
                    line for line in transcript.splitlines(True) if line.startswith("Test Case ")
                )
                for position, log in (
                    ("before", context + transcript),
                    ("active", transcript.replace(active_start, active_start + context, 1)),
                    ("after", transcript + context),
                ):
                    with self.subTest(leg=leg, position=position, context=context):
                        if leg == "positive":
                            result = subject.evaluate_positive(
                                core, self.tests, log, 0, 0, self.tis, 0
                            )
                            self.assertIs(result["positive_received"], True)
                        else:
                            self.assertIs(self.evaluate(log)["expected_red_received"], True)

    def test_real_diagnostics_still_refuse_both_legs_with_source_context(self):
        assertion = next(line for line in self.log.splitlines(True) if ".swift:435:" in line)
        positive = (
            self.log.replace(assertion, "")
            .replace("failed at", "passed at")
            .replace("failed (", "passed (")
            .replace("1 failure", "0 failures")
        )
        diagnostics = (
            "/path/File.swift:111:20: error: CONTROLLED refusal",
            "<unknown>:0: error: CONTROLLED refusal",
            "error: emit-module command failed",
            "clang: error: CONTROLLED refusal",
            "swift-frontend: error: CONTROLLED refusal",
            "ld: error: CONTROLLED refusal",
            "Swift/ErrorType.swift:253: Fatal error: CONTROLLED refusal",
            "Fatal error: CONTROLLED refusal",
            "XCTAssertEqual failed",
        )
        for diagnostic in diagnostics:
            context = '111 | let text = "file.swift:12: error: example"\n'
            for leg, transcript in (("positive", positive), ("counterfactual", self.log)):
                with self.subTest(leg=leg, diagnostic=diagnostic), self.assertRaises(ValueError):
                    log = context + transcript + diagnostic + "\n"
                    if leg == "positive":
                        subject.evaluate_positive(core, self.tests, log, 0, 0, self.tis, 0)
                    else:
                        self.evaluate(log)

    def test_current_input_refuses_same_bytes_through_an_internal_parent_alias(self):
        retained = self.root / "retained-input"
        retained.mkdir()
        image = retained / "input.swift"
        image.write_bytes(b"// CONTROLLED identical source image\n")
        self.assertEqual(
            subject.regular_current_input(self.root, "retained-input/input.swift"), image
        )
        alias = self.root / "aliased-input"
        if os.name == "nt":
            import _winapi

            _winapi.CreateJunction(str(retained), str(alias))
        else:
            alias.symlink_to(retained, target_is_directory=True)
        try:
            self.assertEqual((alias / "input.swift").read_bytes(), image.read_bytes())
            with self.assertRaisesRegex(ValueError, "unaliased"):
                subject.regular_current_input(self.root, "aliased-input/input.swift")
        finally:
            if os.name == "nt":
                alias.rmdir()
            else:
                alias.unlink()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receiving", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    RECEIVING = args.receiving.resolve(strict=True)
    if args.receiving.is_symlink() or not RECEIVING.is_dir():
        raise ValueError("explicit owned receiving directory required")
    unittest.main(argv=[__file__, *remaining], verbosity=2)
