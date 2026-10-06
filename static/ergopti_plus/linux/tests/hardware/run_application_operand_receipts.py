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
io.stderr:write("ERGOPTI_APPLICATION_STAGE=load\n")
local Chooser = require("ui.app_chooser")
local Actions = require("modules.gestures.manager")
io.stderr:write("ERGOPTI_APPLICATION_STAGE=chooser\n")
local id = assert(Chooser.desktop_id(os.getenv("ERGOPTI_NATIVE_APPLICATION_ENTRY")))
io.stderr:write("ERGOPTI_APPLICATION_STAGE=assignment\n")
assert(Actions.set_action_parameter("tap_3", "open_app", id))
io.stderr:write("ERGOPTI_APPLICATION_STAGE=execution\n")
assert(Actions.execute_action("open_app", "tap_3"))
io.stderr:write("ERGOPTI_APPLICATION_STAGE=receipt\n")
local receipt = os.getenv("ERGOPTI_NATIVE_APPLICATION_RECEIPT")
for _ = 1, 100 do
	local file = io.open(receipt, "r")
	if file then
		local actual = file:read("*a")
		file:close()
		if actual ~= id then
			io.stderr:write("ERGOPTI_APPLICATION_RECEIPT=identity_mismatch\n")
		end
		assert(actual == id, "the selected application identity changed")
		return
	end
	os.execute("sleep 0.02")
end
io.stderr:write("ERGOPTI_APPLICATION_RECEIPT=not_observed\n")
error("the selected desktop entry did not launch: " .. id)
"""


def application_stage(stderr):
    """Reduce owned worker diagnostics to one closed stage without payload text."""
    prefix = "ERGOPTI_APPLICATION_STAGE="
    allowed = {"load", "chooser", "assignment", "execution", "receipt"}
    stage = "unknown"
    for line in stderr.splitlines():
        if line.startswith(prefix):
            value = line[len(prefix) :]
            stage = value if value in allowed else "unknown"
    return stage


def application_receipt_state(stderr):
    """Report only closed reader observations, never receipt bytes or paths."""
    prefix = "ERGOPTI_APPLICATION_RECEIPT="
    allowed = {"not_observed", "identity_mismatch"}
    state = "unknown"
    for line in stderr.splitlines():
        if line.startswith(prefix):
            value = line[len(prefix) :]
            state = value if value in allowed else "unknown"
    return state


def main():
    checks, failures = 0, 0
    with tempfile.TemporaryDirectory(prefix="ergopti-app-operands-") as folder:
        root = pathlib.Path(folder)
        applications = root / "data" / "applications"
        applications.mkdir(parents=True)
        launcher = root / "record-application"
        launcher.write_text(
            "#!/bin/sh\nset -eu\n"
            'pending="${ERGOPTI_NATIVE_APPLICATION_RECEIPT}.pending"\n'
            'printf %s "$1" > "$pending"\n'
            'mv -- "$pending" "$ERGOPTI_NATIVE_APPLICATION_RECEIPT"\n'
        )
        launcher.chmod(0o700)
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
                            "ERGOPTI_NATIVE_APPLICATION_ENTRY": str(entry),
                            "ERGOPTI_NATIVE_APPLICATION_RECEIPT": str(receipt),
                            "LUA_PATH": "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                        }
                    )
                    child = subprocess.run(
                        ["dbus-run-session", "--", "luajit", "-e", WORKER],
                        env=env,
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                    if child.returncode:
                        failures += 1
                        stage = application_stage(child.stderr)
                        receipt_detail = (
                            f";receipt_state={application_receipt_state(child.stderr)}"
                            if stage == "receipt"
                            else ""
                        )
                        print(
                            "::error title=Native application operand::"
                            f"stage={stage};case={index};native_exit={child.returncode}"
                            f"{receipt_detail}"
                        )
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
