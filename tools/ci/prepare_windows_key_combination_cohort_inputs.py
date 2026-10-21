"""tools/ci/prepare_windows_key_combination_cohort_inputs.py

Prepare actual Git source provenance without changing the fixed 28-case census.

Selects a conservative declared Windows compiler/test/runtime source closure
from actual Git, retaining all legacy rows. No per-hash approval is required.
Native-produced PAC outputs have their separate original build receipt owner.
"""

import argparse
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

LEGACY_SHA = "a60f016ec2a530831fc5ae03015a60f1356ed4cb36035eeb1ab3e59bbcbfaeae"
BUNDLE_BUILDER = "tools/build/build_static_bundle.py"
BUNDLE_MANIFEST = "tools/build/windows_bundle_manifest.json"
WIN = "static/ergopti_plus/windows/"
SHARED = "static/ergopti_plus/_shared/"
# The actual -Publish owner overwrites precisely these paths before the cohorts.
PRODUCED = {
    WIN + "vendor/ergopti_network_pac.exe",
    WIN + "vendor/ergopti_network_pac.json",
    WIN + "vendor/ergopti_network_pac.LICENSE.txt",
}
ENROLLMENT_INPUTS = {
    "tools/ci/run-windows-key-combination-cohorts.cjs",
    "tools/ci/prepare_windows_key_combination_cohort_inputs.py",
    "tools/test/test-windows-key-combination-cohorts.cjs",
    "tools/test/test_windows_key_combination_source_roster.py",
    "tools/test/validate-ahk-suite-manifest.cjs",
    "tools/ci/windows-key-combination-cohort-original-inputs.json",
    "tools/test/portable-control-inputs.json",
}
BUILD_INPUTS = {
    ".github/workflows/ci-windows.yml",
    ".github/workflows/ci-windows-unit.yml",
    ".github/workflows/ci-windows-build.yml",
    ".node-version",
    "package.json",
    "package-lock.json",
    BUNDLE_BUILDER,
    BUNDLE_MANIFEST,
    "tools/build/build-features-manifest.js",
    "tools/lib/paths.cjs",
    "tools/lib/configuration-scopes.cjs",
    "tools/build/build_windows_nav_owner.ps1",
    "tools/build/build_windows_network_pac.ps1",
    "tools/build/prepare_network_pac_sources.py",
    SHARED + "data/linux_native_runtime.json",
    SHARED + "modules/network/pac_helpers.js",
}


def demand(ok, message):
    if not ok:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git(root, *args, data=None):
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        input=data,
        env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=120,
        check=False,
    )
    demand(result.returncode == 0 and result.stderr == b"", "Read-only Git receiving failed")
    return result.stdout


def tree(root, commit):
    result = {}
    for item in git(root, "ls-tree", "-r", "-z", commit).split(b"\0"):
        if not item:
            continue
        facts, raw_path = item.split(b"\t", 1)
        mode, kind, blob = facts.decode("ascii").split()
        path = raw_path.decode("utf-8", "strict")
        demand(path not in result, "Duplicate Git source path")
        result[path] = (mode, kind, blob)
    return result


def blob(root, rows, path):
    demand(
        path in rows and rows[path][0] in {"100644", "100755"} and rows[path][1] == "blob",
        "Source must be a committed regular file",
    )
    return git(root, "cat-file", "blob", rows[path][2])


def disk_image(root, path):
    current = root
    for piece in path.split("/"):
        demand(piece not in {"", ".", ".."} and "\\" not in piece, "Unsafe source path")
        current = current / piece
        demand(not current.is_symlink(), "Source symlink refused")
    demand(stat.S_ISREG(current.lstat().st_mode), "Source is not regular")
    return current.read_bytes()


def manifest_model(root, rows, evidence):
    """Execute the exact admitted original resolver bytes, never reopen/cache code."""
    image = blob(root, rows, BUNDLE_BUILDER)
    model = types.ModuleType("_windows91_original_bundle_resolver")
    model.__file__ = str(root / BUNDLE_BUILDER)
    prior = sys.modules.get(model.__name__)
    existed = model.__name__ in sys.modules
    sys.modules[model.__name__] = model
    try:
        exec(compile(image, model.__file__, "exec"), model.__dict__)
        path = evidence / "committed-windows-bundle-manifest.json"
        path.write_bytes(blob(root, rows, BUNDLE_MANIFEST))
        return model.load_manifest(path)
    finally:
        if existed:
            sys.modules[model.__name__] = prior
        else:
            sys.modules.pop(model.__name__, None)


def selected_paths(legacy, rows, manifest, require_enrollment=False):
    reasons = {path: ["retained-original-cohort-source"] for path in legacy["source_sha256"]}
    if require_enrollment:
        demand(
            ENROLLMENT_INPUTS <= rows.keys(),
            "Final Git helper/preparer/control source enrollment is incomplete",
        )
    for path in sorted(rows):
        if path in PRODUCED:
            continue
        roles = []
        if path.startswith(WIN) and not path.endswith(".md"):
            roles.append("windows-compiler-test-native-build-source-superset")
        if path.startswith(SHARED) and path.endswith(".ahk"):
            roles.append("shared-ahk-include-source-superset")
        # The real suite loads all registration files; shared fixtures can be read at bootstrap.
        if path.startswith(SHARED + "tests/"):
            roles.append("shared-registered-fixture-source-superset")
        if path.startswith(SHARED + "native/network/"):
            roles.append("original-native-pac-build-source")
        if path in BUILD_INPUTS:
            roles.append("declared-original-build-input")
        if path in ENROLLMENT_INPUTS and path in rows:
            roles.append("declared-cohort-tool-source")
        for include in manifest.includes:
            if path == include.source or path.startswith(include.source + "/"):
                if not any(group.matches(path) for group in manifest.excludes):
                    demand(
                        not any(
                            path == blocked or path.startswith(blocked + "/")
                            for blocked in manifest.not_shipped
                        ),
                        "Original bundle refuses declared source",
                    )
                    roles.append("original-bundle-runtime-source")
        if roles:
            reasons.setdefault(path, []).extend(roles)
    demand(
        not PRODUCED.intersection(reasons), "Produced runtime output cannot become a Git source pin"
    )
    demand(BUILD_INPUTS <= reasons.keys(), "Original build input missing")
    for required in manifest.required:
        demand(
            required.source in reasons or required.source in PRODUCED,
            "Required runtime asset lacks source/produced classification",
        )
    return reasons


def validate_image(committed, observed):
    demand(observed == committed, "Runtime/compiler source differs from committed Git")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkout", required=True)
    parser.add_argument("--actual-commit", required=True)
    parser.add_argument("--legacy-inputs", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--require-enrollment",
        action="store_true",
        help="Refuse unless the final helper/preparer/control files are committed; generated inputs never self-hash",
    )
    args = parser.parse_args()
    root = Path(args.checkout).resolve(strict=True)
    commit = args.actual_commit
    demand(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "Actual Git commit required")
    demand(
        git(root, "rev-parse", "HEAD").decode().strip() == commit,
        "HEAD is not actual received source",
    )
    before = tree(root, commit)
    legacy_bytes = Path(args.legacy_inputs).read_bytes()
    demand(sha(legacy_bytes) == LEGACY_SHA, "Original independent cohort frame changed")
    legacy = json.loads(legacy_bytes)
    demand(
        [row["planned"] for row in legacy["cohorts"]] == [16, 12]
        and legacy["planned_total"] == 28
        and legacy["expected_children"] == 4,
        "Original behavioral census changed",
    )
    output = Path(args.output)
    demand(not output.exists() and not output.is_symlink(), "Occupied output refused")
    output.mkdir()
    # Failure may retain exclusive source evidence, but never emits an accepting receipt.
    manifest = manifest_model(root, before, output)
    reasons = selected_paths(legacy, before, manifest, args.require_enrollment)
    sources = {}
    provenance = []
    for path, roles in reasons.items():
        data = blob(root, before, path)
        validate_image(data, disk_image(root, path))
        sources[path] = sha(data)
        provenance.append(
            {
                "path": path,
                "mode": before[path][0],
                "type": before[path][1],
                "git_blob": before[path][2],
                "sha256": sha(data),
                "roles": roles,
            }
        )
    demand(
        git(root, "rev-parse", "HEAD").decode().strip() == commit and tree(root, commit) == before,
        "Git source identity changed",
    )
    for path, expected in sources.items():
        demand(sha(disk_image(root, path)) == expected, "Final source image changed")
    updated = dict(legacy, source_sha256=sources)
    demand(
        {key: value for key, value in updated.items() if key != "source_sha256"}
        == {key: value for key, value in legacy.items() if key != "source_sha256"},
        "Behavioral oracle changed",
    )
    generated = (json.dumps(updated, indent=2) + "\n").encode()
    (output / "windows-key-combination-cohort-inputs.json").write_bytes(generated)
    receipt = {
        "schema": 1,
        "role": "actual-git-source-provenance-not-behavioral-oracle",
        "source_commit": commit,
        "source_tree": git(root, "rev-parse", commit + "^{tree}").decode().strip(),
        "legacy_inputs_sha256": LEGACY_SHA,
        "generated_inputs_sha256": sha(generated),
        "original_source_count": len(legacy["source_sha256"]),
        "current_source_count": len(sources),
        "retained_original_path_order": list(sources)[: len(legacy["source_sha256"])]
        == list(legacy["source_sha256"]),
        "sources": provenance,
        "produced_native_artifacts": sorted(PRODUCED),
        "produced_native_receiving": "separate original PAC source/artifact receipt required; not qualified here",
        "native28": "UNRUN",
        "runtime_admission": False,
        "final_cohort_tools_required": args.require_enrollment,
        "final_cohort_tools_present": sorted(ENROLLMENT_INPUTS.intersection(before)),
        "generated_inputs_self_hashed": False,
    }
    (output / "source-provenance-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
