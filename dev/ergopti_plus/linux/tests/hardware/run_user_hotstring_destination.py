#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_user_hotstring_destination.py
#
# Qualify native accessible bus/object receipts on a real GTK accessibility bus.
# Owns a virtual Xvfb/openbox session; this does not claim physical keyboard input.

import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time


WORKER = r"""
package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path
local Atspi = require("adapters.atspi_focus")
local Destination = require("adapters.user_hotstring_destination")
local direct, ok = Atspi._get_native_snapshot()
assert(ok and direct.active_scope == true, "native active GTK field must be conclusive")
local bounded, admitted = Atspi.get_snapshot()
assert(admitted and bounded.native_bus_name == direct.native_bus_name
    and bounded.native_object_path == direct.native_object_path,
    "bounded helper must preserve actual native identity")
assert(type(direct.native_bus_name) == "string" and direct.native_bus_name:match("^:%d+%.%d+$"))
assert(type(direct.native_object_path) == "string" and direct.native_object_path:sub(1,1) == "/")
local capture = Destination.capture()
if direct.role == 40 then assert(capture == nil, "password field cannot own user execution")
else assert(capture and Destination.current(capture), "normal exact destination must be owned") end
io.write("RECEIPT:" .. require("json").encode({bus=direct.native_bus_name,path=direct.native_object_path,role=direct.role}))
"""


def stop(process):
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def gtk():
    import gi

    gi.require_version("Gtk", "3.0")
    from gi.repository import GLib, Gtk

    window = Gtk.Window(title="ergopti-programmable-native-owner")
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    entries = [Gtk.Entry(), Gtk.Entry(), Gtk.Entry()]
    entries[2].set_visibility(False)
    for entry in entries:
        box.pack_start(entry, True, True, 0)
    window.add(box)
    window.show_all()
    window.present()
    entries[0].grab_focus()
    current = [0]

    def advance():
        current[0] += 1
        entries[current[0]].grab_focus()
        return True

    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, advance)
    GLib.timeout_add_seconds(20, Gtk.main_quit)
    Gtk.main()


def session(root):
    worker = root / "worker.lua"
    worker.write_text(WORKER)
    with (root / "openbox.log").open("wb") as wm_log:
        wm = subprocess.Popen(["openbox"], stdout=wm_log, stderr=wm_log)
        try:
            with (root / "gtk.log").open("wb") as gtk_log:
                app = subprocess.Popen(
                    [
                        os.environ.get("ERGOPTI_ATSPI_GTK_PYTHON", "/usr/bin/python3"),
                        __file__,
                        "--gtk",
                    ],
                    stdout=gtk_log,
                    stderr=gtk_log,
                )
                try:
                    deadline = time.monotonic() + 5
                    while True:
                        visible = subprocess.run(
                            [
                                "xdotool",
                                "search",
                                "--onlyvisible",
                                "--name",
                                "ergopti-programmable-native-owner",
                            ],
                            capture_output=True,
                            timeout=2,
                        )
                        if visible.returncode == 0:
                            break
                        assert app.poll() is None, "GTK fixture exited before its window mapped"
                        assert time.monotonic() < deadline, "native owner fixture did not map"
                        time.sleep(0.05)
                    time.sleep(1)
                    receipts = []
                    for expected in (61, 61, 40):
                        run = subprocess.run(
                            ["luajit", str(worker)], capture_output=True, text=True, timeout=5
                        )
                        assert run.returncode == 0, run.stdout + run.stderr
                        receipt = json.loads(run.stdout.rsplit("RECEIPT:", 1)[1])
                        assert receipt["role"] == expected, (
                            "real focused field role changed unexpectedly"
                        )
                        receipts.append(receipt)
                        if expected != 40:
                            app.send_signal(signal.SIGUSR1)
                            time.sleep(0.2)
                    assert len({r["bus"] for r in receipts}) == 1, (
                        "same GTK app must retain its unique native bus"
                    )
                    assert len({r["path"] for r in receipts}) == 3, (
                        "three controls in one window require distinct native owners"
                    )
                    print(
                        "PASS virtual native destination: stable app bus, three exact field paths, password refusal"
                    )
                finally:
                    stop(app)
        finally:
            stop(wm)


def main():
    if "--gtk" in sys.argv:
        gtk()
        return 0
    if "--session" in sys.argv:
        session(pathlib.Path(sys.argv[-1]))
        return 0
    os.chdir(pathlib.Path(__file__).resolve().parents[2])
    for tool in ("xvfb-run", "dbus-run-session", "openbox", "xdotool", "luajit"):
        if shutil.which(tool) is None:
            print(f"ENVIRONMENT: {tool} is missing", file=sys.stderr)
            return 2
    with tempfile.TemporaryDirectory(prefix="ergopti-user-hotstring-native-") as temp:
        result = subprocess.run(
            [
                "xvfb-run",
                "-a",
                "dbus-run-session",
                sys.executable,
                str(pathlib.Path(__file__).resolve()),
                "--session",
                temp,
            ],
            timeout=35,
        )
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
