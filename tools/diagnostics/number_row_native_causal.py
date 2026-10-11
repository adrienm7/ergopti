"""Receive only the private final-byte counterfactual, never a product-source pass."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

import keyboard_geometry_xctest_receipt as positive

CLASS = "NumberRowSourceProbeTests"
TARGET = "testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject"
# Independently enrolled identities, not generated from the changed producer.
METHODS = (
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
    TARGET,
)
PRODUCER_SHA = "6b09c1ba4203f7b20bdabeac2800c2547898a75b9fdd6135dfa5bb18b680cd02"
TEST_SHA = "c5fc9a251c9de50196e0ef97ee7741ecdc3e01078cbeb7f77fabd6927a2a20c3"
MANIFEST_SHA = "77118a5238f504b1475988957843427f61aaaa798ab9f972e812205a2fb5b7ba"
NEEDLE = b"Data(bytes: currentBytes, count: CFDataGetLength(currentData)) == originalBytes"
POSITIVE_SHA = "9cef4f9256f3604ac07d710d77c95424718012f23c6a8b472f9e5936253ac094"
TRANSPORT_SHA = "f62344840267ab207370df974cc344fce83cbe3b758f2a25c986837a41d04269"


def SHA(data):
    return hashlib.sha256(data).hexdigest()


# The transport decoder remains the existing module. These fixture/restoration
# predicates are copied from the existing positive workflow without relaxation.
TIS_SCRIPT = r"""
const fs = require('node:fs');
const crypto = require('node:crypto');
const transport = require(process.argv[1]);
const root = process.argv[2];
const beforeStart = fs.readFileSync(root + '/start.json');
const beforeManifest = fs.readFileSync(root + '/manifest.json');
const session = transport.validate(root, process.argv[3]);
const expectedSources = {
  testActualSelectedUSPlainAndShiftUseUnchangedIndependentExpectations: 'com.apple.keylayout.US',
  testActualFrenchDeadStateDoesNotLeakIntoNextPositionOrSuccessor: 'com.apple.keylayout.French',
  testFrozenNativeLayoutIsAlignedDetachedFromControlledMutableStorage: 'com.apple.keylayout.US',
  testActualUSCapsMaskChangesAnIndependentLetterExpectation: 'com.apple.keylayout.US',
  testActualCarbonCapsDomainsPreserveNativeModifierAndDeadStateABI: 'com.apple.keylayout.French',
  testActualLayoutRefusesChangedSourceTypeDataOrUnavailableFinalRead: 'com.apple.keylayout.US',
  testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject: 'com.apple.keylayout.US'
};
const expected = Object.keys(expectedSources).sort();
const observed = session.receipts.map((row) => {
  if (row.test.state !== 'present' || row.omittedEvents !== 0) throw new Error('native diagnostic identity refused');
  const match = /^(?:(?:\w+\.)?NumberRowSourceProbeTests\.|-\[(?:\w+\.)?NumberRowSourceProbeTests )(test\w+)(?:\])?:(com\.apple\.keylayout\.(?:US|French))$/.exec(row.test.value);
  if (!match || !Object.hasOwn(expectedSources, match[1]) || match[2] !== expectedSources[match[1]]) throw new Error('foreign native method fixture');
  const captures = row.events.filter((event) => event.phase === 'original.capture');
  if (captures.length !== 1 || captures[0].original?.id?.state !== 'present' || typeof captures[0].original.id.value !== 'string' || captures[0].original.id.value.length === 0) throw new Error('captured original source unavailable');
  const originalID = captures[0].original.id.value;
  for (const phase of ['restore.inner.after', 'restore.outer.after']) {
    const events = row.events.filter((event) => event.phase === phase);
    if (events.length !== 1 || events[0].status !== 0) throw new Error('native source restoration refused');
    if (events[0].original?.id?.state !== 'present' || events[0].original.id.value !== originalID || events[0].current?.id?.state !== 'present' || events[0].current.id.value !== originalID) throw new Error('sampled selected source restoration refused');
  }
  return match[1];
}).sort();
if (!session.complete || JSON.stringify(observed) !== JSON.stringify(expected)) throw new Error('exact seven native diagnostic closures refused');
if (!beforeStart.equals(fs.readFileSync(root + '/start.json')) || !beforeManifest.equals(fs.readFileSync(root + '/manifest.json'))) throw new Error('terminal replacement refused');
process.stdout.write(JSON.stringify({complete: true, count: 7, methods: observed, session: process.argv[3], manifestSHA256: crypto.createHash('sha256').update(beforeManifest).digest('hex')}));
"""


def verify_mutation(original, counterfactual, test_source):
    if SHA(original) != PRODUCER_SHA or SHA(test_source) != TEST_SHA:
        raise ValueError("original producer/test source unavailable")
    if original.count(NEEDLE) != 1 or counterfactual != original.replace(NEEDLE, b"true", 1):
        raise ValueError("sole permitted final-byte omission refused")
    if sorted(re.findall(rb"\bfunc (test\w+)\(\)", test_source)) != sorted(
        x.encode() for x in METHODS
    ):
        raise ValueError("independent twelve-case census refused")
    return {
        "original_producer_sha256": SHA(original),
        "counterfactual_producer_sha256": SHA(counterfactual),
        "test_sha256": SHA(test_source),
        "image_role": "private-counterfactual-not-canonical-product",
        "counterfactual_git_blob": None,
    }


def materialize_projection(repo, head, manifest_path, destination):
    """Copy only pinned Git inputs to a fresh outside root; omit one predicate."""
    manifest_bytes = manifest_path.read_bytes()
    if SHA(manifest_bytes) != MANIFEST_SHA:
        raise ValueError("pinned projection recipe refused")
    manifest = json.loads(manifest_bytes)
    repo = repo.resolve()
    destination = destination.resolve()
    if destination.exists() or destination.is_relative_to(repo) or repo.is_relative_to(destination):
        raise ValueError("fresh outside projection required")
    if head != manifest["original_head"]:
        raise ValueError("original source head refused")
    observed_head = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=repo, text=True
    ).strip()
    if observed_head != head:
        raise ValueError("actual current Git source changed")
    inputs = {}
    for row in manifest["paths"]:
        spec = head + ":" + row["path"]
        data = subprocess.check_output(["git", "show", spec], cwd=repo)
        blob = subprocess.check_output(["git", "rev-parse", spec], cwd=repo, text=True).strip()
        if SHA(data) != row["sha256"] or blob != row["git_blob"]:
            raise ValueError("original Git input refused")
        inputs[row["path"]] = data
    producer = manifest["permitted_omission"]["path"]
    tests = manifest["original_test_source_unchanged"]
    original = inputs[producer]
    counterfactual = original.replace(NEEDLE, b"true", 1)
    verify_mutation(original, counterfactual, inputs[tests])
    inputs[producer] = counterfactual
    destination.mkdir()
    for path, data in inputs.items():
        item = destination / path
        item.parent.mkdir(parents=True, exist_ok=True)
        item.write_bytes(data)
    return verify_projection(manifest_path, destination, original)


def verify_projection(manifest_path, root, original):
    data = manifest_path.read_bytes()
    if SHA(data) != MANIFEST_SHA:
        raise ValueError("pinned projection recipe refused")
    manifest = json.loads(data)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("projection root refused")
    rows = {row["path"]: row for row in manifest["paths"]}
    actual = set()
    for item in root.rglob("*"):
        if item.is_symlink():
            raise ValueError("projection symlink refused")
        if item.is_file():
            actual.add(item.relative_to(root).as_posix())
    if actual != set(rows):
        raise ValueError("exact projection input census refused")
    producer = manifest["permitted_omission"]["path"]
    tests = manifest["original_test_source_unchanged"]
    for path, row in rows.items():
        expected = SHA(original.replace(NEEDLE, b"true", 1)) if path == producer else row["sha256"]
        if SHA((root / path).read_bytes()) != expected:
            raise ValueError("projection source image refused: " + path)
    return verify_mutation(original, (root / producer).read_bytes(), (root / tests).read_bytes())


def method_identity(identity):
    match = re.fullmatch(r"(?:\w+\.)?" + CLASS + r"\.(test\w+)", identity)
    if match is None:
        match = re.fullmatch(r"-\[(?:\w+\.)?" + CLASS + r" (test\w+)\]", identity)
    if match is None or match[1] not in METHODS:
        raise ValueError("foreign XCTest identity")
    return match[1]


def evaluate(test_source, log, swift_exit, capture_exit, tis, tis_exit):
    if SHA(Path(positive.__file__).read_bytes()) != POSITIVE_SHA:
        raise ValueError("original positive receiver changed")
    if type(swift_exit) is not int or not 1 <= swift_exit <= 255:
        raise ValueError("actual Swift expected-red status refused")
    if (
        type(capture_exit) is not int
        or capture_exit != 0
        or type(tis_exit) is not int
        or tis_exit != 0
    ):
        raise ValueError("capture or TIS decoder failed")
    if SHA(test_source) != TEST_SHA:
        raise ValueError("original test source changed")
    normalized = log.replace("\r\n", "\n")
    starts, ends, assertions = [], [], []
    selected_started = selected_failed = selected_passed = 0
    active = None
    for line in normalized.splitlines():
        selected_started += bool(re.match(r"^Test Suite 'Selected tests' started at ", line))
        selected_failed += bool(re.match(r"^Test Suite 'Selected tests' failed at ", line))
        selected_passed += bool(re.match(r"^Test Suite 'Selected tests' passed at ", line))
        row = re.match(r"^Test Case '(.+)' (started\.|passed \(|failed \(|skipped \()", line)
        if row:
            method = method_identity(row[1])
            if row[2] == "started.":
                if active is not None:
                    raise ValueError("overlapping XCTest start")
                active = method
                starts.append(method)
            else:
                if active != method:
                    raise ValueError("XCTest terminal without exact start")
                active = None
                ends.append((method, row[2]))
        # No tolerance for a different assertion or a compiler/runtime error.
        if "error:" in line or "XCTAssert" in line and " failed" in line:
            match = re.fullmatch(
                r".*NumberRowSourceProbeTests\.swift:321: error: (.+) : XCTAssertThrowsError failed: did not throw error(?: - ?)?",
                line,
            )
            if match is None or method_identity(match[1]) != TARGET or active != TARGET:
                raise ValueError("unrelated or unbound XCTest assertion")
            assertions.append(TARGET)
    expected_ends = sorted((m, "failed (" if m == TARGET else "passed (") for m in METHODS)
    if active is not None or sorted(starts) != sorted(METHODS) or sorted(ends) != expected_ends:
        raise ValueError("exact eleven-pass one-fail cohort refused")
    if (selected_started, selected_failed, selected_passed) != (1, 1, 0) or assertions != [TARGET]:
        raise ValueError("exact named causal assertion refused")
    summaries = re.findall(
        r"^\s*Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)",
        normalized,
        re.MULTILINE,
    )
    if (
        not summaries
        or any(row != ("12", "1", "0") for row in summaries)
        or re.search(r"^Test Suite '.+' passed at ", normalized, re.MULTILINE)
    ):
        raise ValueError("contradictory XCTest suite summary")
    seven = sorted(METHODS[:6] + (TARGET,))
    if (
        not isinstance(tis, dict)
        or tis.get("complete") is not True
        or type(tis.get("count")) is not int
        or tis["count"] != 7
        or tis.get("methods") != seven
    ):
        raise ValueError("seven exact TIS closures unavailable")
    unchanged = positive.evaluate(test_source.decode("utf-8"), log, CLASS, swift_exit, capture_exit)
    if (
        unchanged["complete"] is not False
        or unchanged["passed"] is not False
        or unchanged["failures"] != [TARGET]
        or unchanged["expected_count"] != 12
        or unchanged["received_count"] != 12
    ):
        raise ValueError("original positive receiver unexpectedly admitted counterfactual")
    return {
        "schema": 1,
        "scope": "number-row-final-byte-single-omission",
        "expected_red_received": True,
        "causal_method": TARGET,
        "passed_case_count": 11,
        "failed_case_count": 1,
        "skipped_case_count": 0,
        "swift_exit": swift_exit,
        "capture_exit": capture_exit,
        "original_positive_receipt": unchanged,
        "tis": tis,
        "image_role": "private-counterfactual-not-canonical-product",
        "canonical_product_source_qualified": False,
        "physical_keyboard_qualified": False,
        "application_launch_qualified": False,
    }


def main():
    parser = argparse.ArgumentParser()
    for name in (
        "manifest",
        "projection",
        "original-producer",
        "test-source",
        "log",
        "transport",
        "tis-root",
        "receipt",
        "tis-stdout",
        "tis-stderr",
    ):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--node", type=Path, required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--swift-exit", type=int, required=True)
    parser.add_argument("--capture-exit", type=int, required=True)
    args = parser.parse_args()
    try:
        proof = verify_projection(
            args.manifest, args.projection, args.original_producer.read_bytes()
        )
        if (
            args.test_source.read_bytes()
            != (
                args.projection
                / json.loads(args.manifest.read_bytes())["original_test_source_unchanged"]
            ).read_bytes()
        ):
            raise ValueError("test source detached from projection")
        if SHA(args.transport.read_bytes()) != TRANSPORT_SHA:
            raise ValueError("original TIS transport changed")
        # Validate through the unchanged transport, not a caller-supplied verdict.
        raw = subprocess.run(
            [
                str(args.node),
                "-e",
                TIS_SCRIPT,
                str(args.transport.resolve()),
                str(args.tis_root.resolve()),
                args.session,
            ],
            capture_output=True,
            timeout=15,
            check=False,
        )
        args.tis_stdout.open("xb").write(raw.stdout)
        args.tis_stderr.open("xb").write(raw.stderr)
        tis = json.loads(raw.stdout) if raw.returncode == 0 else None
        result = evaluate(
            args.test_source.read_bytes(),
            args.log.read_text(encoding="utf-8"),
            args.swift_exit,
            args.capture_exit,
            tis,
            raw.returncode,
        )
        result["projection_proof"] = proof
        status = 0
    except (OSError, UnicodeError, ValueError, subprocess.TimeoutExpired) as error:
        result = {
            "schema": 1,
            "expected_red_received": False,
            "reason": str(error),
            "canonical_product_source_qualified": False,
            "physical_keyboard_qualified": False,
            "application_launch_qualified": False,
        }
        status = 1
    with args.receipt.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(result, stream, sort_keys=True)
        stream.write("\n")
    return status


if __name__ == "__main__":
    sys.exit(main())
