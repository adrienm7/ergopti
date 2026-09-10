# tools/diagnostics/hs274_shutdown_test.py
"""Exercise the real macOS process scope without installing or emitting input."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time


def child():
    """Mirror upstream's first-signal graceful, second-signal forced shutdown."""
    stopping = False

    def stop(number, frame):
        nonlocal stopping
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        os.write(1, b"first-signal\n")
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    os.write(1, b"ready\n")
    deadline = time.monotonic() + 15
    while not stopping:
        if time.monotonic() >= deadline:
            raise RuntimeError("No shutdown signal arrived")
        time.sleep(0.01)
    # Leave time for a duplicate forwarded signal to interrupt graceful work.
    time.sleep(0.25)
    os.write(1, b"complete\n")


def main():
    """Retain both direct and sudo outcomes from the existing ownership helper."""
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or os.geteuid() == 0:
        raise RuntimeError("Shutdown probe requires the disposable macOS console user")
    spec = importlib.util.spec_from_file_location("hs274_remap", Path(__file__).with_name("hs274-remap.py"))
    remap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(remap)
    report = {"cases": []}
    with tempfile.TemporaryDirectory(prefix="hs274-shutdown-") as directory:
        output = Path(directory)
        for privileged in (False, True):
            for iteration in range(3):
                name = f"{'sudo' if privileged else 'direct'}-{iteration}"
                case = {"name": name}
                report["cases"].append(case)
                command = [sys.executable, str(Path(__file__).resolve()), "--child"]
                if privileged:
                    command = ["sudo", "-n"] + command
                log = output / ("hs274-remap-" + name + ".log")
                try:
                    with remap.owned_process(command, name, output, case) as process:
                        deadline = time.monotonic() + 5
                        while "ready\n" not in log.read_text(encoding="utf-8"):
                            if process.poll() is not None or time.monotonic() >= deadline:
                                raise RuntimeError("Shutdown child did not become ready")
                            time.sleep(0.01)
                except Exception as error:
                    case["error"] = f"{type(error).__name__}: {error}"
                case["lines"] = log.read_text(encoding="utf-8").splitlines()
                case["passed"] = ("error" not in case and case["lines"] == ["ready", "first-signal", "complete"]
                                  and case["processes"][name].get("exit") == 0)
    print(json.dumps(report, indent=2), flush=True)
    return 0 if all(case["passed"] for case in report["cases"]) else 1


if __name__ == "__main__":
    if sys.argv[1:] == ["--child"]:
        child()
    else:
        sys.exit(main())
