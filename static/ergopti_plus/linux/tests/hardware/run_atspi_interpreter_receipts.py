#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_atspi_interpreter_receipts.py
#
# Exercise the public bounded AT-SPI helper with real interpreter options,
# GTK fields, an accessibility bus and an owned Xvfb/openbox session. This is
# virtual graphical validation, not a physical keyboard or desktop session.

import os
import pathlib
import select
import signal
import subprocess
import sys
import tempfile
import time


WORKER = r"""
package.path = assert(os.getenv("ERGOPTI_ATSPI_PACKAGE_PATH"))
local A = require("adapters.atspi_focus")
local expected = tonumber(os.getenv("ERGOPTI_ATSPI_EXPECTED_ROLE"))
local direct, conclusive = A._get_native_snapshot()
assert(conclusive and direct.role == expected, "actual focused GTK field was not available")
local helper, helper_ok = A.get_snapshot()
assert(helper_ok and helper.role == expected, "bounded helper did not launch the actual Lua interpreter")
"""


def stop(process):
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def session(root):
    checks, failures = 0, 0
    worker = root / "worker.lua"
    worker.write_text(WORKER)
    with (root / "openbox.log").open("wb") as wm_log:
        wm = subprocess.Popen(["openbox"], stdout=wm_log, stderr=wm_log)
        try:
            for kind, role in (("text", 61), ("password", 40)):
                title = "ergopti-native-atspi-" + kind
                command = [
                    os.environ.get("ERGOPTI_ATSPI_GTK_PYTHON", "/usr/bin/python3"),
                    "tests/hardware/atspi_fixture_app.py",
                    title,
                ]
                if kind == "password":
                    command.append("password")
                with (root / (kind + ".log")).open("wb") as gtk_log:
                    gtk = subprocess.Popen(command, stdout=gtk_log, stderr=gtk_log)
                    try:
                        deadline = time.monotonic() + 5
                        while True:
                            window = subprocess.run(
                                ["xdotool", "search", "--onlyvisible", "--name", title],
                                capture_output=True,
                                timeout=2,
                            )
                            if window.returncode == 0:
                                break
                            assert gtk.poll() is None, (
                                "GTK fixture exited before mapping its window"
                            )
                            assert time.monotonic() < deadline, "owned GTK window did not map"
                            time.sleep(0.05)
                        # Mapping precedes the native accessibility registration.
                        time.sleep(1)
                        for options in (
                            [],
                            ["-joff"],
                            ["-O0"],
                            ["-joff", "-O0"],
                            ["-e", "jit.off()"],
                            ["-E"],
                        ):
                            checks += 1
                            env = dict(os.environ)
                            env.update(
                                ERGOPTI_ATSPI_EXPECTED_ROLE=str(role),
                                ERGOPTI_ATSPI_PACKAGE_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                            )
                            result = subprocess.run(
                                ["luajit", *options, str(worker)],
                                env=env,
                                capture_output=True,
                                text=True,
                                timeout=5,
                            )
                            if result.returncode == 0:
                                print(f"PASS virtual AT-SPI {kind} options={options!r}", flush=True)
                            else:
                                failures += 1
                                print(
                                    f"FAIL virtual AT-SPI {kind} options={options!r}: {(result.stdout + result.stderr)[-1000:]}",
                                    flush=True,
                                )
                    finally:
                        stop(gtk)
        finally:
            stop(wm)
    print(f"Virtual AT-SPI interpreter receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--session":
        return session(pathlib.Path(sys.argv[2]))
    with tempfile.TemporaryDirectory(prefix="ergopti-native-atspi-interpreter-") as folder:
        root = pathlib.Path(folder)
        read_fd, write_fd = os.pipe()
        with (root / "xvfb.log").open("wb") as display_log:
            display = subprocess.Popen(
                ["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "1024x768x24"],
                pass_fds=(write_fd,),
                stdout=display_log,
                stderr=display_log,
            )
            os.close(write_fd)
            try:
                assert select.select([read_fd], [], [], 5)[0], "owned Xvfb did not report a display"
                with os.fdopen(read_fd) as stream:
                    number = stream.readline().strip()
                assert number.isdigit(), "owned Xvfb returned an invalid display"
                env = dict(os.environ)
                env.update(
                    DISPLAY=":" + number,
                    GTK_MODULES="gail:atk-bridge",
                    NO_AT_BRIDGE="0",
                    XDG_CONFIG_HOME=str(root / "config"),
                )
                # D-Bus owns and stops its private bus and accessibility services.
                child = subprocess.Popen(
                    [
                        "dbus-run-session",
                        "--",
                        sys.executable,
                        str(pathlib.Path(__file__).resolve()),
                        "--session",
                        str(root),
                    ],
                    env=env,
                    start_new_session=True,
                )
                try:
                    return child.wait(timeout=45)
                finally:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGTERM)
                        stop(child)
            finally:
                stop(display)


if __name__ == "__main__":
    raise SystemExit(main())
