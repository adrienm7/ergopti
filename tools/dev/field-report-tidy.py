#!/usr/bin/env python3
# tools/dev/field-report-tidy.py

# ==============================================================================
# MODULE: Field report tidy
# DESCRIPTION:
# Sorts a finished field report folder into subfolders so the synthesis reads
# first: the 2026-11-15 macOS report held some sixty files side by side and
# the maintainer could not tell which one was the summary. Shared by the
# macOS, Linux and Windows collectors.
#
#   0_main/      the synthesis: analysis.md, timeline.txt, env.json, todo_summary.md, steps.txt, the
#                field run's terminal output, and their JSON twins
#   1_logs/      the scrubbed driver logs (*.log)
#   2_digests/   the grep digests and crash summaries over those logs
#   3_system/    every other step output (system, toolchain, Karabiner...)
#   field_run*/  the app's own results, left where the collector copied them
#
# 0_main/README.md names each folder. Runs last, after every step that reads
# the flat names (the analysis, the TODO summary), and before the redaction
# and the commit. A file already inside a subfolder is never moved.
#
# USAGE:
#   python3 tools/dev/field-report-tidy.py <report folder>
# ==============================================================================

import sys
from pathlib import Path

MAIN = "0_main"
LOGS = "1_logs"
DIGESTS = "2_digests"
SYSTEM = "3_system"

# The synthesis, in reading order (README lists them so).
MAIN_FILES = [
    ("analysis.md", "What to fix first, check verdicts, errors and warnings: start here."),
    (
        "timeline.txt",
        "Every step with its start and duration, the slowest and over-budget ones first.",
    ),
    ("todo_summary.md", "One verdict per TODO point to confirm on this OS."),
    ("steps.txt", "Every collector step with its exit status."),
    (
        "env.json",
        "The machine: Ergopti instances per phase, other remappers, permissions, devices, idle CPU.",
    ),
    ("field_run.txt", "The field run's terminal output, one verdict per step."),
    ("not_automated.txt", "What the run cannot automate, and why."),
    ("analysis_console.txt", "The analysis's console output."),
    ("analysis.json", "analysis.md as data (the next report compares against it)."),
    ("todo_summary.json", "todo_summary.md as data."),
    ("todo_summary.txt", "todo_summary.md as the terminal printed it."),
    ("timeline.json", "timeline.txt as data."),
    ("step_times.tsv", "The raw step timings (epoch seconds) the timeline is built from."),
    ("facts_console.txt", "The facts builder's console output."),
]


def destination(path):
    """Returns the subfolder a root file of the report belongs to."""
    name = path.name
    if name in dict(MAIN_FILES):
        return MAIN
    if name.endswith(".log"):
        return LOGS
    if name.startswith("digest_") or name.startswith("crash_"):
        return DIGESTS
    return SYSTEM


def write_readme(folder):
    """Writes 0_main/README.md, the index of the report."""
    lines = ["# Field report " + folder.name, "", "## Read first (0_main)", ""]
    for name, role in MAIN_FILES:
        if (folder / MAIN / name).is_file():
            lines.append("- [{0}]({0}): {1}".format(name, role))
    lines += [
        "",
        "## Folders",
        "",
        "- `../{}/`: the scrubbed driver logs.".format(LOGS),
        "- `../{}/`: grep digests over those logs and crash summaries.".format(DIGESTS),
        "- `../{}/`: every other step output (system, toolchain, Karabiner, runtime).".format(
            SYSTEM
        ),
        "- `../field_run/`: the app's own results per step (field_run_attempt_N: runs a reload cut short).",
        "",
    ]
    (folder / MAIN / "README.md").write_text("\n".join(lines), encoding="utf-8")


def tidy(folder):
    """Moves every root file of the report into its subfolder."""
    for path in sorted(p for p in folder.iterdir() if p.is_file()):
        target_dir = folder / destination(path)
        target_dir.mkdir(exist_ok=True)
        target = target_dir / path.name
        if target.exists():
            print(
                "[field-report-tidy] kept {}: {} already exists".format(path.name, target),
                file=sys.stderr,
            )
            continue
        path.rename(target)
    (folder / MAIN).mkdir(exist_ok=True)
    write_readme(folder)


def main(argv):
    if len(argv) != 2 or not Path(argv[1]).is_dir():
        print("usage: field-report-tidy.py <report folder>", file=sys.stderr)
        return 2
    tidy(Path(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
