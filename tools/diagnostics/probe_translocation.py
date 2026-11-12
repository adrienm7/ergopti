# tools/diagnostics/probe_translocation.py
"""Temporary probe: can a hosted runner produce an App Translocation mount?"""

import ctypes
import os
from pathlib import Path
import plistlib
import subprocess
import time
import uuid

home = Path.home()
app = home / "probe-downloads" / "Probe Été.app"
macos = app / "Contents/MacOS"
macos.mkdir(parents=True, exist_ok=True)
with (app / "Contents/Info.plist").open("wb") as handle:
    plistlib.dump(
        {
            "CFBundleExecutable": "Probe",
            "CFBundleIdentifier": "io.ergopti.probe.translocation",
            "CFBundleName": "Probe",
            "CFBundlePackageType": "APPL",
        },
        handle,
    )
marker = home / "probe-path.txt"
(macos / "Probe").write_text(f'#!/bin/sh\necho "$0" > "{marker}"\nsleep 20\n')
(macos / "Probe").chmod(0o755)
subprocess.run(["codesign", "--force", "--deep", "-s", "-", str(app)], check=False)
stamp = f"0083;{int(time.time()):x};Safari;{uuid.uuid4()}".upper()
subprocess.run(["xattr", "-r", "-w", "com.apple.quarantine", stamp, str(app)], check=False)
print(subprocess.run(["spctl", "--status"], capture_output=True, text=True))
print(subprocess.run(["spctl", "-a", "-vv", str(app)], capture_output=True, text=True))

sec = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/Security.framework/Security")
cf = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
cf.CFURLCreateFromFileSystemRepresentation.restype = ctypes.c_void_p
cf.CFURLCreateFromFileSystemRepresentation.argtypes = [
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_long,
    ctypes.c_bool,
]
cf.CFURLGetFileSystemRepresentation.restype = ctypes.c_bool
cf.CFURLGetFileSystemRepresentation.argtypes = [
    ctypes.c_void_p,
    ctypes.c_bool,
    ctypes.c_char_p,
    ctypes.c_long,
]
cf.CFCopyDescription.restype = ctypes.c_void_p
cf.CFCopyDescription.argtypes = [ctypes.c_void_p]
cf.CFStringGetCString.restype = ctypes.c_bool
cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]


def describe(ref):
    if not ref:
        return "null"
    text = ctypes.create_string_buffer(4096)
    cf.CFStringGetCString(cf.CFCopyDescription(ref), text, 4096, 0x08000100)
    return text.value.decode("utf-8", "replace")


raw = os.fsencode(app)
url = cf.CFURLCreateFromFileSystemRepresentation(None, raw, len(raw), True)
create = sec.SecTranslocateCreateSecureDirectoryForURL
create.restype = ctypes.c_void_p
create.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
error = ctypes.c_void_p()
translocated = create(url, None, ctypes.byref(error))
print("create error:", describe(error.value))
if translocated:
    buffer = ctypes.create_string_buffer(4096)
    cf.CFURLGetFileSystemRepresentation(translocated, True, buffer, 4096)
    path = buffer.value.decode()
    print("translocated:", path)
    print(subprocess.run(["mount"], capture_output=True, text=True).stdout[-1500:])
    print(subprocess.run(["open", "-n", path], capture_output=True, text=True))
    time.sleep(4)
    print("marker:", marker.read_text() if marker.exists() else "absent")
    marker.unlink(missing_ok=True)
print(subprocess.run(["open", "-n", str(app)], capture_output=True, text=True))
time.sleep(4)
print("natural marker:", marker.read_text() if marker.exists() else "absent")
print(
    subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout.count(
        "Probe"
    )
)
for line in subprocess.run(
    ["ps", "-axo", "pid=,command="], capture_output=True, text=True
).stdout.splitlines():
    if "Probe" in line:
        print(line)
print(
    subprocess.run(
        [
            "log",
            "show",
            "--last",
            "2m",
            "--style",
            "compact",
            "--predicate",
            'eventMessage CONTAINS[c] "translocat" OR eventMessage CONTAINS[c] "io.ergopti.probe"',
        ],
        capture_output=True,
        text=True,
    ).stdout[-6000:]
)
