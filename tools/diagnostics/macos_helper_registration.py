# tools/diagnostics/macos_helper_registration.py
"""Exercise headless guardian registration using a freshly built helper on CI."""

import json
import os
from pathlib import Path
import subprocess
import sys


def observe(application, output):
    """Register only the disposable runner's exact, previously absent helper job."""
    if sys.platform != "darwin" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise RuntimeError("Helper registration acceptance requires hosted macOS")
    executable = Path(application).resolve(strict=True) / "Contents/MacOS/ErgoptiPlus"
    label = "gui/" + str(os.getuid()) + "/com.ergoptiplus.remap-guardian"
    def inspect_job():
        return subprocess.run(["/bin/launchctl", "print", label], capture_output=True, text=True, timeout=10)
    if inspect_job().returncode == 0:
        raise RuntimeError("A guardian job already exists; refusing to replace it")
    identity = executable.stat()
    environment = os.environ.copy()
    environment.update(ERGOPTI_LAUNCHER_EXECUTABLE=str(executable),
                       ERGOPTI_LAUNCHER_DEVICE=str(identity.st_dev), ERGOPTI_LAUNCHER_INODE=str(identity.st_ino))
    receipt = {"kind": "native-helper-registration", "full_git_bootstrap_verified": False}
    def invoke(flag, values=environment):
        result = subprocess.run([str(executable), flag], env=values, capture_output=True, text=True, timeout=15)
        return {"exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
    try:
        wrong = dict(environment, ERGOPTI_LAUNCHER_INODE=str(identity.st_ino + 1))
        receipt["rejected"] = invoke("--register-remap-guardian", wrong)
        if receipt["rejected"]["exit"] != 64 or inspect_job().returncode == 0:
            raise RuntimeError("Invalid helper identity caused registration")
        receipt["registered"] = invoke("--register-remap-guardian")
        if receipt["registered"]["exit"] != 0 or receipt["registered"]["stdout"].strip() != "ready":
            raise RuntimeError("Native helper did not register a ready guardian: " + repr(receipt["registered"]))
        receipt["observed"] = invoke("--remap-guardian-status")
        if receipt["observed"]["exit"] != 0 or receipt["observed"]["stdout"].strip() != "ready":
            raise RuntimeError("Independent guardian readiness readback failed")
        receipt["repeated"] = invoke("--register-remap-guardian")
        if receipt["repeated"]["exit"] != 0 or receipt["repeated"]["stdout"].strip() != "ready":
            raise RuntimeError("Repeated registration did not preserve readiness")
    finally:
        if inspect_job().returncode == 0:
            stopped = subprocess.run(["/bin/launchctl", "bootout", label], capture_output=True, text=True, timeout=10)
            receipt["cleanup"] = {"exit": stopped.returncode, "stderr": stopped.stderr}
        receipt["job_absent_after_cleanup"] = inspect_job().returncode != 0
        Path(output).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8", newline="\n")
        if not receipt["job_absent_after_cleanup"]:
            raise RuntimeError("Owned helper guardian job survived cleanup")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Expected helper application and receipt output path")
    observe(*sys.argv[1:])
