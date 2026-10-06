# tools/diagnostics/native_global_switcher/run_owner_controls.py
"""Version 1: run the independent Lua controls inside an owned temporary scope."""

import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile

# Independent reviewed control inventory; never derive expectations from the owner.
CONTROL_CASES = (
    "hardware_pin_replaced_after_command",
    "hardware_pin_replaced_during_constructor",
    "hardware_pin_restored_after_command",
    "session_command_stuck_after_up",
    "session_tab_stuck_after_up",
    "session_flags_stuck_after_up",
    "session_stale_after_up",
    "session_malformed_after_up",
    "session_release_later",
    "session_preheld",
    "healthy",
    "hardware_constructor_nil",
    "hardware_constructor_throw",
    "unadmitted_hardware_still_running",
    "unadmitted_hardware_query_nil",
    "unadmitted_hardware_query_throw",
    "post_return_without_delivery",
    "post_return_without_delivery_external_effect",
    "delivery_without_effect",
    "physical_left_command",
    "physical_right_command",
    "physical_tab",
    "wrong_hardware_source",
    "hardware_start_nil",
    "hardware_start_false",
    "hardware_start_throw",
    "hardware_sync_callback_then_refusal",
    "timer_stop_false",
    "timer_stop_nil",
    "timer_stop_throw",
    "tap_stop_false",
    "tap_stop_nil",
    "tap_stop_throw",
    "source_revoked_after_command",
    "source_pin_replaced_after_command",
    "physical_during_command",
    "long_physical_hold_wrap",
    "command_post_refused_after_delivery",
    "accessibility_refused",
    "foreign_event_pid",
)


def run_controls(lua, source_directory):
    """Copy exact captured bytes, preserve Lua's status, and retire only this scope."""
    source_directory = Path(source_directory)
    source = (source_directory / "global-switcher.lua").read_bytes()
    tests = (source_directory / "test_probe_owner.lua").read_bytes()
    census = tests.decode("utf-8").split("local cases = {", 1)[-1].split("\n}", 1)[0]
    observed = tuple(re.findall(r'"([a-z_]+)"', census))
    if observed != CONTROL_CASES:
        raise ValueError("Portable control inventory differs from reviewed version 1")
    with tempfile.TemporaryDirectory(prefix="ergopti-global-switcher-controls-") as directory:
        scope = Path(directory)
        (scope / "global-switcher.lua").write_bytes(source)
        (scope / "test_probe_owner.lua").write_bytes(tests)
        for name in CONTROL_CASES:
            (scope / ("control-" + name)).mkdir()
        result = subprocess.run([lua, str(scope / "test_probe_owner.lua"), str(scope)], check=False)
        # A signalled POSIX child has a negative subprocess status. Preserve the
        # corresponding conventional shell outcome, never report successful cleanup.
        return result.returncode if result.returncode >= 0 else 128 - result.returncode


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", required=True, help="Literal Lua interpreter executable")
    parser.add_argument("--source-directory", type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args(arguments)
    try:
        return run_controls(args.lua, args.source_directory)
    except (OSError, ValueError):
        print("Global switcher portable control setup or interpreter refused.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
