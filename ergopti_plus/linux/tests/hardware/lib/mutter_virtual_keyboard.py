#!/usr/bin/env python3
"""A virtual keyboard in a headless mutter, through its RemoteDesktop D-Bus API.

Mutter gives XWayland its keymap only once a keyboard exists; a headless
session has none. This opens a RemoteDesktop session (kept open as long as
this process holds its D-Bus connection), prints ``READY``, then reads lines
``key <evdev code> <1|0>`` from stdin and presses or releases that key.
"""

import sys

from gi.repository import Gio, GLib

BUS_NAME = "org.gnome.Mutter.RemoteDesktop"
SESSION_INTERFACE = "org.gnome.Mutter.RemoteDesktop.Session"


def call(bus, path, interface, method, args=None, reply=None):
    """One synchronous call on the RemoteDesktop service."""
    reply_type = GLib.VariantType(reply) if reply else None
    return bus.call_sync(
        BUS_NAME, path, interface, method, args, reply_type, Gio.DBusCallFlags.NONE, -1, None
    )


def main():
    """Open the session and replay the key lines."""
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    path = call(
        bus, "/org/gnome/Mutter/RemoteDesktop", BUS_NAME, "CreateSession", None, "(o)"
    ).unpack()[0]
    call(bus, path, SESSION_INTERFACE, "Start")
    print("READY", flush=True)
    for line in sys.stdin:
        parts = line.split()
        if len(parts) == 3 and parts[0] == "key":
            pressed = GLib.Variant("(ub)", (int(parts[1]), parts[2] == "1"))
            call(bus, path, SESSION_INTERFACE, "NotifyKeyboardKeycode", pressed)
            print("OK", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
