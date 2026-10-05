# tools/diagnostics/macos-release-launch.py
"""Retain a downloaded release's actual Launch Services startup on disposable macOS."""

import json
import hashlib
import os
import re
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import time
from urllib.parse import quote

# The job log shows the failure without downloading the artifact; the full logs
# stay in the artifact, so a noisy failure is capped here.
MAX_EVIDENCE_LINES = 60


def require_startup_ready(log_text):
    """Reject early log creation without a completed application startup branch."""
    if "[ERROR]" in log_text:
        raise RuntimeError("Application reported a Lua error during startup")
    for marker in ("Onboarding wizard opened.", "User interface initialized successfully."):
        if marker in log_text:
            return marker
    raise RuntimeError("Application never completed onboarding or runtime UI startup")


def failure_evidence(report, logs):
    """Return the failure and the log lines behind it, for the job log itself."""
    lines = [f"release launch failed: {report['error']}"]
    for path in sorted(logs.glob("*.log")) if logs.is_dir() else []:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if "[ERROR]" in line or "FATAL" in line:
                lines.append(f"{path.name}: {line}")
    return lines[:MAX_EVIDENCE_LINES]


def processes(executable):
    """Resolve only the exact executable command belonging to this fixture."""
    result = subprocess.run(
        ["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True
    )
    return [
        int(line.strip().split(None, 1)[0])
        for line in result.stdout.splitlines()
        if len(line.strip().split(None, 1)) == 2
        and line.strip().split(None, 1)[1] == str(executable)
    ]


def _published_json_object(pairs):
    """Refuse ambiguous transport objects without echoing their contents."""
    value = {}
    for key, item in pairs:
        if key in value:
            raise RuntimeError("Published archive transport has duplicate fields")
        value[key] = item
    return value


def _published_command(arguments, execute, capture=False):
    """Require the actual synchronous command's typed successful completion."""
    result = execute(arguments, check=True, capture_output=capture, text=True)
    if type(result.returncode) is not int or result.returncode != 0:
        raise RuntimeError("Published archive command refused")
    return result


def published_archive_bindings(execute=None):
    """Read the same validated archive policy the actual producer consumes."""
    if execute is None:
        execute = subprocess.run
    root = Path(__file__).resolve().parents[2]
    program = (
        "const fs = require('node:fs');"
        "const {resolveArchives} = require(process.argv[1]);"
        "const defaults = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));"
        "process.stdout.write(JSON.stringify(resolveArchives(defaults)) + '\\n');"
    )
    result = _published_command(
        [
            "node",
            "-e",
            program,
            str(root / "tools/build/macos-release-archives.cjs"),
            str(root / "static/ergopti_plus/_shared/modules/updater/defaults.json"),
        ],
        execute,
        True,
    )
    try:
        bindings = json.loads(result.stdout, object_pairs_hook=_published_json_object)
    except (ValueError, TypeError) as error:
        raise RuntimeError("Published archive policy transport refused") from error
    if type(bindings) is not list or not bindings:
        raise RuntimeError("Published archive policy transport refused")
    names, formats = set(), set()
    for binding in bindings:
        if (
            type(binding) is not dict
            or set(binding) != {"name", "format"}
            or type(binding["name"]) is not str
            or not binding["name"]
            or Path(binding["name"]).name != binding["name"]
            or binding["format"] not in ("zip", "tar.xz")
            or binding["name"] in names
            or binding["format"] in formats
        ):
            raise RuntimeError("Published archive policy transport refused")
        names.add(binding["name"])
        formats.add(binding["format"])
    return bindings


def install_published_release(repository, tag, temporary, destination, execute=None):
    """Install one digest-verified declared asset without a preferred-failure fallback."""
    if (
        type(repository) is not str
        or re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repository) is None
        or type(tag) is not str
        or not tag
    ):
        raise RuntimeError("Published release identity refused")
    if execute is None:
        execute = subprocess.run
    bindings = published_archive_bindings(execute)
    result = _published_command(
        ["gh", "api", f"repos/{repository}/releases/tags/{quote(tag, safe='')}"],
        execute,
        True,
    )
    release = json.loads(result.stdout, object_pairs_hook=_published_json_object)
    if (
        type(release) is not dict
        or release.get("draft") is not False
        or release.get("tag_name") != tag
        or type(release.get("assets")) is not list
        or any(type(asset) is not dict for asset in release["assets"])
    ):
        raise RuntimeError("Published release metadata refused")
    selected = None
    for binding in bindings:
        matches = [asset for asset in release["assets"] if asset.get("name") == binding["name"]]
        if not matches:
            continue
        if len(matches) != 1:
            raise RuntimeError("Published preferred archive is ambiguous")
        selected, asset = binding, matches[0]
        break
    if selected is None:
        raise RuntimeError("Published release has no declared application archive")
    digest = asset.get("digest")
    if (
        type(digest) is not str
        or not digest.startswith("sha256:")
        or len(digest) != 71
        or any(char not in "0123456789abcdef" for char in digest[7:])
    ):
        raise RuntimeError("Published application digest is absent or mismatched")
    size = asset.get("size")
    if type(size) is not int or not 0 < size <= 2**53 - 1:
        raise RuntimeError("Published application size is absent or mismatched")
    temporary, destination = Path(temporary), Path(destination)
    target = temporary / "release-download"
    target.mkdir()
    _published_command(
        [
            "gh",
            "release",
            "download",
            tag,
            "--repo",
            repository,
            "--pattern",
            selected["name"],
            "--dir",
            str(target),
        ],
        execute,
    )
    archive = target / selected["name"]
    if not stat.S_ISREG(archive.lstat().st_mode) or archive.stat().st_size == 0:
        raise RuntimeError("Published application archive is not a nonempty regular file")
    if archive.stat().st_size != size:
        raise RuntimeError("Published application size is absent or mismatched")
    if "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError("Published application digest is absent or mismatched")
    if (destination / "ErgoptiPlus.app").exists():
        raise RuntimeError("Refusing to replace an existing application")
    if selected["format"] == "zip":
        arguments = ["/usr/bin/ditto", "-x", "-k", str(archive), str(destination)]
    else:
        arguments = ["/usr/bin/tar", "-xJpf", str(archive), "-C", str(destination)]
    _published_command(arguments, execute)
    if "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError("Published application archive changed during extraction")
    provenance = {
        "tag": tag,
        "asset": asset,
        "verified_digest": digest,
        "format": selected["format"],
    }
    (temporary / "release-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    return provenance


def main():
    """Observe beyond log creation and preserve failures before owned cleanup."""
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("Release launch observation requires a disposable macOS runner")
    app = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    output.mkdir(exist_ok=False)
    launcher = app / "Contents/MacOS/ErgoptiPlus"
    child = app / "Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon"
    if not launcher.is_file() or not child.is_file():
        raise RuntimeError("Downloaded application is missing its executables")
    for executable in (launcher, child):
        if processes(executable):
            raise RuntimeError("A fixture executable is already running")
    report = {"app": str(app), "samples": [], "full_functionality_validated": False}
    # launcher.log and, without a LogsDirPath override, the driver logs share
    # the default logs folder (_shared/modules/paths/app_dirs.toml).
    logs = Path.home() / "Library/Logs/ergopti_plus"
    launcher_log = logs / "launcher.log"
    if launcher_log.exists():
        raise RuntimeError("Release launch requires a fresh launcher log")
    started = time.monotonic()
    try:
        # Finder does not retain an `open -W` helper throughout app startup.
        result = subprocess.run(
            ["open", "-n", str(app)], capture_output=True, text=True, timeout=10
        )
        report["open"] = {
            "code": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        }
        result.check_returncode()
        while time.monotonic() - started < 45:
            sample = {
                "seconds": round(time.monotonic() - started, 3),
                "launcher": processes(launcher),
                "hammerspoon": processes(child),
            }
            report["samples"].append(sample)
            log = launcher_log.read_text(encoding="utf-8") if launcher_log.exists() else ""
            if "FATAL:" in log:
                raise RuntimeError("Published application reported a fatal startup failure")
            if sample["seconds"] >= 10 and (
                len(sample["launcher"]) != 1 or len(sample["hammerspoon"]) != 1
            ):
                raise RuntimeError("Published application did not retain both exact processes")
            time.sleep(1)
        text = "\n".join(
            path.read_text(encoding="utf-8") for path in logs.glob("ErgoptiPlus_*.log")
        )
        report["startup_ready"] = require_startup_ready(text)
        report["survived_observation"] = True
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
    finally:
        try:
            screenshot = subprocess.run(
                ["screencapture", "-x", str(output / "desktop.png")],
                capture_output=True,
                timeout=10,
            )
            report["screenshot_exit"] = screenshot.returncode
        except subprocess.TimeoutExpired:
            report["screenshot_error"] = "Screenshot timed out"
        for path in (launcher_log, logs / "ErgoptiPlus_boot.log"):
            if path.is_file():
                shutil.copyfile(path, output / path.name)
        if logs.is_dir():
            shutil.copytree(logs, output / "lua-logs")
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        if "error" in report:
            print("\n".join(failure_evidence(report, logs)), file=sys.stderr)
        for executable in (launcher, child):
            for pid in processes(executable):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
    return 1 if "error" in report else 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--install-published":
        if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
            raise RuntimeError("Published release installation requires a disposable macOS runner")
        install_published_release(
            os.environ["GITHUB_REPOSITORY"],
            os.environ["RELEASE_TAG"],
            os.environ["RUNNER_TEMP"],
            Path("/Applications"),
        )
    else:
        sys.exit(main())
