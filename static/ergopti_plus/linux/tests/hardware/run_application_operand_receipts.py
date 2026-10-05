#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_application_operand_receipts.py
#
# Native gtk-launch reads owned desktop entries on a private Xvfb display and
# D-Bus session. The real chooser, parameter API and action executor run without
# shell or launcher mocks. The launched application writes its identity receipt;
# this validates virtual desktop services, not physical keyboard hardware.

import os
import pathlib
import subprocess
import tempfile


WORKER = r"""
local Chooser = require("ui.app_chooser")
local Actions = require("modules.gestures.manager")
local id = assert(Chooser.desktop_id(os.getenv("ERGOPTI_NATIVE_APPLICATION_ENTRY")))
assert(Actions.set_action_parameter("tap_3", "open_app", id))
assert(Actions.execute_action("open_app", "tap_3"))
local receipt = os.getenv("ERGOPTI_NATIVE_APPLICATION_RECEIPT")
for _ = 1, 100 do
	local file = io.open(receipt, "r")
	if file then
		local actual = file:read("*a")
		file:close()
		assert(actual == id, "the selected application identity changed")
		return
	end
	os.execute("sleep 0.02")
end
error("the selected desktop entry did not launch: " .. id)
"""


SESSION_WORKER = r"""
import os
import pathlib
import subprocess
import sys
import time

# Xvfb's displayfd proves X11 startup, but not GTK's first-launch services.
# Qualify the actual launcher in this same private bus/display before starting
# the unchanged functional receipt deadline. This receipt belongs to setup;
# every action case must still produce its own independently checked receipt.
ready = pathlib.Path(os.environ["ERGOPTI_NATIVE_APPLICATION_READY"])
identity = "ergopti-native-launcher-ready"
environment = dict(os.environ)
environment["ERGOPTI_NATIVE_APPLICATION_RECEIPT"] = str(ready)
started = time.monotonic()
launcher = subprocess.run(
    ["gtk-launch", "--", identity], env=environment,
    capture_output=True, text=True, timeout=10,
)
assert launcher.returncode == 0, "native GTK prerequisite failed: " + launcher.stderr
for _ in range(100):
    if ready.exists() and ready.read_text() == identity:
        break
    time.sleep(0.02)
else:
    raise AssertionError("native GTK prerequisite did not produce its readiness receipt")
print(f"OBS native GTK/D-Bus ready after {time.monotonic() - started:.3f}s", flush=True)
child = subprocess.run(
    ["luajit", "-e", sys.argv[1]], capture_output=True, text=True, timeout=10,
)
sys.stdout.write(child.stdout)
sys.stderr.write(child.stderr)
raise SystemExit(child.returncode)
"""


def main():
    checks, failures = 0, 0
    # Catalogue isolation must not hide GLib's native schema prerequisites.
    schemas = pathlib.Path(os.environ.get("GSETTINGS_SCHEMA_DIR", "/usr/share/glib-2.0/schemas"))
    assert (schemas / "gschemas.compiled").is_file(), "native GTK schemas are unavailable"
    with tempfile.TemporaryDirectory(prefix="ergopti-app-operands-") as folder:
        root = pathlib.Path(folder)
        applications = root / "data" / "applications"
        applications.mkdir(parents=True)
        launcher = root / "record-application"
        launcher.write_text('#!/bin/sh\nprintf %s "$1" > "$ERGOPTI_NATIVE_APPLICATION_RECEIPT"\n')
        launcher.chmod(0o700)
        (applications / "ergopti-native-launcher-ready.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Native launcher readiness\n"
            f'Exec={launcher} "ergopti-native-launcher-ready"\nTerminal=false\n'
        )
        read_fd, write_fd = os.pipe()
        with (root / "display.log").open("w") as log:
            display = subprocess.Popen(
                [
                    "Xvfb",
                    "-displayfd",
                    str(write_fd),
                    "-screen",
                    "0",
                    "800x600x24",
                    "-nolisten",
                    "tcp",
                ],
                pass_fds=(write_fd,),
                stdout=log,
                stderr=log,
            )
            os.close(write_fd)
            try:
                number = os.read(read_fd, 64).decode().strip()
                assert number and display.poll() is None, "owned virtual display did not start"
                for index, identity in enumerate(
                    ("ordinary-app", "--version", "-help", "app with ' quote")
                ):
                    checks += 1
                    entry = applications / (identity + ".desktop")
                    entry.write_text(
                        "[Desktop Entry]\nType=Application\nName=Operand receipt\n"
                        f'Exec={launcher} "{identity}"\nTerminal=false\n'
                    )
                    receipt = root / ("receipt-" + str(index))
                    env = dict(os.environ)
                    env.update(
                        {
                            "DISPLAY": ":" + number,
                            "XDG_DATA_HOME": str(root / "data"),
                            "XDG_DATA_DIRS": str(root / "empty"),
                            "XDG_CONFIG_HOME": str(root / "config"),
                            "GSETTINGS_SCHEMA_DIR": str(schemas),
                            "ERGOPTI_NATIVE_APPLICATION_ENTRY": str(entry),
                            "ERGOPTI_NATIVE_APPLICATION_RECEIPT": str(receipt),
                            "ERGOPTI_NATIVE_APPLICATION_READY": str(root / ("ready-" + str(index))),
                            "LUA_PATH": "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                        }
                    )
                    child = subprocess.run(
                        ["dbus-run-session", "--", "python3", "-c", SESSION_WORKER, WORKER],
                        env=env,
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                    if child.stdout.strip():
                        print(child.stdout.strip())
                    if child.returncode:
                        failures += 1
                        print(
                            f"FAIL native application operand {identity!r}: {child.stderr.strip()}"
                        )
                    else:
                        assert receipt.read_text() == identity
                        print(f"PASS native application operand {identity!r}")
            finally:
                os.close(read_fd)
                display.terminate()
                display.wait(timeout=5)
    print(
        f"native application operand receipts: {checks - failures}/{checks} passed, {failures} failed"
    )
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
