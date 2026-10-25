#!/usr/bin/env python3
# tools/test/linux_distro_suite_diagnostic.py
"""Read one distribution row's raw suite log and hand its evidence to the record step.

tools/test/run-linux-distro-unit.sh runs one suite of module groups in a
container of the archive lot's image: "unit" is every group of
tests/support/module_groups.lua but the integration group, "integration" that
group alone. Each group's log prints whole under one header, in declared order.
This reads that log, refuses a missing, extra, reordered or incomplete group
summary, annotates the runner's own failure lines, and on a green run appends
the passed count and the admitted LuaJIT version to GITHUB_OUTPUT. The Unit
distribution rows and the Integration distribution rows share it, so a row
cannot pass with another suite's groups.

Usage: linux_distro_suite_diagnostic.py LOG RUN_LUA DISTRO NATIVE_STATUS SUITE
"""

import os
import pathlib
import re
import sys

SUITES = ("unit", "integration")
INTEGRATION_GROUP = "integration"
SEPARATOR = "=" * 40


def annotation(suite, kind, message):
    """Print one GitHub annotation, escaped the way the runner requires."""
    message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print("::" + kind + " title=Linux distro " + suite + " suite::" + message)


def expected_groups(groups, suite):
    """The groups one suite runs, in declared order, or None for an unknown layout."""
    if not groups or groups[0] != INTEGRATION_GROUP:
        return None
    return groups[1:] if suite == "unit" else groups[:1]


def main(arguments):
    log_path, runner_path, distro, native_status, suite = arguments
    if suite not in SUITES:
        annotation("unknown", "error", distro + ": unknown suite " + suite)
        return 2
    text = pathlib.Path(log_path).read_text(encoding="utf-8", errors="replace")
    runner = pathlib.Path(runner_path).read_text(encoding="utf-8")
    groups_path = pathlib.Path(runner_path).parent / "support" / "module_groups.lua"
    groups = re.findall(r'\{ name = "([a-z_]+)"', groups_path.read_text(encoding="utf-8"))
    template = (
        r"\n"
        + SEPARATOR
        + r"\nOVERALL RESULTS:\nTotal modules: %d\nPassed tests:  %d\nFailed tests:  %d\n"
        + SEPARATOR
    )

    if native_status != "0":
        for line in text.splitlines():
            if line.startswith("tests/run.lua: ") or line.startswith("luajit: "):
                annotation(suite, "error", distro + ": " + line)

    # Couple only to the existing runner's exact format string, not a second tally.
    if runner.count('"' + template + '"') != 1:
        annotation(
            suite,
            "error",
            distro + ": native runner summary format is unavailable; inspect the raw artifact",
        )
        return 2
    # The helper runs the suite's module groups at once and prints each log
    # whole under its header, in the order tests/support/module_groups.lua declares.
    parts = re.split(r"(?m)^distro-unit-group ([a-z_]+)\n", text)
    names = parts[1::2]
    expected = expected_groups(groups, suite)
    if not expected or names != expected:
        annotation(
            suite,
            "error",
            distro
            + ": native exit "
            + native_status
            + "; expected the groups "
            + ", ".join(expected or [])
            + ", received "
            + ", ".join(names)
            + "; inspect the raw artifact",
        )
        return 2
    pattern = re.compile(
        r"(?m)^"
        + SEPARATOR
        + r"\nOVERALL RESULTS:\nTotal modules: ([0-9]+)\nPassed tests:  ([0-9]+)\nFailed tests:  ([0-9]+)\n"
        + SEPARATOR
        + r"(?:\n|$)"
    )
    totals = [0, 0, 0]
    for name, body in zip(names, parts[2::2]):
        frames = list(pattern.finditer(body))
        if len(frames) != 1 or len(re.findall(r"(?m)^OVERALL RESULTS:$", body)) != 1:
            annotation(
                suite,
                "error",
                distro
                + " "
                + name
                + ": native exit "
                + native_status
                + "; expected one complete summary, received "
                + str(len(frames))
                + "; inspect the raw artifact",
            )
            return 2
        frame = frames[0]
        modules, passed, failed = map(int, frame.groups())
        if modules <= 0 or passed + failed <= 0 or (native_status == "0" and failed != 0):
            annotation(
                suite,
                "error",
                distro
                + " "
                + name
                + ": native exit/summary contradiction; inspect the raw artifact",
            )
            return 2
        totals = [totals[0] + modules, totals[1] + passed, totals[2] + failed]
        # Emit the actual runner's failure and module-load first lines without deriving
        # expected results. Full traceback/replay bytes remain in the uploaded raw log.
        if native_status != "0":
            for line in body[: frame.start()].splitlines():
                if line.startswith("  ! load error in "):
                    annotation(suite, "error", distro + " " + name + ": " + line.strip())
            for line in body[frame.end() :].splitlines():
                if line.startswith("  - ") or line.startswith("    replay: "):
                    annotation(suite, "error", distro + " " + name + ": " + line.strip())
    summary = (
        distro
        + ": native exit "
        + native_status
        + "; groups="
        + str(len(names))
        + ", modules="
        + str(totals[0])
        + ", passed="
        + str(totals[1])
        + ", failed="
        + str(totals[2])
    )
    annotation(suite, "notice" if native_status == "0" else "error", summary)
    # The evidence names the interpreter the helper admitted, printed once before the groups.
    interpreters = re.findall(r"(?m)^(LuaJIT [0-9][^\s]*)$", parts[0])
    if native_status == "0":
        if len(interpreters) != 1:
            annotation(
                suite,
                "error",
                distro
                + ": expected one admitted LuaJIT version, received "
                + str(len(interpreters))
                + "; inspect the raw artifact",
            )
            return 2
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write("passed=" + str(totals[1]) + "\ninterpreter=" + interpreters[0] + "\n")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 6:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        raise SystemExit(64)
    raise SystemExit(main(sys.argv[1:]))
