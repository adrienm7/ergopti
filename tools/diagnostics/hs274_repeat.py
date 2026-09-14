# tools/diagnostics/hs274_repeat.py
"""Require OS-generated repeat events without extra physical input reports."""


def validate_repeat_output(native):
    """Distinguish the remapped tap from one Space hold and its OS repeats."""
    if (native.get("repeat_observed") is not True or native.get("reports_queued") != 4
            or native.get("space_pair_observed") is not True):
        raise ValueError("Native autorepeat stimulus did not complete")
    events = native.get("events")
    if not isinstance(events, list) or len(events) < 6:
        raise ValueError("Native autorepeat output is incomplete")
    expected = [(10, 0), (11, 0), (10, 0)] + [(10, 1)] * (len(events) - 4) + [(11, 0)]
    for event, (kind, repeated) in zip(events, expected):
        if (event.get("type") != kind or event.get("keycode") != 49
                or type(event.get("autorepeat")) is not int or event["autorepeat"] != repeated):
            raise ValueError("Native autorepeat lost its original press, repeated output or release")
