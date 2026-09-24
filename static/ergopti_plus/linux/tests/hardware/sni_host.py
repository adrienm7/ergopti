#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/sni_host.py
#
# A minimal StatusNotifierWatcher + host: the part of a desktop panel that
# decides whether a tray icon exists.
#
# KDE Plasma, GNOME's AppIndicator extension, waybar, xfce4-panel's SNI plugin
# and every other modern Linux tray do the same three things: own
# org.kde.StatusNotifierWatcher on the session bus, accept
# RegisterStatusNotifierItem from applications, then read the item's
# properties and its com.canonical.dbusmenu menu. This script does exactly
# that and nothing else, so "the icon appears" becomes a checkable fact on a
# machine with no panel: an item registered, it carries an icon, and its menu
# holds the rows the daemon built.
#
# Usage:
#   sni_host.py --ready-file F --timeout S [--expect-label TEXT]...
#               [--expect-icon-file] [--exit-after-check]
# Writes F once the watcher owns its name (so the caller starts the app only
# then), and prints one JSON report on stdout. Exit 0 = every expectation held,
# 1 = an expectation failed, 2 = the environment could not host the test.

import argparse
import json
import os
import re
import sys

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


def menu_rows(layout):
    """Flattens a dbusmenu GetLayout tree into (id, visible label) pairs, in order."""
    rows = []
    item_id, props, children = layout
    label = props.get("label")
    if label and props.get("visible", True):
        rows.append((item_id, label.replace("_", "")))
    for child in children:
        rows.extend(menu_rows(child.unpack() if hasattr(child, "unpack") else child))
    return rows


def menu_labels(layout):
    """The visible labels of a dbusmenu GetLayout tree, in order."""
    return [label for _, label in menu_rows(layout)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--expect-label", action="append", default=[])
    parser.add_argument("--expect-icon-file", action="store_true")
    # The indicator registers with an empty menu and the daemon fills it just
    # after: inspecting at once would read that placeholder.
    parser.add_argument("--settle", type=float, default=0.0)
    parser.add_argument("--min-labels", type=int, default=0)
    # A label shaped like "menu.global.reload" is an i18n key the catalogue did
    # not resolve — the whole menu reads like that when the locale files are
    # not found.
    parser.add_argument("--forbid-raw-keys", action="store_true")
    # Clicks the row with this label exactly as a panel does (dbusmenu Event
    # "clicked"), so the application's own handler runs through its real
    # signal path.
    parser.add_argument("--click-label")
    args = parser.parse_args()

    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    node = Gio.DBusNodeInfo.new_for_xml(WATCHER_XML)
    items = []
    loop = GLib.MainLoop()
    report = {"registered": [], "failures": []}

    def on_call(conn, sender, path, iface, method, params, invocation):
        if method == "RegisterStatusNotifierItem":
            service = params.unpack()[0]
            # Ayatana passes an object path and relies on the sender for the
            # bus name; others pass the bus name. Normalise to (name, path).
            if service.startswith("/"):
                items.append((sender, service))
            else:
                items.append((service, "/StatusNotifierItem"))
            conn.emit_signal(None, "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                             "StatusNotifierItemRegistered", GLib.Variant("(s)", (service,)))
            GLib.timeout_add(int(args.settle * 1000), inspect)
        invocation.return_value(None)

    def on_get(conn, sender, path, iface, prop):
        if prop == "RegisteredStatusNotifierItems":
            return GLib.Variant("as", [name + path for name, path in items])
        if prop == "IsStatusNotifierHostRegistered":
            return GLib.Variant("b", True)
        if prop == "ProtocolVersion":
            return GLib.Variant("i", 0)
        return None

    def get_prop(name, path, prop):
        reply = bus.call_sync(name, path, "org.freedesktop.DBus.Properties", "Get",
                              GLib.Variant("(ss)", ("org.kde.StatusNotifierItem", prop)),
                              GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, 5000, None)
        return reply.unpack()[0]

    def inspect():
        name, path = items[-1]
        item = {"service": name, "path": path}
        try:
            for prop in ("Id", "Title", "Status", "IconName", "IconThemePath", "Menu"):
                try:
                    item[prop] = get_prop(name, path, prop)
                except GLib.Error as err:
                    item[prop] = None
                    item.setdefault("errors", []).append(f"{prop}: {err.message}")
            labels = []
            if item.get("Menu"):
                layout = bus.call_sync(name, item["Menu"], "com.canonical.dbusmenu", "GetLayout",
                                       GLib.Variant("(iias)", (0, -1, [])),
                                       GLib.VariantType("(u(ia{sv}av))"),
                                       Gio.DBusCallFlags.NONE, 5000, None)
                rows = menu_rows(layout.unpack()[1])
                labels = [label for _, label in rows]
                if args.click_label:
                    target = [row_id for row_id, label in rows if label == args.click_label]
                    if not target:
                        report["failures"].append(f"no row labelled {args.click_label!r} to click")
                    else:
                        bus.call_sync(name, item["Menu"], "com.canonical.dbusmenu", "Event",
                                      GLib.Variant("(isvu)", (target[0], "clicked", GLib.Variant("i", 0), 0)),
                                      None, Gio.DBusCallFlags.NONE, 5000, None)
                        item["clicked"] = args.click_label
            item["labels"] = labels
        except GLib.Error as err:
            report["failures"].append(f"inspecting {name}{path}: {err.message}")
        report["registered"].append(item)

        if item.get("Status") != "Active":
            report["failures"].append(f"item status is {item.get('Status')!r}, not 'Active' — panels hide it")
        icon = item.get("IconName") or ""
        if not icon:
            report["failures"].append("the item has no IconName — a blank, unclickable panel slot")
        if icon and not icon.startswith("/") and ("/" in icon or icon.startswith(".")):
            # The panel is another process with another working directory: a
            # relative path resolves to nothing there, whatever it names here.
            report["failures"].append(f"icon {icon!r} is a relative path — the panel cannot resolve it")
        if args.expect_icon_file:
            theme = item.get("IconThemePath") or ""
            candidates = [icon] if icon.startswith("/") else [
                os.path.join(theme, icon + ext) for ext in (".png", ".svg", "")]
            if not any(os.path.isfile(c) for c in candidates):
                report["failures"].append(
                    f"icon {icon!r} (theme path {theme!r}) is not the bundled Ergopti logo file")
        if len(labels) < args.min_labels:
            report["failures"].append(f"the menu has {len(labels)} row(s), expected at least {args.min_labels}")
        if args.forbid_raw_keys:
            raw = [label for label in labels if re.fullmatch(r"[a-z_]+(\.[a-z0-9_]+)+", label)]
            if raw:
                report["failures"].append(f"untranslated i18n keys in the menu: {raw[:5]}")
        for expected in args.expect_label:
            if not any(expected in label for label in labels):
                report["failures"].append(f"no menu row contains {expected!r}")
        loop.quit()
        return False

    bus.register_object("/StatusNotifierWatcher", node.interfaces[0], on_call, on_get, None)

    def on_acquired(*_):
        with open(args.ready_file, "w") as fh:
            fh.write("ready\n")

    def on_lost(*_):
        report["failures"].append("could not own org.kde.StatusNotifierWatcher")
        loop.quit()

    Gio.bus_own_name_on_connection(bus, "org.kde.StatusNotifierWatcher",
                                   Gio.BusNameOwnerFlags.NONE, on_acquired, on_lost)

    def on_timeout():
        report["failures"].append(f"no tray item registered within {args.timeout:.0f} s")
        loop.quit()
        return False

    GLib.timeout_add(int(args.timeout * 1000), on_timeout)
    loop.run()
    print(json.dumps(report, indent=2, ensure_ascii=False, default=str))
    sys.exit(1 if report["failures"] else 0)


if __name__ == "__main__":
    main()
