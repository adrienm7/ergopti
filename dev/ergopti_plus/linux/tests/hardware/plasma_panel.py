#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/plasma_panel.py
#
# A StatusNotifierWatcher whose menu client caches the dbusmenu layout the way
# KDE Plasma's importer (plasma-workspace libdbusmenuqt, DBusMenuImporter) does,
# then clicks one row several times in a row without any reload.
#
# What it models, because the field report of 2026-11-25 (Arch, Plasma 6,
# Wayland: "the tray is not responsive at all, you have to Reload between each
# thing") came from it and a client that refetches everything cannot see it:
#   - a menu is read with GetLayout(id, depth 1): its own rows, not theirs;
#   - opening a submenu sends Event "opened" and AboutToShow, and refetches the
#     submenu only when AboutToShow answers true or the submenu holds no row;
#   - LayoutUpdated(revision, parent) refetches that parent, again at depth 1;
#   - ItemsPropertiesUpdated updates the cached rows' properties by id;
#   - a click is Event "clicked" on the id the cache holds.
# libdbusmenu-glib emits LayoutUpdated on the root (parent 0) and answers false
# to every AboutToShow, so a submenu the cache holds is fetched again only
# under a new row id.
#
# Usage:
#   plasma_panel.py --ready-file F --path "A > B" [--clicks N] [--settle S] [--timeout S]
# Writes F once the watcher owns its name, then prints one JSON report. Exit 0 =
# every click reached a live row, flipped the row's toggle-state as the cache
# shows it and advanced the layout revision; 1 = a check failed; 2 = no
# environment (no PyGObject or no session bus).

import argparse
import json
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
  </interface>
</node>
"""

MENU_INTERFACE = "com.canonical.dbusmenu"


def label_of(properties):
    """The row's visible text: dbusmenu marks a mnemonic with "_" and escapes a literal one as "__"."""
    return "_".join(part.replace("_", "") for part in (properties.get("label") or "").split("__"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--path", required=True)
    parser.add_argument("--clicks", type=int, default=2)
    parser.add_argument("--settle", type=float, default=1.5)
    parser.add_argument("--timeout", type=float, default=40.0)
    args = parser.parse_args()
    labels = [part.strip() for part in args.path.split(" > ") if part.strip()]

    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except GLib.Error as err:
        print(f"ENVIRONMENT: no session bus ({err.message})", file=sys.stderr)
        sys.exit(2)
    loop = GLib.MainLoop()
    items = []
    report = {"clicks": [], "failures": []}
    # The importer's cache: every row's properties by id, every menu's child ids.
    properties, children, pending = {}, {}, set()
    revision = [0]

    def call(method, signature, values, reply=None):
        name, menu = items[-1][0], items[-1][2]
        return bus.call_sync(
            name,
            menu,
            MENU_INTERFACE,
            method,
            GLib.Variant(signature, values),
            GLib.VariantType(reply) if reply else None,
            Gio.DBusCallFlags.NONE,
            5000,
            None,
        )

    def refresh(parent):
        answer, tree = call("GetLayout", "(iias)", (parent, 1, []), "(u(ia{sv}av))").unpack()
        revision[0] = max(revision[0], answer)
        ids = []
        for child in tree[2]:
            child_id, child_properties, _ = child
            properties[child_id] = dict(child_properties)
            ids.append(child_id)
        children[parent] = ids

    def pump(seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            GLib.MainContext.default().iteration(False)
            time.sleep(0.01)
        # The importer coalesces layout updates on a short timer.
        for parent in sorted(pending):
            pending.discard(parent)
            if parent == 0 or parent in children or parent in properties:
                refresh(parent)

    def on_signal(_conn, _sender, _path, _iface, signal_name, params):
        if signal_name == "LayoutUpdated":
            answer, parent = params.unpack()
            revision[0] = max(revision[0], answer)
            pending.add(parent)
        elif signal_name == "ItemsPropertiesUpdated":
            updated, removed = params.unpack()
            for row_id, changed in updated:
                properties.setdefault(row_id, {}).update(changed)
            for row_id, names in removed:
                for name in names:
                    properties.get(row_id, {}).pop(name, None)

    def open_menu(row_id):
        call("Event", "(isvu)", (row_id, "opened", GLib.Variant("i", 0), 0))
        refetch = call("AboutToShow", "(i)", (row_id,), "(b)").unpack()[0]
        if refetch or not children.get(row_id):
            refresh(row_id)
        pump(0.3)

    def find(parent, wanted):
        for row_id in children.get(parent, []):
            row = properties.get(row_id, {})
            if row.get("visible", True) and label_of(row) == wanted:
                return row_id
        return None

    def run():
        name = items[-1][0]
        bus.signal_subscribe(
            name, MENU_INTERFACE, None, None, None, Gio.DBusSignalFlags.NONE, on_signal
        )
        refresh(0)
        for attempt in range(1, args.clicks + 1):
            pump(0.1)
            parent, target = 0, None
            for depth, wanted in enumerate(labels):
                if depth > 0:
                    open_menu(parent)
                target = find(parent, wanted)
                if target is None:
                    seen = [
                        label_of(properties.get(row_id, {})) for row_id in children.get(parent, [])
                    ]
                    report["failures"].append(
                        f"click {attempt}: no row {wanted!r} in the cached menu; rows: {seen}"
                    )
                    break
                parent = target
            if target is None:
                break
            before_state, before_revision = properties[target].get("toggle-state"), revision[0]
            try:
                call("Event", "(isvu)", (target, "clicked", GLib.Variant("i", 0), 0))
            except GLib.Error as err:
                # Plasma drops this error: the click silently does nothing.
                report["failures"].append(
                    f"click {attempt} on cached row {target} refused: {err.message}"
                )
                break
            pump(args.settle)
            # Reopen the path as a person does and read the row the cache now shows.
            parent, shown = 0, None
            for depth, wanted in enumerate(labels):
                if depth > 0:
                    open_menu(parent)
                shown = find(parent, wanted)
                if shown is None:
                    break
                parent = shown
            after_state = properties.get(shown, {}).get("toggle-state") if shown else None
            report["clicks"].append(
                {
                    "row": target,
                    "from": before_state,
                    "to": after_state,
                    "revision": [before_revision, revision[0]],
                }
            )
            if after_state is None or after_state == before_state:
                report["failures"].append(
                    f"click {attempt}: the cached row still shows toggle-state {before_state!r}"
                )
            if revision[0] <= before_revision:
                report["failures"].append(
                    f"click {attempt}: the layout revision stayed at {before_revision}"
                )
        loop.quit()
        return False

    def on_call(_conn, sender, _path, _iface, method, params, invocation):
        if method == "RegisterStatusNotifierItem":
            service = params.unpack()[0]
            item_path = "/StatusNotifierItem"
            if service.startswith("/"):
                service, item_path = sender, service
            menu = bus.call_sync(
                service,
                item_path,
                "org.freedesktop.DBus.Properties",
                "Get",
                GLib.Variant("(ss)", ("org.kde.StatusNotifierItem", "Menu")),
                GLib.VariantType("(v)"),
                Gio.DBusCallFlags.NONE,
                5000,
                None,
            ).unpack()[0]
            items.append((service, item_path, menu))
            GLib.timeout_add(int(args.settle * 1000), run)
        invocation.return_value(None)

    def on_get(_conn, _sender, _path, _iface, prop):
        if prop == "RegisteredStatusNotifierItems":
            return GLib.Variant("as", [name + path for name, path, _ in items])
        if prop == "IsStatusNotifierHostRegistered":
            return GLib.Variant("b", True)
        return GLib.Variant("i", 0)

    node = Gio.DBusNodeInfo.new_for_xml(WATCHER_XML)
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
    if len(report["clicks"]) != args.clicks and not report["failures"]:
        report["failures"].append(f"{len(report['clicks'])} click(s) of {args.clicks} ran")
    print(json.dumps(report, indent=2, ensure_ascii=False))
    sys.exit(1 if report["failures"] else 0)


if __name__ == "__main__":
    main()
