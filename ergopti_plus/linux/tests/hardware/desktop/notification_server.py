#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/desktop/notification_server.py
#
# The part of a desktop that shows notifications: owns
# org.freedesktop.Notifications on the session bus, as GNOME Shell, KDE Plasma,
# dunst and mako do, and appends one JSON line per Notify call (application,
# summary, body, urgency) to a file. The driver's real `notify-send` reaches it
# exactly as it reaches a desktop's own server.
#
# Usage: notification_server.py --ready-file F --log L [--timeout S]
# Writes F once the name is owned. Exit 0 on timeout or SIGTERM; 2 = no
# environment (no PyGObject or no session bus).

import argparse
import json
import signal
import sys

try:
    from gi.repository import Gio, GLib
except ImportError:
    print("ENVIRONMENT: python3-gi (PyGObject) is required", file=sys.stderr)
    sys.exit(2)

SERVER_XML = """
<node>
  <interface name="org.freedesktop.Notifications">
    <method name="Notify">
      <arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/>
      <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/>
      <arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/>
    </method>
    <method name="GetCapabilities"><arg type="as" direction="out"/></method>
    <method name="GetServerInformation">
      <arg type="s" direction="out"/><arg type="s" direction="out"/>
      <arg type="s" direction="out"/><arg type="s" direction="out"/>
    </method>
    <method name="CloseNotification"><arg type="u" direction="in"/></method>
  </interface>
</node>
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args()

    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except GLib.Error as err:
        print(f"ENVIRONMENT: no session bus ({err.message})", file=sys.stderr)
        sys.exit(2)
    loop = GLib.MainLoop()
    counter = [0]

    def on_call(conn, sender, path, iface, method, params, invocation):
        if method == "Notify":
            app, _, _, summary, body, _, hints, _ = params.unpack()
            counter[0] += 1
            with open(args.log, "a", encoding="utf-8") as handle:
                handle.write(
                    json.dumps(
                        {
                            "app": app,
                            "summary": summary,
                            "body": body,
                            "urgency": hints.get("urgency"),
                        },
                        ensure_ascii=False,
                    )
                    + "\n"
                )
            invocation.return_value(GLib.Variant("(u)", (counter[0],)))
        elif method == "GetCapabilities":
            invocation.return_value(GLib.Variant("(as)", (["body"],)))
        elif method == "GetServerInformation":
            invocation.return_value(
                GLib.Variant("(ssss)", ("ergopti-proof", "ergopti", "1", "1.2"))
            )
        else:
            invocation.return_value(None)

    node = Gio.DBusNodeInfo.new_for_xml(SERVER_XML)
    bus.register_object("/org/freedesktop/Notifications", node.interfaces[0], on_call, None, None)

    def on_acquired(*_):
        with open(args.ready_file, "w", encoding="utf-8") as handle:
            handle.write("ready\n")

    Gio.bus_own_name_on_connection(
        bus,
        "org.freedesktop.Notifications",
        Gio.BusNameOwnerFlags.NONE,
        on_acquired,
        lambda *_: loop.quit(),
    )
    GLib.timeout_add(int(args.timeout * 1000), lambda: loop.quit() or False)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, lambda: loop.quit() or False)
    loop.run()
    sys.exit(0)


if __name__ == "__main__":
    main()
