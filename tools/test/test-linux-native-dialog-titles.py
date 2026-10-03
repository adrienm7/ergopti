# tools/test/test-linux-native-dialog-titles.py
"""Real public Zenity captions, cancellation and results on an owned X11 display.

Requires Node 22, LuaJIT, Zenity, Xvfb and libXtst. Run inside dbus-run-session;
optional signed runtime prefixes are supplied through the ordinary environment.
No missing prerequisite turns this explicit native profile into a green skip.
"""

import ctypes as c
import json
import os
import select
import subprocess
import time

x = c.CDLL("libX11.so.6")
x.XOpenDisplay.argtypes = [c.c_char_p]
x.XOpenDisplay.restype = c.c_void_p
x.XDefaultRootWindow.argtypes = [c.c_void_p]
x.XDefaultRootWindow.restype = c.c_ulong
x.XQueryTree.argtypes = [
    c.c_void_p,
    c.c_ulong,
    c.POINTER(c.c_ulong),
    c.POINTER(c.c_ulong),
    c.POINTER(c.POINTER(c.c_ulong)),
    c.POINTER(c.c_uint),
]
x.XInternAtom.argtypes = [c.c_void_p, c.c_char_p, c.c_int]
x.XInternAtom.restype = c.c_ulong
x.XGetWindowProperty.argtypes = [
    c.c_void_p,
    c.c_ulong,
    c.c_ulong,
    c.c_long,
    c.c_long,
    c.c_int,
    c.c_ulong,
    c.POINTER(c.c_ulong),
    c.POINTER(c.c_int),
    c.POINTER(c.c_ulong),
    c.POINTER(c.c_ulong),
    c.POINTER(c.c_void_p),
]


class Attrs(c.Structure):
    _fields_ = [
        ("x", c.c_int),
        ("y", c.c_int),
        ("width", c.c_int),
        ("height", c.c_int),
        ("border_width", c.c_int),
        ("depth", c.c_int),
        ("visual", c.c_void_p),
        ("root", c.c_ulong),
        ("klass", c.c_int),
        ("bit_gravity", c.c_int),
        ("win_gravity", c.c_int),
        ("backing_store", c.c_int),
        ("backing_planes", c.c_ulong),
        ("backing_pixel", c.c_ulong),
        ("save_under", c.c_int),
        ("colormap", c.c_ulong),
        ("map_installed", c.c_int),
        ("map_state", c.c_int),
        ("all_event_masks", c.c_long),
        ("your_event_mask", c.c_long),
        ("do_not_propagate_mask", c.c_long),
        ("override_redirect", c.c_int),
        ("screen", c.c_void_p),
    ]


x.XGetWindowAttributes.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(Attrs)]
x.XFree.argtypes = [c.c_void_p]
x.XCloseDisplay.argtypes = [c.c_void_p]
x.XSetInputFocus.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_ulong]
x.XKeysymToKeycode.argtypes = [c.c_void_p, c.c_ulong]
x.XKeysymToKeycode.restype = c.c_uint
x.XFlush.argtypes = [c.c_void_p]
xtest = c.CDLL("libXtst.so.6")
xtest.XTestFakeKeyEvent.argtypes = [c.c_void_p, c.c_uint, c.c_int, c.c_ulong]


class ClientData(c.Union):
    _fields_ = [("b", c.c_char * 20), ("s", c.c_short * 10), ("l", c.c_long * 5)]


class ClientMessage(c.Structure):
    _fields_ = [
        ("type", c.c_int),
        ("serial", c.c_ulong),
        ("send_event", c.c_int),
        ("display", c.c_void_p),
        ("window", c.c_ulong),
        ("message_type", c.c_ulong),
        ("format", c.c_int),
        ("data", ClientData),
    ]


class XEvent(c.Union):
    _fields_ = [("client", ClientMessage), ("padding", c.c_long * 24)]


x.XSendEvent.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_long, c.POINTER(XEvent)]

import pathlib
import tempfile
import shutil
import sys
import signal

root = (
    pathlib.Path(sys.argv[1]).resolve()
    if len(sys.argv) > 1
    else pathlib.Path(__file__).resolve().parents[2]
)
zenity = shutil.which("zenity")
xvfb = shutil.which("Xvfb")
lua = shutil.which("luajit")
assert zenity and xvfb and lua, "native title profile requires actual Zenity, Xvfb and LuaJIT"
r, w = os.pipe()
server = subprocess.Popen(
    [xvfb, "-displayfd", str(w), "-screen", "0", "1024x768x24", "-nolisten", "tcp"],
    pass_fds=[w],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.PIPE,
)
os.close(w)
d = None
try:
    assert select.select([r], [], [], 10)[0], "Xvfb failed to publish its owned display"
    with os.fdopen(r, "r") as display_pipe:
        display = display_pipe.readline().strip()
    assert display.isdecimal(), "Xvfb must publish one complete owned display number"
    env = dict(
        os.environ, DISPLAY=":" + display, GDK_BACKEND="x11", GSK_RENDERER="cairo", GTK_A11Y="none"
    )
    d = x.XOpenDisplay(env["DISPLAY"].encode())
    assert d, "owned X11 display must connect"

    def prop(hwnd, name):
        actual = c.c_ulong()
        fmt = c.c_int()
        n = c.c_ulong()
        left = c.c_ulong()
        buf = c.c_void_p()
        status = x.XGetWindowProperty(
            d,
            hwnd,
            x.XInternAtom(d, name.encode(), 0),
            0,
            65536,
            0,
            0,
            c.byref(actual),
            c.byref(fmt),
            c.byref(n),
            c.byref(left),
            c.byref(buf),
        )
        if status or not buf:
            return None
        try:
            return (
                c.cast(buf, c.POINTER(c.c_ulong))[0]
                if fmt.value == 32
                else c.string_at(buf, n.value)
            )
        finally:
            x.XFree(buf)

    def owned_pids(pid):
        # This container does not publish task/*/children reliably. The kernel's
        # exact process session is exclusive to the start_new_session fixture.
        owners = set()
        for status in pathlib.Path("/proc").glob("[0-9]*/stat"):
            try:
                fields = status.read_text().rsplit(")", 1)[1].split()
                if int(fields[3]) == pid:
                    owners.add(int(status.parent.name))
            except (FileNotFoundError, ProcessLookupError):
                pass
        return owners

    def find_window(pid):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            owners = owned_pids(pid)
            tree_root = c.c_ulong()
            parent = c.c_ulong()
            kids = c.POINTER(c.c_ulong)()
            n = c.c_uint()
            assert x.XQueryTree(
                d,
                x.XDefaultRootWindow(d),
                c.byref(tree_root),
                c.byref(parent),
                c.byref(kids),
                c.byref(n),
            )
            try:
                for i in range(n.value):
                    hwnd = kids[i]
                    attrs = Attrs()
                    native_pid = prop(hwnd, "_NET_WM_PID")
                    if (
                        x.XGetWindowAttributes(d, hwnd, c.byref(attrs))
                        and attrs.map_state == 2
                        and native_pid in owners
                    ):
                        title = prop(hwnd, "_NET_WM_NAME")
                        assert title is not None, (
                            "mapped owned native dialog must publish its actual UTF-8 caption"
                        )
                        return {
                            "pid": native_pid,
                            "hwnd": int(hwnd),
                            "title": title.decode("utf-8"),
                            "mapped": attrs.map_state,
                        }
            finally:
                if kids:
                    x.XFree(kids)
            time.sleep(0.02)
        raise AssertionError("actual owned public dialog must become visible")

    def dismiss(hwnd, accept):
        if accept:
            x.XSetInputFocus(d, hwnd, 2, 0)
            keycode = x.XKeysymToKeycode(d, 0xFF0D)
            assert keycode, "native Return keycode must exist"
            assert xtest.XTestFakeKeyEvent(d, keycode, 1, 0)
            assert xtest.XTestFakeKeyEvent(d, keycode, 0, 0)
        else:
            event = XEvent()
            event.client.type = 33
            event.client.display = d
            event.client.window = hwnd
            event.client.message_type = x.XInternAtom(d, b"WM_PROTOCOLS", 0)
            event.client.format = 32
            event.client.data.l[0] = x.XInternAtom(d, b"WM_DELETE_WINDOW", 0)
            assert x.XSendEvent(d, hwnd, 0, 0, c.byref(event)), (
                "close request must target the owned native window"
            )
        x.XFlush(d)

    policies = [
        ({"prefix": "ErgoptiPlus", "separator": " — "}, "ErgoptiPlus — "),
        ({"prefix": "", "separator": " — "}, ""),
        ({"prefix": "Future", "separator": " :: "}, "Future :: "),
        ({"prefix": 'Quoted "`', "separator": " / "}, 'Quoted "` / '),
        ({"prefix": "Future ; policy", "separator": " : "}, "Future ; policy : "),
    ]
    receipts = []
    with tempfile.TemporaryDirectory(prefix="ergopti-native-caption-") as temporary:
        private = pathlib.Path(temporary)
        for number, (policy, expected_prefix) in enumerate(policies):
            policy_root = private / str(number)
            manifest = policy_root / "static/ergopti_plus/_shared/ui/apps.manifest.json"
            manifest.parent.mkdir(parents=True)
            original = json.loads(
                (root / "static/ergopti_plus/_shared/ui/apps.manifest.json").read_text()
            )
            original["window_title"] = policy
            manifest.write_text(json.dumps(original))
            subprocess.run(
                [
                    "node",
                    "-e",
                    "require(process.argv[1]).main(process.argv[2])",
                    str(root / "tools/codegen/codegen-window-titles.cjs"),
                    str(policy_root),
                ],
                check=True,
                timeout=10,
            )
            shared = root / "static/ergopti_plus/_shared/lua"
            driver = root / "static/ergopti_plus/linux"
            package_path = ";".join(
                [
                    str(policy_root / "static/ergopti_plus/_shared/lua/?.lua"),
                    str(driver / "?.lua"),
                    str(driver / "?/init.lua"),
                    str(shared / "?.lua"),
                    str(shared / "?/init.lua"),
                ]
            )
            for mode, label in [
                ("prompt", "Native entry"),
                ("application", "Native application"),
                ("directory", "Select configuration folder"),
                ("error", "Error"),
                ("empty_error", ""),
            ]:
                for accept in (
                    [False, True] if mode == "prompt" else [mode in ("error", "empty_error")]
                ):
                    worker = private / "worker.lua"
                    worker.write_text(
                        "package.path = "
                        + json.dumps(package_path)
                        + ' .. ";" .. package.path\n'
                        + "local logger=require('tests.helpers').make_logger_stub();local errors=0\n"
                        + "logger.error=function() errors=errors+1 end;package.loaded['logger.shim']=logger\n"
                        + "local releases, restores = 0, 0\n"
                        + "package.loaded['adapters.keyboard_hook'] = {while_released=function(fn) releases=releases+1; local result={fn()}; restores=restores+1; return unpack(result) end}\n"
                        + "local shell=require('adapters.shell_runner')\n"
                        + (
                            "local value=require('ui.text_prompt').ask('Native entry','Preserved native body',' Exact café ')\n"
                            if mode == "prompt"
                            else "local value=require('ui.app_chooser').pick(shell,'Native application')\n"
                            if mode == "application"
                            else "local value=require('ui.config_dir_picker').pick(shell,{default_config_dir=function() return '/tmp' end},{get=function() return 'Select configuration folder' end},'/tmp')\n"
                            if mode == "directory"
                            else "local dialogs\n"
                            "package.loaded['ui.menu.llm_backend_rows']={rows=function(_,ports) dialogs=ports;return {} end}\n"
                            "package.loaded['ui.menu.start_at_login']={enabled=function() return false end}\n"
                            "package.loaded['adapters.storage']={get=function(key,default) if key=='locale' then return 'en' end;return default end,set=function() return false end}\n"
                            "require('infra.locale').set_locale('en')\n"
                            "require('ui.menu.menu_builder').build({llm={is_enabled=function() return false end},_version='native-profile',on_quit=function() end})\n"
                            "assert(type(dialogs)=='table','real menu provider must publish native dialog ports')\n"
                            "local before=errors;dialogs.error('Preserved native error body'"
                            + (",''" if mode == "empty_error" else "")
                            + ");local value='acknowledged|errors:'..(errors-before)\n"
                        )
                        + (
                            "io.write(value);"
                            if mode in ("error", "empty_error")
                            else "io.write(value==nil and 'cancelled' or 'accepted|'..value);"
                        )
                        + "io.write('|modal:'..releases..':'..restores)\n"
                    )
                    child = subprocess.Popen(
                        [lua, str(worker)],
                        env=env,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        start_new_session=True,
                    )
                    try:
                        try:
                            receipt = find_window(child.pid)
                        except BaseException:
                            if child.poll() is not None:
                                bad_out, bad_err = child.communicate()
                                print(
                                    json.dumps(
                                        {
                                            "child_exit": child.returncode,
                                            "stdout": bad_out.decode(),
                                            "stderr": bad_err.decode(),
                                            "worker": worker.read_text(),
                                        }
                                    ),
                                    flush=True,
                                )
                            raise
                        expected_title = (
                            ["ErgoptiPlus", "", "Future", 'Quoted "`', "Future ; policy"][number]
                            if mode == "empty_error"
                            else expected_prefix + label
                        )
                        assert receipt["title"] == expected_title, receipt
                        assert (
                            pathlib.Path("/proc") / str(receipt["pid"]) / "exe"
                        ).resolve() == pathlib.Path(zenity).resolve(), (
                            "caption must belong to the actual Zenity executable"
                        )
                        dismiss(receipt["hwnd"], accept)
                        out, err = child.communicate(timeout=10)
                        assert child.returncode == 0, {
                            "exit": child.returncode,
                            "stderr": err.decode(),
                        }
                        expected = (
                            "acknowledged|errors:0|modal:1:1"
                            if mode in ("error", "empty_error")
                            else "accepted| Exact café |modal:1:1"
                            if accept
                            else "cancelled|modal:1:1"
                        )
                        assert out.decode() == expected, {
                            "expected": expected,
                            "actual": out.decode(),
                            "stderr": err.decode(),
                        }
                        assert not owned_pids(child.pid), "owned dialog process session must retire"
                        tree_root = c.c_ulong()
                        parent = c.c_ulong()
                        kids = c.POINTER(c.c_ulong)()
                        n = c.c_uint()
                        assert x.XQueryTree(
                            d,
                            x.XDefaultRootWindow(d),
                            c.byref(tree_root),
                            c.byref(parent),
                            c.byref(kids),
                            c.byref(n),
                        )
                        try:
                            assert receipt["hwnd"] not in [kids[i] for i in range(n.value)], (
                                "owned native window must retire"
                            )
                        finally:
                            if kids:
                                x.XFree(kids)
                        assert err == b"", {"native_fixture_stderr": err.decode()}
                        receipt.update(
                            policy=number,
                            consumer=mode,
                            accepted=accept,
                            result=out.decode(),
                            stderr=err.decode(),
                        )
                        receipts.append(receipt)
                        print(json.dumps(receipt, ensure_ascii=False), flush=True)
                    finally:
                        if child.poll() is None:
                            os.killpg(child.pid, signal.SIGTERM)
                            out, err = child.communicate(timeout=5)
                            print(
                                json.dumps(
                                    {
                                        "terminated_stdout": out.decode(),
                                        "terminated_stderr": err.decode(),
                                    }
                                ),
                                flush=True,
                            )
    print(json.dumps({"native_cases": len(receipts), "passed": len(receipts)}))
finally:
    if d:
        x.XCloseDisplay(d)
    server.terminate()
    _, server_err = server.communicate(timeout=5)
    print(json.dumps({"xvfb_status": server.returncode, "xvfb_stderr": server_err.decode()}))
    assert server.returncode == 0, server_err
