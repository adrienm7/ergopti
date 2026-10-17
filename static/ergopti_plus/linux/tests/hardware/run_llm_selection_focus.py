#!/usr/bin/env python3
# tests/hardware/run_llm_selection_focus.py
"""Prove async AI targeting against same-process, identically titled X11 windows."""

import ctypes
import ctypes.util
import json
import os
import pathlib
import selectors
import subprocess


def main():
    driver = pathlib.Path(__file__).resolve().parents[2]
    x11 = ctypes.CDLL(ctypes.util.find_library("X11"))
    display_t, window_t = ctypes.c_void_p, ctypes.c_ulong
    x11.XOpenDisplay.argtypes, x11.XOpenDisplay.restype = [ctypes.c_char_p], display_t
    x11.XDefaultRootWindow.argtypes, x11.XDefaultRootWindow.restype = [display_t], window_t
    x11.XCreateSimpleWindow.argtypes = [
        display_t,
        window_t,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint,
        ctypes.c_uint,
        ctypes.c_uint,
        ctypes.c_ulong,
        ctypes.c_ulong,
    ]
    x11.XCreateSimpleWindow.restype = window_t
    x11.XInternAtom.argtypes, x11.XInternAtom.restype = (
        [display_t, ctypes.c_char_p, ctypes.c_int],
        ctypes.c_ulong,
    )
    x11.XChangeProperty.argtypes = [
        display_t,
        window_t,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    x11.XStoreName.argtypes = [display_t, window_t, ctypes.c_char_p]
    x11.XMapWindow.argtypes = [display_t, window_t]
    x11.XSelectInput.argtypes = [display_t, window_t, ctypes.c_long]
    x11.XSetInputFocus.argtypes = [display_t, window_t, ctypes.c_int, ctypes.c_ulong]
    x11.XSync.argtypes = [display_t, ctypes.c_int]
    x11.XPending.argtypes, x11.XPending.restype = [display_t], ctypes.c_int
    x11.XNextEvent.argtypes = [display_t, ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [display_t]

    class KeyEvent(ctypes.Structure):
        _fields_ = [
            ("type", ctypes.c_int),
            ("serial", ctypes.c_ulong),
            ("send_event", ctypes.c_int),
            ("display", display_t),
            ("window", window_t),
        ]

    class Event(ctypes.Union):
        _fields_ = [("key", KeyEvent), ("padding", ctypes.c_long * 24)]

    read_fd, write_fd = os.pipe()
    server = subprocess.Popen(
        ["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "800x600x24", "-nolisten", "tcp"],
        pass_fds=(write_fd,),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    os.close(write_fd)
    display, observer = None, None
    try:
        with os.fdopen(read_fd) as ready, selectors.DefaultSelector() as selector:
            selector.register(ready, selectors.EVENT_READ)
            assert selector.select(10), "owned Xvfb did not publish a display"
            name = ":" + ready.readline().strip()
        display = x11.XOpenDisplay(name.encode())
        assert display
        root = x11.XDefaultRootWindow(display)

        def atom(value):
            return x11.XInternAtom(display, value.encode(), 0)

        def property_value(window, property_name, property_type, value):
            native = ctypes.c_ulong(value)
            x11.XChangeProperty(
                display,
                window,
                atom(property_name),
                atom(property_type),
                32,
                0,
                ctypes.byref(native),
                1,
            )

        property_value(root, "_NET_SUPPORTED", "ATOM", atom("_NET_ACTIVE_WINDOW"))
        windows = []
        for x in (0, 300):
            window = x11.XCreateSimpleWindow(display, root, x, 0, 200, 100, 0, 0, 0)
            x11.XStoreName(display, window, b"Owned identical AI title")
            property_value(window, "_NET_WM_PID", "CARDINAL", os.getpid())
            x11.XSelectInput(display, window, 1)  # KeyPressMask, independent target oracle.
            x11.XMapWindow(display, window)
            windows.append(window)

        def focus(window):
            property_value(root, "_NET_ACTIVE_WINDOW", "WINDOW", window)
            x11.XSetInputFocus(display, window, 1, 0)
            x11.XSync(display, 0)

        def events():
            x11.XSync(display, 0)
            pressed = []
            while x11.XPending(display):
                event = Event()
                x11.XNextEvent(display, ctypes.byref(event))
                if event.key.type == 2:
                    pressed.append(event.key.window)
            return pressed

        env = dict(os.environ, DISPLAY=name, XDG_SESSION_TYPE="x11", WAYLAND_DISPLAY="")
        env["LUA_PATH"] = (
            "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;"
            + env.get("LUA_PATH", ";")
        )
        observer = subprocess.Popen(
            ["luajit", "tests/hardware/llm_selection_focus.lua"],
            cwd=driver,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )

        def command(value):
            observer.stdin.write(value + "\n")
            observer.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(observer.stdout, selectors.EVENT_READ)
                assert selector.select(10), "native AI focus command timed out"
            line = observer.stdout.readline()
            assert line, "native AI focus child ended before replying"
            return json.loads(line)

        for suffix in ("", "-prediction"):
            focus(windows[0])
            first = command("start" + suffix)
            assert first["started"] and first["request"] == 1
            assert command("finish" + suffix)["applied"] == 1
            positive = events()
            assert positive and set(positive) == {windows[0]}, (
                "the matching native target must receive real XTest input"
            )

            focus(windows[0])
            second = command("start" + suffix)
            focus(windows[1])  # Programmatic focus change: no pointer/control-key event.
            assert not events(), "switching native focus must not synthesize keyboard input"
            switched = command("probe")
            result = command("finish" + suffix)
            wrong = events()
            assert first["app"] == second["app"] == switched["app"]
            assert first["title"] == second["title"] == switched["title"]
            assert result["applied"] == 0 and not wrong, (
                "AI rewrote another same-app, same-title native window",
                suffix,
                result,
                wrong,
                windows[1],
            )
        print(
            "PASS native same-app/title AI focus: matching tone/prediction targets type; switched targets receive zero output"
        )
    finally:
        if observer is not None:
            observer.terminate()
            observer.communicate(timeout=5)
        if display is not None:
            x11.XCloseDisplay(display)
        server.terminate()
        server.wait(timeout=5)


if __name__ == "__main__":
    main()
