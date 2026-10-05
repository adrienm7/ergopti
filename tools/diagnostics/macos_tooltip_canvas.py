# tools/diagnostics/macos_tooltip_canvas.py
"""Observe twelve real Hammerspoon tooltip canvases with a reserved native child.

This qualifies rendering only. It does not measure physical input, keyboard
watchers, installed application startup or TCC approval. Runtime provisioning
must separately retain the official HTTPS archive digest and publisher evidence.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

import macos_owned_process as owner


def require(condition, message):
    """Refuse a missing native qualification prerequisite."""
    if not condition:
        raise ValueError(message)


def digest(path):
    """Capture exact file bytes without passing machine output through RTK."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def identities(repo):
    """Fence every copied Mac/shared source and the actual ownership helper."""
    paths = []
    for name in ("macos", "_shared"):
        directory = repo / "static/ergopti_plus" / name
        require(directory.is_dir() and not directory.is_symlink(), "Source root unavailable")
        for path in directory.rglob("*"):
            require(not path.is_symlink(), "Redirected production snapshot input: " + str(path))
            if path.is_file():
                paths.append(path)
    paths += [
        repo / "tools/diagnostics/macos_owned_process.py",
        repo / "tools/build/build_macos_app.sh",
    ]
    return {str(path.relative_to(repo)): digest(path) for path in sorted(paths)}


def selected_version(repo):
    """Read the unchanged repository-selected runtime rather than inventing a fallback."""
    source = (repo / "tools/build/build_macos_app.sh").read_text(encoding="utf-8")
    versions = re.findall(
        r'^HAMMERSPOON_VERSION="\$\{HAMMERSPOON_VERSION:-([^}]+)\}"$', source, re.MULTILINE
    )
    require(len(versions) == 1, "Repository-selected Hammerspoon version ambiguous or absent")
    return versions[0]


def admit_runtime(app, version, output, label):
    """Retain actual strict signature and signer replies without asserting publisher trust."""
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(
        info.get("CFBundleShortVersionString") == version,
        "App differs from repository-selected Hammerspoon version",
    )
    executable = app / "Contents/MacOS/Hammerspoon"
    require(executable.is_file() and not executable.is_symlink(), "Native executable unavailable")
    require(os.access(executable, os.X_OK), "Native executable not executable")
    replies = {}
    for operation, arguments in (
        ("verify", ["--verify", "--strict", "--deep"]),
        ("signer", ["--display", "--verbose=4"]),
    ):
        result = subprocess.run(
            ["/usr/bin/codesign", *arguments, str(app)],
            capture_output=True,
            timeout=30,
            check=False,
        )
        for name in ("stdout", "stderr"):
            path = output / f"{label}-signature-{operation}.{name}"
            path.write_bytes(getattr(result, name))
            replies[f"{operation}_{name}_sha256"] = digest(path)
        require(result.returncode == 0, "Actual runtime signature " + operation + " refused")
    return {
        "version": version,
        "executable_sha256": digest(executable),
        "signature_integrity": "strict codesign verified",
        "publisher_authenticated_by_supervisor": False,
        "signature_replies": replies,
    }


def supervise(group, output, expected_version, unchanged, timeout=60):
    """Accept real native output only while the exact direct child remains reserved and live."""
    from macos_tooltip_canvas_observer import observe

    deadline = time.monotonic() + timeout
    while True:
        require(group.observe_exit() is None, "Exact native Hammerspoon exited before observation")
        result_path = output / "result.json"
        if result_path.exists():
            require(not result_path.is_symlink(), "Redirected native result refused")
            result = json.loads(result_path.read_text(encoding="utf-8"))
            require(
                type(result.get("pid")) is int and result["pid"] == group.process.pid,
                "Native receipt did not originate from the exact acquired child",
            )
            require(
                result.get("version") == expected_version, "Actual native runtime version differs"
            )
            pixels = observe(result, output)
            require(group.observe_exit() is None, "Native owner exited during pixel observation")
            unchanged()
            return {
                "native_execution": "executed",
                "native_process_observed": True,
                "painted_captures": 12,
                "result": result,
                "pixels": pixels,
            }
        require(time.monotonic() < deadline, "Actual paint observation exceeded its deadline")
        time.sleep(0.05)


def owned_observation(executable, config, output, operation, native):
    """Register before cancellation, preserve failure, retire the reserved inherited PGID."""
    group = None
    failure = None
    result = None
    handlers = {}
    cleanup_errors = []

    def interrupted(_signal, _frame):
        raise owner.OwnedProcessInterrupted("Native canvas observation interrupted")

    def register(acquired):
        nonlocal group
        group = acquired

    try:
        for sig in (signal.SIGTERM, signal.SIGINT):
            previous = signal.getsignal(sig)
            signal.signal(sig, interrupted)
            handlers[sig] = previous
        with (
            (output / "launch.stdout").open("xb") as out,
            (output / "launch.stderr").open("xb") as err,
        ):
            owner.acquire_owned(
                [str(executable), "-MJConfigFile", str(config)],
                native,
                register,
                cwd=config.parent,
                stdout=out,
                stderr=err,
            )
        require(group is not None, "Native child acquisition did not register an owner")
        result = operation(group)
    except BaseException as error:
        failure = str(error) or type(error).__name__
    finally:
        # Cancellation cannot interrupt the ownership proof/reap and leave an
        # apparently successful receipt. Original handlers are restored below.
        for sig in handlers:
            try:
                signal.signal(sig, signal.SIG_IGN)
            except Exception as error:
                cleanup_errors.append("Signal masking: " + str(error))
        try:
            if group is not None:
                require(group.settle(), "Native canvas retains inherited-PGID retirement debt")
        except BaseException as error:
            cleanup_errors.append("Retirement: " + (str(error) or type(error).__name__))
        finally:
            for sig, previous in handlers.items():
                try:
                    signal.signal(sig, previous)
                except Exception as error:
                    cleanup_errors.append("Signal restoration: " + str(error))
    receipt = dict(result or {})
    receipt.update(
        {
            "status": "error" if failure or cleanup_errors else "ok",
            "operation_error": failure,
            "cleanup_errors": cleanup_errors,
            "native_owner": group.receipt() if group is not None else None,
            "application_cleanup": "confirmed inherited PGID retired"
            if group is not None and group.reaped
            else "unconfirmed; inputs retained",
        }
    )
    return receipt


def run(repo, app, output):
    """Snapshot real sources and execute only the unique copied signed app executable."""
    require(sys.platform == "darwin", "Requires native macOS, a GUI login and actual Hammerspoon")
    require(
        sys.version_info >= (3, 13), "Requires macOS CPython 3.13+ for native WNOWAIT ownership"
    )
    from PIL import __version__ as pillow_version

    require(pillow_version == "11.3.0", "Requires Pillow 11.3.0 for the independent pixel observer")
    repo, app = repo.resolve(strict=True), app.resolve(strict=True)
    output = output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    output.chmod(0o700)
    scratch = Path(tempfile.mkdtemp(prefix="ergopti-tooltip-native-")).resolve()
    scratch.chmod(0o700)
    here = Path(__file__).resolve().parent
    report = {
        "status": "error",
        "scratch": str(scratch),
        "native_execution": "unexecuted",
        "physical_input": "unmeasured",
        "watcher_orchestration": "unmeasured",
        "installed_package": "unmeasured",
        "pillow_version": pillow_version,
        "startup": "direct copied signed executable; Launch Services unmeasured",
    }
    try:
        before = identities(repo)
        require(
            Path(owner.__file__).resolve()
            == (repo / "tools/diagnostics/macos_owned_process.py").resolve(),
            "Native ownership helper loaded from another source",
        )
        names = (
            "macos_tooltip_canvas.lua",
            "macos_tooltip_canvas.py",
            "macos_tooltip_canvas_observer.py",
        )
        probe_hashes = {name: digest(here / name) for name in names}
        version = selected_version(repo)
        report["original_runtime"] = admit_runtime(app, version, output, "original")
        source_root = scratch / "source"
        for name in ("macos", "_shared"):
            shutil.copytree(
                repo / "static/ergopti_plus" / name, source_root / "static/ergopti_plus" / name
            )
        for relative, expected in before.items():
            if relative.startswith("static/"):
                require(
                    digest(source_root / relative) == expected, "Source copy differs: " + relative
                )
        require(identities(repo) == before, "Production source drifted during snapshot acquisition")
        owner.exclusive_receipt(
            output / "sources.json", {"production": before, "probe": probe_hashes}
        )
        copied_app = scratch / "Hammerspoon.app"
        subprocess.run(["/usr/bin/ditto", str(app), str(copied_app)], check=True, timeout=60)
        report["copied_runtime"] = admit_runtime(copied_app, version, output, "copied")
        executable = copied_app / "Contents/MacOS/Hammerspoon"
        require(
            digest(executable) == report["original_runtime"]["executable_sha256"],
            "Copied actual runtime executable changed",
        )
        config = scratch / "macos_tooltip_canvas.lua"
        shutil.copyfile(here / "macos_tooltip_canvas.lua", config)
        owner.exclusive_receipt(
            scratch / "probe-config.json",
            {
                "source_root": str(source_root),
                "output_dir": str(output.resolve()),
                "expected_version": version,
            },
        )

        def unchanged():
            require(
                identities(repo) == before, "Production sources drifted during native observation"
            )
            for relative, expected in before.items():
                if relative.startswith("static/"):
                    require(
                        digest(source_root / relative) == expected,
                        "Copied production source drifted during native observation: " + relative,
                    )
            require(
                {name: digest(here / name) for name in names} == probe_hashes,
                "Diagnostic sources drifted during native observation",
            )
            require(
                digest(executable) == report["copied_runtime"]["executable_sha256"],
                "Copied executable drifted during native observation",
            )

        report.update(
            owned_observation(
                executable,
                config,
                output,
                lambda group: supervise(group, output, version, unchanged),
                owner.NativeProcessGroups(),
            )
        )
    except BaseException as error:
        report.update(status="error", error=str(error) or type(error).__name__)
    owner.exclusive_receipt(output / "supervisor.json", report)
    return report


def main():
    """Expose one native observation with fresh output and an exact source root."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    options = parser.parse_args()
    try:
        report = run(options.repo, options.app, options.output)
    except Exception as error:
        print("Native canvas admission failed: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps(report))
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
