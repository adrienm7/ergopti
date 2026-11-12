# tools/diagnostics/probe_translocation.py
"""Temporary probe: can a hosted runner produce an App Translocation mount?"""

import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).parent))
import macos_app_relocation as relocation  # noqa: E402

home = Path.home()
marker = home / "probe-path.txt"


def run(arguments, timeout=20):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
        print(
            "$",
            " ".join(arguments),
            "->",
            result.returncode,
            result.stdout[-800:],
            result.stderr[-800:],
        )
    except subprocess.TimeoutExpired:
        print("$", " ".join(arguments), "-> TIMEOUT")


def make(name):
    app = home / "probe-downloads" / name / "Probe Été.app"
    shutil.rmtree(app.parent, ignore_errors=True)
    (app / "Contents/MacOS").mkdir(parents=True)
    with (app / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump(
            {
                "CFBundleExecutable": "Probe",
                "CFBundleIdentifier": "io.ergopti.probe." + name,
                "CFBundleName": "Probe",
                "CFBundlePackageType": "APPL",
            },
            handle,
        )
    (app / "Contents/MacOS/Probe").write_text(f'#!/bin/sh\necho "$0" > "{marker}"\nsleep 5\n')
    (app / "Contents/MacOS/Probe").chmod(0o755)
    run(["codesign", "--force", "--deep", "-s", "-", str(app)])
    return app


def launch(path):
    marker.unlink(missing_ok=True)
    run(["open", "-n", str(path)], timeout=15)
    time.sleep(4)
    print("marker:", marker.read_text().strip() if marker.exists() else "absent")


run(["spctl", "--status"])
mounts = relocation.Translocation()
for name, flags in (("plain", None), ("pending", "0083"), ("approved", "00c3")):
    print(f"===== variant {name} quarantine={flags}", flush=True)
    app = make(name)
    if flags:
        stamp = relocation.quarantine_stamp().replace("0083", flags, 1)
        run(["xattr", "-r", "-w", "com.apple.quarantine", stamp, str(app)])
    try:
        mounted = mounts.create(app)
        print("translocated:", mounted, flush=True)
        run(["ls", "-la", str(mounted)])
        launch(mounted)
        mounts.delete(mounted)
        print("deleted mount; exists:", mounted.exists())
    except Exception as error:
        print("translocation error:", type(error).__name__, error)
    print("--- natural open of the original")
    launch(app)
run(["mount"])
run(
    [
        "log",
        "show",
        "--last",
        "3m",
        "--style",
        "compact",
        "--predicate",
        'eventMessage CONTAINS[c] "translocat" OR eventMessage CONTAINS[c] "io.ergopti.probe"',
    ],
    timeout=60,
)
os._exit(0)
