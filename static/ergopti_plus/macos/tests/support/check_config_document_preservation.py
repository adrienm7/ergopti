"""Independent TOML type/value oracle for a real private-file remap save.

The production owner and file algorithm run through the portable Hammerspoon
ports, so this does not qualify physical macOS input or installed Hammerspoon.
Python's independent tomllib parser supplies the type/kind oracle Lua lacks.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
from pathlib import Path
import subprocess
import tempfile
import tomllib

SOURCE = """[karabiner]
integration_enabled = false
[future]
maximum = 9_223_372_036_854_775_807
precise = 1.2345678901234567
kind = 1.0
empty = []
exponent = 1.2345678901234567e+42
values = [9223372036854775807, 1.0, { precise = 0.12345678901234566, empty = [] }]
[future."with.dot"]
"" = []
[temporal]
date = 1979-05-27
time = 07:32:00.123456
local_datetime = 1979-05-27T07:32:00
utc = 1979-05-27T07:32:00Z
offset = 1979-05-27T07:32:00.123456-07:00
quoted = "1979-05-27"
rows = [1979-05-27, { time = 07:32:00.123456 }]
"""

EXPECTED_FUTURE = {
    "maximum": 9223372036854775807,
    "precise": 1.2345678901234567,
    "kind": 1.0,
    "empty": [],
    "exponent": 1.2345678901234567e42,
    "values": [
        9223372036854775807,
        1.0,
        {"precise": 0.12345678901234566, "empty": []},
    ],
    "with.dot": {"": []},
}
EXPECTED_TEMPORAL = {
    "date": datetime.date(1979, 5, 27),
    "time": datetime.time(7, 32, 0, 123456),
    "local_datetime": datetime.datetime(1979, 5, 27, 7, 32),
    "utc": datetime.datetime(1979, 5, 27, 7, 32, tzinfo=datetime.timezone.utc),
    "offset": datetime.datetime(
        1979,
        5,
        27,
        7,
        32,
        0,
        123456,
        tzinfo=datetime.timezone(datetime.timedelta(hours=-7)),
    ),
    "quoted": "1979-05-27",
    "rows": [datetime.date(1979, 5, 27), {"time": datetime.time(7, 32, 0, 123456)}],
}
EXPECTED = {
    "karabiner": {"integration_enabled": False},
    "future": EXPECTED_FUTURE,
    "temporal": EXPECTED_TEMPORAL,
    "tap_holds": {"timeout_ms": 1234},
}

OWNER_PROBE = r"""
local root, path = assert(arg[1]), assert(arg[2])
package.path = root .. "/static/ergopti_plus/macos/?.lua;"
    .. root .. "/static/ergopti_plus/macos/?/init.lua;"
    .. root .. "/static/ergopti_plus/macos/tests/stubs/?.lua;"
    .. root .. "/static/ergopti_plus/_shared/lua/?.lua;"
    .. root .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local helpers = require("tests.helpers")
local Config = helpers.load_with_stubs("platform.remap.config")
local candidate = Config.build_default_state({ { id = "tab" } }, {})
candidate.enabled = nil
candidate.tap_hold_timeout_ms = 1234
local saved, detail, receipt = Config.save_user_config(candidate, path)
print("saved=" .. tostring(saved) .. " detail=" .. tostring(detail) .. " receipt=" .. type(receipt))
assert(saved == true, tostring(detail))
"""


def same_typed(actual: object, expected: object) -> bool:
    """Compare the complete handwritten model, including int/float/list kinds."""
    if type(actual) is not type(expected):
        return False
    if isinstance(expected, dict):
        return actual.keys() == expected.keys() and all(
            same_typed(actual[key], value) for key, value in expected.items()
        )
    if isinstance(expected, list):
        return len(actual) == len(expected) and all(
            same_typed(left, right) for left, right in zip(actual, expected)
        )
    return actual == expected


def check_owned_signed_zero(root: Path, receipts: Path, runtime: str) -> list[dict]:
    """Publish handwritten owned zero mutations through the actual Config owner."""
    rows = []
    vectors = [
        ("-0.0", "0.0", 1.0, 0.0),
        ("0.0", "-0.0", -1.0, -0.0),
        ("-0.0", "-0.0", -1.0, -0.0),
        ("0.0", "0.0", 1.0, 0.0),
        ("0.0", "0", 1.0, 0),
    ]
    for index, (original, changed, sign, expected) in enumerate(vectors):
        with tempfile.TemporaryDirectory(prefix="ergopti-owned-zero-", dir=receipts) as temporary:
            path = Path(temporary)
            configuration, probe = path / "config.toml", path / "probe.lua"
            source = f"[tap_holds]\ntimeout_ms = {original}\n"
            configuration.write_text(source, encoding="utf-8", newline="\n")
            probe.write_text(
                OWNER_PROBE.replace(
                    "candidate.tap_hold_timeout_ms = 1234",
                    "candidate.tap_hold_timeout_ms = tonumber(assert(arg[3]))",
                ),
                encoding="utf-8",
                newline="\n",
            )
            result = subprocess.run(
                [runtime, str(probe), str(root), str(configuration), changed],
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            published = configuration.read_text(encoding="utf-8")
        (receipts / f"owned-zero-{index}.log").write_text(result.stdout, encoding="utf-8")
        (receipts / f"owned-zero-{index}.toml").write_text(published, encoding="utf-8")
        parsed = tomllib.loads(published)
        value = parsed.get("tap_holds", {}).get("timeout_ms")
        rows.append(
            {
                "original": original,
                "requested": changed,
                "owner_exit": result.returncode,
                "checks": {
                    "complete_typed_model": same_typed(
                        parsed, {"tap_holds": {"timeout_ms": expected}}
                    ),
                    "requested_numeric_kind": type(value) is type(expected),
                    "requested_sign": isinstance(value, (int, float))
                    and math.copysign(1.0, value) == sign,
                    "exact_zero_token": f"timeout_ms = {changed}\n" in published,
                },
            }
        )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--runtime", default="lua5.4")
    parser.add_argument("--receipts", type=Path, required=True)
    args = parser.parse_args()
    root, receipts = args.repository.resolve(), args.receipts.resolve()
    receipts.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ergopti-toml-document-", dir=receipts) as temporary:
        path = Path(temporary)
        configuration, probe = path / "config.toml", path / "probe.lua"
        configuration.write_text(SOURCE, encoding="utf-8", newline="\n")
        probe.write_text(OWNER_PROBE, encoding="utf-8", newline="\n")
        result = subprocess.run(
            [args.runtime, str(probe), str(root), str(configuration)],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        (receipts / "owner.log").write_text(result.stdout, encoding="utf-8")
        published = configuration.read_text(encoding="utf-8")
        (receipts / "source.toml").write_text(SOURCE, encoding="utf-8")
        (receipts / "published.toml").write_text(published, encoding="utf-8")
    parsed = tomllib.loads(published)
    checks = {
        "complete_typed_model": same_typed(parsed, EXPECTED),
        "complete_future_model": same_typed(parsed.get("future"), EXPECTED_FUTURE),
        "complete_temporal_model": same_typed(parsed.get("temporal"), EXPECTED_TEMPORAL),
        "requested_owned_value": same_typed(parsed.get("tap_holds"), {"timeout_ms": 1234}),
        "maximum_integer_token": "maximum = 9_223_372_036_854_775_807\n" in published,
        "precise_float_token": "precise = 1.2345678901234567\n" in published,
        "float_kind_token": "kind = 1.0\n" in published,
        "exponent_token": "exponent = 1.2345678901234567e+42\n" in published,
        "date_unquoted_token": "date = 1979-05-27\n" in published,
        "time_unquoted_token": "time = 07:32:00.123456\n" in published,
        "offset_unquoted_token": "offset = 1979-05-27T07:32:00.123456-07:00\n" in published,
    }
    signed_zero = check_owned_signed_zero(root, receipts, args.runtime)
    receipt = {
        "owned_signed_zero": signed_zero,
        "runtime": args.runtime,
        "owner_exit": result.returncode,
        "checks": checks,
        "actual_model_repr": repr(parsed),
        "source_sha256": hashlib.sha256(SOURCE.encode()).hexdigest(),
        "published_sha256": hashlib.sha256(published.encode()).hexdigest(),
    }
    (receipts / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt, indent=2))
    return (
        0
        if result.returncode == 0
        and all(checks.values())
        and all(row["owner_exit"] == 0 and all(row["checks"].values()) for row in signed_zero)
        else 1
    )


if __name__ == "__main__":
    raise SystemExit(main())
