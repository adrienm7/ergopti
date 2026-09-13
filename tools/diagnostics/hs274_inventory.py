# tools/diagnostics/hs274_inventory.py
"""Retain every native leaf inventory without claiming snapshot synchronization."""

import json

from hs274_capture import integer, unique_object
from hs274_stream import decimal

MARKER = "HS274_KEY_INVENTORY "


def read_inventories(output, fixture_device):
    """Require the controlled fixture's observations, retaining other devices too."""
    expected = integer(fixture_device, "expected fixture device", minimum=1)
    records, fixture = [], []
    for line in output.splitlines(keepends=True):
        if not line.startswith(MARKER):
            continue
        if not line.endswith("\n"):
            raise ValueError("Incomplete native key inventory")
        row = json.loads(line[len(MARKER):], object_pairs_hook=unique_object)
        if not isinstance(row, dict) or set(row) != {
                "version", "device", "coverage", "capacity", "enumerated", "exhausted", "elements", "readable"}:
            raise ValueError("Invalid native key inventory envelope")
        if type(row["version"]) is not int or row["version"] != 2 or row["coverage"] != "fixture_only":
            raise ValueError("Unsupported native key inventory")
        device = decimal(row["device"], minimum=1)
        if any(type(row[field]) is not bool for field in ("enumerated", "exhausted", "readable")):
            raise ValueError("Invalid native key inventory flags")
        capacity = integer(row["capacity"], "native inventory capacity", minimum=1, maximum=(1 << 32) - 1)
        if not isinstance(row["elements"], list) or len(row["elements"]) > capacity:
            raise ValueError("Invalid native key inventory bound")
        if row["readable"] and (not row["enumerated"] or row["exhausted"] or not row["elements"]):
            raise ValueError("Contradictory native key inventory")
        records.append(row)
        if device == expected:
            fixture.append(row)
    if not fixture or any(not row["readable"] for row in fixture):
        raise ValueError("Controlled fixture key inventory was not readable")
    return records
