"""Independently classify actual native Compose results on all shipped layouts."""

import argparse
import copy
import hashlib
import json
import os
import sys
from pathlib import Path
import subprocess
import tempfile

# Set this before importing a local helper so replay creates no archive cache.
sys.dont_write_bytecode = True

from materialize import materialize  # noqa: E402


def require(value, message):
    """Reject a failed observation under optimized Python as well."""
    if not value:
        raise ValueError(message)


def classify(record):
    """Keep independent explicit bounds and distinguish known and new roots."""
    rows = record["layouts"]
    require(
        [r["id"] for r in rows]
        == ["bepo", "ergol", "ergopti", "ergopti_ansi", "ergopti_plus", "ergopti_plus_ansi"],
        "registry subjects",
    )
    require(sum(r["states"] for r in rows) == 140, "state floor")
    require(sum(r["unique_wire_expectations"] for r in rows) == 4391, "expectation floor")
    require(
        [len(r["native_mismatches"]) for r in rows] == [1, 0, 0, 0, 4, 4],
        "deviation classification",
    )
    bepo = rows[0]["native_mismatches"][0]
    require(
        bepo["sequence"] == ["dead_currency", "dead_cedilla"]
        and bepo["expected"] == "₢"
        and bepo["trail"][-1]["status"] == 1,
        "Bepo inherited prefix",
    )
    wanted = {
        ("s1_circumflex", "j"),
        ("s4_greek", "ξ"),
        ("s5_superscript", "ʲ"),
        ("s6_subscript", "ⱼ"),
    }
    for row in rows[-2:]:
        mismatches = row["native_mismatches"]
        require(
            {(m["state"], m["expected"]) for m in mismatches} == wanted, "known Magic identities"
        )
        require(
            all(m["sequence"][-1] == "U2605" and m["trail"][-1]["status"] == 3 for m in mismatches),
            "known Magic wire outcomes",
        )
    require(
        all(not r["ambiguous_neutral_text_compositions"] for r in rows),
        "ambiguous native-character admission",
    )


def main():
    """Run archived original-owner probes without modifying retained evidence."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo_root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root = args.repo_root.resolve()
    campaign = Path(__file__).resolve().parents[1]
    runs = []
    with tempfile.TemporaryDirectory(prefix="dead-keys-root-shared-") as directory:
        temporary = Path(directory)
        shared = materialize(campaign, temporary / "workers") / "shared"
        for name, argv in [
            (
                "enumeration",
                [
                    "python3",
                    str(shared / "shared_probe.py"),
                    str(root),
                    "--output",
                    str(temporary / "enumeration.json"),
                ],
            ),
            (
                "prefix",
                [
                    "python3",
                    str(shared / "prefix_probe.py"),
                    str(root),
                    str(temporary / "prefix.json"),
                ],
            ),
        ]:
            result = subprocess.run(
                argv,
                cwd=root,
                capture_output=True,
                timeout=90,
                env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
            )
            require(result.returncode == 0, (name, result.stderr.decode(errors="replace")))
            runs.append(
                {
                    "name": name,
                    "exit": result.returncode,
                    "program_sha256": hashlib.sha256(Path(argv[1]).read_bytes()).hexdigest(),
                    "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
                    "stderr_sha256": hashlib.sha256(result.stderr).hexdigest(),
                }
            )
        record = json.loads((temporary / "enumeration.json").read_bytes())
        classify(record)
        rejected = []
        for label, mutate in [
            ("missing layout", lambda r: r["layouts"].pop()),
            (
                "missing expectations",
                lambda r: r["layouts"][0].__setitem__("unique_wire_expectations", 0),
            ),
            ("concealed new deviation", lambda r: r["layouts"][0]["native_mismatches"].clear()),
            (
                "changed known deviation",
                lambda r: r["layouts"][-1]["native_mismatches"][0].__setitem__("expected", "wrong"),
            ),
        ]:
            changed = copy.deepcopy(record)
            mutate(changed)
            try:
                classify(changed)
            except (ValueError, KeyError, IndexError):
                rejected.append(label)
            else:
                raise ValueError("false-green classification: " + label)
        prefix = json.loads((temporary / "prefix.json").read_bytes())
        require(len(prefix["observations"]) == 5, "prefix controls")
        result = {
            "head": subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=root, text=True
            ).strip(),
            "layouts": 6,
            "states": 140,
            "wire_expectations": 4391,
            "known_magic_deviations": 8,
            "new_bepo_deviations": 1,
            "prefix_controls": 5,
            "classification_negative_controls": rejected,
            "runs": runs,
            "native_dependency": prefix["native_dependency"],
            "locale": prefix["system_locale_reference"],
            "qualification": record["qualification"],
        }
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"runs": 2, "negative_controls": len(rejected), "all_exit": 0}))


if __name__ == "__main__":
    main()
