#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/desktop/tray_panel.py
#
# A StatusNotifierWatcher that walks the tray menu the way a person does: it
# opens each submenu of a label path (dbusmenu "opened" then AboutToShow, as
# GNOME's AppIndicator extension and KDE's panel do), clicks the last row, and
# fetches the layout again before the next path, since the application rebuilds
# its menu after a click and every row id changes.
#
# Usage:
#   tray_panel.py --ready-file F [--timeout S] [--click "A > B > C"]...
#                 [--dump-children "A > B"] [--settle S] [--wait-for FILE]
# Writes F once the watcher owns its name, then prints one JSON report:
#   clicks    the paths clicked, in order
#   children  the visible labels directly under --dump-children, after the clicks
#   enabled   the same rows' enabled flags
# Exit 0 = every path was found and clicked; 1 = a path was missing; 2 = no
# environment (no PyGObject or no session bus).

import argparse
import json
import os
import sys
import time

try:
    from gi.repository import Gio, GLib
except ImportError:
    print("ENVIRONMENT: python3-gi (PyGObject) is required", file=sys.stderr)
    sys.exit(2)

WATCHER_XML = """
<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
    <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
    <signal name="StatusNotifierHostRegistered"/>
  </interface>
</node>
"""


def unpack(node):
    """Returns a dbusmenu node as an (id, properties, children) tuple."""
    return node.unpack() if hasattr(node, "unpack") else node


def label_of(properties):
    """The row's visible text: dbusmenu marks a mnemonic with "_" and escapes a literal one as "__"."""
    return "_".join(part.replace("_", "") for part in (properties.get("label") or "").split("__"))


def names_row(label, wanted):
    """A row's label names it, or names it followed by its count or its state.

    Counts and reasons change with each click (« Hotstrings (3011) »,
    « … — Catégorie désactivée »), the name before them does not.
    """
    return label == wanted or label.startswith(wanted + " (") or label.startswith(wanted + " —")


def split_path(text):
    """Splits "A > B > C" into its labels."""
    return [part.strip() for part in text.split(" > ") if part.strip()]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--settle", type=float, default=1.0)
    parser.add_argument("--click", action="append", default=[])
    parser.add_argument("--dump-children")
    # Holds the clicks until this file exists, so the caller can change the
    # world between the menu being published and the person clicking it.
    parser.add_argument("--wait-for")
    args = parser.parse_args()

    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except GLib.Error as err:
        print(f"ENVIRONMENT: no session bus ({err.message})", file=sys.stderr)
        sys.exit(2)
    node = Gio.DBusNodeInfo.new_for_xml(WATCHER_XML)
    loop = GLib.MainLoop()
    items = []
    report = {"clicks": [], "failures": []}

    def call(name, path, method, params, reply):
        return bus.call_sync(
            name,
            path,
            "com.canonical.dbusmenu",
            method,
            params,
            GLib.VariantType(reply) if reply else None,
            Gio.DBusCallFlags.NONE,
            5000,
            None,
        )

    def menu_path(name, item_path):
        reply = bus.call_sync(
            name,
            item_path,
            "org.freedesktop.DBus.Properties",
            "Get",
            GLib.Variant("(ss)", ("org.kde.StatusNotifierItem", "Menu")),
            GLib.VariantType("(v)"),
            Gio.DBusCallFlags.NONE,
            5000,
            None,
        )
        return reply.unpack()[0]

    def walk(name, menu, labels):
        """Opens each submenu of labels and returns the last row's (id, properties)."""
        parent = 0
        found = None
        for depth, wanted in enumerate(labels):
            if parent != 0:
                call(
                    name,
                    menu,
                    "Event",
                    GLib.Variant("(isvu)", (parent, "opened", GLib.Variant("i", 0), 0)),
                    None,
                )
                call(name, menu, "AboutToShow", GLib.Variant("(i)", (parent,)), "(b)")
            tree = call(
                name, menu, "GetLayout", GLib.Variant("(iias)", (parent, 1, [])), "(u(ia{sv}av))"
            ).unpack()[1]
            matches = [
                unpack(child)
                for child in tree[2]
                if names_row(label_of(unpack(child)[1]), wanted)
                and unpack(child)[1].get("visible", True)
            ]
            if len(matches) != 1:
                seen = [label_of(unpack(child)[1]) for child in tree[2]]
                report["failures"].append(
                    f"{len(matches)} row(s) {wanted!r} at depth {depth}; rows: {seen}"
                )
                return None
            found = matches[0]
            parent = found[0]
        return found

    def run():
        name, item_path = items[-1]
        menu = menu_path(name, item_path)
        if args.wait_for:
            while not os.path.exists(args.wait_for):
                GLib.MainContext.default().iteration(False)
                time.sleep(0.05)
        for text in args.click:
            row = walk(name, menu, split_path(text))
            if row is None:
                break
            if row[1].get("enabled", True) is False:
                report["failures"].append(f"{text!r} is greyed out")
                break
            call(
                name,
                menu,
                "Event",
                GLib.Variant("(isvu)", (row[0], "clicked", GLib.Variant("i", 0), 0)),
                None,
            )
            report["clicks"].append(text)
            # The application handles the click on its own loop, then publishes
            # a rebuilt menu; the next walk must read that one.
            deadline = time.monotonic() + args.settle
            while time.monotonic() < deadline:
                GLib.MainContext.default().iteration(False)
                time.sleep(0.05)
        if args.dump_children and not report["failures"]:
            labels = split_path(args.dump_children)
            row = walk(name, menu, labels)
            if row is not None:
                call(
                    name,
                    menu,
                    "Event",
                    GLib.Variant("(isvu)", (row[0], "opened", GLib.Variant("i", 0), 0)),
                    None,
                )
                call(name, menu, "AboutToShow", GLib.Variant("(i)", (row[0],)), "(b)")
                tree = call(
                    name,
                    menu,
                    "GetLayout",
                    GLib.Variant("(iias)", (row[0], 1, [])),
                    "(u(ia{sv}av))",
                ).unpack()[1]
                children = [
                    unpack(child)[1] for child in tree[2] if unpack(child)[1].get("visible", True)
                ]
                report["children"] = [label_of(props) for props in children if label_of(props)]
                report["enabled"] = [
                    props.get("enabled", True) for props in children if label_of(props)
                ]
        loop.quit()
        return False

    def on_call(conn, sender, path, iface, method, params, invocation):
        if method == "RegisterStatusNotifierItem":
            service = params.unpack()[0]
            item_path = "/StatusNotifierItem"
            if service.startswith("/"):
                service, item_path = sender, service
            items.append((service, item_path))
            invocation.return_value(None)
            GLib.timeout_add(int(args.settle * 1000), run)
        else:
            invocation.return_value(None)

    def on_get(conn, sender, path, iface, prop):
        if prop == "RegisteredStatusNotifierItems":
            return GLib.Variant("as", [f"{n}{p}" for n, p in items])
        if prop == "IsStatusNotifierHostRegistered":
            return GLib.Variant("b", True)
        return GLib.Variant("i", 0)

    bus.register_object("/StatusNotifierWatcher", node.interfaces[0], on_call, on_get, None)

    def on_acquired(*_):
        with open(args.ready_file, "w", encoding="utf-8") as handle:
            handle.write("ready\n")

    def on_lost(*_):
        report["failures"].append("could not own org.kde.StatusNotifierWatcher")
        loop.quit()

    Gio.bus_own_name_on_connection(
        bus, "org.kde.StatusNotifierWatcher", Gio.BusNameOwnerFlags.NONE, on_acquired, on_lost
    )

    def on_timeout():
        report["failures"].append(f"no tray item registered within {args.timeout:.0f} s")
        loop.quit()
        return False

    GLib.timeout_add(int(args.timeout * 1000), on_timeout)
    loop.run()
    print(json.dumps(report, indent=2, ensure_ascii=False))
    sys.exit(1 if report["failures"] else 0)


if __name__ == "__main__":
    main()
