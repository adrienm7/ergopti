#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_wayland_focus_identity.py

"""Qualify production focus ownership on an actual headless Wayland compositor.

Run as a normal user with sway, swaymsg, LuaJIT and Python GTK3 bindings installed.
Sway uses wlroots' headless backend and pixman; Xwayland is explicitly disabled.
No physical input or native text injection is claimed. Exit 2 means prerequisites
could not establish the native fixture; an assertion failure exits 1.
"""

import contextlib
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time


APP_ID = "ergopti-wayland-focus-proof"
TITLE = "Ergopti native Wayland focus"
DRIVER = Path(__file__).resolve().parents[2]
LUA_WORKER = r"""
package.path = './?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;' .. package.path
local Json = require('json')
local Window = require('adapters.window_info')
local Lifecycle = require('adapters.process_lifecycle')
local transitions = 0
Lifecycle.onFocusChange(function() transitions = transitions + 1 end)
Lifecycle.start()
io.write('READY\n'); io.flush()
for _ in io.lines() do
    local info = Window.getFocused()
    Lifecycle.tick(1)
    io.write(Json.encode({info = info, identity = Window.focused_identity(), transitions = transitions}) .. '\n')
    io.flush()
end
Lifecycle.stop()
"""


class PrerequisiteFailure(Exception):
    """The environment could not establish an actual native fixture."""


class Interrupted(Exception):
    """A signal must unwind all owned native processes before exiting."""

    def __init__(self, signum):
        self.signum = signum


def interrupt(signum, _frame):
    """Route termination through the same cleanup as assertion failures."""
    raise Interrupted(signum)


def stop(process):
    """Retire an owned process group even when its leader already exited."""
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)
    deadline = time.monotonic() + 3
    escalated = False
    while True:
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return
        if not escalated:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            escalated = True
        if time.monotonic() >= deadline:
            raise RuntimeError("owned native process group survived cleanup: " + str(process.pid))
        time.sleep(0.02)


def gtk_worker():
    """Create two native xdg-shell surfaces in one GTK application process."""
    import gi

    gi.require_version("Gtk", "3.0")
    from gi.repository import GLib, Gtk

    GLib.set_prgname(APP_ID)
    windows = []
    for index in range(2):
        window = Gtk.Window(title=TITLE)
        entry = Gtk.Entry()
        entry.set_text("Owned Wayland field " + str(index))
        window.add(entry)
        window.set_default_size(350, 150)
        window.show_all()
        entry.grab_focus()
        windows.append(window)
    Gtk.main()


def prerequisites():
    """Reject absent tools before starting any native process."""
    if os.geteuid() == 0:
        raise PrerequisiteFailure("run this rootless qualification as a normal user")
    for name in ("LUA_INIT", "LUA_INIT_5_1"):
        if os.getenv(name):
            raise PrerequisiteFailure("unset " + name + " to load original production modules")
    tools = {}
    for name in ("sway", "swaymsg", "luajit"):
        tools[name] = shutil.which(name)
        if tools[name] is None:
            raise PrerequisiteFailure("required executable is missing: " + name)
    tools["gtk_python"] = os.getenv("ERGOPTI_WAYLAND_GTK_PYTHON", "/usr/bin/python3")
    try:
        checked = subprocess.run(
            [
                tools["gtk_python"],
                "-c",
                "import gi; gi.require_version('Gtk', '3.0'); from gi.repository import Gtk",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PrerequisiteFailure(
            "cannot run the GTK3 Python prerequisite: " + str(error)
        ) from error
    if checked.returncode != 0:
        raise PrerequisiteFailure("Python GTK3 bindings are unavailable: " + checked.stderr.strip())
    return tools


def app_windows(node):
    """Collect only the two test-owned native surfaces from the real IPC tree."""
    if node.get("app_id") == APP_ID:
        yield node
    for child in node.get("nodes", []) + node.get("floating_nodes", []):
        yield from app_windows(child)


def read_line(process):
    """Keep an unresponsive production query from retaining the fixture forever."""
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(10):
            raise AssertionError("the production focus worker did not return within 10 seconds")
    line = process.stdout.readline()
    if not line:
        raise AssertionError("the production focus worker exited without its next native answer")
    return line.strip()


def qualify(tools):
    """Exercise original WindowInfo and Lifecycle against actual compositor focus."""
    with tempfile.TemporaryDirectory(prefix="ergopti-wayland-focus-") as temporary:
        root = Path(temporary)
        runtime = root / "run"
        runtime.mkdir(mode=0o700)
        config = root / "sway.conf"
        config.write_text(
            "xwayland disable\n"
            "swaybg_command -\n"
            "output HEADLESS-1 resolution 1024x768\n"
            "input * xkb_layout us\n"
            "seat seat0 fallback true\n"
            "focus_follows_mouse no\n"
        )
        env = dict(os.environ)
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "SWAYSOCK", "I3SOCK"):
            env.pop(name, None)
        env.update(
            XDG_RUNTIME_DIR=str(runtime),
            XDG_SESSION_TYPE="wayland",
            GDK_BACKEND="wayland",
            WLR_BACKENDS="headless",
            WLR_RENDERER="pixman",
            NO_AT_BRIDGE="1",
        )
        children = []
        logs = []
        with contextlib.ExitStack() as stack:

            def launch(arguments, name, interactive=False):
                log_path = root / (name + ".log")
                logs.append(log_path)
                log = stack.enter_context(log_path.open("w"))
                process = subprocess.Popen(
                    arguments,
                    cwd=DRIVER,
                    env=env,
                    stdin=subprocess.PIPE if interactive else subprocess.DEVNULL,
                    stdout=subprocess.PIPE if interactive else log,
                    stderr=log,
                    text=True,
                    start_new_session=True,
                )
                children.append(process)
                return process

            def ipc(*arguments):
                reply = subprocess.run(
                    [tools["swaymsg"], *arguments],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                if reply.returncode != 0:
                    raise AssertionError("owned Sway IPC failed: " + reply.stderr.strip())
                return json.loads(reply.stdout)

            try:
                compositor = launch([tools["sway"], "-c", str(config), "-d"], "sway")
                deadline = time.monotonic() + 10
                while True:
                    sockets = list(runtime.glob("sway-ipc.*.sock"))
                    displays = [p for p in runtime.glob("wayland-*") if p.is_socket()]
                    if sockets and displays:
                        env["SWAYSOCK"] = str(sockets[0])
                        env["WAYLAND_DISPLAY"] = displays[0].name
                        break
                    if compositor.poll() is not None or time.monotonic() >= deadline:
                        raise PrerequisiteFailure(
                            "headless Sway/pixman did not establish its native sockets"
                        )
                    time.sleep(0.05)

                gtk = launch(
                    [tools["gtk_python"], str(Path(__file__).resolve()), "--gtk-worker"], "gtk"
                )
                deadline = time.monotonic() + 10
                while True:
                    windows = list(app_windows(ipc("-t", "get_tree", "-r")))
                    if len(windows) == 2:
                        break
                    if gtk.poll() is not None or time.monotonic() >= deadline:
                        raise PrerequisiteFailure(
                            "GTK3 did not map both native Wayland test windows"
                        )
                    time.sleep(0.05)
                assert all(window.get("shell") == "xdg_shell" for window in windows), windows
                assert all(window.get("name") == TITLE for window in windows), windows
                assert windows[0]["pid"] == windows[1]["pid"] == gtk.pid, windows
                assert windows[0]["id"] != windows[1]["id"], windows
                assert ipc("[con_id=" + str(windows[0]["id"]) + "] focus")[0]["success"]
                worker = launch([tools["luajit"], "-e", LUA_WORKER], "lua", interactive=True)
                assert read_line(worker) == "READY", (
                    "native focus worker did not acknowledge startup"
                )
                observations = []
                for window, changes in (
                    (windows[0], 0),
                    (windows[1], 1),
                    (windows[1], 1),
                    (windows[0], 2),
                ):
                    assert ipc("[con_id=" + str(window["id"]) + "] focus")[0]["success"]
                    worker.stdin.write("probe\n")
                    worker.stdin.flush()
                    answer = json.loads(read_line(worker))
                    expected = {
                        "info": {
                            "appId": APP_ID,
                            "windowTitle": TITLE,
                            "bundleId": "",
                            "executablePath": "",
                        },
                        "identity": "sway:" + str(window["pid"]) + ":" + str(window["id"]),
                        "transitions": changes,
                    }
                    assert answer == expected, {"expected": expected, "actual": answer}
                    observations.append(answer)
                version = subprocess.check_output(
                    [tools["sway"], "--version"], env=env, text=True, timeout=5
                ).strip()
                commit = subprocess.check_output(
                    ["git", "rev-parse", "HEAD"], cwd=DRIVER, text=True, timeout=5
                ).strip()
                return {
                    "source_commit": commit,
                    "compositor": version,
                    "tools": tools,
                    "environment": {
                        "WLR_BACKENDS": "headless",
                        "WLR_RENDERER": "pixman",
                        "GDK_BACKEND": "wayland",
                        "DISPLAY": "unset",
                        "Xwayland": "disabled",
                    },
                    "surface_protocol": "native GTK3 xdg_shell",
                    "physical_input_claim": False,
                    "source_sha256": {
                        name: hashlib.sha256((DRIVER / name).read_bytes()).hexdigest()
                        for name in ("adapters/window_info.lua", "adapters/process_lifecycle.lua")
                    },
                    "observations": observations,
                }
            except Exception:
                for log_path in logs:
                    sys.stderr.write("\n" + log_path.name + ":\n" + log_path.read_text()[-6000:])
                raise
            finally:
                cleanup_errors = []
                for process in reversed(children):
                    try:
                        stop(process)
                    except Exception as error:
                        cleanup_errors.append(str(error))
                if cleanup_errors:
                    raise RuntimeError("native cleanup failed: " + "; ".join(cleanup_errors))


def main():
    """Report real qualification, explicit prerequisite failure, or a test failure."""
    if sys.argv[1:] == ["--gtk-worker"]:
        gtk_worker()
        return 0
    if sys.argv[1:]:
        sys.stderr.write("Usage: python3 tests/hardware/run_wayland_focus_identity.py\n")
        return 2
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupt)
    try:
        proof = qualify(prerequisites())
    except PrerequisiteFailure as error:
        sys.stderr.write("ENVIRONMENT: " + str(error) + "\n")
        return 2
    except Interrupted as error:
        sys.stderr.write("Interrupted; owned Wayland processes retired.\n")
        return 128 + error.signum
    except Exception as error:
        sys.stderr.write("FAIL: " + str(error) + "\n")
        return 1
    print(
        "PASS: real Wayland native focus and lifecycle distinguish identical windows of one process"
    )
    print(json.dumps(proof, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
