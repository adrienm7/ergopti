# tools/diagnostics/hs274_baseline_contract.py
"""Refuse a Hammerspoon consumer run while the producer cannot serve its baseline.

The live Lua consumer (physical_baseline.lua) admits one baseline descriptor
version. The diagnostic producer (hs274-stream-source.hpp), CLI transfer
(hs274-stream-baseline-client.hpp) and Python fixture reader
(hs274_baseline_frames.py) declare their own. When they differ,
every native run with the Hammerspoon consumer spends a macOS runner and then
fails at admission, so hs274-native.yml runs this check first and stops with a
named reason until WP4 aligns the producer.
"""

from pathlib import Path
import argparse
import re
import sys

CONSUMER = "static/ergopti_plus/macos/modules/keylogger/physical_baseline.lua"
PRODUCER = "tools/diagnostics/hs274-stream-source.hpp"
READER = "tools/diagnostics/hs274_baseline_frames.py"
CLI = "tools/diagnostics/hs274-stream-baseline-client.hpp"
REASON = "consumer_baseline_version_mismatch"
REFUSED = 3


def single(pattern, path):
    """Return the one integer group of a pattern that must match exactly once."""
    matches = re.findall(pattern, path.read_text(), re.MULTILINE)
    if len(matches) != 1:
        raise RuntimeError(f"Expected one baseline version declaration in {path}")
    return matches[0]


def versions(root):
    """Read all four baseline-version boundaries from their source declarations."""
    consumer = int(single(r"^M\.VERSION = (\d+)$", root / CONSUMER))
    producer = int(single(r'opened\["baseline"\] = \{\{"version", (\d+)u\}', root / PRODUCER))
    cli = int(single(r'descriptor\.at\("version"\) != (\d+)u', root / CLI))
    low, high = single(
        r'integer\(descriptor\["version"\], "baseline version", (\d+), (\d+)\)', root / READER
    )
    return {"consumer": consumer, "producer": producer, "cli": cli, "reader": (int(low), int(high))}


def main(argv=None):
    """Exit zero only when producer, CLI and reader serve the consumer's version."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    found = versions(parser.parse_args(argv).root)
    low, high = found["reader"]
    consumer = found["consumer"]
    if found["producer"] != consumer or found["cli"] != consumer or not low <= consumer <= high:
        print(
            f"HS274_BASELINE_CONTRACT refused: {REASON} (consumer {consumer}, "
            f"producer {found['producer']}, CLI {found['cli']}, reader {low}..{high}); "
            "the producer must emit the consumer's baseline version (WP4)"
        )
        return REFUSED
    print(f"HS274_BASELINE_CONTRACT ok: baseline version {consumer}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
