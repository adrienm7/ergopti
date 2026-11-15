#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/wait_a11y_bus.py
"""Wait until the session bus serves the accessibility bus address.

A GTK application asks org.a11y.Bus for the accessibility bus once, when it
starts; one started before at-spi-bus-launcher owns that name never joins the
bus, and every probe of its window reads « inconclusive » for its whole life.
A fixed sleep after launching the bus launcher lost that race on a slow runner,
so the hardware scripts wait for the address itself.

Usage: wait_a11y_bus.py <timeout-seconds>. Exit 0 once the address is served;
2 (environment) when the deadline passes first.
"""

import argparse
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

# One round trip to a bus daemon on the same machine, and the pause between two.
CALL_TIMEOUT_MS = 500
POLL_SECONDS = 0.05


def a11y_address(connection):
    """The address org.a11y.Bus serves, or an empty string while it serves none."""
    try:
        reply = connection.call_sync(
            "org.a11y.Bus",
            "/org/a11y/bus",
            "org.a11y.Bus",
            "GetAddress",
            None,
            GLib.VariantType("(s)"),
            # The launcher this script started, never a second one activated here.
            Gio.DBusCallFlags.NO_AUTO_START,
            CALL_TIMEOUT_MS,
            None,
        )
    except GLib.Error:
        return ""
    return reply.unpack()[0]


def main():
    parser = argparse.ArgumentParser(description="Wait for the accessibility bus")
    parser.add_argument("timeout", type=float)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("the timeout must be positive")
    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        if a11y_address(connection):
            return 0
        time.sleep(POLL_SECONDS)
    print(
        f"ENVIRONMENT: the accessibility bus was not served within {args.timeout:g} s",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
