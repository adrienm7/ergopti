#!/usr/bin/env python3
# tests/hardware/container_session.py
"""A desktop session over the kernel model, for the Linux container proofs.

The proofs close the "To confirm on Linux" checks a cloud container can run
(maintainer decision of 2026-11-10): the real daemon runs unchanged over
tests/hardware/virtual_kernel_preload.c, which stands in for evdev and uinput; the
desktop is a real X server (Xvfb, openbox, the accessibility bus) or a real
Wayland compositor (sway headless); the editor is a real application read back
through AT-SPI or the clipboard.

Run inside a private mount namespace (run_container_proofs.sh does it): the
model's nodes are FIFOs on a tmpfs mounted over /dev/input, and its
/proc/bus/input/devices is bind-mounted over the kernel's, so the production
device finder reads the model as it would read the kernel.
"""

import ctypes
import json
import os
import pathlib
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
DRIVER = HERE.parent.parent
# lua-lgi installs for the distro's Lua 5.1, not under LuaJIT's default paths;
# without it the daemon draws no prediction offer (as run_daemon_live.sh says).
LUA_PATH = (
    "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;"
    "/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;"
)
LUA_CPATH = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;"
EVENT = struct.Struct("@qqHHi")
EV_SYN, EV_KEY, EV_REL = 0, 1, 2
# Pointer buttons and wheel notches as the X server numbers them.
X_BUTTONS = {0x110: 1, 0x111: 3, 0x112: 2}
REL_X, REL_Y, REL_HWHEEL, REL_WHEEL = 0, 1, 6, 8


# Prints {"text", "caret"} of the first widget of the given role (AT-SPI role
# name with underscores: text, password_text), or nothing when there is none.
ATSPI_READER = r"""
import json, sys
import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi
wanted = getattr(Atspi.Role, sys.argv[1].upper())
def walk(node, depth=0):
    if depth > 40:
        return None
    try:
        if node.get_role() == wanted:
            return node
        for index in range(node.get_child_count()):
            found = walk(node.get_child_at_index(index), depth + 1)
            if found:
                return found
    except Exception:
        return None
    return None
desktop = Atspi.get_desktop(0)
for index in range(desktop.get_child_count()):
    found = walk(desktop.get_child_at_index(index))
    if found:
        print(json.dumps({"text": Atspi.Text.get_text(found, 0, -1), "caret": Atspi.Text.get_caret_offset(found)}))
        break
"""


class ProofFailure(AssertionError):
    """One assertion of a proof did not hold."""


def check(condition, message):
    """Raises a ProofFailure carrying `message` unless `condition` holds."""
    if not condition:
        raise ProofFailure(message)
    print("  ok   " + message, flush=True)


def wait_for(predicate, seconds, step=0.1):
    """Polls `predicate` until it returns a truthy value or `seconds` pass."""
    deadline = time.monotonic() + seconds
    while True:
        value = predicate()
        if value or time.monotonic() >= deadline:
            return value
        time.sleep(step)


class Xtest:
    """Delivers key and pointer frames to an X server, as xf86-input-libinput does."""

    def __init__(self, display):
        self.x11 = ctypes.CDLL("libX11.so.6")
        self.xtst = ctypes.CDLL("libXtst.so.6")
        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.display = self.x11.XOpenDisplay(display.encode())
        if not self.display:
            raise RuntimeError("ENVIRONMENT: no X display " + display)
        for name in ("XTestFakeKeyEvent", "XTestFakeButtonEvent"):
            getattr(self.xtst, name).argtypes = [
                ctypes.c_void_p,
                ctypes.c_uint,
                ctypes.c_int,
                ctypes.c_ulong,
            ]
        self.xtst.XTestFakeRelativeMotionEvent.argtypes = [
            ctypes.c_void_p,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_ulong,
        ]
        self.x11.XFlush.argtypes = [ctypes.c_void_p]

    def deliver(self, line):
        kind, code, value = line.split()
        code, value = int(code), int(value)
        if kind == "K" and code in X_BUTTONS:
            self.xtst.XTestFakeButtonEvent(self.display, X_BUTTONS[code], 1 if value else 0, 0)
        elif kind == "K" and value != 2:
            # The X keycode of an evdev code is that code plus 8 (evdev rules).
            self.xtst.XTestFakeKeyEvent(self.display, code + 8, 1 if value else 0, 0)
        elif kind == "R" and code in (REL_WHEEL, REL_HWHEEL) and value != 0:
            button = {
                (REL_WHEEL, True): 4,
                (REL_WHEEL, False): 5,
                (REL_HWHEEL, True): 7,
                (REL_HWHEEL, False): 6,
            }[(code, value > 0)]
            for _ in range(abs(value)):
                self.xtst.XTestFakeButtonEvent(self.display, button, 1, 0)
                self.xtst.XTestFakeButtonEvent(self.display, button, 0, 0)
        elif kind == "R" and code in (REL_X, REL_Y):
            dx, dy = (value, 0) if code == REL_X else (0, value)
            self.xtst.XTestFakeRelativeMotionEvent(self.display, dx, dy, 0)
        self.x11.XFlush(self.display)


class Session:
    """One desktop, one kernel model, one daemon."""

    def __init__(self, desktop, devices, layout="us"):
        if os.geteuid() != 0:
            raise RuntimeError("ENVIRONMENT: the proofs mount over /dev/input and need root")
        self.kind = desktop
        self.layout = layout
        self.devices = devices
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="ergopti-proof-"))
        self.home = self.root / "home"
        self.home.mkdir()
        self.processes = []
        self.desktop_fifo = self.root / "desktop"
        self.status = self.root / "grabs"
        self.frames = self.root / "frames"
        self.uinput = self.root / "uinput"
        self.log = self.root / "daemon.log"
        for path in (self.status, self.frames):
            path.write_text("")
        self.env = dict(
            os.environ,
            HOME=str(self.home),
            XDG_CONFIG_HOME=str(self.home / ".config"),
            XDG_DATA_HOME=str(self.home / ".local/share"),
            LUA_PATH=LUA_PATH,
            LUA_CPATH=LUA_CPATH,
            XKB_DEFAULT_LAYOUT=layout,
            NO_AT_BRIDGE="0",
        )
        self.daemon = None
        self.desktop_writer = None
        self.nodes = {}
        self.hidden = []

    # ----- kernel model ---------------------------------------------------

    def mount_devices(self):
        """Puts the model's nodes and device list where the kernel's are."""
        # A kernel without evdev has no /dev/input: the mount point is made here.
        os.makedirs("/dev/input", exist_ok=True)
        subprocess.run(["mount", "-t", "tmpfs", "tmpfs", "/dev/input"], check=True)
        for device in self.devices:
            node = "/dev/input/event%d" % device["event"]
            os.mkfifo(node, 0o660)
            self.nodes[device["name"]] = os.open(node, os.O_RDWR | os.O_NONBLOCK)
        proc = self.root / "proc_devices"
        proc.write_text(proc_text(self.devices))
        subprocess.run(["mount", "--bind", str(proc), "/proc/bus/input/devices"], check=True)
        os.mkfifo(self.uinput)
        self.preload = build_preload(self.root)
        # Only the daemon runs over the model; the desktop keeps the real libc.
        self.daemon_env = dict(
            preload_env(self.devices, self.status, self.uinput), LD_PRELOAD=str(self.preload)
        )
        # Opened read-write: the writer's open never meets a FIFO without a reader.
        self.uinput_reader = os.open(self.uinput, os.O_RDWR)
        threading.Thread(target=self.read_uinput, daemon=True).start()

    def read_uinput(self):
        """Decodes what the daemon writes to /dev/uinput, frame by frame."""
        pending, buffered = [], b""
        while True:
            chunk = os.read(self.uinput_reader, 4096)
            if not chunk:
                return
            buffered += chunk
            while len(buffered) >= EVENT.size:
                _, _, kind, code, value = EVENT.unpack(buffered[: EVENT.size])
                buffered = buffered[EVENT.size :]
                if kind == EV_SYN and code == 0:
                    with open(self.frames, "a") as log:
                        for row in pending:
                            log.write(row + "\n")
                    for row in pending:
                        if self.desktop_writer:
                            self.to_desktop(row)
                    pending = []
                elif kind == EV_KEY:
                    pending.append("K %d %d" % (code, value))
                elif kind == EV_REL:
                    pending.append("R %d %d" % (code, value))

    def grabbed(self, name):
        """Whether the daemon holds EVIOCGRAB on a model device, from its log."""
        event = next(d["event"] for d in self.devices if d["name"] == name)
        state = None
        for line in self.status.read_text().splitlines():
            parts = line.split()
            if parts[1] == "event%d" % event:
                state = parts[2] == "1"
        return bool(state)

    def physical(self, name, rows):
        """Writes one physical frame per row group, as a device reports them.

        rows: [(type, code, value), ...]; a SYN_REPORT is appended. The desktop
        receives the frame too unless the daemon holds this device's grab, the
        only path the kernel gives an ungrabbed device.
        """
        now = time.time()
        sec, usec = int(now), int((now - int(now)) * 1_000_000)
        payload = b"".join(EVENT.pack(sec, usec, t, c, v) for t, c, v in rows)
        payload += EVENT.pack(sec, usec, EV_SYN, 0, 0)
        os.write(self.nodes[name], payload)
        if not self.grabbed(name):
            for t, c, v in rows:
                if t == EV_KEY:
                    self.to_desktop("K %d %d" % (c, v))
                elif t == EV_REL:
                    self.to_desktop("R %d %d" % (c, v))

    def key(self, name, code, value):
        self.physical(name, [(EV_KEY, code, value)])

    def tap(self, name, code, hold=0.03, gap=0.06):
        self.key(name, code, 1)
        time.sleep(hold)
        self.key(name, code, 0)
        time.sleep(gap)

    def output(self):
        """Every frame row the daemon's virtual keyboard wrote, in order."""
        return [line for line in self.frames.read_text().splitlines() if line]

    def mark(self):
        """The number of output rows so far, to read only what comes after."""
        return len(self.output())

    def since(self, mark):
        return self.output()[mark:]

    # ----- desktop ----------------------------------------------------------

    def spawn(self, argv, **kwargs):
        process = subprocess.Popen(
            argv,
            env=kwargs.pop("env", self.env),
            stdout=kwargs.pop("stdout", subprocess.DEVNULL),
            stderr=kwargs.pop("stderr", subprocess.DEVNULL),
            **kwargs,
        )
        self.processes.append(process)
        return process

    def start_desktop(self):
        os.mkfifo(self.desktop_fifo)
        if self.kind == "x11":
            self.start_x11()
        else:
            self.start_wayland()

    def start_bus(self):
        output = subprocess.run(
            ["dbus-launch", "--sh-syntax"], env=self.env, check=True, capture_output=True, text=True
        ).stdout
        for line in output.splitlines():
            if line.startswith("DBUS_SESSION_BUS_ADDRESS="):
                self.env["DBUS_SESSION_BUS_ADDRESS"] = line.split("=", 1)[1].rstrip(";").strip("'")
            if line.startswith("DBUS_SESSION_BUS_PID="):
                self.bus_pid = int(line.split("=", 1)[1].rstrip(";"))
        launcher = next(
            p
            for p in (
                "/usr/libexec/at-spi-bus-launcher",
                "/usr/lib/at-spi2-core/at-spi-bus-launcher",
            )
            if os.path.exists(p)
        )
        self.spawn([launcher, "--launch-immediately"])
        time.sleep(1)

    def start_x11(self):
        display = ":%d" % (60 + os.getpid() % 30)
        self.spawn(["Xvfb", display, "-screen", "0", "1024x768x24", "-nolisten", "tcp"])
        self.env["DISPLAY"] = display
        self.env["XDG_SESSION_TYPE"] = "x11"
        self.env.pop("WAYLAND_DISPLAY", None)
        wait_for(
            lambda: subprocess.run(["xdpyinfo"], env=self.env, capture_output=True).returncode == 0,
            10,
        )
        if self.layout != "us":
            subprocess.run(["setxkbmap", self.layout], env=self.env, check=True)
        self.start_bus()
        self.spawn(["openbox"])
        time.sleep(1)
        self.xtest = Xtest(display)
        # One key from the XTEST slave before the daemon starts, so the server's
        # core keyboard already follows the device that carries the daemon's
        # output, as it does on a desktop whose keyboard the daemon grabbed once
        # its first key went out. A switch of source slave during the run sends
        # an XKB new-keyboard notify, which revokes the daemon's layout receipt
        # for good today (TODO.md, "Linux X11: a same-group XKB notify").
        self.xtest.deliver("K 42 1")
        self.xtest.deliver("K 42 0")

        def pump():
            with open(self.desktop_fifo, "r") as fifo:
                for line in fifo:
                    if line.strip():
                        self.xtest.deliver(line.strip())

        threading.Thread(target=pump, daemon=True).start()
        self.desktop_writer = open(self.desktop_fifo, "w", buffering=1)

    def start_wayland(self):
        """sway headless (wlroots, with data-control) or mutter headless (GNOME, without)."""
        # A runtime folder of its own: sway names its socket wayland-N itself and
        # reuses a stale name another session left in a shared folder. Short, as
        # a Unix socket path is limited to 108 bytes.
        runtime = pathlib.Path("/run/ergopti-proof-%d" % os.getpid())
        runtime.mkdir(mode=0o700)
        self.runtime = runtime
        self.env["XDG_RUNTIME_DIR"] = str(runtime)
        self.env.pop("DISPLAY", None)
        self.env["XDG_SESSION_TYPE"] = "wayland"
        self.env["GDK_BACKEND"] = "wayland"
        socket = "wayland-ergopti-%d" % os.getpid()
        self.start_bus()
        before = set(os.listdir(runtime))
        if self.kind == "sway":
            self.env["XDG_CURRENT_DESKTOP"] = "sway"
            self.spawn(
                ["sway", "-c", "/dev/null"],
                env=dict(
                    self.env,
                    WLR_BACKENDS="headless",
                    WLR_LIBINPUT_NO_DEVICES="1",
                    WLR_RENDERER="pixman",
                ),
            )
        else:
            self.env["XDG_CURRENT_DESKTOP"] = "GNOME"
            self.spawn(
                [
                    "mutter",
                    "--headless",
                    "--wayland",
                    "--no-x11",
                    "--wayland-display=" + socket,
                    "--virtual-monitor",
                    "1024x768",
                ]
            )
        if self.kind == "sway":
            # sway names its own socket: the new wayland-N in the runtime folder.
            socket = wait_for(
                lambda: next(
                    (
                        n
                        for n in set(os.listdir(runtime)) - before
                        if n.startswith("wayland-") and "." not in n
                    ),
                    None,
                ),
                15,
            )
        if not socket or not wait_for(lambda: (runtime / socket).exists(), 15):
            raise RuntimeError("ENVIRONMENT: %s headless did not start" % self.kind)
        self.env["WAYLAND_DISPLAY"] = socket
        if self.kind == "sway":
            bridge = build_wayland_bridge(self.root)
            self.spawn(
                [str(bridge)],
                stdin=open(self.desktop_fifo, "r", opener=lambda p, f: os.open(p, os.O_RDWR)),
            )
        else:
            # mutter offers no virtual keyboard to a client: the frames are
            # recorded and nothing reaches its (absent) editor.
            threading.Thread(target=self.drain_desktop, daemon=True).start()
        self.desktop_writer = open(self.desktop_fifo, "w", buffering=1)
        time.sleep(0.5)

    def drain_desktop(self):
        with open(self.desktop_fifo, "r") as fifo:
            for _ in fifo:
                pass

    def hide_command(self, name):
        """Makes a command absent for the session (the namespace's view only)."""
        path = shutil.which(name)
        if path:
            subprocess.run(["mount", "--bind", "/dev/null", path], check=True)
            self.hidden.append(path)

    def to_desktop(self, line):
        # A Wayland keyboard carries keys only: pointer frames have no seat here.
        if self.kind != "x11" and (line.startswith("R") or int(line.split()[1]) >= 0x100):
            return
        self.desktop_writer.write(line + "\n")

    def editor(self, path, text=""):
        """Opens a real editor (mousepad) on a file holding `text`."""
        path.write_text(text)
        self.spawn(["mousepad", "--disable-server", str(path)])
        return wait_for(lambda: self.text_widget(), 15)

    # ----- AT-SPI -----------------------------------------------------------

    def editor_state(self, role="text"):
        """(text, caret offset) of the first text widget on this session's bus.

        Read in a child process: the AT-SPI client binds to the first bus it
        meets, and a proof runs several sessions, each with its own bus.
        """
        result = subprocess.run(
            [sys.executable, "-c", ATSPI_READER, role],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        if result.returncode != 0 or not result.stdout:
            return None, None
        state = json.loads(result.stdout)
        return state["text"], state["caret"]

    def text_widget(self, role="text"):
        """Whether a text widget of `role` is on this session's AT-SPI bus."""
        return self.editor_state(role)[0] is not None

    # ----- daemon -----------------------------------------------------------

    def prepare(self, lua_snippet=""):
        """Seeds the private HOME through the real configuration owners."""
        code = 'require("tests.support.live_preferences").daemon()\n' + lua_snippet
        subprocess.run(["luajit", "-e", code], cwd=DRIVER, env=self.env, check=True)
        return self.home / ".config" / config_folder(self.env)

    def start_daemon(self, *extra):
        argv = [
            "luajit",
            "ergopti_hotstrings.lua",
            "--verbose",
            "--config",
            "tests/e2e/fixtures/daemon_keys.toml",
        ] + list(extra)
        self.daemon = subprocess.Popen(
            argv,
            cwd=DRIVER,
            env=dict(self.env, **self.daemon_env),
            stdout=open(self.log, "w"),
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        ready = wait_for(
            lambda: "Daemon ready" in self.log.read_text() or self.daemon.poll() is not None, 60
        )
        if self.daemon.poll() is not None or not ready:
            self.dump_log()
            raise ProofFailure("the daemon did not report itself ready")
        keyboard = next(d["name"] for d in self.devices if d["kind"] == "keyboard")
        check(wait_for(lambda: self.grabbed(keyboard), 10), "the daemon grabbed the model keyboard")
        time.sleep(1.5)

    def alive(self):
        """Whether the daemon still runs and still holds the model keyboard."""
        keyboard = next(d["name"] for d in self.devices if d["kind"] == "keyboard")
        return self.daemon.poll() is None and self.grabbed(keyboard)

    def log_text(self):
        return self.log.read_text(errors="replace") if self.log.exists() else ""

    def dump_log(self, lines=60):
        print("  --- daemon log (last lines) ---")
        for line in self.log_text().splitlines()[-lines:]:
            print("  " + line)

    def stop(self):
        if self.daemon and self.daemon.poll() is None:
            os.killpg(self.daemon.pid, signal.SIGTERM)
            try:
                self.daemon.wait(10)
            except subprocess.TimeoutExpired:
                os.killpg(self.daemon.pid, signal.SIGKILL)
        for process in reversed(self.processes):
            if process.poll() is None:
                process.terminate()
        for process in self.processes:
            try:
                process.wait(5)
            except subprocess.TimeoutExpired:
                process.kill()
        if getattr(self, "bus_pid", None):
            try:
                os.kill(self.bus_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for fd in self.nodes.values():
            os.close(fd)
        for path in self.hidden:
            subprocess.run(["umount", path], check=False)
        subprocess.run(["umount", "/proc/bus/input/devices"], check=False)
        subprocess.run(["umount", "/dev/input"], check=False)
        if getattr(self, "runtime", None):
            shutil.rmtree(self.runtime, ignore_errors=True)
        if not os.environ.get("ERGOPTI_PROOF_KEEP"):
            shutil.rmtree(self.root, ignore_errors=True)


# Capability bits of the model devices, as a real keyboard and a real USB mouse
# report them; the one source for both /proc/bus/input/devices and EVIOCGBIT.
CAPABILITIES = {
    "keyboard": {"ev": [0, 1, 4, 20], "key": list(range(1, 249)), "rel": [], "msc": [4]},
    "mouse": {
        "ev": [0, 1, 2, 4],
        "key": [0x110, 0x111, 0x112, 0x113, 0x114],
        "rel": [0, 1, 6, 8, 11, 12],
        "msc": [4],
    },
}


def bitmap_bytes(bits, size=96):
    out = bytearray(size)
    for bit in bits:
        out[bit // 8] |= 1 << (bit % 8)
    return bytes(out)


def proc_words(bits):
    """A bitmap as /proc/bus/input/devices prints it: 64-bit hex words, high first."""
    value = sum(1 << bit for bit in bits)
    words = []
    while True:
        words.append("%x" % (value & ((1 << 64) - 1)))
        value >>= 64
        if not value:
            break
    return " ".join(reversed(words))


def proc_text(devices):
    blocks = []
    for device in devices:
        caps, event = CAPABILITIES[device["kind"]], device["event"]
        handlers = (
            "sysrq kbd event%d leds" % event
            if device["kind"] == "keyboard"
            else "mouse0 event%d" % event
        )
        lines = [
            "I: Bus=0003 Vendor=feed Product=%04x Version=0111" % event,
            'N: Name="%s"' % device["name"],
            "P: Phys=usb-0000:00:14.0-%d/input0" % event,
            "S: Sysfs=/devices/pci0000:00/0000:00:14.0/usb1/1-%d/input/input%d" % (event, event),
            "U: Uniq=",
            "H: Handlers=" + handlers,
            "B: PROP=0",
            "B: EV=" + proc_words(caps["ev"]),
            "B: KEY=" + proc_words(caps["key"]),
        ]
        if caps["rel"]:
            lines.append("B: REL=" + proc_words(caps["rel"]))
        lines.append("B: MSC=10")
        blocks.append("\n".join(lines) + "\n")
    return "\n".join(blocks) + "\n"


def preload_env(devices, status, uinput):
    env = {
        "ERGOPTI_VK_DEVICES": ",".join(str(d["event"]) for d in devices),
        "ERGOPTI_VK_STATUS": str(status),
        "ERGOPTI_VK_UINPUT": str(uinput),
    }
    for device in devices:
        caps = CAPABILITIES[device["kind"]]
        env["ERGOPTI_VK_DEVICE_%d" % device["event"]] = "|".join(
            [device["name"]]
            + [bitmap_bytes(caps[field]).hex() for field in ("ev", "key", "rel", "msc")]
        )
    return env


def build_preload(root):
    """Compiles the kernel model shim into `root`."""
    library = root / "virtual_kernel_preload.so"
    subprocess.run(
        [
            "gcc",
            "-O1",
            "-shared",
            "-fPIC",
            str(HERE / "virtual_kernel_preload.c"),
            "-o",
            str(library),
            "-ldl",
            "-lpthread",
        ],
        check=True,
    )
    return library


def config_folder(env):
    return subprocess.run(
        ["luajit", "-e", 'io.write(require("app_dirs").linux.folder_name)'],
        cwd=DRIVER,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def build_wayland_bridge(root):
    """Compiles wayland_key_bridge.c against its protocol, into `root`."""
    protocol = HERE / "fixtures" / "wayland" / "virtual-keyboard-unstable-v1.xml"
    header = root / "virtual-keyboard-unstable-v1-client-protocol.h"
    code = root / "virtual-keyboard-unstable-v1-protocol.c"
    subprocess.run(["wayland-scanner", "client-header", str(protocol), str(header)], check=True)
    subprocess.run(["wayland-scanner", "private-code", str(protocol), str(code)], check=True)
    flags = subprocess.run(
        ["pkg-config", "--cflags", "--libs", "wayland-client", "xkbcommon"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()
    binary = root / "wayland_key_bridge"
    subprocess.run(
        [
            "gcc",
            "-O1",
            "-I",
            str(root),
            str(HERE / "wayland_key_bridge.c"),
            str(code),
            "-o",
            str(binary),
        ]
        + flags,
        check=True,
    )
    return binary


def run(proof):
    """Runs `proof(session_factory)` and maps the outcome to the harness exit codes."""
    try:
        proof()
    except ProofFailure as failure:
        print("  FAIL " + str(failure), flush=True)
        return 1
    except RuntimeError as error:
        if str(error).startswith("ENVIRONMENT:"):
            print(str(error), flush=True)
            return 2
        raise
    return 0
