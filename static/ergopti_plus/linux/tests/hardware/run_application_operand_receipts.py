#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_application_operand_receipts.py
#
# Native gtk-launch reads owned desktop entries on a private Xvfb display and
# D-Bus session. The real chooser, parameter API and action executor run without
# shell or launcher mocks. The launched application writes its identity receipt;
# this validates virtual desktop services, not physical keyboard hardware.

import argparse
from contextlib import contextmanager
import json
import os
import sys
import time
import uuid

import application_operand_diagnostics as diagnostic
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
local Clock = require("infra.monotonic")
local Json = require("json")
local function snapshot()
	local file = io.open(receipt, "r")
	if not file then return { present = false, observed_bytes = 0, text_prefix = "" } end
	local value = file:read(4097) or ""
	file:close()
	return { present = true, observed_bytes = #value, text_prefix = value:sub(1, 4096), truncated = #value > 4096 }
end
local before_ms, before_receipt = Clock.now_ms(), snapshot()
local function trace(phase, after_receipt)
	local packet = { schema = 1, nonce = os.getenv("ERGOPTI_APPLICATION_NONCE"), identity = id,
		phase = phase, clock_backend = Clock.backend(), clock_resolution_ms = Clock.resolution_ms(),
		before_ms = before_ms, after_ms = Clock.now_ms(), before_receipt = before_receipt, after_receipt = after_receipt }
	local destination = os.getenv("ERGOPTI_APPLICATION_POLL_TRACE")
	local stream = assert(io.open(destination .. ".stage", "w"))
	assert(stream:write(assert(Json.encode(packet)) .. "\n"))
	assert(stream:flush())
	assert(stream:close())
	assert(os.rename(destination .. ".stage", destination))
end
for _ = 1, 100 do
	local file = io.open(receipt, "r")
	if file then
		local actual = file:read("*a")
		file:close()
		if actual ~= id then
			io.stderr:write("ERGOPTI_APPLICATION_RECEIPT=identity_mismatch\n")
		end
		trace("observed", snapshot())
		assert(actual == id, "the selected application identity changed")
		return
	end
	os.execute("sleep 0.02")
end
io.stderr:write("ERGOPTI_APPLICATION_RECEIPT=not_observed\n")
trace("missing", snapshot())
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
    ["/usr/bin/gtk-launch", "--", identity], env=environment,
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
# Replace this session worker with the real target, keeping the outer diagnostic
# owner responsible for the same PID, capture pipes, timeout and terminal wait.
os.execvp("luajit", ["luajit", "-e", sys.argv[1]])
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


@contextmanager
def evidence_directory():
    """Retain bounded diagnostic files on failure; never auto-delete an unresolved trial."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-dir")
    options = parser.parse_args()
    if options.evidence_dir is None:
        root = pathlib.Path(tempfile.mkdtemp(prefix="ergopti-app-operands-"))
    else:
        root = pathlib.Path(options.evidence_dir)
        root.mkdir(mode=0o700)
    try:
        yield str(root.resolve(strict=True))
    finally:
        print("Native application diagnostic files retained: " + str(root))


def main():
    checks, failures = 0, 0
    # Preserve the actual cold GTK prerequisite despite isolated XDG catalogues.
    schemas = pathlib.Path(os.environ.get("GSETTINGS_SCHEMA_DIR", "/usr/share/glib-2.0/schemas"))
    assert (schemas / "gschemas.compiled").is_file(), "native GTK schemas are unavailable"
    with evidence_directory() as folder:
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
        (applications / "ergopti-native-launcher-ready.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Native launcher readiness\n"
            f'Exec={launcher} "ergopti-native-launcher-ready"\nTerminal=false\n'
        )
        wrapper_directory = root / "bin"
        wrapper_directory.mkdir(mode=0o700)
        wrapper = wrapper_directory / "gtk-launch"
        assert sys.executable.startswith("/") and not any(c.isspace() for c in sys.executable), (
            "The selected Python executable cannot form a native shebang"
        )
        wrapper.write_text(
            "#!"
            + sys.executable
            + "\nimport sys\nsys.path.insert(0, "
            + repr(str(pathlib.Path(diagnostic.__file__).parent.resolve()))
            + ")\nfrom application_operand_diagnostics import wrapper_main\nraise SystemExit(wrapper_main())\n"
        )
        wrapper.chmod(0o700)
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
                    case_root = root / ("diagnostic-" + str(index))
                    case_root.mkdir(mode=0o700)
                    nonce = uuid.uuid4().hex
                    context_path = case_root / "context.json"
                    diagnostic.publish(
                        context_path,
                        {
                            "directory": str(case_root),
                            "nonce": nonce,
                            "identity": identity,
                            "receipt": str(receipt),
                        },
                    )
                    env = dict(os.environ)
                    env.update(
                        {
                            "PATH": str(wrapper_directory)
                            + os.pathsep
                            + os.environ.get("PATH", ""),
                            "ERGOPTI_APPLICATION_DIAGNOSTIC_CONTEXT": str(context_path),
                            "ERGOPTI_APPLICATION_NONCE": nonce,
                            "ERGOPTI_APPLICATION_POLL_TRACE": str(case_root / "poll.json"),
                            "DISPLAY": ":" + number,
                            "XDG_DATA_HOME": str(root / "data"),
                            "XDG_DATA_DIRS": str(root / "empty"),
                            "XDG_CONFIG_HOME": str(root / "config"),
                            "GSETTINGS_SCHEMA_DIR": str(schemas),
                            "ERGOPTI_NATIVE_APPLICATION_READY": str(root / ("ready-" + str(index))),
                            "ERGOPTI_NATIVE_APPLICATION_ENTRY": str(entry),
                            "ERGOPTI_NATIVE_APPLICATION_RECEIPT": str(receipt),
                            "LUA_PATH": "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                        }
                    )
                    before_child = time.monotonic_ns()
                    child = diagnostic.run_owned_case(
                        ["dbus-run-session", "--", "python3", "-c", SESSION_WORKER, WORKER], env
                    )
                    facts = {
                        "schema": 1,
                        "nonce": nonce,
                        "identity": identity,
                        "before_child_ns": before_child,
                        "after_child_ns": time.monotonic_ns(),
                        "worker_exit": child.returncode,
                        "observer_timed_out": child.observer_timed_out,
                        "receipt_after_worker": diagnostic.receipt_snapshot(receipt),
                    }
                    for label, filename in (("gtk", "gtk-terminal.json"), ("poll", "poll.json")):
                        diagnostic_path = case_root / filename
                        facts[label] = (
                            json.loads(diagnostic_path.read_bytes())
                            if diagnostic_path.exists()
                            else None
                        )
                        if facts[label] is not None:
                            assert (
                                facts[label]["nonce"] == nonce
                                and facts[label]["identity"] == identity
                            ), "Diagnostic belongs to a different controlled trial"
                    if child.stdout.strip():
                        print(child.stdout.strip())
                    diagnostic.publish(case_root / "case.json", facts)
                    print("APPLICATION_DIAGNOSTIC " + json.dumps(facts, sort_keys=True))
                    diagnostic_complete = diagnostic.native_launch_complete(facts["gtk"])
                    if child.returncode or child.observer_timed_out or not diagnostic_complete:
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
