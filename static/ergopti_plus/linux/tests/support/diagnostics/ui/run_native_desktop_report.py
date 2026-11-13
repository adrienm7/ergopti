"""Qualify Report/Main launch confirmations with a real private GTK association."""

import argparse
import ctypes
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time


def identity(pid):
    """Read exact kernel identity without accepting PID reuse as ownership."""
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()
    except (FileNotFoundError, ProcessLookupError):
        return None
    return fields[19]


def children():
    """Return only this subreaper's actual adopted descendants."""
    owned = []
    for status in Path("/proc").glob("[0-9]*/stat"):
        try:
            fields = status.read_text().rsplit(") ", 1)[1].split()
            if int(fields[1]) == os.getpid():
                owned.append((int(status.parent.name), fields[19]))
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            pass
    return owned


def main():
    """Transfer GUI lifetime explicitly, then independently clean the test desktop."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", default="luajit")
    parser.add_argument(
        "--mode", choices=("normal", "cancel", "deadline", "enoent", "crash"), required=True
    )
    parser.add_argument("--baseline-root", type=Path)
    args = parser.parse_args()
    assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
    driver = Path(__file__).resolve().parents[4]
    with tempfile.TemporaryDirectory(prefix="ergopti-desktop-report-") as directory:
        root = Path(directory)
        apps, config = root / "data/applications", root / "config"
        apps.mkdir(parents=True)
        config.mkdir()
        xlog = (root / "xserver.log").open("wb")
        xserver = subprocess.Popen(
            ["Xvfb", "-displayfd", "1", "-screen", "0", "800x600x24", "-nolisten", "tcp", "-ac"],
            stdout=subprocess.PIPE,
            stderr=xlog,
        )
        process, receipt = None, None
        try:
            display = xserver.stdout.readline().decode().strip()
            assert display.isdigit(), "private X server failed"
            env = dict(
                os.environ,
                ERGOPTI_TEST_DRIVER_ROOT=str(driver),
                ERGOPTI_DIAGNOSTIC_DESKTOP_PROBE_DIR=directory,
                XDG_CONFIG_HOME=str(config),
                XDG_DATA_HOME=str(root / "data"),
                XDG_STATE_HOME=str(root / "state"),
                XDG_CURRENT_DESKTOP="GNOME",
                NO_AT_BRIDGE="1",
                GTK_A11Y="none",
                DISPLAY=":" + display,
            )
            if args.baseline_root:
                env["ERGOPTI_DESKTOP_BASELINE_ROOT"] = str(args.baseline_root.resolve())
            if args.mode in ("cancel", "deadline", "crash"):
                env.update(
                    XDG_CURRENT_DESKTOP="X-Generic",
                    DESKTOP_SESSION="",
                    DE="generic",
                    KDE_FULL_SESSION="",
                    GNOME_DESKTOP_SESSION_ID="",
                )
            handler = root / "handler.py"
            handler.write_text(
                "import gi,json,os,sys\nfrom pathlib import Path\n"
                "gi.require_version('Gtk','3.0')\ngi.require_version('GdkX11','3.0')\n"
                "from gi.repository import Gtk,GLib,GdkX11\n"
                "p=Path(" + repr(directory) + ")\n"
                "assert Path(sys.argv[1]).read_text()=='Owned synthetic diagnostic document\\n'\n"
                "win=Gtk.Window(title='Owned synthetic file handler')\n"
                "win.add(Gtk.Label(label='Owned synthetic diagnostic document'))\n"
                "win.connect('destroy',Gtk.main_quit)\nwin.show_all()\n"
                "def ready():\n"
                " f=Path('/proc/self/stat').read_text().rsplit(') ',1)[1].split()\n"
                " (p/'ready.tmp').write_text(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp(),"
                "'start_ticks':f[19],'gtk_window_id':win.get_window().get_xid(),"
                "'stdio_devnull':all(os.readlink('/proc/self/fd/'+str(fd))=='/dev/null' for fd in (0,1,2))}))\n"
                " os.replace(p/'ready.tmp',p/'ready')\n return False\n"
                "GLib.idle_add(ready)\nGtk.main()\n"
            )
            (apps / "ergopti-owned-handler.desktop").write_text(
                "[Desktop Entry]\nType=Application\nName=Ergopti owned GTK handler\n"
                "Exec=/usr/bin/python3 "
                + str(handler)
                + " %f\nMimeType=text/plain;\nNoDisplay=true\n"
            )
            (config / "mimeapps.list").write_text(
                "[Default Applications]\ntext/plain=ergopti-owned-handler.desktop\n"
            )
            (root / "report ' literal é.txt").write_text("Owned synthetic diagnostic document\n")
            if args.mode == "enoent":
                absent = root / "no-programs"
                absent.mkdir()
                env["PATH"] = str(absent)
            executable = args.lua if os.path.isabs(args.lua) else shutil.which(args.lua)
            assert executable, "requested Lua interpreter missing"
            admitted_at = time.monotonic()
            process = subprocess.Popen(
                [executable, str(Path(__file__).with_name("native_desktop_report.lua")), args.mode],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if args.mode == "crash":
                ready_deadline = time.monotonic() + 3
                while not (root / "daemon-ready").exists() and time.monotonic() < ready_deadline:
                    time.sleep(0.002)
                owner = json.loads((root / "daemon-ready").read_text())
                assert process.pid == owner["parent_pid"]
                assert identity(process.pid) == owner["parent_start_ticks"]
                assert identity(owner["worker_pid"]) == owner["worker_start_ticks"]
                process.kill()
                stdout, stderr = process.communicate(timeout=2)
                assert process.returncode == -signal.SIGKILL, (
                    "daemon parent was not killed by the supervisor"
                )
                worker_status = None
                while time.monotonic() < admitted_at + 35:
                    reaped, status = os.waitpid(owner["worker_pid"], os.WNOHANG)
                    if reaped:
                        worker_status = os.waitstatus_to_exitcode(status)
                        break
                    time.sleep(0.002)
                assert worker_status == 124, (
                    "the worker did not independently finish its exact watchdog"
                )
                assert identity(owner["worker_pid"]) is None, (
                    "worker still exists after physical wait"
                )
                elapsed_ms = (time.monotonic() - admitted_at) * 1000
                assert 30000 <= elapsed_ms < 35000, (
                    "worker watchdog did not preserve its canonical budget"
                )
                receipt = json.loads((root / "ready").read_text())
                assert identity(receipt["pid"]) == receipt["start_ticks"], (
                    "watchdog killed the transferred GTK application"
                )
                gui_fields = (
                    Path(f"/proc/{receipt['pid']}/stat").read_text().rsplit(") ", 1)[1].split()
                )
                assert gui_fields[0] not in ("Z", "X"), (
                    "a dead GUI is not a surviving desktop intent"
                )
                print(
                    json.dumps(
                        {
                            "mode": "crash",
                            "real_sigkill_parent": True,
                            "watchdog_exit_code": worker_status,
                            "worker_physically_reaped": True,
                            "worker_elapsed_ms": elapsed_ms,
                            "requested_timeout_ms": 30000,
                            "accepted_gui_survived_parent_crash": True,
                        }
                    )
                )
            else:
                stdout, stderr = process.communicate(timeout=38)
            print(stdout.decode(), end="")
            print(stderr.decode(), end="")
            if (root / "ready").exists():
                receipt = json.loads((root / "ready").read_text())
            if args.mode != "enoent":
                assert receipt is not None, "no actual GTK mapped receipt"
            print(
                json.dumps(
                    {
                        "fixture_exit": process.returncode,
                        "home_preserved": env.get("HOME") == os.environ.get("HOME"),
                        "private_xdg_association": True,
                        "cleanup_owner": "external fixture subreaper",
                    }
                )
            )
        finally:
            if process and process.poll() is None:
                process.kill()
                process.wait()
            if receipt and identity(receipt["pid"]) == receipt["start_ticks"]:
                os.kill(receipt["pid"], signal.SIGKILL)
            if xserver.poll() is None:
                xserver.terminate()
            xserver.wait(timeout=2)
            xlog.close()
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                for pid, start_ticks in children():
                    if identity(pid) == start_ticks:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                try:
                    reaped, _ = os.waitpid(-1, os.WNOHANG)
                    if not reaped:
                        time.sleep(0.002)
                except ChildProcessError:
                    break
            assert not children(), "external supervisor retained its own descendants"
            print("EXTERNAL_DESKTOP_CLEANUP owned_children=0 private_display_stopped=true")
        return 0 if args.mode == "crash" else process.returncode if process else 2


if __name__ == "__main__":
    raise SystemExit(main())
