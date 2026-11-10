#!/usr/bin/env python3
"""Print the editable text of one running application, read through AT-SPI.

Usage: atspi_editor_text.py <application-name>
Prints ``TEXT <hex of the UTF-8 bytes>`` and exits 0, or exits 3 when the
application or its editable text is not on the accessibility bus. Hex keeps
spaces, newlines and narrow no-break spaces intact through a pipe.
"""

import sys

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

MAX_DEPTH = 40


def editable_text(node, depth=0):
    """The first editable text node under ``node``, depth first."""
    if node is None or depth > MAX_DEPTH:
        return None
    try:
        states = node.get_state_set()
        if states.contains(Atspi.StateType.EDITABLE) and node.get_text_iface() is not None:
            return node
        count = node.get_child_count()
    except gi.repository.GLib.Error:
        return None
    for index in range(count):
        found = editable_text(node.get_child_at_index(index), depth + 1)
        if found is not None:
            return found
    return None


def main():
    """Find the application and print its text."""
    name = sys.argv[1]
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        application = desktop.get_child_at_index(index)
        if application is None or application.get_name() != name:
            continue
        node = editable_text(application)
        if node is None:
            continue
        text = Atspi.Text.get_text(node, 0, Atspi.Text.get_character_count(node))
        print("TEXT " + text.encode("utf-8").hex())
        return 0
    return 3


if __name__ == "__main__":
    sys.exit(main())
