# tools/diagnostics/hs274_baseline.py
"""Validate the finite native acquisition probe without inventing held state."""

import json
import time

from hs274_capture import integer, unique_object, read_capture
from hs274_stream import decimal

MARKER = "HS274_BASELINE_PROBE "


def read_baseline(output, device):
    """Retain native refusals, but never publish held state from a failed query."""
    integer(device, "expected baseline device", minimum=1)
    lines = [line for line in output.splitlines(keepends=True) if line.startswith(MARKER)]
    if len(lines) != 1 or not lines[0].endswith("\n"):
        raise ValueError("Expected one complete native baseline probe")
    probe = json.loads(lines[0][len(MARKER):], object_pairs_hook=unique_object)
    if not isinstance(probe, dict) or set(probe) != {"device", "coverage", "enumerated", "exhausted", "elements"}:
        raise ValueError("Unexpected baseline probe fields")
    if decimal(probe["device"], minimum=1) != device or probe["coverage"] != "fixture_only":
        raise ValueError("Unexpected baseline device or coverage")
    if any(type(probe[field]) is not bool for field in ("enumerated", "exhausted")):
        raise ValueError("Invalid baseline inventory flags")
    if not isinstance(probe["elements"], list) or len(probe["elements"]) > 2:
        raise ValueError("Invalid baseline element inventory")
    cookies, values = set(), {}
    acquired = probe["enumerated"] and not probe["exhausted"]
    previous_finish = 0
    for element in probe["elements"]:
        if not isinstance(element, dict) or set(element) != {"page", "usage", "cookie", "cached", "updated"}:
            raise ValueError("Invalid baseline element fields")
        page = integer(element["page"], "baseline page", maximum=(1 << 32) - 1)
        usage = integer(element["usage"], "baseline usage", maximum=(1 << 32) - 1)
        cookie = integer(element["cookie"], "baseline cookie", maximum=(1 << 32) - 1)
        if page != 7 or usage not in (41, 44) or usage in values or cookie in cookies:
            raise ValueError("Unexpected or duplicated baseline element")
        cookies.add(cookie)
        values[usage] = None
        for mode in ("cached", "updated"):
            sample = element[mode]
            fields = {"status", "returned_value", "started", "finished"}
            if not isinstance(sample, dict) or not fields <= set(sample):
                raise ValueError("Invalid baseline read fields")
            status = integer(sample["status"], "baseline status", -(1 << 31), (1 << 31) - 1)
            if type(sample["returned_value"]) is not bool:
                raise ValueError("Invalid baseline value presence")
            valid = status == 0 and sample["returned_value"]
            if set(sample) != fields | ({"timestamp", "value", "value_cookie"} if valid else set()):
                raise ValueError("Untrusted or missing baseline value fields")
            started, finished = decimal(sample["started"]), decimal(sample["finished"])
            if not previous_finish <= started <= finished:
                raise ValueError("Baseline query timestamps are reversed")
            previous_finish = finished
            if valid:
                if integer(sample["value_cookie"], "baseline value cookie", maximum=(1 << 32) - 1) != cookie:
                    raise ValueError("Baseline value belongs to another element")
                if decimal(sample["timestamp"]) > finished:
                    raise ValueError("Baseline value timestamp is in the future")
                value = decimal(sample["value"], maximum=1)
                if mode == "updated":
                    values[usage] = value
            elif mode == "updated":
                acquired = False
    acquired = acquired and set(values) == {41, 44}
    return {"probe": probe, "acquired": acquired, "held": values if acquired else None}


def require_held_baseline(output, device, expected):
    """Require the explicitly controlled fixture state, not merely successful I/O."""
    if type(expected) is not dict or set(expected) != {41, 44} or any(
            type(value) is not int or value not in (0, 1) for value in expected.values()):
        raise ValueError("Invalid expected fixture baseline")
    result = read_baseline(output, device)
    if not result["acquired"] or result["held"] != expected:
        raise ValueError("Native acquisition did not establish the controlled held baseline")
    return result


def wait_baseline(path, process, device, seconds):
    """Wait for the same live producer's complete startup probe, without restarting."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("Core exited before the baseline probe completed")
        output = path.read_text(encoding="utf-8") if path.is_file() else ""
        if any(line.startswith(MARKER) and line.endswith("\n") for line in output.splitlines(keepends=True)):
            return read_baseline(output, device)
        time.sleep(0.1)
    raise RuntimeError("Native baseline probe timed out")


def validate_baseline_native(native, probe):
    """Keep inherited observations separate from the explicitly new Space pair."""
    if any(native.get(field) is not True for field in (
            "baseline_mode", "baseline_down_observed", "space_pair_observed", "metadata_restored", "metadata_work_completed")):
        raise ValueError("Native held fixture did not complete its owned lifecycle")
    if native.get("transport_error") is not False or integer(native.get("reports_queued"), "baseline reports") != 4:
        raise ValueError("Held fixture report delivery failed")
    inherited = native.get("baseline_events")
    if not isinstance(inherited, list) or not any(
            row.get("type") == 10 and row.get("keycode") == 49 for row in inherited if isinstance(row, dict)):
        raise ValueError("Missing independently observed initial held Space")
    fresh = native.get("events")
    if not isinstance(fresh, list) or [(row["type"], row["keycode"]) for row in fresh] != [(10, 49), (11, 49)]:
        raise ValueError("Fresh Space pair was lost or mixed with inherited output")
    released = decimal(native.get("baseline_release_at"), minimum=1)
    if not probe["acquired"] or probe["held"] != {41: 0, 44: 1}:
        raise ValueError("Probe did not acquire the controlled held Space")
    if any(decimal(element["updated"]["finished"]) > released for element in probe["probe"]["elements"]):
        raise ValueError("Fixture released Space before the acquisition completed")
    return released


def validate_baseline_capture(output, device, released):
    """Check the known fixture's release/new-press boundary, preserving all raw rows."""
    integer(released, "baseline release boundary", minimum=1)
    capture, keyboard = read_capture(output, device)
    inherited, fresh = [], []
    for row in keyboard:
        edge = (row["usage"] if row["has_usage"] else None, row["value"])
        (inherited if row["timestamp"] < released else fresh).append(edge)
    if any(edge != (44, 1) for edge in inherited) or fresh != [(44, 0), (44, 1), (44, 0)]:
        raise ValueError("Raw held fixture did not preserve release and the fresh physical press")
    return capture
