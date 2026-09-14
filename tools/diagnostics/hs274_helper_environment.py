# tools/diagnostics/hs274_helper_environment.py
"""Reuse a verified helper to exercise real Hammerspoon child environments."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from hs274_hammerspoon import native_lifecycle
from hs274_hammerspoon_registration import register_application
from macos_native_helper import digest, source_identity

FIXTURE = Path(__file__).with_name("fixtures") / "hs274-native-helper-package.json"


def selection():
    """Load the retained native package rather than rebuilding unchanged Swift."""
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def authenticate(directory):
    """Require exact native receipt, archive bytes and current shared source inputs."""
    expected = selection()["identity"]
    directory = Path(directory)
    archives = list(directory.rglob("ErgoptiPlus.app.zip"))
    receipts = list(directory.rglob("native-helper.json"))
    if len(archives) != 1 or len(receipts) != 1:
        raise ValueError("Expected exactly one retained helper archive and receipt")
    archive, receipt = archives[0], receipts[0]
    if archive.is_symlink() or receipt.is_symlink():
        raise ValueError("Redirected native helper artifact")
    if json.loads(receipt.read_text(encoding="utf-8")) != expected:
        raise ValueError("Helper artifact differs from the accepted native receipt")
    if digest(archive) != expected["archive_sha256"] or archive.stat().st_size != expected["archive_bytes"]:
        raise ValueError("Helper archive integrity failed")
    if source_identity() != expected["sources"]:
        raise ValueError("Current native sources differ from the retained helper")
    return archive


def observe(directory, hammerspoon, output):
    """Run the production task adapter in an isolated real Hammerspoon process."""
    if sys.platform != "darwin" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise RuntimeError("Native environment acceptance requires a hosted macOS runner")
    archive = authenticate(directory)
    output = Path(output).absolute()
    output.mkdir()
    native_root = output / "runtime"
    native_root.mkdir()
    subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(native_root)], check=True)
    helper_app = native_root / "ErgoptiPlus.app"
    helper = helper_app / "Contents/MacOS/ErgoptiPlus"
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(helper_app)], check=True)
    if digest(helper) != selection()["identity"]["executable_sha256"]:
        raise ValueError("Extracted native helper executable changed")
    copied = native_root / "Hammerspoon.app"
    subprocess.run(["/usr/bin/ditto", str(hammerspoon), str(copied)], check=True)
    report = {}
    register_application(report, copied)
    here = Path(__file__).resolve().parent
    init = native_root / "init.lua"
    shutil.copyfile(here / "hs274-helper-environment.lua", init)
    executable = copied / "Contents/MacOS/Hammerspoon"
    result = output / "result.json"
    identity = helper.stat()
    config = {"repo": str(here.parents[1]), "helper": str(helper), "result": str(result),
              "wrong_inode": str(identity.st_ino + 1), "environment": {
                  "ERGOPTI_LAUNCHER_EXECUTABLE": str(helper), "ERGOPTI_LAUNCHER_DEVICE": str(identity.st_dev),
                  "ERGOPTI_LAUNCHER_INODE": str(identity.st_ino)}}
    (native_root / "helper-environment-config.json").write_text(json.dumps(config), encoding="utf-8", newline="\n")
    environment = os.environ.copy()
    for name in config["environment"]:
        environment.pop(name, None)
    lifecycle = native_lifecycle()
    native = lifecycle.NativeProcesses()
    with (output / "launch.log").open("xb") as log:
        launcher = subprocess.Popen(["/usr/bin/open", "-n", "-g", "-W", str(copied), "--args", "-MJConfigFile", str(init)],
                                    env=environment, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 20
            while not result.exists():
                if launcher.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Native Hammerspoon environment probe did not settle")
                time.sleep(0.05)
            receipt = json.loads(result.read_text(encoding="utf-8"))
            if (receipt.get("error") or receipt.get("good_exit") != 0 or receipt.get("wrong_identity_exit") != 64
                    or receipt.get("parent_identity_absent") is not True or receipt.get("forbidden_started") is not False
                    or len(native.matching(executable)) != 1):
                raise RuntimeError("Native task environment acceptance failed: " + repr(receipt))
            report["result"] = receipt
        finally:
            lifecycle.cleanup(native, executable, launcher)
            report["application_cleanup"] = "confirmed"
            (output / "receipt.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    if sys.argv[1:] == ["selection"]:
        selected = selection()
        print("run_id=" + str(selected["producer_run"]))
        print("artifact_name=" + selected["artifact_name"])
    elif len(sys.argv) == 4:
        observe(*sys.argv[1:])
    else:
        raise SystemExit("Expected selection, or artifact directory, Hammerspoon app, and new output directory")
