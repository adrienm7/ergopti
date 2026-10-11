"""Generate one reviewed build-input composition; never grant native authority."""

import argparse
import hashlib
from types import ModuleType
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("recipe", "approval", "receiver", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--approval-sha256", required=True)
    args = parser.parse_args()
    repo = Path.cwd().resolve()
    if args.receiver.as_posix() != "tools/diagnostics/number_row_native_causal.py":
        raise ValueError("exact dedicated receiver path required")
    pins = {
        "tools/diagnostics/number_row_native_causal.py": "d913505e2d3522d5023227b947f3c7896ba3ef4aeadfbd0c1a7042fa9686c148",
        "tools/diagnostics/keyboard_geometry_xctest_receipt.py": "9cef4f9256f3604ac07d710d77c95424718012f23c6a8b472f9e5936253ac094",
        "tools/diagnostics/test_number_row_native_causal.py": "f058b0937e278229f2b348d07c65c8e73c575dbb12cbbde53713ab91d3df9ca2",
        "tools/diagnostics/tis_evidence_transport.cjs": "f62344840267ab207370df974cc344fce83cbe3b758f2a25c986837a41d04269",
    }
    if subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() != args.head:
        raise ValueError("actual source commit refused")
    admitted_images = {}
    for path, expected in pins.items():
        item = repo / path
        data = item.read_bytes()
        if (
            item.is_symlink()
            or not item.is_file()
            or hashlib.sha256(data).hexdigest() != expected
            or data != subprocess.check_output(["git", "show", args.head + ":" + path])
        ):
            raise ValueError("reviewed composition control source drift refused")
        admitted_images[path] = data
    destination = args.output
    if (
        destination.is_symlink()
        or destination.exists()
        or destination.resolve().is_relative_to(repo)
    ):
        raise ValueError("new outside composition output required")
    if not destination.parent.is_dir():
        raise ValueError("existing owned output parent required")
    positive_path = "tools/diagnostics/keyboard_geometry_xctest_receipt.py"
    positive_name = "keyboard_geometry_xctest_receipt"
    missing = object()
    previous = sys.modules.get(positive_name, missing)
    positive = ModuleType(positive_name)
    positive.__file__ = str((repo / positive_path).resolve())
    subject = ModuleType("reviewed_number_row_composition")
    subject.__file__ = str(args.receiver.resolve())
    try:
        sys.modules[positive_name] = positive
        exec(compile(admitted_images[positive_path], positive.__file__, "exec"), positive.__dict__)
        exec(
            compile(admitted_images[args.receiver.as_posix()], subject.__file__, "exec"),
            subject.__dict__,
        )
    finally:
        if previous is missing:
            sys.modules.pop(positive_name, None)
        else:
            sys.modules[positive_name] = previous
    composition = subject.create_composition(
        repo, args.head, args.recipe, args.approval, args.approval_sha256
    )
    data = (json.dumps(composition, indent=2, sort_keys=True) + "\n").encode()
    # The output is provenance. Its reviewed digest must be received separately
    # before the preparer/receiver may accept it for a native run.
    with destination.open("xb") as stream:
        stream.write(data)
    print(
        json.dumps(
            {
                "composition_sha256": hashlib.sha256(data).hexdigest(),
                "actual_commit": args.head,
                "native_execution": "UNRUN",
            }
        )
    )


if __name__ == "__main__":
    main()
