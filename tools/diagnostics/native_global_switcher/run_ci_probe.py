# tools/diagnostics/native_global_switcher/run_ci_probe.py
"""Additive native CI entry: prerequisite refusal is unqualified failure, not skip."""

import argparse
from pathlib import Path

import run_native_probe


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(arguments)
    root = args.source_root.resolve(strict=True)
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    # Execute the same persistent controller in this process; no wrapper child or
    # PID-only delegation can discard its exact early-registered capabilities.
    status = run_native_probe.main(
        [
            "--download",
            "--scratch",
            str(args.output),
            "--owner-library",
            str(root / "tools/diagnostics/macos_owned_process.py"),
            "--inventory-library",
            str(root / "tools/diagnostics/native_hs_program_providers/run_native.py"),
        ]
    )
    if type(status) is int and status == 0:
        print(
            "::notice title=Global switcher probe::Isolated native switch observed and physically retired; product/physical-key qualification remains unexecuted."
        )
        return 0
    if type(status) is int and status == 77:
        print(
            "::error title=Global switcher probe::Native prerequisites refused; UNQUALIFIED, never passed or skipped. No TCC grant attempted."
        )
        return 1
    print(
        "::error title=Global switcher probe::Native probe failed; preserve exact owned receipts and logs."
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
