"""Portable receiver controls; synthetic expected-red data is never native proof."""

import argparse
import copy
import gzip
import io
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import tarfile
import unittest

# Paths are explicit enrollment inputs; canonical installation must not infer a
# private packet or fall back to another checkout/artifact directory.
parser = argparse.ArgumentParser(description=__doc__)
for name in (
    "fixture-manifest",
    "projection",
    "receiving",
    "receiver",
    "positive-receiver",
    "transport",
    "node",
):
    parser.add_argument("--" + name, type=Path, required=True)
args, unittest_args = parser.parse_known_args()
FIXTURE_MANIFEST_SHA = "50fbec17bdd2f624bf65c6e16613deb2c0ddd2b9d6eff10a640520780770b8d1"
fixture_data = args.fixture_manifest.read_bytes()
if hashlib.sha256(fixture_data).hexdigest() != FIXTURE_MANIFEST_SHA:
    raise ValueError("immutable portable fixture manifest refused")
fixture_manifest = json.loads(fixture_data)
FIXTURES = args.fixture_manifest.resolve().parent
EXPECTED_INPUTS = (
    "NumberRowSourceProbe.original.swift.raw",
    "NumberRowSourceProbeTests.original.swift.raw",
    "NumberRowSourceProbe.counterfactual.swift.raw",
    "historical-positive.raw",
    "projection-manifest.original-c15.json.raw",
    "historical-tis/start.json.raw",
    "historical-tis/manifest.json.raw",
    "historical-tis/record-000001.dat",
    "historical-tis/record-000002.dat",
    "historical-tis/record-000003.dat",
    "historical-tis/record-000004.dat",
    "historical-tis/record-000005.dat",
    "historical-tis/record-000006.dat",
    "historical-tis/record-000007.dat",
)
if sorted(fixture_manifest["files"]) != sorted(EXPECTED_INPUTS):
    raise ValueError("exact portable fixture enrollment refused")
# The logical oracle stays exact; only its physical transport changes.
HISTORICAL_POSITIVE_ENVELOPE_SHA = (
    "969eb0c5b767c1636364849f844ce20197e0da30451f9952f1617f0f40308230"
)
HISTORICAL_POSITIVE_ARCHIVE_SHA = "9e25600adb72942a4512b5c091d72d64cb7cd9d7470425142ef0d7854b8be8f4"


def load_historical_positive():
    envelope_path = FIXTURES / "historical-positive-envelope.json"
    archive_path = FIXTURES / "historical-positive.tar.gz"
    for path in (envelope_path, archive_path):
        if path.is_symlink() or not path.is_file():
            raise ValueError("regular historical archive/envelope required")
    if envelope_path.stat().st_size > 4096:
        raise ValueError("bounded historical envelope required")
    envelope_data = envelope_path.read_bytes()
    if hashlib.sha256(envelope_data).hexdigest() != HISTORICAL_POSITIVE_ENVELOPE_SHA:
        raise ValueError("immutable historical generator envelope refused")
    envelope = json.loads(envelope_data)
    row = fixture_manifest["files"]["historical-positive.raw"]
    member_name = "evidence/historical-positive.raw.txt"
    if envelope["capsule"] != {
        "entries": [
            {
                "proposed_member": member_name,
                "source_path": row["retained_original_path"],
                "bytes": row["bytes"],
                "sha256": row["sha256"],
            }
        ],
        "files": 1,
        "bytes": row["bytes"],
    }:
        raise ValueError("exact single historical generator subject required")
    if not 0 < archive_path.stat().st_size <= 65536:
        raise ValueError("bounded historical archive required")
    archive_data = archive_path.read_bytes()
    with gzip.GzipFile(fileobj=io.BytesIO(archive_data), mode="rb") as zipped:
        tar_data = zipped.read(65537)
    if len(tar_data) > 65536:
        raise ValueError("bounded historical tar required")
    with tarfile.open(fileobj=io.BytesIO(tar_data), mode="r:") as archive:
        members = archive.getmembers()
        if len(members) != 1 or members[0].name != member_name:
            raise ValueError("exact single historical archive member required")
        member = members[0]
        if not member.isreg() or member.pax_headers or member.mode != 0o600 or member.mtime != 0:
            raise ValueError("regular inert historical archive member required")
        if member.size != row["bytes"]:
            raise ValueError("immutable historical native bytes changed")
        with archive.extractfile(member) as source:
            data = source.read(row["bytes"] + 1)
    if len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != row["sha256"]:
        raise ValueError("immutable historical native bytes changed")
    if hashlib.sha256(archive_data).hexdigest() != HISTORICAL_POSITIVE_ARCHIVE_SHA:
        raise ValueError("immutable historical archive transport changed")
    return data


HISTORICAL_POSITIVE_BYTES = load_historical_positive()
for name in EXPECTED_INPUTS:
    row = fixture_manifest["files"][name]
    if name == "historical-positive.raw":
        data = HISTORICAL_POSITIVE_BYTES
    else:
        path = FIXTURES / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("regular enrolled portable fixture required")
        data = path.read_bytes()
    if len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != row["sha256"]:
        raise ValueError("immutable portable fixture bytes changed")
RECEIVING = args.receiving.resolve()
PROJECTION = args.projection.resolve()
if (
    not RECEIVING.is_dir()
    or args.receiving.is_symlink()
    or not PROJECTION.is_dir()
    or args.projection.is_symlink()
):
    raise ValueError("explicit existing private receiving/projection roots required")
if (
    RECEIVING == FIXTURES
    or RECEIVING.is_relative_to(FIXTURES)
    or FIXTURES.is_relative_to(RECEIVING)
    or RECEIVING == PROJECTION
    or RECEIVING.is_relative_to(PROJECTION)
    or PROJECTION.is_relative_to(RECEIVING)
):
    raise ValueError("scratch must be separate from immutable fixtures/projection")


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


positive = load_module("keyboard_geometry_xctest_receipt", args.positive_receiver)
subject = load_module("number_row_native_causal", args.receiver)
TRANSPORT = args.transport.resolve()
if hashlib.sha256(TRANSPORT.read_bytes()).hexdigest() != subject.TRANSPORT_SHA:
    raise ValueError("unchanged TIS transport required")
NODE = str(args.node.resolve())
NAMES = (
    "testActualSelectedUSPlainAndShiftUseUnchangedIndependentExpectations",
    "testActualFrenchDeadStateDoesNotLeakIntoNextPositionOrSuccessor",
    "testFrozenNativeLayoutIsAlignedDetachedFromControlledMutableStorage",
    "testActualUSCapsMaskChangesAnIndependentLetterExpectation",
    "testActualCarbonCapsDomainsPreserveNativeModifierAndDeadStateABI",
    "testActualLayoutRefusesChangedSourceTypeDataOrUnavailableFinalRead",
    "testMissingUnicodeDataAndForeignInitialIdentityNeverReadFallback",
    "testInvalidInvocationRefusesBeforeAnyNativeRead",
    "testHeadlessRoleRequiresTenCanonicalDistinctPositionsAndBoundedIdentity",
    "testWorkerPreservesUInt32DeadStateAndExactFortyRowOrder",
    "testWorkerRefusesPartialForeignOrMislabelledFactsWithoutPublication",
    "testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject",
)
TARGET = NAMES[-1]
TEST_SOURCE = (FIXTURES / "NumberRowSourceProbeTests.original.swift.raw").read_bytes()
ORIGINAL = (FIXTURES / "NumberRowSourceProbe.original.swift.raw").read_bytes()
COUNTERFACTUAL = (FIXTURES / "NumberRowSourceProbe.counterfactual.swift.raw").read_bytes()
# Preserve Path.read_text's original universal-newline behavior after exact-byte admission.
with io.TextIOWrapper(
    io.BytesIO(HISTORICAL_POSITIVE_BYTES), encoding="utf-8", newline=None
) as baseline:
    BASELINE = baseline.read()
BASE_TIS = FIXTURES / "historical-tis"
MANIFEST = json.loads((BASE_TIS / "manifest.json.raw").read_bytes())
SESSION = MANIFEST["session"]


def identity(method):
    return "-[ErgoptiPlusTests.NumberRowSourceProbeTests " + method + "]"


def synthetic_red():
    # The source-bound failed assertion is synthetic, not an observed Swift run.
    log = BASELINE.replace("\r\n", "\n")
    start = "Test Case '" + identity(TARGET) + "' started."
    assertion = (
        "/private/projection/NumberRowSourceProbeTests.swift:321: error: "
        + identity(TARGET)
        + " : XCTAssertThrowsError failed: did not throw error - "
    )
    assert log.count(start) == 1
    log = log.replace(start, start + "\n" + assertion)
    terminal = "Test Case '" + identity(TARGET) + "' passed ("
    assert log.count(terminal) == 1
    log = log.replace(terminal, "Test Case '" + identity(TARGET) + "' failed (")
    log = re.sub(r"^(Test Suite '.+') passed at ", r"\1 failed at ", log, flags=re.MULTILINE)
    log = log.replace("with 0 failures (0 unexpected)", "with 1 failure (0 unexpected)")
    return log


RED = synthetic_red()
TIS = {"complete": True, "count": 7, "methods": sorted(NAMES[:6] + (TARGET,))}


def receive(log=RED, swift=1, capture=0, tis=None, tis_exit=0):
    return subject.evaluate(
        TEST_SOURCE, log, swift, capture, copy.deepcopy(TIS if tis is None else tis), tis_exit
    )


class SourceControls(unittest.TestCase):
    def test_source_exact_single_omission(self):
        proof = subject.verify_mutation(ORIGINAL, COUNTERFACTUAL, TEST_SOURCE)
        self.assertEqual(proof["image_role"], "private-counterfactual-not-canonical-product")
        self.assertIsNone(proof["counterfactual_git_blob"])
        self.assertEqual(
            COUNTERFACTUAL,
            ORIGINAL.replace(
                b"Data(bytes: currentBytes, count: CFDataGetLength(currentData)) == originalBytes",
                b"true",
                1,
            ),
        )

    def test_source_original_is_not_counterfactual(self):
        with self.assertRaises(ValueError):
            subject.verify_mutation(ORIGINAL, ORIGINAL, TEST_SOURCE)

    def test_source_other_predicate_omission_refused(self):
        extra = COUNTERFACTUAL.replace(b"current.keyboardType == snapshot.keyboardType", b"true", 1)
        self.assertNotEqual(extra, COUNTERFACTUAL)
        with self.assertRaises(ValueError):
            subject.verify_mutation(ORIGINAL, extra, TEST_SOURCE)

    def test_source_test_assertion_change_refused(self):
        changed = TEST_SOURCE.replace(b"XCTAssertEqual(reads, 2)", b"XCTAssertEqual(reads, 1)", 1)
        self.assertNotEqual(changed, TEST_SOURCE)
        with self.assertRaises(ValueError):
            subject.verify_mutation(ORIGINAL, COUNTERFACTUAL, changed)

    def test_original_positive_historical_twelve_pass(self):
        result = subject.positive.evaluate(
            TEST_SOURCE.decode(), BASELINE, "NumberRowSourceProbeTests", 0, 0
        )
        self.assertIs(result["passed"], True)
        self.assertIs(result["complete"], True)
        self.assertEqual(result["expected_count"], 12)
        self.assertEqual(result["received_count"], 12)
        self.assertEqual(result["failures"], [])

    def test_original_positive_rejects_synthetic_red(self):
        result = subject.positive.evaluate(
            TEST_SOURCE.decode(), RED, "NumberRowSourceProbeTests", 1, 0
        )
        self.assertIs(result["passed"], False)
        self.assertIs(result["complete"], False)
        self.assertEqual(result["failures"], [TARGET])

    def test_expected_red_receiver_accepts_single_synthetic_failure(self):
        result = receive()
        self.assertIs(result["expected_red_received"], True)
        self.assertIs(result["canonical_product_source_qualified"], False)
        self.assertEqual(
            (
                result["passed_case_count"],
                result["failed_case_count"],
                result["skipped_case_count"],
            ),
            (11, 1, 0),
        )
        self.assertIs(result["original_positive_receipt"]["complete"], False)

    def test_expected_red_dotted_identity_supported(self):
        log = RED
        for name in NAMES:
            log = log.replace(identity(name), "ErgoptiPlusTests.NumberRowSourceProbeTests." + name)
        self.assertIs(receive(log)["expected_red_received"], True)


# Each independent mutation must change the fixture and be refused. This list is
# the fixed portable outcome census, not an oracle regenerated by the subject.
TRANSCRIPT_CONTROLS = {
    "swift_zero": lambda: (RED, 0, 0, TIS, 0),
    "swift_signal": lambda: (RED, -15, 0, TIS, 0),
    "swift_bool": lambda: (RED, True, 0, TIS, 0),
    "capture_nonzero": lambda: (RED, 1, 1, TIS, 0),
    "capture_bool": lambda: (RED, 1, False, TIS, 0),
    "tis_nonzero": lambda: (RED, 1, 0, TIS, 1),
    "tis_false_complete": lambda: (RED, 1, 0, {**TIS, "complete": False}, 0),
    "tis_six_records": lambda: (RED, 1, 0, {**TIS, "count": 6}, 0),
    "tis_wrong_name": lambda: (
        RED,
        1,
        0,
        {**TIS, "methods": sorted(NAMES[:6] + ("testForeign",))},
        0,
    ),
    "original_all_pass": lambda: (BASELINE, 1, 0, TIS, 0),
    "compiler_only": lambda: ("error: failed to compile\n", 1, 0, TIS, 0),
    "missing_named_assertion": lambda: (
        re.sub(r"^.*NumberRowSourceProbeTests.swift:321: error:.*\n", "", RED, flags=re.MULTILINE),
        1,
        0,
        TIS,
        0,
    ),
    "other_assertion": lambda: (
        RED.replace(
            "XCTAssertThrowsError failed: did not throw error",
            "XCTAssertEqual failed: wrong output",
        ),
        1,
        0,
        TIS,
        0,
    ),
    "wrong_source_line": lambda: (
        RED.replace(".swift:321: error:", ".swift:339: error:"),
        1,
        0,
        TIS,
        0,
    ),
    "assertion_not_active": lambda: (
        RED
        + "/private/NumberRowSourceProbeTests.swift:321: error: "
        + identity(TARGET)
        + " : XCTAssertThrowsError failed: did not throw error - \n",
        1,
        0,
        TIS,
        0,
    ),
    "extra_runtime_error": lambda: (RED + "error: native service failed\n", 1, 0, TIS, 0),
    "other_case_fails": lambda: (
        RED.replace(
            "Test Case '" + identity(NAMES[0]) + "' passed (",
            "Test Case '" + identity(NAMES[0]) + "' failed (",
        ),
        1,
        0,
        TIS,
        0,
    ),
    "target_skip": lambda: (
        RED.replace(
            "Test Case '" + identity(TARGET) + "' failed (",
            "Test Case '" + identity(TARGET) + "' skipped (",
        ),
        1,
        0,
        TIS,
        0,
    ),
    "missing_terminal": lambda: (
        re.sub(
            r"^Test Case '" + re.escape(identity(NAMES[0])) + r"' passed .*\n",
            "",
            RED,
            flags=re.MULTILINE,
        ),
        1,
        0,
        TIS,
        0,
    ),
    "duplicate_start": lambda: (
        RED.replace(
            "Test Case '" + identity(NAMES[0]) + "' started.",
            "Test Case '"
            + identity(NAMES[0])
            + "' started.\nTest Case '"
            + identity(NAMES[0])
            + "' started.",
        ),
        1,
        0,
        TIS,
        0,
    ),
    "foreign_class": lambda: (
        RED.replace(
            "NumberRowSourceProbeTests testWorkerRefuses", "ForeignTests testWorkerRefuses"
        ),
        1,
        0,
        TIS,
        0,
    ),
    "missing_selected_terminal": lambda: (
        re.sub(r"^Test Suite 'Selected tests' failed at .*\n", "", RED, flags=re.MULTILINE),
        1,
        0,
        TIS,
        0,
    ),
    "selected_passed": lambda: (
        RED.replace(
            "Test Suite 'Selected tests' failed at ", "Test Suite 'Selected tests' passed at "
        ),
        1,
        0,
        TIS,
        0,
    ),
    "contradictory_summary": lambda: (
        RED.replace("with 1 failure (0 unexpected)", "with 0 failures (0 unexpected)", 1),
        1,
        0,
        TIS,
        0,
    ),
}


class TranscriptControls(unittest.TestCase):
    pass


def transcript_case(make):
    def test(self):
        args = make()
        baseline = (RED, 1, 0, TIS, 0)
        self.assertTrue(
            any(type(a) is not type(b) or a != b for a, b in zip(args, baseline)),
            "control must perturb value or type",
        )
        with self.assertRaises(ValueError):
            subject.evaluate(TEST_SOURCE, *args)

    return test


for name, make in TRANSCRIPT_CONTROLS.items():
    setattr(TranscriptControls, "test_refuse_" + name, transcript_case(make))


# These controls run the existing real decoder and the exact native restoration
# predicates on privately copied historical records. They do not run Carbon.
def mutate_record(root, change):
    path = root / "record-000001.dat"
    prefix = b"TIS_TEST_EVIDENCE "
    raw = path.read_bytes()
    row = json.loads(raw[len(prefix) :])
    change(row)
    data = prefix + json.dumps(row, separators=(",", ":")).encode() + b"\n"
    path.write_bytes(data)
    manifest = json.loads((root / "manifest.json").read_bytes())
    manifest["records"][0]["bytes"] = len(data)
    manifest["records"][0]["sha256"] = hashlib.sha256(data).hexdigest()
    (root / "manifest.json").write_text(json.dumps(manifest))


def event(row, phase):
    return next(e for e in row["events"] if e["phase"] == phase)


TIS_CONTROLS = {
    "missing_capture": lambda root: mutate_record(
        root,
        lambda row: row.update(
            events=[e for e in row["events"] if e["phase"] != "original.capture"]
        ),
    ),
    "duplicate_capture": lambda root: mutate_record(
        root, lambda row: row["events"].append(copy.deepcopy(event(row, "original.capture")))
    ),
    "missing_inner_restore": lambda root: mutate_record(
        root,
        lambda row: row.update(
            events=[e for e in row["events"] if e["phase"] != "restore.inner.after"]
        ),
    ),
    "duplicate_outer_restore": lambda root: mutate_record(
        root, lambda row: row["events"].append(copy.deepcopy(event(row, "restore.outer.after")))
    ),
    "nonzero_restore": lambda root: mutate_record(
        root, lambda row: event(row, "restore.outer.after").update(status=1)
    ),
    "current_id_mismatch": lambda root: mutate_record(
        root,
        lambda row: event(row, "restore.inner.after")["current"]["id"].update(
            value="com.apple.keylayout.Foreign"
        ),
    ),
    "retained_id_mismatch": lambda root: mutate_record(
        root,
        lambda row: event(row, "restore.outer.after")["original"]["id"].update(
            value="com.apple.keylayout.Foreign"
        ),
    ),
    "missing_original_id": lambda root: mutate_record(
        root,
        lambda row: event(row, "original.capture")["original"]["id"].update(
            state="missing", value=None
        ),
    ),
    "wrong_native_fixture": lambda root: mutate_record(
        root,
        lambda row: row["test"].update(
            value=row["test"]["value"].replace(
                "com.apple.keylayout.French", "com.apple.keylayout.US"
            )
            if "French" in row["test"]["value"]
            else row["test"]["value"].replace(
                "com.apple.keylayout.US", "com.apple.keylayout.French"
            )
        ),
    ),
    "omitted_events": lambda root: mutate_record(root, lambda row: row.update(omittedEvents=1)),
    "foreign_pid": lambda root: mutate_record(root, lambda row: row.update(pid=row["pid"] + 1)),
    "missing_record": lambda root: (root / "record-000007.dat").unlink(),
    "unhashed_record": lambda root: (root / "record-000001.dat").write_bytes(
        (root / "record-000001.dat").read_bytes() + b" "
    ),
}


class TransportControls(unittest.TestCase):
    def test_actual_pinned_node_version(self):
        raw = subprocess.run([NODE, "--version"], capture_output=True, timeout=5, check=False)
        self.assertEqual((raw.returncode, raw.stdout, raw.stderr), (0, b"v22.22.2\n", b""))

    def test_unchanged_transport_and_seven_restoration_predicates_positive(self):
        raw = transport_run(None)
        self.assertEqual(raw.returncode, 0, raw.stderr.decode())
        result = json.loads(raw.stdout)
        self.assertIs(result["complete"], True)
        self.assertEqual(result["count"], 7)
        self.assertEqual(result["methods"], sorted(NAMES[:6] + (TARGET,)))


def transport_run(change):
    with tempfile.TemporaryDirectory(dir=RECEIVING) as temporary:
        root = Path(temporary) / "tis"
        shutil.copytree(BASE_TIS, root)
        (root / "start.json.raw").rename(root / "start.json")
        (root / "manifest.json.raw").rename(root / "manifest.json")
        if change is not None:
            change(root)
        return subprocess.run(
            [NODE, "-e", subject.TIS_SCRIPT, str(TRANSPORT), str(root), SESSION],
            capture_output=True,
            timeout=15,
            check=False,
        )


def transport_case(change):
    def test(self):
        raw = transport_run(change)
        self.assertNotEqual(raw.returncode, 0, "mutated TIS closure must be refused")
        self.assertEqual(raw.stdout, b"")
        self.assertTrue(raw.stderr)

    return test


for name, change in TIS_CONTROLS.items():
    setattr(TransportControls, "test_refuse_" + name, transport_case(change))


class ProjectionControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=RECEIVING)
        self.root = Path(self.temporary.name) / "projection"
        shutil.copytree(PROJECTION, self.root)
        self.recipe = FIXTURES / "projection-manifest.original-c15.json.raw"
        self.manifest = json.loads(self.recipe.read_bytes())

    def tearDown(self):
        self.temporary.cleanup()

    def verify(self):
        return subject.verify_projection(self.recipe, self.root, ORIGINAL)

    def test_exact_99_file_projection_positive(self):
        self.assertEqual(len(self.manifest["paths"]), 99)
        self.assertEqual(self.verify()["counterfactual_git_blob"], None)

    def test_projection_extra_source_refused(self):
        (self.root / "extra.swift").write_text("// not enrolled\n")
        with self.assertRaises(ValueError):
            self.verify()

    def test_projection_missing_source_refused(self):
        (self.root / self.manifest["paths"][0]["path"]).unlink()
        with self.assertRaises(ValueError):
            self.verify()

    def test_projection_foreign_source_change_refused(self):
        path = self.root / "static/ergopti_plus/macos/launcher/Package.swift"
        path.write_bytes(path.read_bytes() + b"\n// unadmitted difference\n")
        with self.assertRaises(ValueError):
            self.verify()

    def test_projection_original_producer_refused(self):
        (self.root / self.manifest["permitted_omission"]["path"]).write_bytes(ORIGINAL)
        with self.assertRaises(ValueError):
            self.verify()

    def test_projection_source_symlink_refused(self):
        (self.root / "unadmitted.swift").symlink_to(self.recipe)
        with self.assertRaises(ValueError):
            self.verify()


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *unittest_args], verbosity=2)
