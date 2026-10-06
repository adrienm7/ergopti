# tools/diagnostics/native_global_switcher/probe_receipts.py
"""Independent acceptance for native observations; post return is never evidence."""

PHASES = [
    {"tag": 0x47534F01, "key": 55, "type": "flagsChanged", "cmd": True},
    {"tag": 0x47534F02, "key": 48, "type": "keyDown", "cmd": True},
    {"tag": 0x47534F03, "key": 48, "type": "keyUp", "cmd": True},
    {"tag": 0x47534F04, "key": 55, "type": "flagsChanged", "cmd": False},
]


def qualify(receipt, fixture_a, fixture_b, hammerspoon_pid):
    """Require exact independent owned applications, all observations, and retirement."""
    if not isinstance(receipt, dict):
        return False
    if receipt.get("status") != "observed" or receipt.get("coverage") != "isolated_fixture_only":
        return False
    if receipt.get("before_pid") != fixture_a or receipt.get("after_pid") != fixture_b:
        return False
    if (
        type(fixture_a) is not int
        or type(fixture_b) is not int
        or fixture_a <= 0
        or fixture_b <= 0
        or fixture_a == fixture_b
    ):
        return False
    if (
        receipt.get("hs_pid") != hammerspoon_pid
        or type(hammerspoon_pid) is not int
        or hammerspoon_pid <= 0
    ):
        return False
    observed = receipt.get("observations")
    if not isinstance(observed, list) or len(observed) != 4:
        return False
    for actual, expected in zip(observed, PHASES):
        if not isinstance(actual, dict) or set(actual) != set(expected) or actual != expected:
            return False
        if (
            any(type(actual[key]) is not int for key in ("tag", "key"))
            or type(actual["cmd"]) is not bool
            or type(actual["type"]) is not str
        ):
            return False
    snapshots = receipt.get("hardware")
    if not isinstance(snapshots, list) or not 5 <= len(snapshots) <= 64:
        return False
    if (
        receipt.get("hardware_truncated") is not False
        or type(receipt.get("hardware_sample_count")) is not int
        or receipt["hardware_sample_count"] != len(snapshots)
    ):
        return False
    for index, row in enumerate(snapshots, 1):
        if (
            not isinstance(row, dict)
            or type(row.get("version")) is not int
            or row.get("version") != 1
            or type(row.get("request")) is not int
            or row.get("request") != index
        ):
            return False
        if (
            row.get("source") != "hid_system"
            or row.get("held") != []
            or type(row.get("flags")) is not int
        ):
            return False
        if any(row.get(key) is not True for key in ("listen_access", "post_access")):
            return False
        # These three modifier flags are not Caps Lock; any non-owned held modifier refuses.
        if row["flags"] & ((1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)):
            return False
        session = row.get("session")
        if not isinstance(session, dict) or set(session) != {
            "version",
            "request",
            "source",
            "held",
            "flags",
        }:
            return False
        if (
            type(session["version"]) is not int
            or session["version"] != 1
            or type(session["request"]) is not int
            or session["request"] != row["request"]
            or session["source"] != "combined_session"
        ):
            return False
        if (
            not isinstance(session["held"], list)
            or any(type(key) is not int for key in session["held"])
            or type(session["flags"]) is not int
            or session["flags"] < 0
        ):
            return False
    # Held session Command is expected during the chord, but the independent final
    # sample must prove release after all four local event observations.
    terminal = snapshots[-1]["session"]
    if terminal["held"] != [] or terminal["flags"] & 0x9E0000:
        return False
    return (
        all(
            receipt.get(key) is True
            for key in (
                "ax_trusted",
                "tap_retired",
                "timer_retired",
                "tasks_retired",
                "session_retired",
                "source_current",
            )
        )
        and receipt.get("cleanup_debt") is False
    )
