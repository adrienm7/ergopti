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


# This is build provenance. Approval digests must be received independently;
# computing an expected digest from unreviewed current bytes grants no authority.
AUXILIARY_PATH = (
    "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/ManagedHTTPWireTests.swift"
)


def _closed_json(path, expected):
    if not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None:
        raise ValueError("independently received digest required")
    if path.is_symlink() or not path.is_file():
        raise ValueError("regular provenance input required")
    data = path.read_bytes()
    if len(data) > 131072 or SHA(data) != expected:
        raise ValueError("reviewed provenance image refused")

    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate provenance field refused")
            result[key] = value
        return result

    return json.loads(data, object_pairs_hook=unique)


# The set limits possible reviewed source roles. Membership alone is never
# approval: each accepted row requires the separately received envelope digest,
# its original tuple, and its actual published/current Git image.
COMPOSABLE_AUXILIARY_PATHS = frozenset(
    (
        AUXILIARY_PATH,
        "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/RemapLeaseWorker.swift",
        "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/RemapLeaseWorkerTests.swift",
    )
)


def _composition_list_contract(legacy, approval, approval_sha, composition):
    if (
        set(approval) != {"schema", "role", "approvals"}
        or type(approval["schema"]) is not int
        or approval["schema"] != 1
        or approval["role"] != "independently-reviewed-committed-source-inputs"
    ):
        raise ValueError("exact source approval envelope required")
    received = approval["approvals"]
    if not isinstance(received, list) or not 1 <= len(received) <= 3:
        raise ValueError("bounded nonempty source approval list required")
    old_rows = legacy["paths"]
    if len(old_rows) != 99 or len({row["path"] for row in old_rows}) != 99:
        raise ValueError("original ninety-nine input census refused")
    old_by_path = {row["path"]: row for row in old_rows}
    keys = {
        "schema",
        "role",
        "path",
        "original_git_blob",
        "original_sha256",
        "published_source_commit",
        "git_blob",
        "sha256",
        "source_review_sha256",
    }
    admitted = {}
    for record in received:
        if (
            not isinstance(record, dict)
            or set(record) != keys
            or type(record["schema"]) is not int
            or record["schema"] != 1
            or record["role"] != "independently-reviewed-committed-source-input"
        ):
            raise ValueError("exact received source approval row required")
        path = record["path"]
        if (
            not isinstance(path, str)
            or path not in COMPOSABLE_AUXILIARY_PATHS
            or path in admitted
            or path not in old_by_path
        ):
            raise ValueError("named unique auxiliary source required")
        for key, length in (
            ("original_git_blob", 40),
            ("original_sha256", 64),
            ("published_source_commit", 40),
            ("git_blob", 40),
            ("sha256", 64),
            ("source_review_sha256", 64),
        ):
            if (
                not isinstance(record[key], str)
                or re.fullmatch(r"[0-9a-f]{" + str(length) + r"}", record[key]) is None
            ):
                raise ValueError("exact received source identity required")
        old = old_by_path[path]
        if (
            record["original_git_blob"] != old["git_blob"]
            or record["original_sha256"] != old["sha256"]
        ):
            raise ValueError("historical auxiliary predecessor refused")
        if record["git_blob"] == old["git_blob"] or record["sha256"] == old["sha256"]:
            raise ValueError("unchanged input is not a new composition")
        admitted[path] = record
    rows = [dict(row) for row in old_rows]
    for row in rows:
        if row["path"] in admitted:
            record = admitted[row["path"]]
            row.update(git_blob=record["git_blob"], sha256=record["sha256"])
    expected = {
        "schema": 1,
        "role": "reviewed-build-input-composition-not-native-qualification",
        "historical_recipe_sha256": MANIFEST_SHA,
        "source_approval_sha256": approval_sha,
        "paths": rows,
    }
    if composition is not None and (
        not isinstance(composition, dict)
        or type(composition.get("schema")) is not int
        or composition != expected
    ):
        raise ValueError("exact reviewed auxiliary list composition refused")
    return legacy, approval, expected


def _composition_contract(recipe_path, approval_path, approval_sha, composition=None):
    legacy = _closed_json(recipe_path, MANIFEST_SHA)
    approval = _closed_json(approval_path, approval_sha)
    if isinstance(approval, dict) and "approvals" in approval:
        return _composition_list_contract(legacy, approval, approval_sha, composition)
    keys = {
        "schema",
        "role",
        "path",
        "original_git_blob",
        "original_sha256",
        "published_source_commit",
        "git_blob",
        "sha256",
        "source_review_sha256",
    }
    if not isinstance(approval, dict) or set(approval) != keys:
        raise ValueError("exact source approval record required")
    if (
        type(approval["schema"]) is not int
        or approval["schema"] != 1
        or approval["role"] != "independently-reviewed-committed-source-input"
    ):
        raise ValueError("source-input approval role refused")
    if approval["path"] != AUXILIARY_PATH:
        raise ValueError("only the named auxiliary source may compose")
    for key, length in (
        ("published_source_commit", 40),
        ("git_blob", 40),
        ("sha256", 64),
        ("source_review_sha256", 64),
    ):
        if (
            not isinstance(approval[key], str)
            or re.fullmatch(r"[0-9a-f]{" + str(length) + r"}", approval[key]) is None
        ):
            raise ValueError("exact received source identity required")
    old_rows = legacy["paths"]
    old = next(row for row in old_rows if row["path"] == AUXILIARY_PATH)
    if (
        approval["original_git_blob"] != old["git_blob"]
        or approval["original_sha256"] != old["sha256"]
    ):
        raise ValueError("historical auxiliary predecessor refused")
    if approval["git_blob"] == old["git_blob"] or approval["sha256"] == old["sha256"]:
        raise ValueError("unchanged input is not a new composition")
    if len(old_rows) != 99 or len({row["path"] for row in old_rows}) != 99:
        raise ValueError("original ninety-nine input census refused")
    rows = [dict(row) for row in old_rows]
    for row in rows:
        if row["path"] == AUXILIARY_PATH:
            row.update(git_blob=approval["git_blob"], sha256=approval["sha256"])
    expected = {
        "schema": 1,
        "role": "reviewed-build-input-composition-not-native-qualification",
        "historical_recipe_sha256": MANIFEST_SHA,
        "source_approval_sha256": approval_sha,
        "paths": rows,
    }
    if composition is not None and (
        not isinstance(composition, dict)
        or type(composition.get("schema")) is not int
        or composition != expected
    ):
        raise ValueError("sole reviewed auxiliary row composition refused")
    return legacy, approval, expected


def _git_input(repo, head, path):
    record = subprocess.check_output(["git", "ls-tree", "-z", head, "--", path], cwd=repo)
    pieces = record.split(b"\0")
    if len(pieces) != 2 or pieces[1] != b"":
        raise ValueError("one exact Git source path required")
    header, name = pieces[0].split(b"\t", 1)
    mode, kind, blob = header.decode().split()
    if name.decode() != path or kind != "blob" or mode not in ("100644", "100755"):
        raise ValueError("regular Git source input required")
    data = subprocess.check_output(["git", "show", head + ":" + path], cwd=repo)
    return data, blob, mode


def _current_composition_inputs(repo, head, legacy, approval, composition):
    repo = repo.resolve()

    def current():
        if (
            subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            != head
        ):
            raise ValueError("actual current source commit changed")

    current()
    if re.fullmatch(r"[0-9a-f]{40}", head) is None:
        raise ValueError("actual full source commit required")
    if "approvals" in approval:
        for record in approval["approvals"]:
            source_commit = record["published_source_commit"]
            ancestry = subprocess.run(
                ["git", "merge-base", "--is-ancestor", source_commit, head],
                cwd=repo,
                capture_output=True,
            )
            if ancestry.returncode != 0:
                raise ValueError("approved committed source is not an ancestor")
            approved, blob, mode = _git_input(repo, source_commit, record["path"])
            if blob != record["git_blob"] or SHA(approved) != record["sha256"] or mode != "100644":
                raise ValueError("approved committed auxiliary tuple refused")
    else:
        source_commit = approval["published_source_commit"]
        ancestry = subprocess.run(
            ["git", "merge-base", "--is-ancestor", source_commit, head],
            cwd=repo,
            capture_output=True,
        )
        if ancestry.returncode != 0:
            raise ValueError("approved committed source is not an ancestor")
        approved, blob, mode = _git_input(repo, source_commit, AUXILIARY_PATH)
        if blob != approval["git_blob"] or SHA(approved) != approval["sha256"] or mode != "100644":
            raise ValueError("approved committed auxiliary tuple refused")
    inputs, provenance = {}, []
    old_by_path = {row["path"]: row for row in legacy["paths"]}
    for row in composition["paths"]:
        path = row["path"]
        original, original_blob, original_mode = _git_input(repo, legacy["original_head"], path)
        old = old_by_path[path]
        if original_blob != old["git_blob"] or SHA(original) != old["sha256"]:
            raise ValueError("immutable historical Git input refused")
        data, blob, mode = _git_input(repo, head, path)
        item = repo / path
        if (
            item.is_symlink()
            or not item.is_file()
            or item.resolve().is_relative_to(repo) is not True
        ):
            raise ValueError("regular current source image required")
        if (
            blob != row["git_blob"]
            or SHA(data) != row["sha256"]
            or mode != original_mode
            or item.read_bytes() != data
        ):
            raise ValueError("reviewed actual source input drift refused: " + path)
        inputs[path] = data
        provenance.append(
            {
                "path": path,
                "historical_commit": legacy["original_head"],
                "historical_git_blob": old["git_blob"],
                "historical_sha256": old["sha256"],
                "actual_commit": head,
                "git_blob": blob,
                "sha256": SHA(data),
                "mode": mode,
            }
        )
    current()
    return inputs, provenance


def create_composition(repo, head, recipe_path, approval_path, approval_sha):
    """Validate a separately received committed tuple; never infer approval."""
    legacy, approval, composition = _composition_contract(recipe_path, approval_path, approval_sha)
    _current_composition_inputs(repo, head, legacy, approval, composition)
    return composition


def verify_composed_projection(
    repo,
    head,
    recipe_path,
    approval_path,
    approval_sha,
    composition_path,
    composition_sha,
    root,
    original,
):
    composition = _closed_json(composition_path, composition_sha)
    legacy, approval, composition = _composition_contract(
        recipe_path, approval_path, approval_sha, composition
    )
    inputs, provenance = _current_composition_inputs(repo, head, legacy, approval, composition)
    repo = repo.resolve()
    if (
        root.is_symlink()
        or not root.is_dir()
        or root.resolve().is_relative_to(repo)
        or repo.is_relative_to(root.resolve())
    ):
        raise ValueError("outside regular projection required")
    actual = set()
    for item in root.rglob("*"):
        if item.is_symlink() or not (item.is_file() or item.is_dir()):
            raise ValueError("regular projection members required")
        if item.is_file():
            actual.add(item.relative_to(root).as_posix())
    if actual != set(inputs):
        raise ValueError("exact ninety-nine composed projection inputs required")
    producer = legacy["permitted_omission"]["path"]
    tests = legacy["original_test_source_unchanged"]
    if original != inputs[producer]:
        raise ValueError("original producer detached from actual Git")
    mutated = original.replace(NEEDLE, b"true", 1)
    proof = verify_mutation(original, mutated, inputs[tests])
    for row in provenance:
        path = row["path"]
        expected = mutated if path == producer else inputs[path]
        if (root / path).read_bytes() != expected:
            raise ValueError("composed projection source image refused: " + path)
        row.update(
            projected_sha256=SHA(expected),
            projected_git_blob=None if path == producer else row["git_blob"],
        )
    if "approvals" in approval:
        proof.update(
            actual_commit=head,
            historical_recipe_sha256=MANIFEST_SHA,
            composition_sha256=composition_sha,
            source_approval_sha256=approval_sha,
            approved_auxiliary_sources=[
                {
                    "path": row["path"],
                    "published_source_commit": row["published_source_commit"],
                    "git_blob": row["git_blob"],
                    "sha256": row["sha256"],
                    "source_review_sha256": row["source_review_sha256"],
                }
                for row in approval["approvals"]
            ],
            paths=provenance,
        )
    else:
        proof.update(
            actual_commit=head,
            historical_recipe_sha256=MANIFEST_SHA,
            composition_sha256=composition_sha,
            source_approval_sha256=approval_sha,
            approved_auxiliary_source_commit=approval["published_source_commit"],
            paths=provenance,
        )
    # Last source join follows all external reads; no native acceptance is granted.
    _current_composition_inputs(repo, head, legacy, approval, composition)
    return proof


def materialize_composed_projection(
    repo,
    head,
    recipe_path,
    approval_path,
    approval_sha,
    composition_path,
    composition_sha,
    destination,
    evidence,
):
    composition = _closed_json(composition_path, composition_sha)
    legacy, approval, composition = _composition_contract(
        recipe_path, approval_path, approval_sha, composition
    )
    inputs, _ = _current_composition_inputs(repo, head, legacy, approval, composition)
    repo = repo.resolve()
    if (
        destination.is_symlink()
        or not destination.is_dir()
        or any(destination.iterdir())
        or destination.resolve().is_relative_to(repo)
        or repo.is_relative_to(destination.resolve())
    ):
        raise ValueError("fresh empty outside projection required")
    if (
        evidence.is_symlink()
        or not evidence.is_dir()
        or any(evidence.iterdir())
        or evidence.resolve().is_relative_to(repo)
        or repo.is_relative_to(evidence.resolve())
        or evidence.resolve().is_relative_to(destination.resolve())
        or destination.resolve().is_relative_to(evidence.resolve())
    ):
        raise ValueError("fresh separate outside evidence required")
    producer = legacy["permitted_omission"]["path"]
    original = inputs[producer]
    mutated = original.replace(NEEDLE, b"true", 1)
    verify_mutation(original, mutated, inputs[legacy["original_test_source_unchanged"]])
    for path, data in inputs.items():
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(mutated if path == producer else data)
    proof = verify_composed_projection(
        repo,
        head,
        recipe_path,
        approval_path,
        approval_sha,
        composition_path,
        composition_sha,
        destination,
        original,
    )
    (evidence / "NumberRowSourceProbe.original.swift").open("xb").write(original)
    with (evidence / "actual-git-projection.json").open("x") as stream:
        json.dump(proof, stream, sort_keys=True)
        stream.write("\n")
    return proof


def materialize_historical_controls(
    repo,
    head,
    recipe_path,
    approval_path,
    approval_sha,
    composition_path,
    composition_sha,
    destination,
    evidence,
    native_projection,
):
    """Original 53 controls only; never a current/native-source projection."""
    composition = _closed_json(composition_path, composition_sha)
    legacy, approval, composition = _composition_contract(
        recipe_path, approval_path, approval_sha, composition
    )
    # Current input provenance is independently required even though the old
    # control projection deliberately retains the historical auxiliary bytes.
    inputs, _ = _current_composition_inputs(repo, head, legacy, approval, composition)
    verify_composed_projection(
        repo,
        head,
        recipe_path,
        approval_path,
        approval_sha,
        composition_path,
        composition_sha,
        native_projection,
        inputs[legacy["permitted_omission"]["path"]],
    )
    repo = repo.resolve()
    if (
        evidence.is_symlink()
        or not evidence.is_dir()
        or evidence.resolve().is_relative_to(repo)
        or repo.is_relative_to(evidence.resolve())
    ):
        raise ValueError("outside regular historical-control evidence required")
    resolved = destination.resolve()
    if destination.is_symlink() or not destination.is_dir() or any(destination.iterdir()):
        raise ValueError("fresh empty historical-controls directory required")
    for other in (repo, evidence.resolve(), native_projection.resolve()):
        if resolved.is_relative_to(other) or other.is_relative_to(resolved):
            raise ValueError("separate outside historical-controls directory required")
    producer = legacy["permitted_omission"]["path"]
    tests = legacy["original_test_source_unchanged"]
    rows, retained = [], {}
    for row in legacy["paths"]:
        data, blob, mode = _git_input(repo, legacy["original_head"], row["path"])
        if blob != row["git_blob"] or SHA(data) != row["sha256"]:
            raise ValueError("original historical-control source input refused")
        retained[row["path"]] = data
        rows.append(
            {
                "path": row["path"],
                "historical_commit": legacy["original_head"],
                "git_blob": blob,
                "sha256": SHA(data),
                "mode": mode,
            }
        )
    if retained[producer] != inputs[producer] or retained[tests] != inputs[tests]:
        raise ValueError("original NumberRow producer/test control identity refused")
    original = retained[producer]
    mutated = original.replace(NEEDLE, b"true", 1)
    verify_mutation(original, mutated, retained[tests])
    for row in rows:
        path = row["path"]
        data = mutated if path == producer else retained[path]
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(data)
        row.update(
            projected_sha256=SHA(data),
            projected_git_blob=None if path == producer else row["git_blob"],
        )
    verify_projection(recipe_path, destination, original)
    proof = {
        "schema": 1,
        "role": "historical-original-53-controls-only-not-current-native-source",
        "actual_orchestrating_commit": head,
        "historical_source_commit": legacy["original_head"],
        "historical_recipe_sha256": MANIFEST_SHA,
        "source_approval_sha256": approval_sha,
        "composition_sha256": composition_sha,
        "paths": rows,
        "native_execution": "UNRUN",
        "native_source_projection": False,
    }
    # Last actual-source join follows all historical reads and projection IO.
    _current_composition_inputs(repo, head, legacy, approval, composition)
    with (evidence / "historical-controls-projection.json").open("x") as stream:
        json.dump(proof, stream, sort_keys=True)
        stream.write("\n")
    _current_composition_inputs(repo, head, legacy, approval, composition)
    return proof


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
    for name in ("composition", "source-approval"):
        parser.add_argument("--" + name, type=Path)
    for name in ("composition-sha256", "source-approval-sha256", "source-head"):
        parser.add_argument("--" + name)
    args = parser.parse_args()
    try:
        selected = (
            args.composition,
            args.source_approval,
            args.composition_sha256,
            args.source_approval_sha256,
            args.source_head,
        )
        if any(value is not None for value in selected):
            if not all(value is not None for value in selected):
                raise ValueError("complete separately received composition inputs required")
            proof = verify_composed_projection(
                Path.cwd(),
                args.source_head,
                args.manifest,
                args.source_approval,
                args.source_approval_sha256,
                args.composition,
                args.composition_sha256,
                args.projection,
                args.original_producer.read_bytes(),
            )
        else:
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
        if args.composition is not None:
            # Final join follows the unchanged external decoder and verdict.
            proof = verify_composed_projection(
                Path.cwd(),
                args.source_head,
                args.manifest,
                args.source_approval,
                args.source_approval_sha256,
                args.composition,
                args.composition_sha256,
                args.projection,
                args.original_producer.read_bytes(),
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
