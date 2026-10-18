#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_secure_focus_watch.py

"""Exercise the real resident privacy owner against owned GTK/AT-SPI controls.

Requires Xvfb, a session bus, openbox, LuaJIT/luv and Python GTK3 bindings.
No /dev/uinput or physical keyboard is needed. DUMMY enters the original logical
input callback seam; no claim of native text injection is made. Exit 2 means an
explicit missing prerequisite, and every regression or cleanup failure exits 1.
"""

import contextlib
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time


DRIVER = Path(__file__).resolve().parents[2]
TITLE = "Ergopti owned secure focus watcher"


class Interrupted(Exception):
    """Unwind every owned native process before acknowledging a signal."""

    def __init__(self, signum):
        self.signum = signum


def interrupt(signum, _frame):
    """Deliver termination through the same cleanup as failed assertions."""
    raise Interrupted(signum)


def stop(process, timeout=3):
    """Retire an owned process group even if its leader already exited."""
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)


def read_line(process, pending, timeout=10):
    """Read one framed response without TextIO buffering or unbounded waiting."""
    deadline = time.monotonic() + timeout
    while True:
        assert time.monotonic() <= deadline, "native receipt deadline expired"
        newline = pending.find(b"\n")
        if newline >= 0:
            line = bytes(pending[:newline]).decode()
            del pending[: newline + 1]
            if line.startswith("RECEIPT:"):
                return json.loads(line[len("RECEIPT:") :])
            continue
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            assert selector.select(max(0, deadline - time.monotonic())), (
                "production privacy worker did not answer within its native deadline"
            )
        chunk = os.read(process.stdout.fileno(), 4096)
        assert chunk, "production privacy worker exited before answering"
        pending.extend(chunk)
        assert len(pending) <= 65536, "production worker output exceeded its bound"


def gtk(root):
    """Own three real controls, including a password and a mutable ordinary one."""
    import gi

    gi.require_version("Gtk", "3.0")
    from gi.repository import GLib, Gtk

    window = Gtk.Window(title=TITLE)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    entries = [Gtk.Entry(), Gtk.Entry(), Gtk.Entry()]
    entries[2].set_visibility(False)
    for entry in entries:
        box.pack_start(entry, True, True, 0)
    window.add(box)
    window.show_all()
    window.present()
    entries[0].grab_focus()
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(root / "gtk.sock"))
    server.listen(1)
    server.setblocking(False)

    def command(_source, _condition):
        connection, _address = server.accept()
        with connection:
            connection.settimeout(1)
            action = connection.recv(128).decode()
            if action == "reset":
                entries[0].set_visibility(True)
                entries[0].grab_focus()
            elif action in ("focus1", "focus2"):
                entries[int(action[-1])].grab_focus()
            elif action == "hide0":
                entries[0].set_visibility(False)
            elif action != "status":
                raise AssertionError("unknown GTK fixture command")
            focused = [index for index, entry in enumerate(entries) if entry.is_focus()]
            assert len(focused) == 1
            connection.sendall(
                json.dumps(
                    {"field": focused[0], "visible": entries[focused[0]].get_visibility()}
                ).encode()
            )
        return True

    source = GLib.io_add_watch(server.fileno(), GLib.IO_IN, command)
    try:
        Gtk.main()
    finally:
        GLib.source_remove(source)
        server.close()
        with contextlib.suppress(FileNotFoundError):
            (root / "gtk.sock").unlink()


def session(root):
    """Run the exact listener and collection owners on a private accessibility bus."""
    children = []
    with contextlib.ExitStack() as stack:

        def launch(arguments, name, interactive=False):
            log = stack.enter_context((root / (name + ".log")).open("w"))
            process = subprocess.Popen(
                arguments,
                cwd=DRIVER,
                stdin=subprocess.PIPE if interactive else subprocess.DEVNULL,
                stdout=subprocess.PIPE if interactive else log,
                stderr=log,
                start_new_session=True,
            )
            children.append(process)
            return process

        try:
            launch(["openbox"], "openbox")
            app = launch(
                [os.environ["ERGOPTI_ATSPI_GTK_PYTHON"], __file__, "--gtk", str(root)], "gtk"
            )
            deadline = time.monotonic() + 8
            while True:
                mapped = subprocess.run(
                    ["xdotool", "search", "--onlyvisible", "--name", TITLE],
                    capture_output=True,
                    text=True,
                    timeout=2,
                )
                if mapped.returncode == 0 and (root / "gtk.sock").exists():
                    break
                assert app.poll() is None, "owned GTK fixture exited before mapping"
                assert time.monotonic() < deadline, "owned GTK fixture did not map"
                time.sleep(0.02)
            subprocess.run(
                ["xdotool", "windowactivate", "--sync", mapped.stdout.splitlines()[0]],
                check=True,
                timeout=5,
            )

            def focus(action):
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(3)
                    client.connect(str(root / "gtk.sock"))
                    client.sendall(action.encode())
                    return json.loads(client.recv(1024))

            worker = launch(
                ["luajit", "tests/hardware/secure_focus_watch.lua", str(root)], "lua", True
            )
            pending = bytearray()
            initial = read_line(worker, pending)
            assert initial["ready"] and initial["role"] == 61, initial

            def command(action):
                worker.stdin.write((action + "\n").encode())
                worker.stdin.flush()
                return read_line(worker, pending)

            def helper():
                snapshot = subprocess.check_output(
                    ["ps", "-eo", "pid=,ppid=,args="], text=True, timeout=3
                )
                matches = []
                for line in snapshot.splitlines():
                    parts = line.split(None, 2)
                    if (
                        len(parts) == 3
                        and parts[1] == str(worker.pid)
                        and "/adapters/atspi_focus_watch_worker.lua " in parts[2]
                    ):
                        endpoints = [
                            Path(argument)
                            for argument in parts[2].split()
                            if Path(argument).name == "control"
                            and Path(argument).parent.name.startswith("ergopti-focus-")
                        ]
                        assert len(endpoints) == 1, (
                            "exact native control endpoint must be identifiable"
                        )
                        matches.append((int(parts[0]), endpoints[0].parent))
                assert len(matches) == 1, "one exact resident focus process must be owned"
                pid, directory = matches[0]
                assert not directory.exists(), "READY must retire all private FIFO names"
                return pid

            receipts = []

            def sample(case, allowed):
                receipt = command("sample")
                assert receipt["allowed"] == receipt["raw_delta"] == allowed, (case, receipt)
                if allowed == 0:
                    assert receipt["metric_secure"] and receipt["buffer"] == "", (case, receipt)
                else:
                    assert not receipt["metric_secure"] and receipt["buffer"] == "DUMMY", (
                        case,
                        receipt,
                    )
                assert receipt["focus_changes"] == 0, "the top-level window must remain unchanged"
                assert receipt["window_identity"] == initial["window_identity"], receipt
                receipts.append({"case": case, "receipt": receipt})

            command("reset")
            sample("ordinary native field", 5)
            first_path = command("normal")["path"]
            assert focus("focus1")["field"] == 1
            second = command("normal")
            assert second["path"] != first_path and second["bus"] == initial["bus"], second
            command("reset")
            sample("second field of the identical native window", 5)
            assert focus("focus2") == {"field": 2, "visible": False}
            sample("programmatic focus into password", 0)
            password = command("password")
            assert password["path"] not in (first_path, second["path"]), password
            focus("reset")
            command("normal")
            command("reset")
            assert focus("hide0") == {"field": 0, "visible": False}
            sample("same native object changes to password role", 0)
            hidden = command("password")
            assert hidden["path"] == first_path, (
                "role change must preserve the exact control identity"
            )
            focus("reset")
            command("normal")
            command("reset")
            # Deliberately stop pumping the parent longer than the source lease;
            # old queued frames may withhold, but may not kill its healthy child.
            time.sleep(initial["lease_ms"] / 1000 + 0.25)
            sample("busy parent recovers through a fresh resident barrier", 5)
            command("reset")
            pid = helper()
            os.kill(pid, signal.SIGSTOP)
            time.sleep(initial["lease_ms"] / 1000 + 0.2)
            sample("stopped resident remains private beyond its lease", 0)
            os.kill(pid, signal.SIGCONT)
            command("normal")
            assert helper() == pid, "a fresh resumed answer must retain the original child"
            command("reset")
            sample("same resident recovers after SIGCONT", 5)
            os.kill(pid, signal.SIGKILL)
            sample("resident death cannot borrow an old ordinary verdict", 0)
            assert command("restart")["restarted"]
            assert helper() != pid
            command("reset")
            sample("physically settled restart permits ordinary input", 5)
            final_pid = helper()
            worker.stdin.close()
            assert worker.wait(timeout=5) == 0, "native focus worker failed physical settlement"
            assert (
                subprocess.run(
                    ["ps", "-p", str(final_pid), "-o", "stat="], capture_output=True, timeout=3
                ).returncode
                != 0
            ), "the settled helper process must no longer exist"
            print(
                "PASS: real GTK/AT-SPI field privacy, role changes, source freshness and native cleanup"
            )
            print(
                json.dumps(
                    {
                        "scope": "native GTK/AT-SPI; controlled logical input seam; no evdev claim",
                        "receipts": receipts,
                        "source_sha256": {
                            name: hashlib.sha256((DRIVER / name).read_bytes()).hexdigest()
                            for name in (
                                "adapters/atspi_focus.lua",
                                "adapters/atspi_focus_watch.lua",
                                "adapters/atspi_focus_watch_worker.lua",
                                "adapters/secure_field_detector.lua",
                                "modules/keylogger/focus_guard.lua",
                            )
                        },
                    },
                    indent=2,
                )
            )
        except Exception:
            for log in root.glob("*.log"):
                sys.stderr.write("\n" + log.name + ":\n" + log.read_text()[-6000:])
            raise
        finally:
            cleanup_errors = []
            for process in reversed(children):
                try:
                    stop(process)
                except Exception as error:
                    cleanup_errors.append(str(error))
            if cleanup_errors:
                raise RuntimeError("owned native cleanup failed: " + "; ".join(cleanup_errors))


def qualify(root):
    """Own the X server and private session bus, including failure and signals."""
    read_fd, write_fd = os.pipe()
    children = []
    try:
        server = subprocess.Popen(
            [
                "Xvfb",
                "-displayfd",
                str(write_fd),
                "-screen",
                "0",
                "1024x768x24",
                "-nolisten",
                "tcp",
            ],
            pass_fds=(write_fd,),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        children.append(server)
        os.close(write_fd)
        write_fd = None
        with os.fdopen(read_fd) as ready, selectors.DefaultSelector() as selector:
            read_fd = None
            selector.register(ready, selectors.EVENT_READ)
            assert selector.select(5), "owned Xvfb did not publish its display"
            display = ready.readline().strip()
            assert display.isdigit(), "owned Xvfb published an invalid display"
        env = dict(os.environ)
        for name in (
            "WAYLAND_DISPLAY",
            "SWAYSOCK",
            "I3SOCK",
            "DBUS_SESSION_BUS_ADDRESS",
            "AT_SPI_BUS_ADDRESS",
        ):
            env.pop(name, None)
        env.update(
            DISPLAY=":" + display, XDG_SESSION_TYPE="x11", GDK_BACKEND="x11", NO_AT_BRIDGE="0"
        )
        for key, child in (
            ("XDG_CONFIG_HOME", "config"),
            ("XDG_STATE_HOME", "state"),
            ("XDG_CACHE_HOME", "cache"),
        ):
            env[key] = str(root / child)
        child = subprocess.Popen(
            ["dbus-run-session", sys.executable, __file__, "--session", str(root)],
            cwd=DRIVER,
            env=env,
            start_new_session=True,
        )
        children.append(child)
        return child.wait(timeout=45)
    finally:
        if write_fd is not None:
            os.close(write_fd)
        if read_fd is not None:
            os.close(read_fd)
        cleanup_errors = []
        for process in reversed(children):
            try:
                # The session owns three separately grouped children and may
                # need their complete bounded cleanup before it can retire.
                stop(process, timeout=12)
            except Exception as error:
                cleanup_errors.append(str(error))
        if cleanup_errors:
            raise RuntimeError("native session cleanup failed: " + "; ".join(cleanup_errors))


def main():
    """Fail explicitly for missing prerequisites; never skip a native regression."""
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupt)
    if sys.argv[1:2] == ["--gtk"]:
        gtk(Path(sys.argv[2]))
        return 0
    if sys.argv[1:2] == ["--session"]:
        session(Path(sys.argv[2]))
        return 0
    if sys.argv[1:]:
        print("Usage: python3 tests/hardware/run_secure_focus_watch.py", file=sys.stderr)
        return 2
    for name in ("LUA_INIT", "LUA_INIT_5_1"):
        if os.getenv(name):
            print("ENVIRONMENT: unset " + name + " to load the original modules", file=sys.stderr)
            return 2
    for name in ("Xvfb", "dbus-run-session", "openbox", "xdotool", "luajit", "ps"):
        if shutil.which(name) is None:
            print("ENVIRONMENT: required executable missing: " + name, file=sys.stderr)
            return 2
    os.environ.setdefault("ERGOPTI_ATSPI_GTK_PYTHON", "/usr/bin/python3")
    try:
        prerequisite = subprocess.run(
            [
                os.environ["ERGOPTI_ATSPI_GTK_PYTHON"],
                "-c",
                "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        native = subprocess.run(
            [
                "luajit",
                "-e",
                "local f=require('ffi'); require('luv'); "
                "for _,n in ipairs({'libatspi.so.0','libglib-2.0.so.0','libgobject-2.0.so.0','libdbus-1.so.3'}) do f.load(n) end",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print("ENVIRONMENT: native prerequisite could not run: " + str(error), file=sys.stderr)
        return 2
    if prerequisite.returncode != 0 or native.returncode != 0:
        print(
            "ENVIRONMENT: Python GTK3 or native LuaJIT/luv/AT-SPI bindings are unavailable",
            file=sys.stderr,
        )
        return 2
    with tempfile.TemporaryDirectory(prefix="ergopti-secure-focus-native-") as directory:
        return qualify(Path(directory))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Interrupted as error:
        print("Interrupted; owned native processes retired.", file=sys.stderr)
        raise SystemExit(128 + error.signum) from error
    except Exception as error:
        print("FAIL: " + str(error), file=sys.stderr)
        raise SystemExit(1) from error
