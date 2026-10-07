# tools/build/remap_runtime_team_metadata_test.py
"""Ordinary portable output/caller checks; no Darwin, CF or signing execution."""

from pathlib import Path
import importlib.util
import base64
import json
import zlib
import unittest

# Read-only historical oracle bytes; these are never executed or used as SDK inputs.
_HISTORICAL_ORACLE = json.loads(
    zlib.decompress(
        base64.b64decode(
            "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"
        )
    )
)


class HistoricalPath:
    def __init__(self, relative=""):
        self.relative = relative

    def __truediv__(self, component):
        return HistoricalPath(self.relative + ("/" if self.relative else "") + component)

    def read_bytes(self):
        return bytes.fromhex(_HISTORICAL_ORACLE[self.relative])

    def read_text(self):
        return self.read_bytes().decode("utf-8")


PACKET = HistoricalPath()
CANDIDATE = Path(__file__).resolve().parents[2]
INITIALIZER_CONTROLS_ADDITION = '\nextension HS274NativePolicyQualificationTests {\n\tfunc testPortableInitializerDeliveryRetainsAllTwentyTwoFrozenControls() throws {\n\t\ttry fixture { root in\n\t\t\tlet cases: [String] = ["healthy", "unbound", "bytes_mismatch", "empty", "noncanonical", "error", "unknown_response", "duplicate", "retired", "changed_peer", "timer", "queue_refusal", "callback", "foreign_debt", "timer_observation", "empty_refusal", "reserved_kind", "outbound_wire", "pending_cancel", "completion_reentry", "peer_reentry", "completion_exception"]\n\t\t\tlet modes: [[String]] = [[], ["-O"]]\n\t\t\tfor selected in cases {\n\t\t\t\tfor mode in modes {\n\t\t\t\t\tlet script = source("hs274_native_build.py").deletingLastPathComponent()\n\t\t\t\t\t\t.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_initializer_test.py")\n\t\t\t\t\tlet receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n\t\t\t\t\t\t["python3"] + mode + [script.path, "--case", selected, "--owner", root.path], root: root)\n\t\t\t\t\tXCTAssertEqual(receipt.status, 0)\n\t\t\t\t\tXCTAssertTrue(receipt.stdout.isEmpty)\n\t\t\t\t\tXCTAssertTrue(receipt.stderr.contains("Ran 1 test in "))\n\t\t\t\t\tXCTAssertTrue(receipt.stderr.hasSuffix("\\nOK\\n"))\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n'

PRODUCT_DIFFERENCE_AXES_ADDITION = '\nextension HS274NativePolicyQualificationTests {\n\tfunc testPortableProductDifferenceAxesPreserveOriginalRefusals() throws {\n\t\ttry fixture { root in\n\t\t\tlet modes: [[String]] = [[], ["-O"]]\n\t\t\tfor mode in modes {\n\t\t\t\tlet script = source("hs274_native_build.py").deletingLastPathComponent()\n\t\t\t\t\t.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_product_axes_test.py")\n\t\t\t\tlet receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n\t\t\t\t\t["python3"] + mode + [script.path], root: root)\n\t\t\t\tXCTAssertEqual(receipt.status, 0)\n\t\t\t\tXCTAssertTrue(receipt.stdout.isEmpty)\n\t\t\t\tXCTAssertTrue(receipt.stderr.contains("Ran 10 tests in "))\n\t\t\t\tXCTAssertTrue(receipt.stderr.hasSuffix("\\nOK\\n"))\n\t\t\t}\n\t\t}\n\t}\n}\n'

OFFLINE_VHD_ADDITION = '\nextension HS274NativePolicyQualificationTests {\n\tfunc testPortablePinnedVHDSourceUsesTenOriginalControls() throws {\n\t\ttry fixture { root in\n\t\t\tlet modes: [[String]] = [[], ["-O"]]\n\t\t\tfor mode in modes {\n\t\t\t\tlet script = source("hs274_native_build.py").deletingLastPathComponent()\n\t\t\t\t\t.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_vhd_fixture.py")\n\t\t\t\tlet receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n\t\t\t\t\t["python3"] + mode + [script.path, "--group", "source", "--owner", root.path], root: root)\n\t\t\t\tXCTAssertEqual(receipt.status, 0)\n\t\t\t\tXCTAssertEqual(receipt.stdout, "PASS portable VHD group=source tests=10; native=unexecuted\\n")\n\t\t\t\tXCTAssertTrue(receipt.stderr.contains("Ran 10 tests in "))\n\t\t\t\tXCTAssertTrue(receipt.stderr.hasSuffix("\\nOK\\n"))\n\t\t\t}\n\t\t}\n\t}\n\tfunc testPortablePinnedVHDTimerRetainsGenuineCancellationControl() throws {\n\t\ttry fixture { root in\n\t\t\tlet modes: [[String]] = [[], ["-O"]]\n\t\t\tfor mode in modes {\n\t\t\t\tlet script = source("hs274_native_build.py").deletingLastPathComponent()\n\t\t\t\t\t.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_vhd_fixture.py")\n\t\t\t\tlet receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n\t\t\t\t\t["python3"] + mode + [script.path, "--group", "timer", "--owner", root.path], root: root)\n\t\t\t\tXCTAssertEqual(receipt.status, 0)\n\t\t\t\tXCTAssertEqual(receipt.stdout, "PASS portable VHD group=timer tests=1; native=unexecuted\\n")\n\t\t\t\tXCTAssertTrue(receipt.stderr.contains("Ran 1 test in "))\n\t\t\t\tXCTAssertTrue(receipt.stderr.hasSuffix("\\nOK\\n"))\n\t\t\t}\n\t\t}\n\t}\n\tfunc testPortablePinnedVHDCallbackRetainsGenuineDestructionControl() throws {\n\t\ttry fixture { root in\n\t\t\tlet modes: [[String]] = [[], ["-O"]]\n\t\t\tfor mode in modes {\n\t\t\t\tlet script = source("hs274_native_build.py").deletingLastPathComponent()\n\t\t\t\t\t.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_vhd_fixture.py")\n\t\t\t\tlet receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n\t\t\t\t\t["python3"] + mode + [script.path, "--group", "callback", "--owner", root.path], root: root)\n\t\t\t\tXCTAssertEqual(receipt.status, 0)\n\t\t\t\tXCTAssertEqual(receipt.stdout, "PASS portable VHD group=callback tests=1; native=unexecuted\\n")\n\t\t\t\tXCTAssertTrue(receipt.stderr.contains("Ran 1 test in "))\n\t\t\t\tXCTAssertTrue(receipt.stderr.hasSuffix("\\nOK\\n"))\n\t\t\t}\n\t\t}\n\t}\n\tfunc testPortablePinnedVHDLowerPeerUsesGenuineComposedHeaders() throws {\n\t\ttry fixture { root in\n\t\t\tlet modes: [[String]] = [[], ["-O"]]\n\t\t\tfor mode in modes {\n\t\t\t\tlet script = source("hs274_native_build.py").deletingLastPathComponent()\n\t\t\t\t\t.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_vhd_fixture.py")\n\t\t\t\tlet receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n\t\t\t\t\t["python3"] + mode + [script.path, "--group", "lower", "--owner", root.path], root: root)\n\t\t\t\tXCTAssertEqual(receipt.status, 0)\n\t\t\t\tXCTAssertEqual(receipt.stdout, "PASS portable VHD group=lower tests=1; native=unexecuted\\n")\n\t\t\t\tXCTAssertTrue(receipt.stderr.contains("Ran 1 test in "))\n\t\t\t\tXCTAssertTrue(receipt.stderr.hasSuffix("\\nOK\\n"))\n\t\t\t}\n\t\t}\n\t}\n\tfunc testPortablePinnedVHDFixtureRefusesPhysicalInputTampering() throws {\n\t\ttry fixture { root in\n\t\t\tlet modes: [[String]] = [[], ["-O"]]\n\t\t\tfor mode in modes {\n\t\t\t\tlet script = source("hs274_native_build.py").deletingLastPathComponent()\n\t\t\t\t\t.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_vhd_fixture_test.py")\n\t\t\t\tlet receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n\t\t\t\t\t["python3"] + mode + [script.path], root: root)\n\t\t\t\tXCTAssertEqual(receipt.status, 0)\n\t\t\t\tXCTAssertTrue(receipt.stdout.isEmpty)\n\t\t\t\tXCTAssertTrue(receipt.stderr.contains("Ran 21 tests in "))\n\t\t\t\tXCTAssertTrue(receipt.stderr.hasSuffix("\\nOK\\n"))\n\t\t\t}\n\t\t}\n\t}\n}\n'

SWIFT_PATH = "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274OwnedRuntimeCompilationTests.swift"
CPP_PATH = "tools/build/remap_runtime_team_metadata_control.cpp"
MODULE_PATH = "tools/build/remap_runtime_team_metadata.py"
CORPUS_PATH = "tools/build/fixtures/remap_runtime_team_metadata12.json"
IDS = (
    "null-dictionary",
    "wrong-dictionary-type",
    "absent-team",
    "present-ascii",
    "present-unicode",
    "present-empty",
    "present-leading-nul",
    "present-interior-nul",
    "present-high-surrogate",
    "present-low-surrogate",
    "present-boolean",
    "present-data",
    "inventory",
)
EXPECTED = "".join("CASE " + key + " PASS\n" for key in IDS).encode()
ADDITION = """			guard products.status == 0, products.stdout ==
				"PASS observed native products=4 architectures=2; signing and activation unqualified\\n",
				products.stderr.isEmpty else { return }
			let metadata = root.appendingPathComponent("team-metadata")
			try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			let team = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", repository.appendingPathComponent("tools/build/remap_runtime_team_metadata.py").path,
					repository.path, owned.path, metadata.path], root: root)
			XCTAssertEqual(team.status, 0)
			XCTAssertEqual(team.stdout, "PASS native CF Team metadata cases=12; signing and authentication unqualified\\n")
			XCTAssertTrue(team.stderr.isEmpty)
"""


# d9e242b0dda7e8c766b71b418bb80d3db9274a0d added a closed failure message
# without changing the status assertion. Compose its exact inverse with the
# metadata addition; the historical whole-file oracle remains immutable.
OWNED_REFUSAL_DIAGNOSTIC = """			XCTAssertEqual(compiled.status, 0, "Retired owned compilation refusal code: "
				+ HS274RetiredBuildRefusal.code(compiled.stderr, producer: .owned))
"""


LEXICAL_PATH_ADDITION = '\n\tfunc testPortableLexicalContainmentPreservesPublicPathSemantics() throws {\n\t\tlet modes: [[String]] = [[], ["-O"]]\n\t\ttry fixture { root in\n\t\t\tfor mode in modes {\n\t\t\t\tlet script = source("hs274_native_build.py").deletingLastPathComponent()\n\t\t\t\t\t.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_lexical_test.py")\n\t\t\t\tlet receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n\t\t\t\t\t["python3"] + mode + [script.path], root: root)\n\t\t\t\tXCTAssertEqual(receipt.status, 0)\n\t\t\t\tXCTAssertTrue(receipt.stdout.isEmpty)\n\t\t\t\tXCTAssertTrue(receipt.stderr.contains("Ran 48 tests in "))\n\t\t\t\tXCTAssertTrue(receipt.stderr.hasSuffix("\\nOK\\n"))\n\t\t\t}\n\t\t}\n\t}\n'


LEXICAL_CLOSURE_ADDITION = '\n\tfunc testPortableLexicalSourceClosureRefusesHistoricalInputs() throws {\n\t\tlet modes: [[String]] = [[], ["-O"]]\n\t\ttry fixture { root in\n\t\t\tfor mode in modes {\n\t\t\t\tlet script = source("hs274_native_build.py").deletingLastPathComponent()\n\t\t\t\t\t.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_lexical_closure_test.py")\n\t\t\t\tlet receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n\t\t\t\t\t["python3"] + mode + [script.path], root: root)\n\t\t\t\tXCTAssertEqual(receipt.status, 0)\n\t\t\t\tXCTAssertTrue(receipt.stdout.isEmpty)\n\t\t\t\tXCTAssertTrue(receipt.stderr.contains("Ran 8 tests in "))\n\t\t\t\tXCTAssertTrue(receipt.stderr.hasSuffix("\\nOK\\n"))\n\t\t\t}\n\t\t}\n\t}\n'


FIXED_BUILDER_SIZE_ADDITION = '\n\tfunc testPortableFixedBuilderImageSizeKeepsOrdinarySourceBounds() throws {\n\t\tlet modes: [[String]] = [[], ["-O"]]\n\t\ttry fixture { root in\n\t\t\tfor mode in modes {\n\t\t\t\tlet script = source("hs274_native_build.py").deletingLastPathComponent()\n\t\t\t\t\t.appendingPathComponent("hs274_builder_image_size_test.py")\n\t\t\t\tlet receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n\t\t\t\t\t["python3"] + mode + [script.path], root: root)\n\t\t\t\tXCTAssertEqual(receipt.status, 0)\n\t\t\t\tXCTAssertTrue(receipt.stdout.isEmpty)\n\t\t\t\tXCTAssertTrue(receipt.stderr.contains("Ran 5 tests in "))\n\t\t\t\tXCTAssertTrue(receipt.stderr.hasSuffix("\\nOK\\n"))\n\t\t\t}\n\t\t}\n\t}\n'


PRODUCT_CURRENTNESS_ADDITION = '\n\tfunc testPortableProductCurrentnessCutsPreserveOriginalRefusals() throws {\n\t\tlet modes: [[String]] = [[], ["-O"]]\n\t\ttry fixture { root in\n\t\t\tfor mode in modes {\n\t\t\t\tlet script = source("hs274_native_build.py").deletingLastPathComponent()\n\t\t\t\t\t.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_product_cut_test.py")\n\t\t\t\tlet receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n\t\t\t\t\t["python3"] + mode + [script.path], root: root)\n\t\t\t\tXCTAssertEqual(receipt.status, 0)\n\t\t\t\tXCTAssertTrue(receipt.stdout.isEmpty)\n\t\t\t\tXCTAssertTrue(receipt.stderr.contains("Ran 6 tests in "))\n\t\t\t\tXCTAssertTrue(receipt.stderr.hasSuffix("\\nOK\\n"))\n\t\t\t}\n\t\t}\n\t}\n'


FOLLOWING_PROFILE_ADDITION = '\n\tfunc testPortableCurrentOwnedProfileUsesPrivateActualSourceControls() throws {\n\t\tlet modes: [[String]] = [[], ["-O"]]\n\t\ttry fixture { root in\n\t\t\tfor mode in modes {\n\t\t\t\tlet script = source("hs274_native_build.py").deletingLastPathComponent()\n\t\t\t\t\t.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_following_profile_test.py")\n\t\t\t\tlet receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),\n\t\t\t\t\t["python3"] + mode + [script.path], root: root)\n\t\t\t\tXCTAssertEqual(receipt.status, 0)\n\t\t\t\tXCTAssertEqual(receipt.stdout,\n\t\t\t\t\t"PASS portable current owned source profile tests=17 failures=0 errors=0 skipped=0 native=unexecuted\\n")\n\t\t\t\tXCTAssertTrue(receipt.stderr.contains("Ran 17 tests in "))\n\t\t\t\tXCTAssertTrue(receipt.stderr.hasSuffix("\\nOK\\n"))\n\t\t\t}\n\t\t}\n\t}\n'
CURRENT_PROFILE_CONSUMER = "module.validate_current_owned_record(module.parse_json(row.data))"
HISTORICAL_PROFILE_CONSUMER = "module.validate_owned_record(module.parse_json(row.data))"


class PortableSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = CANDIDATE / MODULE_PATH
        spec = importlib.util.spec_from_file_location("team_caller_subject", path)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)
        cls.corpus = (CANDIDATE / CORPUS_PATH).read_bytes()

    def test_literal_closed_stdout(self):
        self.assertIsNone(self.module.admit_output(EXPECTED, b"", self.corpus))

    def test_missing_case_refuses(self):
        with self.assertRaises(self.module.MetadataRefusal):
            self.module.admit_output(
                EXPECTED.replace(b"CASE absent-team PASS\n", b""), b"", self.corpus
            )

    def test_failure_duplicate_and_extra_refuse(self):
        for value in (
            EXPECTED.replace(b"CASE absent-team PASS", b"CASE absent-team FAIL"),
            EXPECTED + b"CASE inventory PASS\n",
            EXPECTED + b"unrecognized\n",
        ):
            with (
                self.subTest(value=value),
                self.assertRaises(self.module.MetadataRefusal),
            ):
                self.module.admit_output(value, b"", self.corpus)

    def test_stderr_and_corpus_drift_refuse(self):
        with self.assertRaises(self.module.MetadataRefusal):
            self.module.admit_output(EXPECTED, b"warning\n", self.corpus)
        with self.assertRaises(self.module.MetadataRefusal):
            self.module.admit_output(EXPECTED, b"", self.corpus + b" ")

    def test_native_control_and_oracle_whole_bytes(self):
        self.assertEqual(
            (CANDIDATE / CPP_PATH).read_bytes(),
            (PACKET / "before/native_team_metadata_control.cpp").read_bytes(),
        )
        self.assertEqual(self.corpus, (PACKET / "before/CASES-BEFORE-CODE.json").read_bytes())

    def test_existing_caller_exact_inverse_and_post_products_guard(self):
        current = (CANDIDATE / SWIFT_PATH).read_text()
        self.assertEqual(current.count(INITIALIZER_CONTROLS_ADDITION), 1)
        current = current.replace(INITIALIZER_CONTROLS_ADDITION, "", 1)
        self.assertEqual(current.count(PRODUCT_DIFFERENCE_AXES_ADDITION), 1)
        current = current.replace(PRODUCT_DIFFERENCE_AXES_ADDITION, "", 1)
        self.assertEqual(current.count(OFFLINE_VHD_ADDITION), 1)
        current = current.replace(OFFLINE_VHD_ADDITION, "", 1)
        self.assertEqual(current.count(LEXICAL_PATH_ADDITION), 1)
        current = current.replace(LEXICAL_PATH_ADDITION, "", 1)
        self.assertEqual(current.count(LEXICAL_CLOSURE_ADDITION), 1)
        current = current.replace(LEXICAL_CLOSURE_ADDITION, "", 1)
        self.assertEqual(current.count(FIXED_BUILDER_SIZE_ADDITION), 1)
        current = current.replace(FIXED_BUILDER_SIZE_ADDITION, "", 1)
        self.assertEqual(current.count(PRODUCT_CURRENTNESS_ADDITION), 1)
        current = current.replace(PRODUCT_CURRENTNESS_ADDITION, "", 1)
        self.assertEqual(current.count(FOLLOWING_PROFILE_ADDITION), 1)
        current = current.replace(FOLLOWING_PROFILE_ADDITION, "", 1)
        self.assertEqual(current.count(CURRENT_PROFILE_CONSUMER), 1)
        current = current.replace(CURRENT_PROFILE_CONSUMER, HISTORICAL_PROFILE_CONSUMER, 1)
        self.assertEqual(current.count(OWNED_REFUSAL_DIAGNOSTIC), 1)
        current = current.replace(
            OWNED_REFUSAL_DIAGNOSTIC, "\t\t\tXCTAssertEqual(compiled.status, 0)\n", 1
        )
        before = (PACKET / "before" / SWIFT_PATH).read_text()
        self.assertEqual(current.count(ADDITION), 1)
        self.assertEqual(current.replace(ADDITION, "", 1), before)
        self.assertLess(
            current.index("XCTAssertTrue(products.stderr.isEmpty)"),
            current.index(ADDITION),
        )
        self.assertLess(current.index("guard ownedEvidence.status == 0"), current.index(ADDITION))
        self.assertLess(current.index("guard baselineReceipt.status == 0"), current.index(ADDITION))
        self.assertNotIn("runSourceCompilation", ADDITION)
        self.assertNotIn("runOwnedRuntimeCompilation", ADDITION)

    def test_no_existing_budgets_or_phase_owner_copies(self):
        source = (CANDIDATE / MODULE_PATH).read_text()
        self.assertIn("deadline = time.monotonic() + 30", source)
        self.assertIn("builder.BASE.run_phase(", source)
        self.assertNotIn("subprocess", source)
        self.assertNotIn("acquire_xcodegen", source)
        self.assertNotIn("clone", source)
        self.assertNotIn("MODELED_ONLY", source)
        self.assertNotIn("sdk", ADDITION.lower())


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PortableSourceTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    passed = result.wasSuccessful() and result.testsRun == 7 and not result.skipped
    print(
        ("PASS" if passed else "FAIL")
        + " portable CF Team metadata caller tests="
        + str(result.testsRun)
        + " failures="
        + str(len(result.failures))
        + " errors="
        + str(len(result.errors))
        + " skipped="
        + str(len(result.skipped))
    )
    raise SystemExit(0 if passed else 1)
