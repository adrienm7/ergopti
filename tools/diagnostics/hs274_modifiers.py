# tools/diagnostics/hs274_modifiers.py
"""Verify the controlled eight-modifier prefix without discarding HID aliases."""

from hs274_capture import integer, read_capture
from hs274_stream import fixture_drain, fixture_records


# The native stimulus independently uses Carbon's virtual-key constants.
KEYCODES = {224: 59, 225: 56, 226: 58, 227: 55, 228: 62, 229: 60, 230: 61, 231: 54}


def transitions(*, overlap=False):
    """Each physical modifier is pressed and released before the collision pair."""
    edges = [(usage, value) for usage in KEYCODES for value in (1, 0)]
    return edges + ([(225, 1), (229, 1), (225, 0), (229, 0)] if overlap else [])


def validate_modifier_output(native, *, overlap=False):
    """Independently require each Quartz modifier press and release flag."""
    if native.get("modifier_pairs_observed") is not True or native.get("reports_queued") != (26 if overlap else 20):
        raise ValueError("Native modifier stimulus did not complete all reports")
    events = native.get("events", [])
    if len(events) != (24 if overlap else 20):
        raise ValueError("Native modifier output is incomplete")
    masks = (1 << 18, 1 << 17, 1 << 19, 1 << 20)
    for index, keycode in enumerate(KEYCODES.values()):
        mask = masks[index % len(masks)]
        for edge in range(2):
            event = events[index * 2 + edge]
            flags = integer(event.get("flags"), "native modifier flags")
            if event.get("type") != 12 or event.get("keycode") != keycode or bool(flags & mask) != (edge == 0):
                raise ValueError("Native modifier output changed side or edge")
    if overlap:
        if native.get("overlap_observed") is not True:
            raise ValueError("Native overlapping modifier reports were not observed")
        for event, (keycode, shifted) in zip(events[16:20], ((56, True), (60, True), (56, True), (60, False))):
            flags = integer(event.get("flags"), "native overlapping flags")
            if event.get("type") != 12 or event.get("keycode") != keycode or bool(flags & (1 << 17)) != shifted:
                raise ValueError("Native overlapping Shift lost its remaining side")


def validate_modifier_capture(output, device, *, overlap=False):
    """Preserve every raw row and reject missing, duplicated or reordered edges."""
    capture, rows = read_capture(output, device)
    actual = [(row["usage"] if row["has_usage"] else None, row["value"]) for row in rows]
    if actual != transitions(overlap=overlap) + [(41, 1), (41, 0), (44, 1), (44, 0)]:
        raise ValueError(f"Unexpected physical modifier/collision transitions: {actual}")
    return capture


def modifier_drain(device, *, overlap=False):
    """Drain the known trailing pair after validating the complete modifier prefix."""
    complete = fixture_drain(device)

    def drained(stream):
        rows = fixture_records(stream["records"], device)
        keyboard = [(index, row) for index, row in enumerate(rows) if row["has_page"]
                    and row["has_usage"] and row["page"] == 7 and 4 <= row["usage"] <= 255]
        edges = [(row["usage"], row["value"]) for _, row in keyboard]
        expected = transitions(overlap=overlap)
        prefix = edges[:len(expected)]
        if prefix != expected[:len(prefix)]:
            raise ValueError("Modifier drain prefix lost or duplicated a physical edge")
        if len(edges) <= len(expected):
            return False
        index, first = keyboard[len(expected)]
        if (first["usage"], first["value"]) != (41, 1) or index < 2:
            raise ValueError("Modifier drain is missing the trailing Escape pair")
        # The retained independent pair starts with two auxiliary rows before
        # Escape. Its existing verifier checks those rows and every trailing row.
        tail = [dict(row, sequence=sequence) for sequence, row in enumerate(rows[index - 2:], 1)]
        return complete({"records": tail})

    return drained
