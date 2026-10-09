# modules/llm/managed_ollama_hint.py
"""Asynchronously receive public runtime hints without admitting a daemon."""

import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import stat
import sys
import time

DRIVER = Path(__file__).absolute().parents[2]
SHARED = DRIVER.parent / "_shared"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


POLICY = load("ergopti_hint_runtime", SHARED / "python/managed_ollama_runtime.py")
HINT = load("ergopti_hint_policy", SHARED / "python/managed_ollama_hint.py")
NATIVE = load("ergopti_hint_native", DRIVER / "platform/ollama_hint_metadata.py")


def receive(
    driver, home, host, *, clock=time.monotonic, remaining=None, expected_policy_sha256=None
):
    """Capture the original clock before the first native read; publish no secrets."""
    started = clock()
    if remaining is not None and (
        type(remaining) not in (int, float) or not math.isfinite(remaining) or remaining <= 0
    ):
        raise POLICY.RuntimeRefusal("deadline")
    deadline = started + remaining if remaining is not None else None

    def progress():
        if deadline is not None and clock() >= deadline:
            raise POLICY.RuntimeRefusal("deadline")

    maximum = POLICY.MAXIMUM_METADATA_BYTES

    def read(path):
        return NATIVE.read_regular(path, maximum, progress=progress)

    raw_budget = read(driver.parent / "_shared/modules/network/bootstrap_retry.json")
    if expected_policy_sha256 is not None and POLICY.sha256(raw_budget) != expected_policy_sha256:
        raise POLICY.RuntimeRefusal("metadata")
    selected_budgets = HINT.canonical_budgets(POLICY, raw_budget)
    deadline = (
        min(deadline, started + selected_budgets["admission"])
        if deadline is not None
        else started + selected_budgets["admission"]
    )
    progress()
    if HINT.budgets(POLICY, read(driver / "modules/llm/network-retry.sh")) != selected_budgets:
        raise POLICY.RuntimeRefusal("metadata")
    shared = driver.parent / "_shared/modules/llm"
    bootstrap = POLICY.metadata_bytes(read(shared / "managed_ollama_bootstrap.json"))
    if (
        type(bootstrap.get("maximum_metadata_bytes")) is not int
        or bootstrap["maximum_metadata_bytes"] != maximum
    ):
        raise POLICY.RuntimeRefusal("metadata")
    if type(home) is not str or not home.startswith("/") or "\0" in home:
        raise POLICY.RuntimeRefusal("metadata")
    directory = Path(home) / "Library/Application Support/Ergopti/ollama-native-http"
    binary = HINT.candidate(
        POLICY,
        read(shared / "managed_ollama_runtime.json"),
        read(shared / "managed_ollama_release.json"),
        read(directory / POLICY.RECEIPT_BASENAME),
        host,
    )
    executable = directory / binary
    observed = executable.stat(follow_symlinks=False)
    if not stat.S_ISREG(observed.st_mode) or not observed.st_mode & 0o111:
        raise POLICY.RuntimeRefusal("metadata")
    progress()
    return {"version": 1, "candidate": str(executable), "budgets": selected_budgets}


def main():
    try:
        if platform.system() != "Darwin":
            raise POLICY.RuntimeRefusal("unavailable")
        parser = argparse.ArgumentParser(add_help=False)
        parser.add_argument("--timeout-seconds", type=float, required=True)
        parser.add_argument("--policy-sha256", required=True)
        parser.add_argument("--architecture", choices=("arm64", "x86_64"), required=True)
        args = parser.parse_args()
        arch = platform.machine()
        if arch != args.architecture:
            raise POLICY.RuntimeRefusal("unavailable")
        host = {"arm64": "macos-arm64", "x86_64": "macos-amd64"}.get(arch)
        if host is None:
            raise POLICY.RuntimeRefusal("unavailable")
        result = receive(
            DRIVER,
            os.environ.get("HOME"),
            host,
            remaining=args.timeout_seconds,
            expected_policy_sha256=args.policy_sha256,
        )
        sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
        return 0
    except (
        POLICY.RuntimeRefusal,
        NATIVE.MetadataRefusal,
        OSError,
        ValueError,
        KeyError,
        TypeError,
    ):
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
