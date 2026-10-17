"""Receive the reviewed current Carbon fixture without changing historical APIs."""

import argparse
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys
from types import ModuleType

OWNER_PATH = "tools/diagnostics/number_row_current_test_causal.py"
NETWORK_PATH = "tools/diagnostics/number_row_current_network_causal.py"
NETWORK_SHA = "b7ffb22ae11d1414cf465f55eb6a97e58f9badde6e96a804d64bc8ef7b683754"
TEST_PATH = (
    "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NumberRowSourceProbeTests.swift"
)
# Independently reviewed fixture v2; neither a transcript nor an approval may
# select another test image or move the permitted causal assertion.
CURRENT_TEST_SHA = "105820510cbe3c5c13dee94d30d7ef1ea738fa9131907ae3cc12278dc10a96f7"
CURRENT_TEST_BLOB = "e1879c6e7985d044c41dd0dc5af6329cb0b37be6"
CURRENT_ASSERTION_LINE = 435
ROSTER_PATH = "tools/diagnostics/fixtures/number-row-current-test/build-inputs.json.raw"
ROSTER_SHA = "b34a6f3efec6b31c1b3b8ffd438aeb73b38aa3b8265bd383054bbc1353393492"
LAUNCHER = "static/ergopti_plus/macos/launcher/"
TARGET_ROOTS = (
    LAUNCHER + "Sources/CPOSIXCompatibility/",
    LAUNCHER + "Sources/ErgoptiPlus/",
    LAUNCHER + "Tests/ErgoptiPlusTests/",
)
CONTROL_INPUTS = {
    LAUNCHER + "Package.swift": "package-manifest",
    LAUNCHER + "Package.resolved": "dependency-lock",
    ".github/ci/dev_release_qualification_exceptions.json": "qualification-policy",
    ".github/ci/stable_release_qualification_exception.json": "qualification-policy",
    "static/ergopti_plus/_shared/tests/corpus/layouts/number_row_levels.json": (
        "selected-test-runtime-fixture"
    ),
}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def load_dependencies(repo, head, owner_sha):
    """Admit committed retained bytes before importing either existing owner."""
    repo = repo.resolve()
    item = repo / NETWORK_PATH
    data = item.read_bytes()
    if item.is_symlink() or not item.is_file() or sha256(data) != NETWORK_SHA:
        raise ValueError("unchanged network companion required")
    network = ModuleType("retained_number_row_network_owner")
    network.__file__ = str(item)
    exec(compile(data, network.__file__, "exec"), network.__dict__)
    core, images = network.load_core(repo, head, NETWORK_SHA)
    owner, blob, mode = core._git_input(repo, head, OWNER_PATH)
    own_path = repo / OWNER_PATH
    if (
        not isinstance(owner_sha, str)
        or re.fullmatch(r"[0-9a-f]{64}", owner_sha) is None
        or sha256(owner) != owner_sha
        or mode != "100644"
        or own_path.is_symlink()
        or not own_path.is_file()
        or not own_path.resolve().is_relative_to(repo)
        or own_path.read_bytes() != owner
    ):
        raise ValueError("independently bound committed current-test owner required")
    roster, _, roster_mode = core._git_input(repo, head, ROSTER_PATH)
    roster_path = repo / ROSTER_PATH
    if (
        roster_mode != "100644"
        or sha256(roster) != ROSTER_SHA
        or roster_path.is_symlink()
        or not roster_path.is_file()
        or not roster_path.resolve().is_relative_to(repo)
        or roster_path.read_bytes() != roster
    ):
        raise ValueError("independently bound committed current-build roster required")
    retained = {**images, OWNER_PATH: owner, ROSTER_PATH: roster}
    verify_source_frame(network, core, repo, head, owner_sha, retained)
    return network, core, retained


def verify_source_frame(network, core, repo, head, owner_sha, retained):
    """Reject changed ownership images after every external receiving boundary."""
    images = network.source_frame(repo, head, NETWORK_SHA)
    owner, blob, mode = core._git_input(repo, head, OWNER_PATH)
    roster, _, roster_mode = core._git_input(repo, head, ROSTER_PATH)
    item = repo / OWNER_PATH
    roster_path = repo / ROSTER_PATH
    if (
        mode != "100644"
        or item.is_symlink()
        or not item.is_file()
        or not item.resolve().is_relative_to(repo.resolve())
        or item.read_bytes() != owner
        or sha256(owner) != owner_sha
        or roster_mode != "100644"
        or sha256(roster) != ROSTER_SHA
        or roster_path.is_symlink()
        or not roster_path.is_file()
        or not roster_path.resolve().is_relative_to(repo.resolve())
        or roster_path.read_bytes() != roster
        or {**images, OWNER_PATH: owner, ROSTER_PATH: roster} != retained
    ):
        raise ValueError("current-test source frame changed")
    if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip() != head:
        raise ValueError("current-test source commit changed after owner admission")


def current_test_contract(
    core, network, contract, test_approval, test_approval_sha, composition=None
):
    """Layer one reviewed test role over the unchanged six-role network contract."""
    legacy, approved, previous = network._current_network_contract(core, *contract)
    received = core._closed_json(test_approval, test_approval_sha)
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
        "causal_method",
        "causal_assertion_line",
    }
    if (
        not isinstance(received, dict)
        or set(received) != keys
        or type(received["schema"]) is not int
        or received["schema"] != 1
        or received["role"] != "independently-reviewed-current-number-row-test"
        or received["path"] != TEST_PATH
        or received["git_blob"] != CURRENT_TEST_BLOB
        or received["sha256"] != CURRENT_TEST_SHA
        or received["causal_method"] != core.TARGET
        or type(received["causal_assertion_line"]) is not int
        or received["causal_assertion_line"] != CURRENT_ASSERTION_LINE
    ):
        raise ValueError("exact separately approved current-test role required")
    original = next(row for row in legacy["paths"] if row["path"] == TEST_PATH)
    if (
        received["original_git_blob"] != original["git_blob"]
        or received["original_sha256"] != original["sha256"]
        or original["sha256"] != core.TEST_SHA
        or legacy["original_test_source_unchanged"] != TEST_PATH
    ):
        raise ValueError("immutable historical test predecessor required")
    for name, length in (("published_source_commit", 40), ("source_review_sha256", 64)):
        if (
            not isinstance(received[name], str)
            or re.fullmatch(r"[0-9a-f]{" + str(length) + "}", received[name]) is None
        ):
            raise ValueError("independently received current-test identity required")
    rows = [dict(row) for row in previous["paths"]]
    for row in rows:
        if row["path"] == TEST_PATH:
            row.update(git_blob=CURRENT_TEST_BLOB, sha256=CURRENT_TEST_SHA)
    combined = {**approved, "approvals": [*approved["approvals"], received]}
    expected = {
        **previous,
        "schema": 3,
        "role": "reviewed-current-test-historical-roster-predecessor-not-current-build",
        "test_source_approval_sha256": test_approval_sha,
        "paths": rows,
    }
    if composition is not None and (
        not isinstance(composition, dict)
        or type(composition.get("schema")) is not int
        or composition != expected
    ):
        raise ValueError("exact seven-role current-test composition required")
    return legacy, combined, expected


def current_build_contract(
    core,
    network,
    contract,
    test_approval,
    test_approval_sha,
    build_approval,
    build_approval_sha,
    composition=None,
):
    """Admit one closed complete local package roster, separately from old99."""
    legacy, approved, predecessor = current_test_contract(
        core, network, contract, test_approval, test_approval_sha
    )
    roster = core._closed_json(Path(__file__).resolve().parents[2] / ROSTER_PATH, ROSTER_SHA)
    if (
        not isinstance(roster, dict)
        or set(roster) != {"schema", "role", "target_input_count", "local_input_count", "paths"}
        or type(roster["schema"]) is not int
        or roster["schema"] != 1
        or roster["role"] != "reviewed-current-selected-carbon-local-build-input-roster"
        or type(roster["target_input_count"]) is not int
        or roster["target_input_count"] != 140
        or type(roster["local_input_count"]) is not int
        or roster["local_input_count"] != 145
        or not isinstance(roster["paths"], list)
        or len(roster["paths"]) != 145
    ):
        raise ValueError("exact complete current local build roster required")
    old = {row["path"]: row for row in legacy["paths"]}
    rows = roster["paths"]
    if [row.get("path") for row in rows] != sorted({row.get("path") for row in rows}):
        raise ValueError("ordered unique complete current input paths required")
    row_keys = {
        "path",
        "git_blob",
        "sha256",
        "mode",
        "input_kind",
        "historical_roster_member",
        "historical_git_blob",
        "historical_sha256",
    }
    for row in rows:
        path = row["path"]
        if (
            set(row) != row_keys
            or row["mode"] != "100644"
            or re.fullmatch(r"[0-9a-f]{40}", row["git_blob"]) is None
            or re.fullmatch(r"[0-9a-f]{64}", row["sha256"]) is None
            or type(row["historical_roster_member"]) is not bool
            or row["historical_roster_member"] != (path in old)
            or row["historical_git_blob"] != (old[path]["git_blob"] if path in old else None)
            or row["historical_sha256"] != (old[path]["sha256"] if path in old else None)
            or row["input_kind"] != CONTROL_INPUTS.get(path, "target-input")
            or path not in CONTROL_INPUTS
            and not path.startswith(TARGET_ROOTS)
            or path.startswith(TARGET_ROOTS)
            and Path(path).suffix not in {".swift", ".c", ".cpp", ".h"}
        ):
            raise ValueError("closed current input identity/predecessor refused")
    by_path = {row["path"]: row for row in rows}
    if not set(old).issubset(by_path) or not set(CONTROL_INPUTS).issubset(by_path):
        raise ValueError("historical or runtime/package input omitted")
    for record in approved["approvals"]:
        if any(by_path[record["path"]][field] != record[field] for field in ("git_blob", "sha256")):
            raise ValueError("separately approved source role detached from complete roster")
    producer = legacy["permitted_omission"]["path"]
    if by_path[producer]["sha256"] != core.PRODUCER_SHA:
        raise ValueError("unchanged production predicate required")
    received = core._closed_json(build_approval, build_approval_sha)
    keys = {
        "schema",
        "role",
        "roster_sha256",
        "published_source_commit",
        "source_review_sha256",
        "test_source_approval_sha256",
        "base_source_approval_sha256",
        "network_source_approval_sha256",
    }
    if (
        not isinstance(received, dict)
        or set(received) != keys
        or type(received["schema"]) is not int
        or received["schema"] != 1
        or received["role"] != "independently-reviewed-complete-current-carbon-local-inputs"
        or received["roster_sha256"] != ROSTER_SHA
        or received["test_source_approval_sha256"] != test_approval_sha
        or received["base_source_approval_sha256"] != predecessor["source_approval_sha256"]
        or received["network_source_approval_sha256"]
        != predecessor["network_source_approval_sha256"]
    ):
        raise ValueError("separate complete-current build approval required")
    for name, size in (("published_source_commit", 40), ("source_review_sha256", 64)):
        if (
            not isinstance(received[name], str)
            or re.fullmatch(r"[0-9a-f]{" + str(size) + "}", received[name]) is None
        ):
            raise ValueError("independently received complete-current identity required")
    # This dedicated selected-test invocation follows the existing PAC owner:
    # complete default tests compile; no temporary release exclusion is applied.
    if os.environ.get("ERGOPTI_DEV_QUALIFICATION_PROFILE"):
        raise ValueError("current Carbon receiving requires no qualification profile")
    expected = {
        "schema": 4,
        "role": "reviewed-complete-current-carbon-local-inputs-not-native-qualification",
        "historical_recipe_sha256": core.MANIFEST_SHA,
        "roster_sha256": ROSTER_SHA,
        "build_source_approval_sha256": build_approval_sha,
        "test_source_approval_sha256": test_approval_sha,
        "source_approval_sha256": predecessor["source_approval_sha256"],
        "network_source_approval_sha256": predecessor["network_source_approval_sha256"],
        "qualification_profile": None,
        "local_input_count": 145,
        "target_input_count": 140,
        "paths": rows,
    }
    if composition is not None and (
        composition != expected
        or json.dumps(composition, sort_keys=True) != json.dumps(expected, sort_keys=True)
    ):
        raise ValueError("exact complete-current local build composition required")
    return legacy, approved, received, expected


def git_inputs(repo, commit, paths):
    """Read genuine Git blobs in one bounded batch, without changing any ref."""
    if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise ValueError("full source commit identity required")
    if subprocess.check_output(["git", "cat-file", "-t", commit], cwd=repo).strip() != b"commit":
        raise ValueError("actual source commit object required")
    tree = subprocess.check_output(
        ["git", "ls-tree", "-rz", "--full-tree", commit, "--", *paths], cwd=repo
    )
    records = []
    for entry in tree.split(b"\0"):
        if not entry:
            continue
        header, name = entry.split(b"\t", 1)
        mode, kind, blob = header.decode().split()
        if mode != "100644" or kind != "blob":
            raise ValueError("regular current Git input required")
        records.append((name.decode(), blob, mode))
    if len(records) != len(paths) or {p for p, _, _ in records} != set(paths):
        raise ValueError("exact committed build input membership required")
    data = subprocess.check_output(
        ["git", "cat-file", "--batch"],
        cwd=repo,
        input="".join(blob + "\n" for _, blob, _ in records).encode(),
    )
    offset, result = 0, {}
    for path, blob, mode in records:
        end = data.find(b"\n", offset)
        header = data[offset:end].decode().split()
        if len(header) != 3 or header[:2] != [blob, "blob"] or not header[2].isdigit():
            raise ValueError("exact Git batch object identity required")
        size = int(header[2])
        content = data[end + 1 : end + 1 + size]
        offset = end + size + 2
        if len(content) != size or data[offset - 1 : offset] != b"\n":
            raise ValueError("complete Git object bytes required")
        result[path] = (content, blob, mode)
    if offset != len(data):
        raise ValueError("unexpected trailing Git object bytes")
    return result


def regular_current_input(repo, path):
    """Require the admitted name itself, including every parent, to be regular."""
    repo = repo.resolve()
    item = repo / path
    if (
        item.is_symlink()
        or not item.is_file()
        or not item.resolve().is_relative_to(repo)
        or item.resolve() != item
    ):
        raise ValueError("regular unaliased current source input required")
    return item


def current_build_inputs(core, repo, head, legacy, approved, build_approval, composition):
    """Join the closed roster to genuine historical, reviewed and current Git."""
    repo = repo.resolve()

    def current():
        if (
            subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            != head
        ):
            raise ValueError("current complete-build source commit changed")
        if os.environ.get("ERGOPTI_DEV_QUALIFICATION_PROFILE"):
            raise ValueError("current complete-build qualification profile changed")

    def ancestor(commit):
        status = subprocess.run(
            ["git", "merge-base", "--is-ancestor", commit, head], cwd=repo, capture_output=True
        )
        if status.returncode != 0:
            raise ValueError("reviewed source commit is not an ancestor")

    current()
    historical = git_inputs(repo, legacy["original_head"], [r["path"] for r in legacy["paths"]])
    for row in legacy["paths"]:
        content, blob, _ = historical[row["path"]]
        if blob != row["git_blob"] or sha256(content) != row["sha256"]:
            raise ValueError("immutable historical input refused")
    for record in approved["approvals"]:
        ancestor(record["published_source_commit"])
        image = git_inputs(repo, record["published_source_commit"], [record["path"]])
        content, blob, _ = image[record["path"]]
        if blob != record["git_blob"] or sha256(content) != record["sha256"]:
            raise ValueError("separately approved genuine source tuple refused")
    rows = composition["paths"]
    paths = [row["path"] for row in rows]
    ancestor(build_approval["published_source_commit"])
    reviewed = git_inputs(repo, build_approval["published_source_commit"], paths)
    actual = git_inputs(repo, head, paths)
    planned_targets = {p for p in paths if p.startswith(TARGET_ROOTS)}
    tree = subprocess.check_output(
        ["git", "ls-tree", "-rz", "--name-only", head, "--", *TARGET_ROOTS], cwd=repo
    )
    if set(tree.decode().strip("\0").split("\0")) != planned_targets:
        raise ValueError("complete current tracked target census changed")
    working_targets = set()
    for prefix in TARGET_ROOTS:
        directory = repo / prefix
        if (
            directory.is_symlink()
            or not directory.is_dir()
            or not directory.resolve().is_relative_to(repo)
            or directory.resolve() != directory
        ):
            raise ValueError("regular target directory required")
        for item in directory.rglob("*"):
            if item.is_symlink() or not (item.is_file() or item.is_dir()):
                raise ValueError("regular current target member required")
            if item.is_file():
                working_targets.add(item.relative_to(repo).as_posix())
    if working_targets != planned_targets:
        raise ValueError("complete current working target census changed")
    inputs, provenance = {}, []
    for row in rows:
        path = row["path"]
        item = regular_current_input(repo, path)
        content, blob, mode = actual[path]
        if (
            reviewed[path] != actual[path]
            or blob != row["git_blob"]
            or mode != row["mode"]
            or sha256(content) != row["sha256"]
            or item.is_symlink()
            or not item.is_file()
            or not item.resolve().is_relative_to(repo)
            or item.read_bytes() != content
        ):
            raise ValueError("reviewed complete-current source drift refused: " + path)
        inputs[path] = content
        provenance.append(
            {
                **row,
                "actual_commit": head,
                "reviewed_commit": build_approval["published_source_commit"],
            }
        )
    current()
    return inputs, provenance


def verify_current_mutation(core, original, counterfactual, tests):
    """Keep the sole producer omission and bind the separately reviewed fixture."""
    if sha256(original) != core.PRODUCER_SHA or sha256(tests) != CURRENT_TEST_SHA:
        raise ValueError("reviewed producer/current-test source required")
    if original.count(core.NEEDLE) != 1 or counterfactual != original.replace(
        core.NEEDLE, b"true", 1
    ):
        raise ValueError("sole permitted final-byte omission refused")
    if sorted(re.findall(rb"\bfunc (test\w+)\(\)", tests)) != sorted(
        name.encode() for name in core.METHODS
    ):
        raise ValueError("independent twelve-case census refused")
    return {
        "original_producer_sha256": sha256(original),
        "counterfactual_producer_sha256": sha256(counterfactual),
        "historical_test_sha256": core.TEST_SHA,
        "test_sha256": CURRENT_TEST_SHA,
        "causal_assertion_line": CURRENT_ASSERTION_LINE,
        "image_role": "private-current-test-counterfactual-not-canonical-product",
        "counterfactual_git_blob": None,
    }


def verify_projection(
    core,
    network,
    repo,
    head,
    contract,
    test_approval,
    test_approval_sha,
    build_approval,
    build_approval_sha,
    composition_path,
    composition_sha,
    root,
    original,
    leg="counterfactual",
):
    """Join every projected byte to actual Git before granting causal receiving."""
    composition = core._closed_json(composition_path, composition_sha)
    legacy, approved, build_record, composition = current_build_contract(
        core,
        network,
        contract,
        test_approval,
        test_approval_sha,
        build_approval,
        build_approval_sha,
        composition,
    )
    inputs, provenance = current_build_inputs(
        core, repo, head, legacy, approved, build_record, composition
    )
    if (
        root.is_symlink()
        or not root.is_dir()
        or root.resolve().is_relative_to(repo.resolve())
        or repo.resolve().is_relative_to(root.resolve())
    ):
        raise ValueError("outside regular current-test projection required")
    actual = set()
    for item in root.rglob("*"):
        if item.is_symlink() or not (item.is_file() or item.is_dir()):
            raise ValueError("regular current-test projection members required")
        if item.is_file():
            actual.add(item.relative_to(root).as_posix())
    if len(inputs) != 145 or actual != set(inputs):
        raise ValueError("exact complete current local projection inputs required")
    producer = legacy["permitted_omission"]["path"]
    if original != inputs[producer]:
        raise ValueError("original producer detached from actual Git")
    mutated = original.replace(core.NEEDLE, b"true", 1)
    proof = verify_current_mutation(core, original, mutated, inputs[TEST_PATH])
    if leg == "positive":
        proof = {
            "original_producer_sha256": sha256(original),
            "test_sha256": CURRENT_TEST_SHA,
            "image_role": "private-current-positive-not-canonical-product",
        }
    elif leg != "counterfactual":
        raise ValueError("exact positive or counterfactual projection leg required")
    for row in provenance:
        path = row["path"]
        expected = mutated if path == producer and leg == "counterfactual" else inputs[path]
        if (root / path).read_bytes() != expected:
            raise ValueError("current-test projected source image refused: " + path)
        row.update(
            projected_sha256=sha256(expected),
            projected_git_blob=None
            if path == producer and leg == "counterfactual"
            else row["git_blob"],
        )
    current_build_contract(
        core,
        network,
        contract,
        test_approval,
        test_approval_sha,
        build_approval,
        build_approval_sha,
        composition,
    )
    current_build_inputs(core, repo, head, legacy, approved, build_record, composition)
    proof.update(
        actual_commit=head,
        paths=provenance,
        historical_recipe_sha256=core.MANIFEST_SHA,
        composition_sha256=composition_sha,
        test_source_approval_sha256=test_approval_sha,
        build_source_approval_sha256=build_approval_sha,
        local_input_count=145,
        target_input_count=140,
        qualification_profile=None,
        leg=leg,
        signed_application_qualified=False,
        external_dependency_native_receiving="UNRUN",
        approved_source_roles=approved["approvals"],
    )
    return proof


def failure_diagnostic(line):
    """Ignore numbered compiler source context while retaining real failures."""
    if re.match(r"^\s*\d+\s*\|", line):
        return False
    diagnostic = re.match(
        r"^\s*(?:[^|\r\n]+:[0-9]+(?::[0-9]+)?:\s*)?(?:fatal\s+)?error:",
        line,
        re.IGNORECASE,
    ) or re.match(
        r"^\s*(?:swift(?:c|-frontend|-driver)?|clang(?:\+\+)?|ld|lld):\s*"
        r"(?:fatal\s+)?error:",
        line,
        re.IGNORECASE,
    )
    return bool(diagnostic) or "XCTAssert" in line and " failed" in line


def evaluate(core, tests, log, swift_exit, capture_exit, tis, tis_exit):
    """Read actual v2 bytes and log under the unchanged exact eleven/one policy."""
    if sha256(Path(core.positive.__file__).read_bytes()) != core.POSITIVE_SHA:
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
    if sha256(tests) != CURRENT_TEST_SHA:
        raise ValueError("reviewed current test source changed")
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
            method = core.method_identity(row[1])
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
        if failure_diagnostic(line):
            match = re.fullmatch(
                r".*NumberRowSourceProbeTests\.swift:"
                + str(CURRENT_ASSERTION_LINE)
                + r": error: (.+) : XCTAssertThrowsError failed: did not throw error(?: - ?)?",
                line,
            )
            if (
                match is None
                or core.method_identity(match[1]) != core.TARGET
                or active != core.TARGET
            ):
                raise ValueError("unrelated or unbound XCTest assertion")
            assertions.append(core.TARGET)
    expected = sorted(
        (name, "failed (" if name == core.TARGET else "passed (") for name in core.METHODS
    )
    if active is not None or sorted(starts) != sorted(core.METHODS) or sorted(ends) != expected:
        raise ValueError("exact eleven-pass one-fail cohort refused")
    if (selected_started, selected_failed, selected_passed) != (1, 1, 0) or assertions != [
        core.TARGET
    ]:
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
    if (
        not isinstance(tis, dict)
        or tis.get("complete") is not True
        or type(tis.get("count")) is not int
        or tis["count"] != 7
        or tis.get("methods") != sorted(core.METHODS[:6] + (core.TARGET,))
    ):
        raise ValueError("seven exact TIS closures unavailable")
    unchanged = core.positive.evaluate(
        tests.decode("utf-8"), log, core.CLASS, swift_exit, capture_exit
    )
    if (
        unchanged["complete"] is not False
        or unchanged["passed"] is not False
        or unchanged["failures"] != [core.TARGET]
        or unchanged["expected_count"] != 12
        or unchanged["received_count"] != 12
        or unchanged["source_sha"] != CURRENT_TEST_SHA
    ):
        raise ValueError(
            "original positive receiver did not refuse the actual current counterfactual"
        )
    return {
        "schema": 1,
        "scope": "number-row-current-test-final-byte-single-omission",
        "expected_red_received": True,
        "causal_method": core.TARGET,
        "causal_assertion_line": CURRENT_ASSERTION_LINE,
        "current_test_sha256": CURRENT_TEST_SHA,
        "historical_test_sha256": core.TEST_SHA,
        "passed_case_count": 11,
        "failed_case_count": 1,
        "skipped_case_count": 0,
        "swift_exit": swift_exit,
        "capture_exit": capture_exit,
        "original_positive_receipt": unchanged,
        "tis": tis,
        "image_role": "private-current-test-counterfactual-not-canonical-product",
        "canonical_product_source_qualified": False,
        "physical_keyboard_qualified": False,
        "application_launch_qualified": False,
    }


def evaluate_positive(core, tests, log, swift_exit, capture_exit, tis, tis_exit):
    """Require the original positive receiver to admit the actual current cohort."""
    if sha256(Path(core.positive.__file__).read_bytes()) != core.POSITIVE_SHA:
        raise ValueError("original positive receiver changed")
    if sha256(tests) != CURRENT_TEST_SHA:
        raise ValueError("reviewed current positive test source changed")
    if any(type(value) is not int or value != 0 for value in (swift_exit, capture_exit, tis_exit)):
        raise ValueError("actual successful positive command statuses required")
    if (
        not isinstance(tis, dict)
        or tis.get("complete") is not True
        or type(tis.get("count")) is not int
        or tis["count"] != 7
        or tis.get("methods") != sorted(core.METHODS[:6] + (core.TARGET,))
    ):
        raise ValueError("seven exact positive TIS closures unavailable")
    normalized = log.replace("\r\n", "\n")
    starts, terminals, active = [], [], None
    selected_started = selected_passed = 0
    for line in normalized.splitlines():
        selected_started += bool(re.match(r"^Test Suite 'Selected tests' started at ", line))
        selected_passed += bool(re.match(r"^Test Suite 'Selected tests' passed at ", line))
        if failure_diagnostic(line) or re.match(r"^Test Suite '.+' failed at ", line):
            raise ValueError("positive XCTest assertion, compiler or suite failure")
        row = re.match(r"^Test Case '(.+)' (started\.|passed \(|failed \(|skipped \()", line)
        if row:
            method = core.method_identity(row[1])
            if row[2] == "started.":
                if active is not None:
                    raise ValueError("overlapping positive XCTest start")
                starts.append(method)
                active = method
            else:
                if active != method or row[2] != "passed (":
                    raise ValueError("positive XCTest terminal without exact passed start")
                active = None
                terminals.append(method)
    summaries = re.findall(
        r"^\s*Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)",
        normalized,
        re.MULTILINE,
    )
    if (
        active is not None
        or sorted(starts) != sorted(core.METHODS)
        or sorted(terminals) != sorted(core.METHODS)
        or (selected_started, selected_passed) != (1, 1)
        or not summaries
        or any(row != ("12", "0", "0") for row in summaries)
    ):
        raise ValueError("exact twelve-pass positive transcript refused")
    positive = core.positive.evaluate(
        tests.decode("utf-8"), log, core.CLASS, swift_exit, capture_exit
    )
    if (
        positive["complete"] is not True
        or positive["passed"] is not True
        or positive["expected_count"] != 12
        or positive["received_count"] != 12
        or positive["failures"] != []
        or positive["source_sha"] != CURRENT_TEST_SHA
    ):
        raise ValueError("original positive receiver refused actual current cohort")
    return {
        "schema": 1,
        "scope": "number-row-current-positive",
        "positive_received": True,
        "current_test_sha256": CURRENT_TEST_SHA,
        "passed_case_count": 12,
        "failed_case_count": 0,
        "skipped_case_count": 0,
        "original_positive_receipt": positive,
        "tis": tis,
        "canonical_product_source_qualified": False,
        "physical_keyboard_qualified": False,
        "application_launch_qualified": False,
    }


def create_composition(
    core,
    network,
    repo,
    head,
    contract,
    test_approval,
    test_approval_sha,
    build_approval,
    build_approval_sha,
):
    """Require real committed approval tuples before emitting a composition."""
    legacy, approved, build_record, composition = current_build_contract(
        core,
        network,
        contract,
        test_approval,
        test_approval_sha,
        build_approval,
        build_approval_sha,
    )
    current_build_inputs(core, repo, head, legacy, approved, build_record, composition)
    current_build_contract(
        core,
        network,
        contract,
        test_approval,
        test_approval_sha,
        build_approval,
        build_approval_sha,
        composition,
    )
    return composition


def materialize(
    core,
    network,
    repo,
    head,
    contract,
    test_approval,
    test_approval_sha,
    build_approval,
    build_approval_sha,
    composition_path,
    composition_sha,
    destination,
    evidence,
    leg="counterfactual",
):
    """Materialize only admitted inputs and one producer omission outside source."""
    composition = core._closed_json(composition_path, composition_sha)
    legacy, approved, build_record, composition = current_build_contract(
        core,
        network,
        contract,
        test_approval,
        test_approval_sha,
        build_approval,
        build_approval_sha,
        composition,
    )
    inputs, _ = current_build_inputs(core, repo, head, legacy, approved, build_record, composition)
    for directory in (destination, evidence):
        if (
            directory.is_symlink()
            or not directory.is_dir()
            or any(directory.iterdir())
            or directory.resolve().is_relative_to(repo.resolve())
            or repo.resolve().is_relative_to(directory.resolve())
        ):
            raise ValueError("fresh empty outside current-test directory required")
    if destination.resolve().is_relative_to(
        evidence.resolve()
    ) or evidence.resolve().is_relative_to(destination.resolve()):
        raise ValueError("separate current-test projection and evidence required")
    producer = legacy["permitted_omission"]["path"]
    original = inputs[producer]
    mutated = original.replace(core.NEEDLE, b"true", 1)
    verify_current_mutation(core, original, mutated, inputs[TEST_PATH])
    if leg not in ("positive", "counterfactual"):
        raise ValueError("exact positive or counterfactual materialization leg required")
    for path, data in inputs.items():
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(mutated if path == producer and leg == "counterfactual" else data)
    proof = verify_projection(
        core,
        network,
        repo,
        head,
        contract,
        test_approval,
        test_approval_sha,
        build_approval,
        build_approval_sha,
        composition_path,
        composition_sha,
        destination,
        original,
        leg,
    )
    with (evidence / "NumberRowSourceProbe.original.swift").open("xb") as stream:
        stream.write(original)
    with (evidence / "actual-git-projection.json").open(
        "x", encoding="utf-8", newline="\n"
    ) as stream:
        json.dump(proof, stream, sort_keys=True)
        stream.write("\n")
    return proof


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--head", required=True)
    parser.add_argument("--owner-sha256", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("generate", "materialize", "receive"):
        command = commands.add_parser(name)
        for field in (
            "recipe",
            "base-approval",
            "network-approval",
            "test-approval",
            "build-approval",
        ):
            command.add_argument("--" + field, type=Path, required=True)
        for field in (
            "base-approval-sha256",
            "network-approval-sha256",
            "test-approval-sha256",
            "build-approval-sha256",
        ):
            command.add_argument("--" + field, required=True)
        if name == "generate":
            command.add_argument("--output", type=Path, required=True)
        else:
            command.add_argument("--composition", type=Path, required=True)
            command.add_argument("--composition-sha256", required=True)
            command.add_argument("--projection", type=Path, required=True)
            command.add_argument("--leg", choices=("positive", "counterfactual"), required=True)
        if name == "materialize":
            command.add_argument("--evidence", type=Path, required=True)
        if name == "receive":
            for field in (
                "original-producer",
                "test-source",
                "log",
                "transport",
                "tis-root",
                "receipt",
                "tis-stdout",
                "tis-stderr",
                "node",
            ):
                command.add_argument("--" + field, type=Path, required=True)
            command.add_argument("--session", required=True)
            command.add_argument("--swift-exit", type=int, required=True)
            command.add_argument("--capture-exit", type=int, required=True)
    args = parser.parse_args()
    repo = Path.cwd().resolve()
    if Path(__file__).is_symlink() or Path(__file__).resolve() != repo / OWNER_PATH:
        raise ValueError("exact committed current-test owner path required")
    network, core, retained = load_dependencies(repo, args.head, args.owner_sha256)
    contract = (
        args.recipe,
        args.base_approval,
        args.base_approval_sha256,
        args.network_approval,
        args.network_approval_sha256,
    )

    def source_current():
        verify_source_frame(network, core, repo, args.head, args.owner_sha256, retained)

    def projection_current():
        return verify_projection(
            core,
            network,
            repo,
            args.head,
            contract,
            args.test_approval,
            args.test_approval_sha256,
            args.build_approval,
            args.build_approval_sha256,
            args.composition,
            args.composition_sha256,
            args.projection,
            args.original_producer.read_bytes(),
            args.leg,
        )

    if args.command == "generate":
        network.new_outside_file(repo, args.output)
        composition = create_composition(
            core,
            network,
            repo,
            args.head,
            contract,
            args.test_approval,
            args.test_approval_sha256,
            args.build_approval,
            args.build_approval_sha256,
        )
        source_current()
        data = (json.dumps(composition, indent=2, sort_keys=True) + "\n").encode()
        with args.output.open("xb") as stream:
            stream.write(data)
        print(
            json.dumps(
                {
                    "actual_commit": args.head,
                    "composition_sha256": sha256(data),
                    "native_execution": "UNRUN",
                }
            )
        )
        return 0
    if args.command == "materialize":
        proof = materialize(
            core,
            network,
            repo,
            args.head,
            contract,
            args.test_approval,
            args.test_approval_sha256,
            args.build_approval,
            args.build_approval_sha256,
            args.composition,
            args.composition_sha256,
            args.projection,
            args.evidence,
            args.leg,
        )
        source_current()
        print(json.dumps({"actual_commit": proof["actual_commit"], "native_execution": "UNRUN"}))
        return 0
    for output in (args.receipt, args.tis_stdout, args.tis_stderr):
        network.new_outside_file(repo, output)
    try:
        projection_current()
        source_current()
        tests = args.test_source.read_bytes()
        if tests != (args.projection / TEST_PATH).read_bytes():
            raise ValueError("current test source detached from projection")
        if sha256(args.transport.read_bytes()) != core.TRANSPORT_SHA:
            raise ValueError("unchanged TIS transport required")
        raw = subprocess.run(
            [
                str(args.node),
                "-e",
                core.TIS_SCRIPT,
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
        evaluator = evaluate_positive if args.leg == "positive" else evaluate
        result = evaluator(
            core,
            tests,
            args.log.read_text(encoding="utf-8"),
            args.swift_exit,
            args.capture_exit,
            tis,
            raw.returncode,
        )
        result["projection_proof"] = projection_current()
        source_current()
        status = 0
    except (OSError, UnicodeError, ValueError, subprocess.SubprocessError) as error:
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
