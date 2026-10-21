"""tools/test/test_windows_key_combination_source_roster.py

Independently receive source provenance and exercise malformed/stale refusals.
This command reads Git/disk and writes only an explicitly supplied receipt.
It never launches the controller helper, AHK, Node or a native build.
"""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import types

OLD = "a60f016ec2a530831fc5ae03015a60f1356ed4cb36035eeb1ab3e59bbcbfaeae"
HELPER = "274f1a3e28279289404b87491e7a43b6974e7a58791197f0baf1ee6a1fd10516"
CHILD = "dc40081e96f631447d71678a7def720b19f34986ba7a57d759e25cdd6df87aec"
CONTROL = "7adf645a1a2b79b9358d7e793dd12ccb0b113f25d49b50ef991a37079b4a470a"
W = "static/ergopti_plus/windows/"
S = "static/ergopti_plus/_shared/"
PAC = sorted(
    W + "vendor/ergopti_network_pac" + suffix for suffix in (".exe", ".json", ".LICENSE.txt")
)
ENROLLMENT = {
    "tools/ci/run-windows-key-combination-cohorts.cjs",
    "tools/ci/prepare_windows_key_combination_cohort_inputs.py",
    "tools/test/test-windows-key-combination-cohorts.cjs",
    "tools/test/test_windows_key_combination_source_roster.py",
    "tools/test/validate-ahk-suite-manifest.cjs",
    "tools/ci/windows-key-combination-cohort-original-inputs.json",
    "tools/test/portable-control-inputs.json",
}
BUILDS = {
    ".github/workflows/ci-windows.yml",
    ".github/workflows/ci-windows-unit.yml",
    ".github/workflows/ci-windows-build.yml",
    ".node-version",
    "package.json",
    "package-lock.json",
    "tools/build/build_static_bundle.py",
    "tools/build/windows_bundle_manifest.json",
    "tools/build/build-features-manifest.js",
    "tools/lib/paths.cjs",
    "tools/lib/configuration-scopes.cjs",
    "tools/build/build_windows_nav_owner.ps1",
    "tools/build/build_windows_network_pac.ps1",
    "tools/build/prepare_network_pac_sources.py",
    S + "data/linux_native_runtime.json",
    S + "modules/network/pac_helpers.js",
}


def require(condition, why):
    if not condition:
        raise ValueError(why)


def sha(value):
    return hashlib.sha256(value).hexdigest()


def decode(data):
    def pairs(rows):
        obj = {}
        for key, value in rows:
            require(key not in obj, "Duplicate JSON key")
            obj[key] = value
        return obj

    return json.loads(data, object_pairs_hook=pairs)


def git(root, *args):
    proc = subprocess.run(
        ["git", "-C", str(root), *args],
        env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"),
        capture_output=True,
        timeout=120,
        check=False,
    )
    require(proc.returncode == 0 and proc.stderr == b"", "Read-only Git failure")
    return proc.stdout


def frame(root):
    return {
        "head": git(root, "rev-parse", "HEAD").decode().strip(),
        "tree": git(root, "rev-parse", "HEAD^{tree}").decode().strip(),
        "index_sha256": sha(git(root, "ls-files", "--stage", "-z")),
    }


def tree(root, commit):
    rows = {}
    for raw in git(root, "ls-tree", "-r", "-z", commit).split(b"\0"):
        if not raw:
            continue
        fact, name = raw.split(b"\t", 1)
        mode, kind, oid = fact.decode("ascii").split()
        name = name.decode("utf-8")
        require(name not in rows, "Duplicate committed path")
        rows[name] = (mode, kind, oid)
    return rows


def disk(root, name):
    require(isinstance(name, str) and not name.startswith("/") and "\\" not in name, "Unsafe path")
    target = root
    for part in name.split("/"):
        require(part not in ("", ".", ".."), "Unsafe path segment")
        target /= part
        require(not target.is_symlink(), "Source component symlink")
    facts = target.lstat()
    require(stat.S_ISREG(facts.st_mode), "Nonregular disk source")
    return target.read_bytes(), stat.S_IMODE(facts.st_mode)


def pattern(glob):
    # Independent scanner for the manifest's documented slash-aware glob grammar.
    require(
        isinstance(glob, str) and glob and not glob.startswith("/") and "\\" not in glob,
        "Unsafe glob",
    )
    result, offset = "", 0
    while offset < len(glob):
        if glob[offset : offset + 3] == "**/":
            result += "(?:[^/]+/)*"
            offset += 3
        elif glob[offset : offset + 2] == "**":
            result += ".*"
            offset += 2
        elif glob[offset] == "*":
            result += "[^/]*"
            offset += 1
        elif glob[offset] == "?":
            result += "[^/]"
            offset += 1
        else:
            result += re.escape(glob[offset])
            offset += 1
    return re.compile(result)


def closure(old, rows, manifest):
    result = {name: ["retained-original-cohort-source"] for name in old["source_sha256"]}
    exclusions = [
        (list(map(pattern, group["globs"])), list(map(pattern, group.get("except", []))))
        for group in manifest["exclude"]
    ]

    def excluded(name):
        return any(
            any(p.fullmatch(name) for p in first) and not any(p.fullmatch(name) for p in second)
            for first, second in exclusions
        )

    def under(name, directory):
        return name == directory or name.startswith(directory + "/")

    for name in sorted(rows):
        if name in PAC:
            continue
        roles = []
        if name.startswith(W) and not name.endswith(".md"):
            roles.append("windows-compiler-test-native-build-source-superset")
        if name.startswith(S) and name.endswith(".ahk"):
            roles.append("shared-ahk-include-source-superset")
        if name.startswith(S + "tests/"):
            roles.append("shared-registered-fixture-source-superset")
        if name.startswith(S + "native/network/"):
            roles.append("original-native-pac-build-source")
        if name in BUILDS:
            roles.append("declared-original-build-input")
        if name in ENROLLMENT and name in rows:
            roles.append("declared-cohort-tool-source")
        for include in manifest["include"]:
            if under(name, include["source"]) and not excluded(name):
                require(
                    not any(
                        under(name, entry["path"].rstrip("/")) for entry in manifest["not_shipped"]
                    ),
                    "Not-shipped conflict",
                )
                roles.append("original-bundle-runtime-source")
        if roles:
            result.setdefault(name, []).extend(roles)
    require(not set(PAC) & result.keys(), "PAC produced output became a source pin")
    require(BUILDS <= result.keys(), "Build closure missing")
    require(
        all(entry["source"] in result or entry["source"] in PAC for entry in manifest["required"]),
        "Required asset unclassified",
    )
    return result


def validate(old, current, receipt, commit, source_tree, expected):
    require(set(current) == set(old), "Unknown or missing input field")
    require(
        {k: v for k, v in current.items() if k != "source_sha256"}
        == {k: v for k, v in old.items() if k != "source_sha256"},
        "Behavioral frame changed",
    )
    require(
        current["planned_total"] == 28
        and current["expected_children"] == 4
        and [r["planned"] for r in current["cohorts"]] == [16, 12],
        "Behavioral census changed",
    )
    require(
        list(current["source_sha256"]) == list(expected), "Missing, foreign or reordered source"
    )
    allowed = {
        "schema",
        "role",
        "source_commit",
        "source_tree",
        "legacy_inputs_sha256",
        "generated_inputs_sha256",
        "original_source_count",
        "current_source_count",
        "retained_original_path_order",
        "sources",
        "produced_native_artifacts",
        "produced_native_receiving",
        "native28",
        "runtime_admission",
        "final_cohort_tools_required",
        "final_cohort_tools_present",
        "generated_inputs_self_hashed",
    }
    require(set(receipt) == allowed, "Unknown or missing receiving field")
    require(
        type(receipt["schema"]) is int
        and receipt["schema"] == 1
        and receipt["role"] == "actual-git-source-provenance-not-behavioral-oracle",
        "Wrong role",
    )
    require(
        receipt["source_commit"] == commit and receipt["source_tree"] == source_tree,
        "Stale source epoch",
    )
    require(receipt["legacy_inputs_sha256"] == OLD, "Wrong original provenance")
    require(
        type(receipt["final_cohort_tools_required"]) is bool
        and receipt["generated_inputs_self_hashed"] is False,
        "Wrong final tool role",
    )
    present = sorted(ENROLLMENT.intersection(expected))
    require(receipt["final_cohort_tools_present"] == present, "Wrong final tool census")
    require(
        not receipt["final_cohort_tools_required"] or set(present) == ENROLLMENT,
        "Incomplete mandatory tools",
    )
    require(
        type(receipt["original_source_count"]) is int
        and receipt["original_source_count"] == len(old["source_sha256"])
        and type(receipt["current_source_count"]) is int
        and receipt["current_source_count"] == len(expected)
        and receipt["retained_original_path_order"] is True,
        "Wrong source census",
    )
    require(
        receipt["produced_native_artifacts"] == PAC
        and receipt["native28"] == "UNRUN"
        and receipt["runtime_admission"] is False
        and receipt["produced_native_receiving"]
        == "separate original PAC source/artifact receipt required; not qualified here",
        "Invented artifact/native qualification",
    )
    require(len(receipt["sources"]) == len(expected), "Wrong source row count")
    for actual, (name, facts) in zip(receipt["sources"], expected.items()):
        require(
            set(actual) == {"path", "mode", "type", "git_blob", "sha256", "roles"},
            "Malformed source row",
        )
        require(actual == {"path": name, **facts}, "Git/mode/blob/source/role mismatch")
        require(current["source_sha256"][name] == facts["sha256"], "Input source digest mismatch")


def controls(old, current, receipt, commit, source_tree, expected):
    outcomes = []

    def refusal(name, mutate):
        left, right = copy.deepcopy(current), copy.deepcopy(receipt)
        mutate(left, right)
        try:
            validate(old, left, right, commit, source_tree, expected)
        except (ValueError, KeyError, TypeError):
            outcomes.append({"name": name, "status": "PASS", "actual": "REFUSED"})
        else:
            raise AssertionError("Accepted " + name)

    refusal("stale commit", lambda a, b: b.update(source_commit="0" * 40))
    refusal("stale tree", lambda a, b: b.update(source_tree="0" * 40))
    refusal("changed budget", lambda a, b: a.update(budget_ms=a["budget_ms"] + 1))
    refusal(
        "changed behavioral name",
        lambda a, b: a["cohorts"][0]["expected_names"].__setitem__(0, "fabricated"),
    )
    refusal("missing behavioral receipt", lambda a, b: a["registration_receipts"].pop())
    refusal("missing source", lambda a, b: a["source_sha256"].pop(next(iter(a["source_sha256"]))))
    refusal("foreign source", lambda a, b: a["source_sha256"].update({"../foreign": "0" * 64}))
    refusal(
        "reordered source",
        lambda a, b: a.update(source_sha256=dict(reversed(list(a["source_sha256"].items())))),
    )
    refusal(
        "changed input source hash",
        lambda a, b: a["source_sha256"].__setitem__(next(iter(a["source_sha256"])), "0" * 64),
    )
    refusal("wrong Git blob", lambda a, b: b["sources"][0].update(git_blob="0" * 40))
    refusal("wrong Git mode", lambda a, b: b["sources"][0].update(mode="120000"))
    refusal("wrong Git type", lambda a, b: b["sources"][0].update(type="tree"))
    refusal("missing source role", lambda a, b: b["sources"][0].update(roles=[]))
    refusal(
        "duplicate source row", lambda a, b: b["sources"].append(copy.deepcopy(b["sources"][0]))
    )
    refusal("unknown row field", lambda a, b: b["sources"][0].update(approved=True))
    refusal("changed original provenance", lambda a, b: b.update(legacy_inputs_sha256="0" * 64))
    refusal("bool source count", lambda a, b: b.update(current_source_count=True))
    refusal("omitted PAC artifact owner", lambda a, b: b.update(produced_native_artifacts=[]))
    refusal("false native success", lambda a, b: b.update(native28="PASS"))
    refusal("false runtime admission", lambda a, b: b.update(runtime_admission=True))
    refusal("unknown receiving field", lambda a, b: b.update(approved=True))
    try:
        decode(b'{"x":1,"x":2}')
    except ValueError:
        outcomes.append({"name": "duplicate JSON field", "status": "PASS", "actual": "REFUSED"})
    else:
        raise AssertionError("Duplicate field accepted")
    return outcomes


def preparer_controls(root, commit, legacy, source, expected_sha, private_parent):
    image = source.read_bytes()
    require(sha(image) == expected_sha, "Preparer source changed before controls")
    model = types.ModuleType("_windows91_retained_preparer_control")
    model.__file__ = str(source)
    exec(compile(image, str(source), "exec"), model.__dict__)
    outcomes = []

    def refused(name, operation):
        try:
            operation()
        except ValueError:
            outcomes.append({"name": name, "status": "PASS", "actual": "REFUSED"})
        else:
            raise AssertionError("Preparer accepted " + name)

    def invoke(args):
        original = sys.argv
        try:
            sys.argv = [str(source), *args]
            model.main()
        finally:
            sys.argv = original

    with tempfile.TemporaryDirectory(
        prefix="windows91-source-controls-", dir=private_parent
    ) as temporary:
        temp = Path(temporary)

        def args(destination, chosen_commit=commit, chosen_legacy=legacy):
            return [
                "--checkout",
                str(root),
                "--actual-commit",
                chosen_commit,
                "--legacy-inputs",
                str(chosen_legacy),
                "--output",
                str(destination),
            ]

        refused("malformed actual commit", lambda: invoke(args(temp / "badcommit", "malformed")))
        old_parent = git(root, "rev-parse", commit + "^").decode().strip()
        require(old_parent != commit, "Stale control must name a different real commit")
        refused("stale real HEAD", lambda: invoke(args(temp / "stale", old_parent)))
        occupied = temp / "occupied"
        occupied.mkdir()
        (occupied / "sentinel").write_bytes(b"owned")
        refused("occupied output", lambda: invoke(args(occupied)))
        require((occupied / "sentinel").read_bytes() == b"owned", "Occupied output changed")
        dangling = temp / "dangling"
        dangling.symlink_to(temp / "absent")
        refused("dangling output symlink", lambda: invoke(args(dangling)))
        refused("unsafe source traversal", lambda: model.disk_image(temp, "../escape"))
        real_name = "static/ergopti_plus/windows/tests/unit/platform/remap/key_combinations/test_key_combinations.ahk"
        real_image = git(root, "show", commit + ":" + real_name)
        changed = temp / "changed-source"
        changed.write_bytes(real_image + b"; private altered source\n")
        refused(
            "changed committed source image",
            lambda: model.validate_image(real_image, model.disk_image(temp, "changed-source")),
        )
        altered = decode(legacy.read_bytes())
        altered["budget_ms"] += 1
        altered_path = temp / "altered-original.json"
        altered_path.write_text(json.dumps(altered))
        refused(
            "changed original behavioral frame",
            lambda: invoke(args(temp / "altered-output", chosen_legacy=altered_path)),
        )
        if not ENROLLMENT <= tree(root, commit).keys():
            enrollment_output = temp / "missing-final-tools"
            refused(
                "missing committed final helper closure",
                lambda: invoke(args(enrollment_output) + ["--require-enrollment"]),
            )
            require(
                not (enrollment_output / "source-provenance-receipt.json").exists(),
                "Refused final tools emitted accepting receipt",
            )
        symlink_file = temp / "same-byte-source"
        same_byte_target = temp / "original-source-copy"
        same_byte_target.write_bytes(real_image)
        require(same_byte_target.read_bytes() == real_image, "Same-byte source control changed")
        symlink_file.symlink_to(same_byte_target)
        refused(
            "source symlink even with retained bytes",
            lambda: model.disk_image(temp, "same-byte-source"),
        )
    require(source.read_bytes() == image, "Preparer source changed during controls")
    return outcomes


def receive(
    root, commit, generated, legacy, helper_path, control_path, output, preparer, preparer_sha
):
    initial = frame(root)
    require(initial["head"] == commit, "Actual HEAD stale")
    original_bytes = legacy.read_bytes()
    require(sha(original_bytes) == OLD, "Immutable original changed")
    old = decode(original_bytes)
    current_bytes = (generated / "windows-key-combination-cohort-inputs.json").read_bytes()
    receipt_bytes = (generated / "source-provenance-receipt.json").read_bytes()
    current, receipt = decode(current_bytes), decode(receipt_bytes)
    require(receipt["generated_inputs_sha256"] == sha(current_bytes), "Wrong generated input bytes")
    rows = tree(root, commit)
    manifest_blob = git(
        root, "cat-file", "blob", rows["tools/build/windows_bundle_manifest.json"][2]
    )
    require(
        (generated / "committed-windows-bundle-manifest.json").read_bytes() == manifest_blob,
        "Manifest is not committed image",
    )
    roles = closure(old, rows, decode(manifest_blob))
    facts, permissions = {}, {}
    for name, source_roles in roles.items():
        require(
            name in rows and rows[name][0] in ("100644", "100755") and rows[name][1] == "blob",
            "Not committed regular source",
        )
        mode, kind, oid = rows[name]
        committed = git(root, "cat-file", "blob", oid)
        observed, permission = disk(root, name)
        require(observed == committed, "Disk differs from committed source: " + name)
        require(bool(permission & 0o111) == (mode == "100755"), "Executable mode differs: " + name)
        facts[name] = {
            "mode": mode,
            "type": kind,
            "git_blob": oid,
            "sha256": sha(committed),
            "roles": source_roles,
        }
        permissions[name] = oct(permission)
    validate(old, current, receipt, commit, initial["tree"], facts)
    helper = helper_path.read_bytes()
    control = control_path.read_bytes()
    require(sha(helper) == HELPER and sha(control) == CONTROL, "Reviewed helper/control changed")
    begin = helper.index(b"async function child(")
    end = helper.index(b"\n}\n", begin) + 3
    require(sha(helper[begin:end]) == CHILD, "Native child lifecycle changed")
    outcomes = controls(old, current, receipt, commit, initial["tree"], facts)
    preparation_controls = preparer_controls(
        root, commit, legacy, preparer, preparer_sha, output.parent
    )
    for name, fact in facts.items():
        image, permission = disk(root, name)
        require(
            sha(image) == fact["sha256"] and oct(permission) == permissions[name],
            "Source changed during receiving",
        )
    require(
        frame(root) == initial and tree(root, commit) == rows,
        "HEAD/index/tree changed during receiving",
    )
    require(
        (generated / "windows-key-combination-cohort-inputs.json").read_bytes() == current_bytes
        and (generated / "source-provenance-receipt.json").read_bytes() == receipt_bytes,
        "Output changed during receiving",
    )
    result = {
        "status": "SOURCE_PROVENANCE_RECEIVED",
        "actual_commit": commit,
        "source_tree": initial["tree"],
        "frame_before": initial,
        "frame_after": frame(root),
        "original_inputs_sha256": OLD,
        "original_sources": len(old["source_sha256"]),
        "actual_sources": len(facts),
        "additional_sources": len(facts) - len(old["source_sha256"]),
        "generated_inputs_sha256": sha(current_bytes),
        "generator_receipt_sha256": sha(receipt_bytes),
        "all_original_non_source_fields_exact": True,
        "all28_names_and_registration_receipts_exact": True,
        "all_source_git_mode_type_blob_disk_and_final_epoch_exact": True,
        "native_child_sha256": CHILD,
        "helper_sha256": HELPER,
        "control_sha256": CONTROL,
        "negative_controls": outcomes,
        "preparer_sha256": preparer_sha,
        "preparer_negative_controls": preparation_controls,
        "native28": "UNRUN",
        "native_physical_altgr_desktop": "UNRUN",
        "runtime_admission": False,
        "produced_PAC_outputs": PAC,
        "produced_PAC_receiving": "separate original build owner; NOT received here",
    }
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(
        json.dumps(
            {
                "status": result["status"],
                "source_rows": len(facts),
                "refusal_controls": len(outcomes) + len(preparation_controls),
                "native28": "UNRUN",
            }
        )
    )


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    for arg in (
        "checkout",
        "actual-commit",
        "generated",
        "legacy-inputs",
        "helper-source",
        "control-source",
        "output",
        "preparer-source",
        "preparer-sha256",
    ):
        p.add_argument("--" + arg, required=True)
    a = p.parse_args()
    receive(
        Path(a.checkout).resolve(strict=True),
        a.actual_commit,
        Path(a.generated),
        Path(a.legacy_inputs),
        Path(a.helper_source),
        Path(a.control_source),
        Path(a.output),
        Path(a.preparer_source),
        a.preparer_sha256,
    )
