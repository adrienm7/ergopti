# tools/build/remap_runtime_auth_hs274_test.py

"""Run an external frozen role/UID corpus against the portable policy.

This obtains no native facts and gives no Security/socket/capture qualification.
Expected outcomes are read unchanged from the independent before-code corpus.
"""

from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess


def run(policy: Path, corpus: Path, output: Path) -> int:
    original_corpus = corpus.read_bytes()
    cases = json.loads(original_corpus)["cases"]
    if len(cases) != 22 or len({case["id"] for case in cases}) != 22:
        raise RuntimeError("Frozen22 corpus count/identity changed")
    output.mkdir(parents=True, exist_ok=False)
    # The independent oracle uses one deliberately abstract operation to isolate
    # Console route/UID admission. It maps to the existing actual Core-agent
    # frontmost_application_changed operation, never to a new production opcode.
    adapter = {"ordinary_supported_request": "frontmost_application_changed"}
    (output / "adapter.json").write_text(json.dumps(adapter, indent=2) + "\n")
    statements = []
    for case in cases:
        receiver = case.get("receiver_uid")
        receiver_cpp = (
            "std::nullopt" if receiver is None else f"std::optional<std::uint32_t>{{{receiver}}}"
        )
        operation = adapter.get(case["operation"], case["operation"])
        result = "policy::admission::denied"
        if case["expected"].startswith("ALLOW_ONLY_WITH_CURRENT_NATIVE_OWNER"):
            result = "policy::admission::native_owner_frame_required"
        elif case["expected"].startswith("ALLOW_ONLY_WITH_CURRENT_NATIVE_FRAME"):
            result = "policy::admission::native_frame_required"
        elif case["expected"].startswith("ATTRIBUTE_"):
            result = "policy::admission::native_owner_frame_required"
        elif case["expected"].startswith("HEALTH_ONLY"):
            result = "policy::admission::health_only"
        context = (
            "policy::observation{policy::route::"
            + case["route"]
            + ", policy::role::"
            + case["local_role"]
            + ", policy::role::"
            + case["peer_role"]
            + f", {case['local_euid']}, {case['peer_euid']}, "
            + receiver_cpp
            + "}"
        )
        statements.append(
            "  check("
            + json.dumps(case["id"])
            + ", policy::operation_admission("
            + context
            + ", "
            + json.dumps(operation)
            + ") == "
            + result
            + ");"
        )
        if case["expected"].startswith("ATTRIBUTE_"):
            # This only verifies independent pure native-field selection. No
            # socket access/cache/actual session receiver has been implemented.
            statements.append(f'  check("native-field-attribution", {context}.peer_euid == 501);')
    source = (
        """#include "remap_runtime_auth_policy.hpp"
#include <iostream>
namespace policy = ergoptiplus::remap::auth_policy;
int failures = 0;
void check(const char* name, bool value) {
  if (!value) { ++failures; std::cerr << name << ": FAIL\\n"; }
}
int main() {
"""
        + "\n".join(statements)
        + "\n  return failures ? 1 : 0;\n}\n"
    )
    cpp = output / "policy.cpp"
    cpp.write_text(source)
    (output / "oracle.json").write_bytes(original_corpus)
    receipts = []
    for mode, flag in [("unoptimized", "-O0"), ("optimized", "-O2")]:
        binary = output / ("policy-" + mode)
        command = [
            os.environ.get("CXX", "c++"),
            "-std=c++17",
            flag,
            "-Wall",
            "-Wextra",
            "-Werror",
            "-I" + str(policy.parent),
            str(cpp),
            "-o",
            str(binary),
        ]
        compile_run = subprocess.run(command, capture_output=True, text=True, timeout=30)
        (output / (mode + "-compile.log")).write_text(compile_run.stdout + compile_run.stderr)
        if compile_run.returncode:
            receipts.append(
                {"mode": mode, "compile_exit": compile_run.returncode, "run": "NOT_EXECUTED"}
            )
            continue
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        (output / (mode + "-run.log")).write_text(result.stdout + result.stderr)
        receipts.append(
            {
                "mode": mode,
                "compile_exit": 0,
                "run_exit": result.returncode,
                "literal_policy_cases": len(cases),
                "native_executed": 0,
            }
        )
    if corpus.read_bytes() != original_corpus:
        raise RuntimeError("Frozen oracle changed")
    report = {
        "qualification": "PORTABLE_LITERAL_POLICY_ONLY",
        "native_executed": 0,
        "oracle_sha256": hashlib.sha256(original_corpus).hexdigest(),
        "policy_sha256": hashlib.sha256(policy.read_bytes()).hexdigest(),
        "adapter": adapter,
        "receipts": receipts,
    }
    (output / "RESULT.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return int(any(receipt.get("run_exit", 1) or receipt["compile_exit"] for receipt in receipts))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("policy", type=Path)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    return run(args.policy, args.corpus, args.output)


if __name__ == "__main__":
    raise SystemExit(main())
