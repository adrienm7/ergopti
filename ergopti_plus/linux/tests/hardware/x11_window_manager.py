#!/usr/bin/env python3
# tests/hardware/x11_window_manager.py

"""Wait for an X window manager to own the screen, then to manage a window.

A harness that starts openbox and maps its window at once races the window
manager's own start: the window can be mapped before openbox announces EWMH
support, and ``xdotool windowactivate`` then aborts with « Your windowmanager
claims not to support _NET_ACTIVE_WINDOW » (desktop-webview job 133797159970,
run_secure_focus_watch.py). A fixed sleep only moves the race. These waits read
the facts the window manager publishes itself:

1. Ready: the root window's ``_NET_SUPPORTING_WM_CHECK`` names a child window
   whose own ``_NET_SUPPORTING_WM_CHECK`` names itself (EWMH's liveness proof),
   and the root's ``_NET_SUPPORTED`` lists ``_NET_ACTIVE_WINDOW``.
2. Managed: the window carries ``WM_STATE`` NormalState, which the window
   manager writes once it has reparented and mapped it (ICCCM 4.1.3.1), so an
   activation request reaches a window it owns.
"""

import ctypes
import sys
import time

NORMAL_STATE = 1
POLL_SECONDS = 0.02
LONG_LENGTH = 1024


def ready(read):
    """Whether a live EWMH window manager that can activate windows owns the screen.

    ``read(window, name)`` returns the property's 32-bit items, or None when the
    property or the window is absent; window 0 is the root.
    """
    check = read(0, "_NET_SUPPORTING_WM_CHECK")
    if not check or check[0] == 0:
        return False
    if read(check[0], "_NET_SUPPORTING_WM_CHECK") != [check[0]]:
        return False
    supported = read(0, "_NET_SUPPORTED") or []
    return read.atom("_NET_ACTIVE_WINDOW") in supported


def managed(read, window):
    """Whether the window manager has taken the window in and shows it."""
    state = read(window, "WM_STATE")
    return bool(state) and state[0] == NORMAL_STATE


class Display:
    """A libX11 connection that reads 32-bit window properties."""

    def __init__(self, name=None):
        self._x11 = ctypes.CDLL("libX11.so.6")
        x11 = self._x11
        x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x11.XOpenDisplay.restype = ctypes.c_void_p
        x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        x11.XDefaultRootWindow.restype = ctypes.c_ulong
        x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        x11.XInternAtom.restype = ctypes.c_ulong
        x11.XGetWindowProperty.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_long,
            ctypes.c_long,
            ctypes.c_int,
            ctypes.c_ulong,
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_void_p),
        ]
        x11.XGetWindowProperty.restype = ctypes.c_int
        x11.XFree.argtypes = [ctypes.c_void_p]
        x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        # The check window of a window manager that just died is gone: reading it
        # raises BadWindow, whose default handler would exit this process.
        handler_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
        self._errors = 0

        def on_error(_display, _event):
            self._errors += 1
            return 0

        self._handler = handler_type(on_error)
        x11.XSetErrorHandler.argtypes = [handler_type]
        x11.XSetErrorHandler(self._handler)
        self._display = x11.XOpenDisplay(name.encode() if name else None)
        if not self._display:
            raise AssertionError("cannot open the X display " + str(name or "$DISPLAY"))
        self._root = x11.XDefaultRootWindow(self._display)
        self._atoms = {}

    def atom(self, name):
        """The X atom of a name, interned once."""
        if name not in self._atoms:
            self._atoms[name] = self._x11.XInternAtom(self._display, name.encode(), 0)
        return self._atoms[name]

    def __call__(self, window, name):
        """The 32-bit items of a property, or None when it or its window is absent."""
        x11 = self._x11
        actual_type, actual_format = ctypes.c_ulong(), ctypes.c_int()
        count, remaining, data = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_void_p()
        errors = self._errors
        status = x11.XGetWindowProperty(
            self._display,
            window or self._root,
            self.atom(name),
            0,
            LONG_LENGTH,
            0,
            0,
            ctypes.byref(actual_type),
            ctypes.byref(actual_format),
            ctypes.byref(count),
            ctypes.byref(remaining),
            ctypes.byref(data),
        )
        x11.XSync(self._display, 0)
        try:
            if status != 0 or self._errors != errors or actual_format.value != 32 or not data:
                return None
            # Format-32 items arrive as C longs, whatever the server's word size.
            items = ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))
            return [items[index] for index in range(count.value)]
        finally:
            if data:
                x11.XFree(data)

    def close(self):
        """Closes the connection."""
        if self._display:
            self._x11.XCloseDisplay(self._display)
            self._display = None


def wait(predicate, seconds, what):
    """Polls until the predicate holds; fails naming what never happened."""
    deadline = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError(what + f" within {seconds} s")
        time.sleep(POLL_SECONDS)


def wait_until_ready(display, seconds=10):
    """Waits until a window manager that can activate windows owns the screen."""
    wait(lambda: ready(display), seconds, "no EWMH window manager announced _NET_ACTIVE_WINDOW")


def wait_until_managed(display, window, seconds=10):
    """Waits until the window manager has mapped the window as a normal window."""
    wait(
        lambda: managed(display, window),
        seconds,
        f"the window manager did not manage window {window}",
    )


def main(arguments):
    """Command line for shell and Lua harnesses: ``ready`` or ``managed <window>``.

    Exit 0 once the fact holds, 1 when the wait ran out (the reason on stderr).
    """
    display = Display()
    try:
        if arguments == ["ready"]:
            wait_until_ready(display)
        elif len(arguments) == 2 and arguments[0] == "managed":
            wait_until_managed(display, int(arguments[1], 0))
        else:
            sys.stderr.write("usage: x11_window_manager.py ready | managed <window>\n")
            return 2
    except AssertionError as error:
        sys.stderr.write(str(error) + "\n")
        return 1
    finally:
        display.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
