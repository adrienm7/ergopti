# tools/diagnostics/macos_helper_registration.py
"""Qualify exact headless guardian registration and retirement on hosted macOS."""

import json
import os
from pathlib import Path
import subprocess
import sys

ABSENT_JOB_STATUS = 113


def observe(application, output):
    """Register only the disposable runner's exact, previously absent helper job."""
    if sys.platform != "darwin" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise RuntimeError("Helper registration acceptance requires hosted macOS")
    executable = Path(application).resolve(strict=True) / "Contents/MacOS/ErgoptiPlus"
    label = "gui/" + str(os.getuid()) + "/com.ergoptiplus.remap-guardian"

    def inspect_job():
        return subprocess.run(
            ["/bin/launchctl", "print", label], capture_output=True, text=True, timeout=10
        )

    identity = executable.stat()
    environment = os.environ.copy()
    environment.update(
        ERGOPTI_LAUNCHER_EXECUTABLE=str(executable),
        ERGOPTI_LAUNCHER_DEVICE=str(identity.st_dev),
        ERGOPTI_LAUNCHER_INODE=str(identity.st_ino),
    )
    receipt = {"kind": "native-helper-registration", "full_git_bootstrap_verified": False}
    primary_error = None
    cleanup_errors = []
    owns_possible_job = False

    def invoke(flag, values=environment):
        result = subprocess.run(
            [str(executable), flag], env=values, capture_output=True, text=True, timeout=15
        )
        return {"exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr}

    try:
        initial = inspect_job()
        receipt["initial_job_status"] = initial.returncode
        if initial.returncode != ABSENT_JOB_STATUS:
            raise RuntimeError("Exact guardian absence was not confirmed before registration")
        wrong = dict(environment, ERGOPTI_LAUNCHER_INODE=str(identity.st_ino + 1))
        receipt["rejected"] = invoke("--register-remap-guardian", wrong)
        if receipt["rejected"]["exit"] != 64 or inspect_job().returncode != ABSENT_JOB_STATUS:
            raise RuntimeError("Invalid helper identity caused registration")
        owns_possible_job = True
        receipt["registered"] = invoke("--register-remap-guardian")
        if receipt["registered"]["exit"] != 0 or receipt["registered"]["stdout"] != "ready\n":
            raise RuntimeError(
                "Native helper did not register a ready guardian: " + repr(receipt["registered"])
            )
        receipt["observed"] = invoke("--remap-guardian-status")
        if receipt["observed"]["exit"] != 0 or receipt["observed"]["stdout"] != "ready\n":
            raise RuntimeError("Independent guardian readiness readback failed")
        receipt["repeated"] = invoke("--register-remap-guardian")
        if receipt["repeated"]["exit"] != 0 or receipt["repeated"]["stdout"] != "ready\n":
            raise RuntimeError("Repeated registration did not preserve readiness")
        receipt["rejected_unregister"] = invoke("--unregister-remap-guardian", wrong)
        retained = inspect_job()
        receipt["job_status_after_rejected_unregister"] = retained.returncode
        if receipt["rejected_unregister"]["exit"] != 64 or retained.returncode != 0:
            raise RuntimeError("Invalid helper identity removed the registered guardian")
        receipt["unregistered"] = invoke("--unregister-remap-guardian")
        absent = inspect_job()
        receipt["job_status_after_unregister"] = absent.returncode
        if (
            receipt["unregistered"]["exit"] != 0
            or receipt["unregistered"]["stdout"] != "unregistered\n"
        ):
            raise RuntimeError("Native helper did not acknowledge guardian removal")
        if absent.returncode != ABSENT_JOB_STATUS:
            raise RuntimeError("Native guardian removal did not prove exact job absence")
        receipt["repeated_unregister"] = invoke("--unregister-remap-guardian")
        repeated_absent = inspect_job()
        receipt["job_status_after_repeated_unregister"] = repeated_absent.returncode
        if (
            receipt["repeated_unregister"]["exit"] != 0
            or receipt["repeated_unregister"]["stdout"] != "unregistered\n"
        ):
            raise RuntimeError("Repeated native guardian removal did not acknowledge absence")
        if repeated_absent.returncode != ABSENT_JOB_STATUS:
            raise RuntimeError("Repeated native guardian removal left an unknown job state")
        receipt["unregistration_verified"] = True
    except Exception as error:
        primary_error = str(error)
        receipt["primary_error"] = primary_error
    finally:
        if owns_possible_job:
            try:
                current = inspect_job()
                if current.returncode == 0:
                    stopped = subprocess.run(
                        ["/bin/launchctl", "bootout", label],
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                    receipt["cleanup"] = {"exit": stopped.returncode, "stderr": stopped.stderr}
                    if stopped.returncode != 0:
                        cleanup_errors.append("Owned guardian safety bootout was refused")
                elif current.returncode != ABSENT_JOB_STATUS:
                    cleanup_errors.append(
                        "Guardian cleanup observation did not confirm presence or absence"
                    )
            except Exception as error:
                cleanup_errors.append("Guardian cleanup failed: " + str(error))
        try:
            final = inspect_job()
            receipt["final_job_status"] = final.returncode
            receipt["job_absent_after_cleanup"] = final.returncode == ABSENT_JOB_STATUS
            if final.returncode != ABSENT_JOB_STATUS:
                cleanup_errors.append("Owned guardian absence after cleanup was not confirmed")
        except Exception as error:
            receipt["job_absent_after_cleanup"] = False
            cleanup_errors.append("Final guardian observation failed: " + str(error))
        receipt["cleanup_errors"] = cleanup_errors
        Path(output).write_text(
            json.dumps(receipt, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
    errors = ([primary_error] if primary_error else []) + cleanup_errors
    if errors:
        raise RuntimeError("; ".join(errors))
    return receipt


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Expected helper application and receipt output path")
    observe(*sys.argv[1:])
