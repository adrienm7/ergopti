# tools/diagnostics/macos-release-launch.py
"""Retain a downloaded release's actual Launch Services startup on disposable macOS."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


def require_startup_ready(log_text):
    """Reject early log creation without a completed application startup branch."""
    if "[ERROR]" in log_text:
        raise RuntimeError("Application reported a Lua error during startup")
    for marker in ("Onboarding wizard opened.", "User interface initialized successfully."):
        if marker in log_text:
            return marker
    raise RuntimeError("Application never completed onboarding or runtime UI startup")


def processes(executable):
    """Resolve only the exact executable command belonging to this fixture."""
    result = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True)
    return [int(line.strip().split(None, 1)[0]) for line in result.stdout.splitlines()
            if len(line.strip().split(None, 1)) == 2 and line.strip().split(None, 1)[1] == str(executable)]


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
    launcher_log = Path.home() / "Library/Logs/ErgoptiPlus/launcher.log"
    if launcher_log.exists():
        raise RuntimeError("Release launch requires a fresh launcher log")
    started = time.monotonic()
    try:
        # Finder does not retain an `open -W` helper throughout app startup.
        result = subprocess.run(["open", "-n", str(app)], capture_output=True, text=True, timeout=10)
        report["open"] = {"code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
        result.check_returncode()
        while time.monotonic() - started < 45:
            sample = {"seconds": round(time.monotonic() - started, 3),
                      "launcher": processes(launcher), "hammerspoon": processes(child)}
            report["samples"].append(sample)
            log = launcher_log.read_text(encoding="utf-8") if launcher_log.exists() else ""
            if "FATAL:" in log:
                raise RuntimeError("Published application reported a fatal startup failure")
            if sample["seconds"] >= 10 and (len(sample["launcher"]) != 1 or len(sample["hammerspoon"]) != 1):
                raise RuntimeError("Published application did not retain both exact processes")
            time.sleep(1)
        logs = Path.home() / ".config/ergopti_plus/hammerspoon/logs"
        text = "\n".join(path.read_text(encoding="utf-8") for path in logs.glob("ErgoptiPlus_*.log"))
        report["startup_ready"] = require_startup_ready(text)
        report["survived_observation"] = True
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
    finally:
        try:
            screenshot = subprocess.run(["screencapture", "-x", str(output / "desktop.png")], capture_output=True, timeout=10)
            report["screenshot_exit"] = screenshot.returncode
        except subprocess.TimeoutExpired:
            report["screenshot_error"] = "Screenshot timed out"
        for path in (launcher_log, Path("/tmp/ErgoptiPlus_boot.log"), Path("/tmp/ErgoptiPlus_errors_boot.log")):
            if path.is_file():
                shutil.copyfile(path, output / path.name)
        logs = Path.home() / ".config/ergopti_plus/hammerspoon/logs"
        if logs.is_dir():
            shutil.copytree(logs, output / "lua-logs")
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        for executable in (launcher, child):
            for pid in processes(executable):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
    return 1 if "error" in report else 0


if __name__ == "__main__":
    sys.exit(main())
