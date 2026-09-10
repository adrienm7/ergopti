# tools/diagnostics/hs274_stream.py
"""Validate complete stream frames and compare them with independent native capture."""

import json
import uuid
from pathlib import Path

from hs274_capture import integer, unique_object


def decimal(value, minimum=0, maximum=(1 << 64) - 1):
    """Require exact canonical decimal strings, without numeric coercion."""
    if not isinstance(value, str) or not value or not value.isascii():
        raise ValueError("Expected an ASCII decimal string")
    if len(value) > len(str(minimum)) + len(str(maximum)):
        raise ValueError("Stream decimal is too long")
    parsed = int(value)
    if str(parsed) != value:
        raise ValueError("Noncanonical stream decimal")
    return integer(parsed, "stream decimal", minimum, maximum)


def read_stream(output, partial=False):
    """During observation, inspect only complete lines; final reads reject truncation."""
    if partial:
        output = output[:output.rfind("\n") + 1]
        if not output:
            return None
    if not output or not output.endswith("\n"):
        raise ValueError("Missing or truncated stream receipt")
    frames = [json.loads(line, object_pairs_hook=unique_object) for line in output.splitlines()]
    opened = frames[0]
    fields = {"version", "kind", "coverage", "incarnation", "lease"}
    if not isinstance(opened, dict) or set(opened) != fields or opened.get("kind") != "opened":
        raise ValueError("Missing stream handshake")
    if type(opened["version"]) is not int or opened["version"] != 1 or opened["coverage"] != "fixture_only":
        raise ValueError("Unexpected stream protocol or coverage")
    incarnation = opened["incarnation"]
    if not isinstance(incarnation, str):
        raise ValueError("Invalid producer incarnation")
    identifier = uuid.UUID(incarnation)
    if not identifier.int or str(identifier) != incarnation:
        raise ValueError("Noncanonical producer incarnation")
    decimal(opened["lease"], minimum=1)
    records = []
    for frame in frames[1:]:
        if not isinstance(frame, dict) or set(frame) != fields | {"records"} or frame.get("kind") != "batch":
            raise ValueError("Unexpected stream frame or lost coverage")
        for field in fields - {"kind"}:
            if type(frame[field]) is not type(opened[field]) or frame[field] != opened[field]:
                raise ValueError("Stream session identity changed")
        if not isinstance(frame["records"], list) or not frame["records"]:
            raise ValueError("Empty or invalid published batch")
        for row in frame["records"]:
            expected = {"sequence", "device", "timestamp", "value", "has_page", "has_usage", "page", "usage"}
            if not isinstance(row, dict) or set(row) != expected:
                raise ValueError("Invalid stream record fields")
            decoded = dict(row)
            for field in ("sequence", "device", "timestamp"):
                decoded[field] = decimal(row[field], minimum=0 if field == "timestamp" else 1)
            decoded["value"] = decimal(row["value"], -(1 << 63), (1 << 63) - 1)
            for field in ("page", "usage"):
                integer(row[field], field, -(1 << 31), (1 << 31) - 1)
            for field in ("has_page", "has_usage"):
                if type(row[field]) is not bool:
                    raise ValueError("Invalid stream usage presence flag")
            if decoded["sequence"] != len(records) + 1:
                raise ValueError("Stream sequence is missing, duplicated or reordered")
            records.append(decoded)
    return {"opened": opened, "records": records}


def validate_stream(output, capture):
    """Every delivered value must match the separately recorded producer receipt."""
    stream = read_stream(output)
    if not stream["records"] or stream["records"] != capture["records"]:
        raise ValueError("Stream differs from independent native capture")
    return stream


def fixture_drain(device):
    """Require the complete recorded fixture shape, including trailing auxiliaries."""
    reference = json.loads((Path(__file__).with_name("fixtures") / "hs274-native-capture.json").read_text(encoding="utf-8"))
    expected = [{key: value for key, value in row.items() if key not in ("timestamp", "device")}
                for row in reference["records"]]
    if not expected:
        raise ValueError("Missing native fixture drain reference")

    def complete(stream):
        rows = stream["records"]
        if len(rows) > len(expected):
            raise ValueError("Native fixture emitted additional records before drain")
        for index, row in enumerate(rows):
            actual = {key: value for key, value in row.items() if key not in ("timestamp", "device")}
            if row["device"] != device or actual != expected[index]:
                raise ValueError("Native fixture stream differs from its drain reference")
        return len(rows) == len(expected)

    return complete


def validate_interruption(output, expected_opened):
    """Require one explicit terminal loss for the new idle observation lease."""
    lines = output.splitlines(keepends=True)
    if len(lines) != 2 or any(not line.endswith("\n") for line in lines):
        raise ValueError("Missing or unexpected interruption frames")
    opened = read_stream(lines[0])["opened"]
    if opened != expected_opened:
        raise ValueError("Interruption belongs to another capture session")
    terminal = json.loads(lines[1], object_pairs_hook=unique_object)
    expected = dict(opened, kind="lost", reason="interrupted")
    if not isinstance(terminal, dict) or set(terminal) != set(expected) or any(
            type(terminal[key]) is not type(value) or terminal[key] != value for key, value in expected.items()):
        raise ValueError("Capture did not report the expected monitor interruption")
    return {"opened": opened, "terminal": terminal}
