#!/usr/bin/env python3
# tests/hardware/run_window_focus_identity.py

"""Verify the production X11 focus adapter against two identically titled windows.

Run from the Linux driver root with LuaJIT, xdotool, Xvfb and libX11 installed.
The fixture owns its X server and never changes the user's desktop focus.
"""

import ctypes
import ctypes.util
import os
from pathlib import Path
import selectors
import subprocess


def main():
    """Start isolated native windows and query one persistent production adapter."""
    driver_root = Path(__file__).resolve().parents[2]
    read_fd, write_fd = os.pipe()
    server = subprocess.Popen(
        ["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "800x600x24", "-nolisten", "tcp"],
        pass_fds=(write_fd,),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    os.close(write_fd)
    children, observer, display = [], None, None
    x11 = ctypes.CDLL(ctypes.util.find_library("X11"))
    x11.XOpenDisplay.argtypes, x11.XOpenDisplay.restype = [ctypes.c_char_p], ctypes.c_void_p
    x11.XDefaultRootWindow.argtypes, x11.XDefaultRootWindow.restype = (
        [ctypes.c_void_p],
        ctypes.c_ulong,
    )
    x11.XCreateSimpleWindow.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint,
        ctypes.c_uint,
        ctypes.c_uint,
        ctypes.c_ulong,
        ctypes.c_ulong,
    ]
    x11.XCreateSimpleWindow.restype = ctypes.c_ulong
    x11.XInternAtom.argtypes, x11.XInternAtom.restype = (
        [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int],
        ctypes.c_ulong,
    )
    x11.XChangeProperty.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    x11.XStoreName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_char_p]
    x11.XMapWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    try:
        with os.fdopen(read_fd) as ready, selectors.DefaultSelector() as selector:
            selector.register(ready, selectors.EVENT_READ)
            assert selector.select(10), "Xvfb did not publish its display"
            display_name = ":" + ready.readline().strip()
        display = x11.XOpenDisplay(display_name.encode())
        assert display, "XOpenDisplay failed"
        root = x11.XDefaultRootWindow(display)
        active = x11.XInternAtom(display, b"_NET_ACTIVE_WINDOW", 0)
        pid_atom = x11.XInternAtom(display, b"_NET_WM_PID", 0)
        window_type = x11.XInternAtom(display, b"WINDOW", 0)
        cardinal = x11.XInternAtom(display, b"CARDINAL", 0)
        supported = x11.XInternAtom(display, b"_NET_SUPPORTED", 0)
        atom_type = x11.XInternAtom(display, b"ATOM", 0)
        active_atom = ctypes.c_ulong(active)
        x11.XChangeProperty(
            display, root, supported, atom_type, 32, 0, ctypes.byref(active_atom), 1
        )
        windows = []
        for command in (["sleep", "60"], ["tail", "-f", "/dev/null"], None):
            if command is None:
                child = children[0]
            else:
                child = subprocess.Popen(
                    command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )
                children.append(child)
            window = x11.XCreateSimpleWindow(display, root, 0, 0, 200, 100, 0, 0, 0)
            x11.XStoreName(display, window, b"Untitled")
            pid = ctypes.c_ulong(child.pid)
            x11.XChangeProperty(display, window, pid_atom, cardinal, 32, 0, ctypes.byref(pid), 1)
            x11.XMapWindow(display, window)
            windows.append((window, child.pid))
        lua = """
package.path = './?.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;' .. package.path
local adapter = require('adapters.window_info')
local lifecycle = require('adapters.process_lifecycle')
local transitions = 0
lifecycle.onFocusChange(function() transitions = transitions + 1 end)
lifecycle.start()
io.write('ready\\n'); io.flush()
for _ in io.lines() do
	local info = adapter.getFocused()
	lifecycle.tick(1)
	io.write(info.windowTitle .. '\\t' .. info.appId .. '\\t' .. (adapter.focused_identity() or '') .. '\\t' .. transitions .. '\\n')
	io.flush()
end
lifecycle.stop()
"""
        child_env = dict(
            os.environ, DISPLAY=display_name, XDG_SESSION_TYPE="x11", WAYLAND_DISPLAY=""
        )
        observer = subprocess.Popen(
            ["luajit", "-e", lua],
            cwd=driver_root,
            env=child_env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        with selectors.DefaultSelector() as selector:
            selector.register(observer.stdout, selectors.EVENT_READ)
            assert selector.select(10), "native lifecycle did not start"
        assert observer.stdout.readline() == "ready\n", "native lifecycle startup failed"
        for transition, ((window, pid), expected) in enumerate(
            zip(
                [windows[0], windows[1], windows[2], windows[0]],
                ["sleep", "tail", "sleep", "sleep"],
            ),
            start=1,
        ):
            focused = ctypes.c_ulong(window)
            x11.XChangeProperty(display, root, active, window_type, 32, 0, ctypes.byref(focused), 1)
            x11.XSync(display, 0)
            observer.stdin.write("probe\n")
            observer.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(observer.stdout, selectors.EVENT_READ)
                assert selector.select(10), "native focus query did not return"
            actual = observer.stdout.readline().rstrip("\n")
            expected_line = f"Untitled\t{expected}\tx11:{pid}:{window}\t{transition}"
            assert actual == expected_line, f"expected {expected_line!r}, received {actual!r}"
        print("PASS: native X11 focus follows window identity across identical titles")
        print("PASS: native lifecycle invalidates context between identical windows of one process")
    finally:
        if observer is not None:
            observer.terminate()
            observer.communicate(timeout=5)
        for child in children:
            child.terminate()
            child.wait(timeout=5)
        if display is not None:
            x11.XCloseDisplay(display)
        server.terminate()
        server.wait(timeout=5)


if __name__ == "__main__":
    main()
