#!/usr/bin/env python3
# tools/diagnostics/macos_cold_ollama_bootstrap.py
"""Receive a real Hammerspoon -> native PTY -> pinned official Ollama installation without Python."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import signal
import shutil
import stat
import tarfile
import uuid
import subprocess
import sys
import time

from hs274_hammerspoon import native_lifecycle

REPOSITORY = Path(__file__).resolve().parents[2]
PREFIX = Path("static/ergopti_plus")
SOURCE_PATHS = (
    "macos/modules/llm/network-retry.sh",
    "macos/modules/llm/ensure-ollama-deps.sh",
    "macos/modules/llm/ollama_deps_checker.lua",
    "macos/modules/llm/ollama_binary.lua",
    "macos/modules/llm/ollama-release.sh",
    "macos/adapters/native_bootstrap_pty.lua",
    "macos/adapters/task_lifecycle.lua",
    "macos/adapters/python_interpreter.lua",
    "_shared/lua/core/llm/native_pty_receipt.lua",
    "_shared/modules/network/proxy_policy.json",
    "_shared/modules/llm/ollama_release.json",
)
# Independent receiving pins: do not derive these from the new installer.
OFFICIAL_VERSION = "0.24.0"
OFFICIAL_SHA256 = "e6d5e8b4bc0cb2a35ff7901c58d81ca2170403a819c4726f58798155fa682e38"
OFFICIAL_BYTES = 133395504


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
        "/Applications/Ollama.app/Contents/Resources/ollama",
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
        "/usr/bin/ollama",
        "/bin/ollama",
        "/usr/sbin/ollama",
        "/sbin/ollama",
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
                ["/usr/bin/lipo", "-verify_arch", platform.machine(), path],
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
        or result.get("ollama_resolver") != "unmodified production resolver"
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
        Path(config["driver"]) / "modules/llm/ensure-ollama-deps.sh"
    ):
        raise RuntimeError("Native cold executed source differs from admitted source")
    if (
        result.get("native_cli") != ["--managed-pty-worker", "1800000"]
        or type(result.get("worker_pid")) is not int
        or result["worker_pid"] <= 0
        or Path(result["receipt_path"]).exists()
    ):
        raise RuntimeError("Native cold CLI or private receipt retirement differs")

    expected_environment = {
        "PROJECT_ROOT": config["driver"],
        "ERGOPTI_NATIVE_ARCH": config["architecture"],
        "ERGOPTI_NATIVE_PYTHONS": "",
        "ERGOPTI_BOOTSTRAP_OLLAMA_RESOLVED_BIN": "",
        "ERGOPTI_BOOTSTRAP_OLLAMA_INSTALL_DIR": config["install_dir"],
        "ERGOPTI_BOOTSTRAP_PYTHON": "",
    }
    if (
        result.get("native_environment") != expected_environment
        or result.get("daemon_validation") != "not-executed"
    ):
        raise RuntimeError("Native cold selection or official installer inputs differ")


def compare_installed_archive(archive, directory):
    """Compare actual received upstream members; reject missing/extra runtime code."""
    directory = directory.resolve(strict=True)
    members, files = {}, {}
    with tarfile.open(archive, "r:gz") as package:
        for member in package.getmembers():
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts:
                raise RuntimeError("Official archive member escapes installation")
            relative = str(name)
            if relative == ".":
                if not member.isdir():
                    raise RuntimeError("Official archive root is not a directory")
                continue
            if relative in members:
                raise RuntimeError("Official archive has duplicate normalized members")
            members[relative] = member
            path = directory / relative
            if not path.resolve(strict=True).is_relative_to(directory):
                raise RuntimeError("Installed official member escapes owned directory")
            observed = path.lstat()
            if member.issym():
                if not stat.S_ISLNK(observed.st_mode) or os.readlink(path) != member.linkname:
                    raise RuntimeError("Installed official symbolic link differs")
            elif member.islnk():
                linked = directory / str(PurePosixPath(member.linkname))
                if (
                    not linked.resolve(strict=True).is_relative_to(directory)
                    or not stat.S_ISREG(observed.st_mode)
                    or not os.path.samefile(path, linked)
                ):
                    raise RuntimeError("Installed official hard link differs")
            elif member.isdir():
                if not stat.S_ISDIR(observed.st_mode):
                    raise RuntimeError("Installed official directory differs")
            elif member.isfile():
                if not stat.S_ISREG(observed.st_mode):
                    raise RuntimeError("Installed official file kind differs")
                stream = package.extractfile(member)
                if stream is None:
                    raise RuntimeError("Official regular member has no bytes")
                expected = hashlib.file_digest(stream, "sha256").hexdigest()
                if path.stat().st_size != member.size or digest(path) != expected:
                    raise RuntimeError("Installed official member bytes differ")
                files[relative] = expected
            else:
                raise RuntimeError("Official archive has unsupported member kind")
            expected_mode = 0o755 if relative == "ollama" else member.mode & 0o7777
            if not member.issym() and stat.S_IMODE(observed.st_mode) != expected_mode:
                raise RuntimeError("Installed official member permissions differ")
    # Explicit directory entries may be absent in a tar. Derive their parents
    # independently, and never silently allow an extra executable or library.
    expected_paths = set(members)
    for name in members:
        expected_paths.update(
            str(parent) for parent in PurePosixPath(name).parents if str(parent) != "."
        )
    observed_paths = {str(path.relative_to(directory)) for path in directory.rglob("*")}
    if observed_paths != expected_paths or "ollama" not in files:
        raise RuntimeError("Installed official runtime inventory differs")
    return files


def receive(app, archive, output, repository):
    if sys.platform != "darwin" or platform.machine() not in ("arm64", "x86_64"):
        raise RuntimeError("Native cold Ollama receiving requires supported native macOS")
    archive = archive.resolve(strict=True)
    if archive.stat().st_size != OFFICIAL_BYTES or digest(archive) != OFFICIAL_SHA256:
        raise RuntimeError("Receiving archive differs from independently pinned upstream bytes")
    repository = repository.resolve(strict=True)
    app, output = app.resolve(strict=True), output.absolute()
    output.mkdir(mode=0o700)
    private = output.with_name(output.name + ".private-" + uuid.uuid4().hex)
    private.mkdir(mode=0o700)
    copied = private / "ErgoptiPlus.app"
    subprocess.run(["/usr/bin/ditto", str(app), str(copied)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(copied)], check=True)
    helper = copied / "Contents/MacOS/ErgoptiPlus"
    hammerspoon = copied / "Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon"
    if not helper.is_file() or not hammerspoon.is_file():
        raise RuntimeError("Signed native launcher and embedded Hammerspoon are required")
    resources = copied / "Contents/Resources"
    source_hashes = {}
    for relative in SOURCE_PATHS:
        bundled, source = resources / PREFIX / relative, repository / PREFIX / relative
        if digest(bundled) != digest(source):
            raise RuntimeError("Cold bundle source is stale: " + relative)
        source_hashes[relative] = digest(bundled)
    home = private / "home"
    home.mkdir(mode=0o700)
    temporary = private / "tmp"
    temporary.mkdir(mode=0o700)
    support = home / "Library/Application Support/Ergopti"
    driver = resources / PREFIX / "macos"
    denied_paths = isolated_runtime_paths(environment=os.environ)
    profile = private / "isolation.sb"
    profile.write_text(sandbox_profile(denied_paths), encoding="utf-8")
    isolation = qualify_runtime_isolation(denied_paths, profile)
    config = {
        "denied_runtime_paths": denied_paths,
        "home": str(home),
        "driver": str(driver),
        "shared": str(driver.parent / "_shared"),
        "install_dir": str(support / "ollama"),
        "architecture": platform.machine(),
        "helper": str(helper),
        "result": str(private / "result.json"),
    }
    config_path = private / "config.json"
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
        "official_archive_sha256": OFFICIAL_SHA256,
        "selection": "unmodified production runtime resolvers under inherited kernel sandbox",
        "isolation": {
            "kind": "native-scoped-sandbox",
            "paths": denied_paths,
            "profile_sha256": digest(profile),
            "observations": isolation,
        },
        "daemon_validation": "not-executed",
        "model_validation": "not-executed",
    }
    with (private / "launch.log").open("xb") as log:
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
            report["caller"] = {key: value for key, value in result.items() if key != "error"}
            if result.get("error"):
                report["caller"]["error"] = "native-caller"
            validate(result, config)
            if native.matching(helper):
                raise RuntimeError("Cold native helper processes remain after terminal receipt")
            binary = Path(config["install_dir"]) / "ollama"
            files = compare_installed_archive(archive, Path(config["install_dir"]))
            subprocess.run(
                ["/usr/bin/codesign", "--verify", "--strict", str(binary)],
                capture_output=True,
                check=True,
                timeout=60,
                env=environment,
            )
            probe = subprocess.run(
                ["/usr/bin/sandbox-exec", "-f", str(profile), str(binary), "--version"],
                capture_output=True,
                text=True,
                timeout=30,
                env=environment,
                check=True,
            )
            # Ollama may report a missing daemon on stderr. Its local client
            # version must still be the actual pinned executable's version.
            if "client version is " + OFFICIAL_VERSION not in probe.stdout + probe.stderr:
                raise RuntimeError("Installed official client does not report the pinned version")
            if digest(archive) != OFFICIAL_SHA256:
                raise RuntimeError("Independent receiving archive changed during installation")
            if any(
                digest(resources / PREFIX / path) != expected
                for path, expected in source_hashes.items()
            ):
                raise RuntimeError("Native receiving sources changed during installation")
            report.update(
                status="passed",
                client_version=OFFICIAL_VERSION,
                installed_files=files,
                helpers_retired=True,
                installed_tree="byte-and-link-identical to verified official archive",
            )
        finally:
            lifecycle.cleanup(native, hammerspoon, consumer)
            # Signal only this copied executable. Disappearance alone cannot
            # prove its guardian/process-group retirement after a failed caller.
            for pid in native.matching(helper):
                native.signal(pid, helper, signal.SIGTERM)
            deadline = time.monotonic() + 60
            while native.matching(helper) and time.monotonic() < deadline:
                time.sleep(0.2)
            report["native_helpers_absent"] = not native.matching(helper)
            report["cleanup"] = (
                report["native_helpers_absent"] is True
                and report.get("caller", {}).get("receipt_retired") is True
                and report.get("caller", {}).get("receipt_removed") is True
            )
            report["private_work_retired"] = False
            if report["cleanup"] is True:
                shutil.rmtree(private)
                report["private_work_retired"] = not private.exists()
            (output / "receipt.json").write_text(
                json.dumps(report, indent=2) + "\n", encoding="utf-8"
            )
            if report["cleanup"] is not True:
                raise RuntimeError("Cold native helper cleanup remains unsettled")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--official-archive", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=REPOSITORY)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    receive(arguments.app, arguments.official_archive, arguments.output, arguments.repository)
