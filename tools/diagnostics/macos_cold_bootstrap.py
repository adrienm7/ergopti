#!/usr/bin/env python3
"""Receive a real Hammerspoon -> native PTY -> pinned MLX cold installation."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import time

from hs274_hammerspoon import native_lifecycle

REPOSITORY = Path(__file__).resolve().parents[2]
PREFIX = Path("static/ergopti_plus")
SOURCE_PATHS = (
    "macos/modules/llm/network-retry.sh",
    "macos/modules/llm/ensure-mlx-deps.sh",
    "macos/modules/llm/managed_bootstrap_http.py",
    "macos/modules/llm/mlx_deps_checker.lua",
    "macos/modules/llm/uv-release.sh",
    "macos/modules/llm/managed-python-release.sh",
    "macos/modules/llm/managed-python-downloads.json",
    "macos/adapters/native_bootstrap_pty.lua",
    "macos/platform/network/native_http.py",
    "_shared/python/network_proxy_policy.py",
    "_shared/lua/core/llm/native_pty_receipt.lua",
    "_shared/modules/network/proxy_policy.json",
    "_shared/modules/llm/managed_python_release.json",
    "macos/uv.lock",
    "macos/pyproject.toml",
)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def validate(result, config):
    """Require literal closure fences independently of the production Lua parser."""
    if (
        result.get("error")
        or result.get("success") is not True
        or result.get("state") != "ready"
        or result.get("runtime_installed") is not True
        or result.get("runtime") != "native Hammerspoon"
        or result.get("tasks") != 1
        or result.get("absent_python_selected") is not True
        or result.get("receipt_retired") is not True
        or result.get("receipt_removed") is not True
        or result.get("worker_status") != 0
        or result.get("ui_failure")
    ):
        raise RuntimeError("Native cold caller did not prove a successful retired installation")
    receipt = result.get("physical_receipt", {})
    expected = {
        "version": 1,
        "nonce": result.get("nonce"),
        "state": "retired",
        "group_retired": True,
        "guardian_reaped": True,
        "pty_eof": True,
        "handles_closed": True,
        "status_valid": True,
        "exit_status": 0,
        "worker_status": 0,
        "source_admitted": True,
    }
    if (
        receipt != expected
        or not isinstance(result.get("nonce"), str)
        or any(
            type(receipt.get(name)) is not bool
            for name in (
                "group_retired",
                "guardian_reaped",
                "pty_eof",
                "handles_closed",
                "status_valid",
                "source_admitted",
            )
        )
        or any(
            type(receipt.get(name)) is not int
            for name in ("version", "exit_status", "worker_status")
        )
        or type(result.get("worker_status")) is not int
        or type(result.get("tasks")) is not int
    ):
        raise RuntimeError("Native cold physical receipt is incomplete")
    if result.get("source_sha256") != digest(
        Path(config["driver"]) / "modules/llm/ensure-mlx-deps.sh"
    ):
        raise RuntimeError("Native cold executed source differs from admitted source")
    if (
        result.get("native_cli") != ["--managed-pty-worker", "1800000"]
        or type(result.get("worker_pid")) is not int
        or result["worker_pid"] <= 0
        or Path(result["receipt_path"]).exists()
    ):
        raise RuntimeError("Native cold CLI or private receipt retirement differs")


def receive(app, output):
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise RuntimeError("Native cold MLX receiving requires macOS arm64")
    app, output = app.resolve(strict=True), output.absolute()
    output.mkdir(mode=0o700)
    copied = output / "ErgoptiPlus.app"
    subprocess.run(["/usr/bin/ditto", str(app), str(copied)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(copied)], check=True)
    helper = copied / "Contents/MacOS/ErgoptiPlus"
    hammerspoon = copied / "Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon"
    if not helper.is_file() or not hammerspoon.is_file():
        raise RuntimeError("Signed native launcher and embedded Hammerspoon are required")
    resources = copied / "Contents/Resources"
    source_hashes = {}
    for relative in SOURCE_PATHS:
        bundled, source = resources / PREFIX / relative, REPOSITORY / PREFIX / relative
        if digest(bundled) != digest(source):
            raise RuntimeError("Cold bundle source is stale: " + relative)
        source_hashes[relative] = digest(bundled)
    # The script prepends these real locations. Require their actual absence
    # rather than introducing a fake PATH executable or reusing a warm uv.
    for path in ("/opt/homebrew/bin/uv", "/usr/local/bin/uv"):
        if Path(path).exists():
            raise RuntimeError("Cold prerequisite failed: preinstalled uv at " + path)
    home = output / "home"
    home.mkdir(mode=0o700)
    temporary = output / "tmp"
    temporary.mkdir(mode=0o700)
    support = home / "Library/Application Support/Ergopti"
    driver = resources / PREFIX / "macos"
    config = {
        "home": str(home),
        "driver": str(driver),
        "shared": str(driver.parent / "_shared"),
        "venv": str(support / "mlx-venv"),
        "uv_root": str(support / "mlx-uv"),
        "helper": str(helper),
        "result": str(output / "result.json"),
    }
    config_path = output / "config.json"
    config_path.write_text(json.dumps(config) + "\n", encoding="utf-8")
    environment = os.environ.copy()
    for name in tuple(environment):
        if (
            name.startswith(("ERGOPTI_", "UV_", "PYTHON"))
            or name.lower() in ("http_proxy", "https_proxy", "all_proxy", "no_proxy")
            or name in ("BASH_ENV", "ENV", "VIRTUAL_ENV", "CONDA_PREFIX")
        ):
            environment.pop(name)
    identity = helper.stat()
    environment.update(
        HOME=str(home),
        TMPDIR=str(temporary),
        PATH="/usr/bin:/bin:/usr/sbin:/sbin",
        XDG_CACHE_HOME=str(home / ".cache"),
        ERGOPTI_CONFIG_DIR=str(home / "config"),
        ERGOPTI_LAUNCHER_EXECUTABLE=str(helper),
        ERGOPTI_LAUNCHER_DEVICE=str(identity.st_dev),
        ERGOPTI_LAUNCHER_INODE=str(identity.st_ino),
        ERGOPTI_COLD_BOOTSTRAP_CONFIG=str(config_path),
    )
    lifecycle = native_lifecycle()
    native = lifecycle.NativeProcesses()
    report = {
        "version": 1,
        "status": "failed",
        "sources": source_hashes,
        "launcher_sha256": digest(helper),
        "hammerspoon_sha256": digest(hammerspoon),
    }
    with (output / "launch.log").open("xb") as log:
        consumer = subprocess.Popen(
            [str(hammerspoon), "-MJConfigFile", str(Path(__file__).with_suffix(".lua"))],
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 1920
            while not Path(config["result"]).exists():
                if consumer.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Cold Hammerspoon caller did not publish a terminal receipt")
                time.sleep(0.2)
            result = json.loads(Path(config["result"]).read_text(encoding="utf-8"))
            report["caller"] = result
            validate(result, config)
            if native.matching(helper):
                raise RuntimeError("Cold native helper processes remain after terminal receipt")
            python = Path(config["venv"]) / "bin/python"
            probe = subprocess.run(
                [
                    str(python),
                    "-I",
                    "-c",
                    "import sys,platform,mlx_lm,huggingface_hub,jinja2,safetensors,truststore;"
                    "assert sys.version_info[:2]==(3,11);assert platform.machine()=='arm64';"
                    "print(sys.version.split()[0])",
                ],
                capture_output=True,
                text=True,
                timeout=120,
                env=environment,
                check=True,
            )
            uv = Path(config["uv_root"]) / "bin/uv"
            version = subprocess.run(
                [str(uv), "--version"],
                capture_output=True,
                text=True,
                timeout=10,
                env=environment,
                check=True,
            ).stdout.strip()
            if version != "uv 0.12.21":
                raise RuntimeError("Cold uv does not match the independently pinned version")
            fingerprint = ":".join(digest(driver / path) for path in ("pyproject.toml", "uv.lock"))
            if (Path(config["venv"]) / ".last_sync_hash").read_text().strip() != fingerprint:
                raise RuntimeError("Cold published fingerprint differs from real locked inputs")
            report.update(
                status="passed",
                uv=version,
                python=probe.stdout.strip(),
                imports="passed",
                fingerprint=fingerprint,
                helpers_retired=True,
            )
        finally:
            lifecycle.cleanup(native, hammerspoon, consumer)
            # On refusal or timeout the actual private helper is signalled by
            # exact executable identity; retain the whole directory as evidence.
            for pid in native.matching(helper):
                native.signal(pid, helper, signal.SIGTERM)
            deadline = time.monotonic() + 60
            while native.matching(helper) and time.monotonic() < deadline:
                time.sleep(0.2)
            report["cleanup"] = not native.matching(helper)
            (output / "receipt.json").write_text(
                json.dumps(report, indent=2) + "\n", encoding="utf-8"
            )
            if report["cleanup"] is not True:
                raise RuntimeError("Cold native helper cleanup remains unsettled")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    receive(arguments.app, arguments.output)
