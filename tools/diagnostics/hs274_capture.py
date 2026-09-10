# tools/diagnostics/hs274_capture.py
"""Validate the finite owned HID capture independently of Quartz output."""

import json

MARKER = "HS274_RAW_CAPTURE "


def unique_object(pairs):
    """Do not let a duplicate JSON field hide a conflicting native value."""
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate native capture field: " + key)
        result[key] = value
    return result


def integer(value, name, minimum=0, maximum=(1 << 64) - 1):
    """Reject coercion and values outside the producer's native representation."""
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"Invalid capture integer: {name}")
    return value


def validate_capture(output, device):
    """Require the exact fixture transitions and an intact, lossless record prefix."""
    integer(device, "expected device", minimum=1)
    lines = [line for line in output.splitlines(keepends=True) if line.startswith(MARKER)]
    if len(lines) != 1 or not lines[0].endswith("\n"):
        raise ValueError("Expected one complete native capture receipt")
    capture = json.loads(lines[0][len(MARKER):], object_pairs_hook=unique_object)
    if not isinstance(capture, dict) or capture.get("coverage") != "fixture_only":
        raise ValueError("Unexpected physical capture coverage")
    records = capture.get("records")
    if not isinstance(records, list) or not records:
        raise ValueError("Native physical capture is empty")
    if integer(capture.get("seen"), "seen") != len(records):
        raise ValueError("Native physical capture lost records")
    for field in ("overflow", "contention"):
        if integer(capture.get(field), field) != 0:
            raise ValueError("Native physical capture reported " + field)
    keyboard = []
    for sequence, row in enumerate(records, 1):
        if not isinstance(row, dict):
            raise ValueError("Invalid native capture record")
        if integer(row.get("sequence"), "sequence", minimum=1) != sequence:
            raise ValueError("Native physical capture sequence gap")
        if integer(row.get("device"), "device", minimum=1) != device:
            raise ValueError("Native physical capture contains another device")
        integer(row.get("timestamp"), "timestamp")
        integer(row.get("value"), "value", -(1 << 63), (1 << 63) - 1)
        for field in ("page", "usage"):
            integer(row.get(field), field, -(1 << 31), (1 << 31) - 1)
        for field in ("has_page", "has_usage"):
            if type(row.get(field)) is not bool:
                raise ValueError("Invalid native usage presence flag")
        if row["has_page"] and row["page"] == 7:
            if row["has_usage"] and row["usage"] == -1:
                # Native auxiliary elements accompany decoded key edges. Keep
                # their original values in the receipt, without another credit.
                continue
            if row["has_usage"] and row["usage"] in (1, 2, 3):
                if row["value"] != 0:
                    raise ValueError("Native capture contains an active HID keyboard error")
                continue
            keyboard.append((row["usage"] if row["has_usage"] else None, row["value"]))
    if keyboard != [(41, 1), (41, 0), (44, 1), (44, 0)]:
        raise ValueError(f"Unexpected physical Escape/Space transitions: {keyboard}")
    return capture
