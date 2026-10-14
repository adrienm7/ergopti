"""Closed current-network source continuation; original APIs remain untouched."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from types import ModuleType

COMPANION_PATH = "tools/diagnostics/number_row_current_network_causal.py"
CORE_PATH = "tools/diagnostics/number_row_native_causal.py"
POSITIVE_PATH = "tools/diagnostics/keyboard_geometry_xctest_receipt.py"
FIXED_SOURCE_PINS = {
    CORE_PATH: "d913505e2d3522d5023227b947f3c7896ba3ef4aeadfbd0c1a7042fa9686c148",
    POSITIVE_PATH: "9cef4f9256f3604ac07d710d77c95424718012f23c6a8b472f9e5936253ac094",
    "tools/diagnostics/generate_number_row_source_composition.py": "8478aca8584e3da947f1e2c3b0f894874cce77aa97022be7832cb40d4182644c",
    "tools/diagnostics/prepare_number_row_native_causal.py": "9203a7f77e0ed607557283b8ff27355ad871d99e58229e018c213d7653e79139",
    "tools/diagnostics/test_number_row_native_causal.py": "f058b0937e278229f2b348d07c65c8e73c575dbb12cbbde53713ab91d3df9ca2",
    "tools/diagnostics/test_number_row_source_composition.py": "0981b0f400596680b19215ffcd2ecef20346dca8bfeae8c46a46f0a7ad68e7f1",
    "tools/diagnostics/tis_evidence_transport.cjs": "f62344840267ab207370df974cc344fce83cbe3b758f2a25c986837a41d04269",
    "tools/diagnostics/fixtures/number-row-native-causal/projection-manifest.original-c15.json.raw": "77118a5238f504b1475988957843427f61aaaa798ab9f972e812205a2fb5b7ba",
    "tools/diagnostics/fixtures/number-row-native-causal/g5-source-approvals.json.raw": "47b2dc03e558db6418234ab6c69a279cc91fd9c29bc587505e13ea0989764549",
}


def SHA(data):
    return hashlib.sha256(data).hexdigest()


def source_frame(repo, head, companion_sha):
    if (
        not isinstance(head, str)
        or re.fullmatch(r"[0-9a-f]{40}", head) is None
        or not isinstance(companion_sha, str)
        or re.fullmatch(r"[0-9a-f]{64}", companion_sha) is None
        or subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
        != head
    ):
        raise ValueError(
            "actual committed source and independently received companion binding required"
        )
    images = {}
    for path, expected in {**FIXED_SOURCE_PINS, COMPANION_PATH: companion_sha}.items():
        item = repo / path
        data = item.read_bytes()
        record = subprocess.check_output(["git", "ls-tree", "-z", head, "--", path], cwd=repo)
        pieces = record.split(b"\0")
        if len(pieces) != 2 or pieces[1] != b"":
            raise ValueError("one exact source image required")
        header, name = pieces[0].split(b"\t", 1)
        mode, kind, blob = header.decode().split()
        if (
            item.is_symlink()
            or not item.is_file()
            or not item.resolve().is_relative_to(repo)
            or name.decode() != path
            or mode != "100644"
            or kind != "blob"
            or SHA(data) != expected
            or data != subprocess.check_output(["git", "show", head + ":" + path], cwd=repo)
        ):
            raise ValueError("original or companion committed source binding refused")
        images[path] = data
    if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip() != head:
        raise ValueError("source changed during image admission")
    return images


def load_core(repo, head, companion_sha):
    images = source_frame(repo, head, companion_sha)
    positive_name = "keyboard_geometry_xctest_receipt"
    missing = object()
    previous = sys.modules.get(positive_name, missing)
    positive = ModuleType(positive_name)
    positive.__file__ = str(repo / POSITIVE_PATH)
    core = ModuleType("unchanged_number_row_causal_core")
    core.__file__ = str(repo / CORE_PATH)
    try:
        sys.modules[positive_name] = positive
        exec(compile(images[POSITIVE_PATH], positive.__file__, "exec"), positive.__dict__)
        exec(compile(images[CORE_PATH], core.__file__, "exec"), core.__dict__)
    finally:
        if previous is missing:
            sys.modules.pop(positive_name, None)
        else:
            sys.modules[positive_name] = previous
    if source_frame(repo, head, companion_sha) != images:
        raise ValueError("admitted source changed during retained-byte load")
    return core, images


def new_outside_file(repo, path):
    if (
        path.is_symlink()
        or path.exists()
        or not path.parent.is_dir()
        or path.resolve().is_relative_to(repo)
    ):
        raise ValueError("new outside output file required")


# This separate opt-in roster is not an expansion of the legacy composition API.
CURRENT_NETWORK_BASE_APPROVAL_SHA = (
    "47b2dc03e558db6418234ab6c69a279cc91fd9c29bc587505e13ea0989764549"
)
CURRENT_NETWORK_BASE_PATHS = (
    "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/RemapLeaseWorker.swift",
    "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/RemapLeaseWorkerTests.swift",
)
CURRENT_NETWORK_ROLES = {
    "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedBootstrapDownload.swift": (
        "980c261c18fd417f896efda44590e3fe4881b419",
        "b0c188bfd62d65336c041183c312c94a7d042d8c38d65f2d9a61469a7aa5b0ad",
        "4485baa5f97fc6232417742976f0e30426e43311",
        "de611cc1f0ae94beb20930ccb7e76e8a21ea1bc488c6dae94802298b47a90b94",
    ),
    "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift": (
        "e17ff5af9c971d32d2a3536693f93a4e02e634cd",
        "0650c5f3c6ab64b79f324dcf07331286a2c7710fec2734fec93c8d800cddd624",
        "2887593d22dfd7c5d5280a31f1210f4a7152b6f7",
        "ab575a32abf59d0258c393509ca8f1067885338e655f5e53f523efc0e4f55a77",
    ),
    "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/ManagedBootstrapDownloadTests.swift": (
        "a36a7cb184fad53e0dd44844f912e0b4ad96c2ad",
        "50c0ccd4135112ac43c65efe3db33664b624326966e3488f793ed4468075cebb",
        "dc6314036b8d9916c67d74b42c2c30653b89c653",
        "64966864219c3ac4d360f4e6e9641e15b5ab88515874dcab1806ccc83bff230f",
    ),
    "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/ManagedHTTPWorkerTests.swift": (
        "1b2f96dc1e9c29b5a79d8eba05d03fa0eca0b9e6",
        "ef4882cc6ac6a7c578e756405cb4ae77f0f80243e96e6417f4fff69be2b54243",
        "6b5960985c4ff5f28297ec0eeb4d2318fb6659be",
        "774549205624192feaebad02234887e1b0a418504dca95e9253cf222d79af03c",
    ),
}


def _current_network_contract(
    core,
    recipe_path,
    approval_path,
    approval_sha,
    network_approval_path,
    network_approval_sha,
    composition=None,
):
    if approval_sha != CURRENT_NETWORK_BASE_APPROVAL_SHA:
        raise ValueError("exact historical two-role base approval required")
    legacy, base, old_composition = core._composition_contract(
        recipe_path, approval_path, approval_sha
    )
    if tuple(row["path"] for row in base["approvals"]) != CURRENT_NETWORK_BASE_PATHS:
        raise ValueError("exact historical two-role base required")
    network = core._closed_json(network_approval_path, network_approval_sha)
    if (
        not isinstance(network, dict)
        or set(network) != {"schema", "role", "approvals"}
        or type(network["schema"]) is not int
        or network["schema"] != 1
        or network["role"] != "independently-reviewed-committed-source-inputs"
        or not isinstance(network["approvals"], list)
        or len(network["approvals"]) != 4
    ):
        raise ValueError("exact independently received four-role network envelope required")
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
    old_by_path = {row["path"]: row for row in legacy["paths"]}
    for path, record in zip(CURRENT_NETWORK_ROLES, network["approvals"]):
        if (
            not isinstance(record, dict)
            or set(record) != keys
            or type(record["schema"]) is not int
            or record["schema"] != 1
            or record["role"] != "independently-reviewed-committed-source-input"
            or record["path"] != path
        ):
            raise ValueError("exact ordered current network source role required")
        received_tuple = (
            record["original_git_blob"],
            record["original_sha256"],
            record["git_blob"],
            record["sha256"],
        )
        if received_tuple != CURRENT_NETWORK_ROLES[path]:
            raise ValueError("exact received network source tuple required")
        old = old_by_path[path]
        if (old["git_blob"], old["sha256"]) != received_tuple[:2]:
            raise ValueError("immutable network source predecessor required")
        for key, length in (("published_source_commit", 40), ("source_review_sha256", 64)):
            if (
                not isinstance(record[key], str)
                or re.fullmatch(r"[0-9a-f]{" + str(length) + r"}", record[key]) is None
            ):
                raise ValueError("externally received network source identity required")
    # Only this closed internal six-role object reaches the original Git/mode/
    # working-image/currentness law. It is not a separately hashed envelope.
    combined = {**base, "approvals": [*base["approvals"], *network["approvals"]]}
    replacements = {row["path"]: row for row in network["approvals"]}
    rows = [dict(row) for row in old_composition["paths"]]
    for row in rows:
        if row["path"] in replacements:
            received = replacements[row["path"]]
            row.update(git_blob=received["git_blob"], sha256=received["sha256"])
    expected = {
        "schema": 2,
        "role": "reviewed-current-network-build-input-composition-not-native-qualification",
        "historical_recipe_sha256": core.MANIFEST_SHA,
        "source_approval_sha256": approval_sha,
        "network_source_approval_sha256": network_approval_sha,
        "paths": rows,
    }
    if composition is not None and (
        not isinstance(composition, dict)
        or type(composition.get("schema")) is not int
        or composition != expected
    ):
        raise ValueError("exact closed six-role current network composition required")
    return legacy, combined, expected


def create_current_network_composition(
    core,
    repo,
    head,
    recipe_path,
    approval_path,
    approval_sha,
    network_approval_path,
    network_approval_sha,
):
    legacy, combined, composition = _current_network_contract(
        core, recipe_path, approval_path, approval_sha, network_approval_path, network_approval_sha
    )
    core._current_composition_inputs(repo, head, legacy, combined, composition)
    return composition


def verify_current_network_projection(
    core,
    repo,
    head,
    recipe_path,
    approval_path,
    approval_sha,
    composition_path,
    composition_sha,
    root,
    original,
    *,
    network_approval_path,
    network_approval_sha,
):
    composition = core._closed_json(composition_path, composition_sha)
    legacy, approval, composition = _current_network_contract(
        core,
        recipe_path,
        approval_path,
        approval_sha,
        network_approval_path,
        network_approval_sha,
        composition,
    )
    inputs, provenance = core._current_composition_inputs(repo, head, legacy, approval, composition)
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
    mutated = original.replace(core.NEEDLE, b"true", 1)
    proof = core.verify_mutation(original, mutated, inputs[tests])
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
            historical_recipe_sha256=core.MANIFEST_SHA,
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
            historical_recipe_sha256=core.MANIFEST_SHA,
            composition_sha256=composition_sha,
            source_approval_sha256=approval_sha,
            approved_auxiliary_source_commit=approval["published_source_commit"],
            paths=provenance,
        )
    proof["network_source_approval_sha256"] = network_approval_sha
    # Re-read both received envelopes after projection reads before the last
    # original Git/currentness join. No native acceptance is granted here.
    _current_network_contract(
        core,
        recipe_path,
        approval_path,
        approval_sha,
        network_approval_path,
        network_approval_sha,
        composition,
    )
    core._current_composition_inputs(repo, head, legacy, approval, composition)
    return proof


def materialize_current_network_projection(
    core,
    repo,
    head,
    recipe_path,
    approval_path,
    approval_sha,
    composition_path,
    composition_sha,
    destination,
    evidence,
    *,
    network_approval_path,
    network_approval_sha,
):
    composition = core._closed_json(composition_path, composition_sha)
    legacy, approval, composition = _current_network_contract(
        core,
        recipe_path,
        approval_path,
        approval_sha,
        network_approval_path,
        network_approval_sha,
        composition,
    )
    inputs, _ = core._current_composition_inputs(repo, head, legacy, approval, composition)
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
    mutated = original.replace(core.NEEDLE, b"true", 1)
    core.verify_mutation(original, mutated, inputs[legacy["original_test_source_unchanged"]])
    for path, data in inputs.items():
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(mutated if path == producer else data)
    proof = verify_current_network_projection(
        core,
        repo,
        head,
        recipe_path,
        approval_path,
        approval_sha,
        composition_path,
        composition_sha,
        destination,
        original,
        network_approval_path=network_approval_path,
        network_approval_sha=network_approval_sha,
    )
    (evidence / "NumberRowSourceProbe.original.swift").open("xb").write(original)
    with (evidence / "actual-git-projection.json").open("x") as stream:
        json.dump(proof, stream, sort_keys=True)
        stream.write("\n")
    return proof


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--head", required=True)
    parser.add_argument("--companion-sha256", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("generate", "materialize", "receive"):
        command = commands.add_parser(name)
        for field in ("recipe", "base-approval", "network-approval"):
            command.add_argument("--" + field, type=Path, required=True)
        for field in ("base-approval-sha256", "network-approval-sha256"):
            command.add_argument("--" + field, required=True)
        if name == "generate":
            command.add_argument("--output", type=Path, required=True)
        else:
            command.add_argument("--composition", type=Path, required=True)
            command.add_argument("--composition-sha256", required=True)
            command.add_argument("--projection", type=Path, required=True)
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
    if Path(__file__).is_symlink() or Path(__file__).resolve() != repo / COMPANION_PATH:
        raise ValueError("exact committed companion path required")
    # No target launch or native allocation occurs in generation/materialization.
    # All command modes load exactly the untouched original native judge.
    core, admitted = load_core(repo, args.head, args.companion_sha256)
    contract = (
        args.recipe,
        args.base_approval,
        args.base_approval_sha256,
        args.network_approval,
        args.network_approval_sha256,
    )
    if args.command == "generate":
        new_outside_file(repo, args.output)
        composition = create_current_network_composition(core, repo, args.head, *contract)
        if source_frame(repo, args.head, args.companion_sha256) != admitted:
            raise ValueError("source changed before composition publication")
        data = (json.dumps(composition, indent=2, sort_keys=True) + "\n").encode()
        with args.output.open("xb") as stream:
            stream.write(data)
        print(
            json.dumps(
                {
                    "actual_commit": args.head,
                    "composition_sha256": SHA(data),
                    "native_execution": "UNRUN",
                }
            )
        )
        return 0
    if args.command == "materialize":
        proof = materialize_current_network_projection(
            core,
            repo,
            args.head,
            args.recipe,
            args.base_approval,
            args.base_approval_sha256,
            args.composition,
            args.composition_sha256,
            args.projection,
            args.evidence,
            network_approval_path=args.network_approval,
            network_approval_sha=args.network_approval_sha256,
        )
        if source_frame(repo, args.head, args.companion_sha256) != admitted:
            raise ValueError("source changed after projection materialization")
        print(json.dumps({"actual_commit": proof["actual_commit"], "native_execution": "UNRUN"}))
        return 0
    for output in (args.receipt, args.tis_stdout, args.tis_stderr):
        new_outside_file(repo, output)
    try:
        proof = verify_current_network_projection(
            core,
            repo,
            args.head,
            args.recipe,
            args.base_approval,
            args.base_approval_sha256,
            args.composition,
            args.composition_sha256,
            args.projection,
            args.original_producer.read_bytes(),
            network_approval_path=args.network_approval,
            network_approval_sha=args.network_approval_sha256,
        )
        legacy = core._closed_json(args.recipe, core.MANIFEST_SHA)
        if (
            args.test_source.read_bytes()
            != (args.projection / legacy["original_test_source_unchanged"]).read_bytes()
        ):
            raise ValueError("test source detached from actual projection")
        if SHA(args.transport.read_bytes()) != core.TRANSPORT_SHA:
            raise ValueError("original TIS transport changed")
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
        result = core.evaluate(
            args.test_source.read_bytes(),
            args.log.read_text(encoding="utf-8"),
            args.swift_exit,
            args.capture_exit,
            tis,
            raw.returncode,
        )
        proof = verify_current_network_projection(
            core,
            repo,
            args.head,
            args.recipe,
            args.base_approval,
            args.base_approval_sha256,
            args.composition,
            args.composition_sha256,
            args.projection,
            args.original_producer.read_bytes(),
            network_approval_path=args.network_approval,
            network_approval_sha=args.network_approval_sha256,
        )
        if source_frame(repo, args.head, args.companion_sha256) != admitted:
            raise ValueError("original or companion source changed after native verdict")
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
