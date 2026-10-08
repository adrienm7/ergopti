#!/usr/bin/env python3
"""Receive a real Hammerspoon -> native PTY -> pinned MLX cold installation."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
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
    "macos/adapters/python_interpreter.lua",
    "macos/platform/network/native_http.py",
    "_shared/python/network_proxy_policy.py",
    "_shared/lua/core/llm/native_pty_receipt.lua",
    "_shared/modules/network/proxy_policy.json",
    "_shared/modules/llm/managed_python_release.json",
    "macos/uv.lock",
    "macos/pyproject.toml",
)

HAMMERSPOON_ARCHIVE_SHA256 = "11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa"
HAMMERSPOON_ARCHIVE_BYTES = 9704557


def isolated_runtime_paths(environment):
    """Name real stock runtime locations; no owned downloaded runtime is denied."""
    developers = {
        "/Applications/Xcode.app/Contents/Developer",
        "/Library/Developer/CommandLineTools",
    }
    if environment.get("DEVELOPER_DIR"):
        developers.add(environment["DEVELOPER_DIR"])
    selected = subprocess.run(
        ["/usr/bin/xcode-select", "-p"], capture_output=True, text=True, check=True
    ).stdout.strip()
    developers.add(selected)
    paths = {
        "/usr/bin/python3",
        "/opt/homebrew/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
        "/usr/local/bin/python3",
        "/opt/homebrew/bin/uv",
        "/usr/local/bin/uv",
        "/usr/bin/uv",
    }
    paths.update(str(Path(folder) / "usr/bin/python3") for folder in developers)
    paths.update(str(Path(path).resolve()) for path in tuple(paths))
    if any(not path.startswith("/") or any(c in path for c in "\r\n\0") for path in paths):
        raise RuntimeError("Cold isolation runtime path refused")
    return sorted(paths)


def sandbox_profile(paths):
    """Deny only captured runtime files to this process and its descendants."""
    return (
        "(version 1)\n(allow default)\n(deny file-read* process-exec\n"
        + "".join("  (literal " + json.dumps(path, ensure_ascii=False) + ")\n" for path in paths)
        + ")\n"
    )


def qualify_runtime_isolation(paths, profile):
    """Probe actual kernel read/exec denials; synthetic missing-runtime stubs cannot qualify."""
    observations = []
    for path in paths:
        file = Path(path)
        if not file.is_file():
            continue
        identity = file.stat()
        fingerprint = digest(file)
        denied_read = subprocess.run(
            ["/usr/bin/sandbox-exec", "-f", str(profile), "/bin/cat", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
        )
        if denied_read.returncode == 0 or "Operation not permitted" not in denied_read.stderr:
            raise RuntimeError("Cold isolation did not deny real runtime read")
        native = (
            subprocess.run(
                ["/usr/bin/lipo", path, "-verify_arch", "arm64"],
                capture_output=True,
                timeout=15,
            ).returncode
            == 0
        )
        denied_exec = False
        if native:
            subprocess.run([path, "--version"], capture_output=True, timeout=15, check=True)
            refused = subprocess.run(
                ["/usr/bin/sandbox-exec", "-f", str(profile), path, "--version"],
                capture_output=True,
                text=True,
                timeout=15,
            )
            if refused.returncode == 0 or "Operation not permitted" not in refused.stderr:
                raise RuntimeError("Cold isolation did not deny real runtime execution")
            denied_exec = True
        after = file.stat()
        if (identity.st_dev, identity.st_ino, fingerprint) != (
            after.st_dev,
            after.st_ino,
            digest(file),
        ):
            raise RuntimeError("Stock runtime changed during cold isolation qualification")
        observations.append(
            {
                "path": path,
                "sha256": fingerprint,
                "device": identity.st_dev,
                "inode": identity.st_ino,
                "bytes": identity.st_size,
                "read_denied": True,
                "native": native,
                "exec_denied": denied_exec,
            }
        )
    if not any(item["native"] and item["exec_denied"] for item in observations):
        raise RuntimeError("Cold isolation requires a genuine native stock runtime denial")
    return observations


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
        or result.get("python_resolver") != "unmodified production resolver"
        or result.get("python_state") != "python_missing"
        or type(result.get("native_python_candidates_count")) is not int
        or result.get("native_python_candidates_count") != 0
        or result.get("denied_runtime_paths") != config["denied_runtime_paths"]
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
    expected_sha = os.environ.get("GITHUB_SHA", "")
    if re.fullmatch(r"[a-f0-9]{40}", expected_sha) is None:
        raise RuntimeError("Cold receiving requires the exact CI source SHA")
    output.mkdir(mode=0o700)
    owner = output.stat()
    try:
        receive_owned(app, output, expected_sha)
    except Exception as failure:
        # Only the exact directory created above may retain a typed refusal.
        current = output.stat()
        receipt = output / "receipt.json"
        if (current.st_dev, current.st_ino) == (
            owner.st_dev,
            owner.st_ino,
        ) and not receipt.exists():
            with receipt.open("x", encoding="utf-8") as stream:
                json.dump(
                    {
                        "version": 1,
                        "status": "failed",
                        "refusal": "native_cold_bootstrap_prerequisite_or_receiving_refused",
                        "exception_type": type(failure).__name__,
                    },
                    stream,
                )
                stream.write("\n")
        raise


def receive_owned(app, output, expected_sha):
    """Receive only inside the fresh directory owned by this invocation."""
    copied = output / "ErgoptiPlus.app"
    subprocess.run(["/usr/bin/ditto", str(app), str(copied)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(copied)], check=True)
    helper = copied / "Contents/MacOS/ErgoptiPlus"
    hammerspoon = copied / "Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon"
    if not helper.is_file() or not hammerspoon.is_file():
        raise RuntimeError("Signed native launcher and embedded Hammerspoon are required")
    resources = copied / "Contents/Resources"
    stamp = resources / PREFIX / "_shared/build_stamp.txt"
    if stamp.read_text(encoding="utf-8").splitlines().count("commit=" + expected_sha) != 1:
        raise RuntimeError("Cold signed application build stamp differs from CI source")
    archive = app.parent / "cache/Hammerspoon-1.1.1.zip"
    if (
        archive.stat().st_size != HAMMERSPOON_ARCHIVE_BYTES
        or digest(archive) != HAMMERSPOON_ARCHIVE_SHA256
    ):
        raise RuntimeError(
            "Cold application was not built from the pinned official Hammerspoon archive"
        )
    info = copied / "Contents/Frameworks/Hammerspoon.app/Contents/Info.plist"
    if plistlib.loads(info.read_bytes())["CFBundleShortVersionString"] != "1.1.1":
        raise RuntimeError("Cold native Hammerspoon version differs")
    source_hashes = {}
    diagnostic_hashes = {
        str(Path(__file__).relative_to(REPOSITORY)): digest(__file__),
        str(Path(__file__).with_suffix(".lua").relative_to(REPOSITORY)): digest(
            Path(__file__).with_suffix(".lua")
        ),
    }
    for relative in SOURCE_PATHS:
        bundled, source = resources / PREFIX / relative, REPOSITORY / PREFIX / relative
        if digest(bundled) != digest(source):
            raise RuntimeError("Cold bundle source is stale: " + relative)
        source_hashes[relative] = digest(bundled)
    # Hosted runners have developer Python and may have uv. A private process
    # sandbox denies those actual files while leaving the host installation intact.
    # The real production resolver observes kernel-denied files, not fake candidates.
    denied_paths = isolated_runtime_paths(os.environ)
    profile = output / "cold-runtime.sb"
    profile.write_text(sandbox_profile(denied_paths), encoding="utf-8")
    isolation = qualify_runtime_isolation(denied_paths, profile)
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
        "denied_runtime_paths": denied_paths,
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
        "sha": expected_sha,
        "build_commit": expected_sha,
        "platform": "darwin",
        "architecture": "arm64",
        "runtime_environment": "controlled isolated cold environment",
        "signature_verified": True,
        "status": "failed",
        "sources": source_hashes,
        "diagnostics": diagnostic_hashes,
        "launcher_sha256": digest(helper),
        "hammerspoon_sha256": digest(hammerspoon),
        "official_hammerspoon": {
            "version": "1.1.1",
            "sha256": HAMMERSPOON_ARCHIVE_SHA256,
            "bytes": HAMMERSPOON_ARCHIVE_BYTES,
        },
        "isolation": {
            "profile_sha256": digest(profile),
            "paths": denied_paths,
            "observations": isolation,
            "host_files_preserved": False,
        },
    }
    with (output / "launch.log").open("xb") as log:
        consumer = subprocess.Popen(
            [
                "/usr/bin/sandbox-exec",
                "-f",
                str(profile),
                str(hammerspoon),
                "-MJConfigFile",
                str(Path(__file__).with_suffix(".lua")),
            ],
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
                    "/usr/bin/sandbox-exec",
                    "-f",
                    str(profile),
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
                ["/usr/bin/sandbox-exec", "-f", str(profile), str(uv), "--version"],
                capture_output=True,
                text=True,
                timeout=10,
                env=environment,
                check=True,
            ).stdout.strip()
            if version != "uv 0.12.21":
                raise RuntimeError("Cold uv does not match the independently pinned version")
            release = json.loads(
                (resources / PREFIX / "_shared/modules/llm/managed_python_release.json").read_text()
            )
            expected_python = release["downloads"]["cpython-3.11.16-darwin-aarch64-none"]
            if probe.stdout.strip() != ".".join(
                str(expected_python[k]) for k in ("major", "minor", "patch")
            ):
                raise RuntimeError("Cold managed Python version differs from pinned download")
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
                managed_runtime_isolated_exec=True,
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
            for item in isolation:
                actual = Path(item["path"]).stat()
                if (
                    actual.st_dev,
                    actual.st_ino,
                    actual.st_size,
                    digest(item["path"]),
                ) != (item["device"], item["inode"], item["bytes"], item["sha256"]):
                    raise RuntimeError("Stock runtime changed during cold receiving")
            report["isolation"]["host_files_preserved"] = True
            for relative, fingerprint in source_hashes.items():
                if (
                    digest(REPOSITORY / PREFIX / relative) != fingerprint
                    or digest(resources / PREFIX / relative) != fingerprint
                ):
                    raise RuntimeError("Cold bundled or repository source changed during receiving")
            for relative, fingerprint in diagnostic_hashes.items():
                if digest(REPOSITORY / relative) != fingerprint:
                    raise RuntimeError("Cold diagnostic source changed during receiving")
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
