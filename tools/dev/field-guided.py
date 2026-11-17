#!/usr/bin/env python3
# tools/dev/field-guided.py

# ==============================================================================
# MODULE: Field report guided and probe steps (collector side)
# DESCRIPTION:
# Runs the steps a field report collector owns itself, beside the daemon's
# field run: state probes read once with no person (a device node's access,
# a unit's autostart, a count of log lines), and guided steps that print one
# gesture, wait for it under a bound and record what they saw. The Linux
# collector runs static/ergopti_plus/linux/diagnostics/data/field_guided_steps.json; the
# macOS field run does the same inside the app (infra/field_run_guided.lua).
#
# FEATURES & RATIONALE:
# 1. Observed, not asked, whenever the outcome can be read: an observe step
#    reads its probes before the prompt (the baseline) and every poll until
#    each one rose; a probe named steady that rose fails it. An attest step is
#    what only a person sees: it takes y, n or s from the terminal.
# 2. Nothing silently skipped: no gesture or answer within the bound is
#    needs_person (gesture_not_observed_<n>s, no_answer_<n>s), a skip is
#    skipped_by_person, a probe that cannot read is fail with its reason.
# 3. Counts and closed codes only: a log probe counts matching lines of the
#    raw day log and never copies one; the Metrics probe counts rows by kind,
#    read-only and lock-free (immutable URI). Results have the field run's
#    result shape (field_guided/NN_<step>.json) so field-todo-summary.py reads
#    them beside the field run's.
# 4. A fixed declaration: commands are argv lists of the declaration, tables
#    and kinds plain names, run without a shell.
#
# USAGE:
#   python3 tools/dev/field-guided.py --steps <declaration> --out <report folder>
#       [--log <today's day log>] [--metrics <metrics database>]
# FIELD_GUIDED_SECONDS_OVERRIDE bounds every gesture (the contract tests).
# ==============================================================================

import argparse
import glob
import json
import os
import re
import select
import sqlite3
import subprocess
import sys
import time
import urllib.parse

MODES = ("probe", "observe", "attest")
ANSWERS = {"y": "pass", "n": "fail", "s": "skip"}
NAME = re.compile(r"^[a-z][a-z0-9_]*$")
COMMAND_SECONDS = 10


def log(text):
    """Prints one collector line."""
    print(f"[field-report] {text}", flush=True)


# =================================
# ======= 1/ Declaration ==========
# =================================


def validate(spec):
    """Validates the declaration; raises ValueError on the first defect.

    Args:
        spec: The decoded declaration.
    """
    if spec.get("schema") != 1 or not isinstance(spec.get("steps"), list) or not spec["steps"]:
        raise ValueError("schema 1 with a nonempty steps list is required")
    if not isinstance(spec.get("poll_seconds"), int) or spec["poll_seconds"] < 1:
        raise ValueError("poll_seconds must be a positive integer")
    seen = set()
    for step in spec["steps"]:
        sid = step.get("id")
        if not isinstance(sid, str) or not NAME.match(sid) or sid in seen:
            raise ValueError(f"invalid or duplicate step id {sid!r}")
        seen.add(sid)
        if step.get("mode") not in MODES:
            raise ValueError(f"{sid}: unknown mode")
        if not isinstance(step.get("proves"), str) or not step["proves"].endswith("."):
            raise ValueError(f"{sid}: needs one sentence of what its pass proves")
        probes = step.get("probes", [])
        if step["mode"] != "attest" and not probes:
            raise ValueError(f"{sid}: a {step['mode']} step reads at least one probe")
        for probe in probes + step.get("steady", []):
            validate_probe(sid, probe)
        if step["mode"] != "probe":
            if not isinstance(step.get("gesture"), str) or not step["gesture"].strip():
                raise ValueError(f"{sid}: says no gesture")
            if not isinstance(step.get("gesture_seconds"), int) or step["gesture_seconds"] < 10:
                raise ValueError(f"{sid}: needs gesture_seconds of at least 10")


def validate_probe(sid, probe):
    """Validates one probe of a step."""
    if not isinstance(probe.get("id"), str) or not NAME.match(probe["id"]):
        raise ValueError(f"{sid}: a probe has no plain id")
    kind = probe.get("kind")
    if kind == "log_count":
        re.compile(probe["pattern"])
    elif kind == "sqlite_count":
        if not NAME.match(probe.get("table", "")) or not NAME.match(probe.get("row_kind", "")):
            raise ValueError(f"{sid}: {probe['id']} names a table or kind that is not a plain name")
    elif kind == "path_access":
        if probe.get("access") not in ("read", "write") or not isinstance(probe.get("glob"), str):
            raise ValueError(f"{sid}: {probe['id']} needs a glob and read or write access")
    elif kind == "command_exit":
        argv = probe.get("argv")
        if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
            raise ValueError(f"{sid}: {probe['id']} needs an argv list")
    else:
        raise ValueError(f"{sid}: {probe.get('id')} has an unknown probe kind")
    if kind != "log_count" and "pattern" in probe:
        raise ValueError(f"{sid}: {probe['id']} carries a pattern it does not read")
    if probe.get("expect") not in (None, "nonzero", "zero"):
        raise ValueError(f"{sid}: {probe['id']} expects nonzero or zero")


# =================================
# ======= 2/ Probes ===============
# =================================


def read_probe(probe, sources):
    """Reads one probe.

    Args:
        probe: The probe declaration.
        sources: {"log": path or None, "metrics": path or None}.

    Returns:
        (value, error): an integer, or None with a closed error code.
    """
    kind = probe["kind"]
    if kind == "log_count":
        path = sources.get("log")
        if not path or not os.path.isfile(path):
            return None, "no_day_log"
        pattern = re.compile(probe["pattern"])
        with open(path, encoding="utf-8", errors="replace") as handle:
            return sum(1 for line in handle if pattern.search(line)), None
    if kind == "sqlite_count":
        path = sources.get("metrics")
        if not path or not os.path.isfile(path):
            return None, "no_metrics_database"
        uri = "file:" + urllib.parse.quote(os.path.abspath(path)) + "?immutable=1"
        try:
            connection = sqlite3.connect(uri, uri=True)
            try:
                row = connection.execute(
                    f"SELECT COUNT(*) FROM {probe['table']} WHERE kind = ?", (probe["row_kind"],)
                ).fetchone()
            finally:
                connection.close()
        except sqlite3.Error:
            return None, "metrics_unreadable"
        return int(row[0]), None
    if kind == "path_access":
        paths = sorted(glob.glob(probe["glob"]))
        mode = os.W_OK if probe["access"] == "write" else os.R_OK
        return sum(1 for path in paths if os.access(path, mode)), None
    try:
        completed = subprocess.run(
            probe["argv"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=COMMAND_SECONDS,
            check=False,
        )
    except FileNotFoundError:
        return None, "command_missing"
    except subprocess.TimeoutExpired:
        return None, "command_timeout"
    return completed.returncode, None


def read_all(probes, sources):
    """Reads every probe: id → (value, error)."""
    return {probe["id"]: read_probe(probe, sources) for probe in probes}


def report_steps(readings, states):
    """The report steps of a result, in the field check grammar."""
    steps = []
    for pid, (value, error) in readings.items():
        steps.append(
            {
                "id": pid,
                "state": states.get(pid, "info"),
                "value": str(value) if error is None else error,
            }
        )
    return steps


# =================================
# ======= 3/ Steps ================
# =================================


def answer_within(seconds):
    """The person's answer key within the given seconds, or None."""
    if not sys.stdin.isatty():
        time.sleep(seconds)
        return None
    ready, _, _ = select.select([sys.stdin], [], [], seconds)
    if not ready:
        return None
    return sys.stdin.readline().strip().lower()[:1] or None


def run_probe_step(step, sources):
    """A state read once: each probe meets its expectation or fails by name."""
    readings = read_all(step["probes"], sources)
    states, codes = {}, []
    for probe in step["probes"]:
        value, error = readings[probe["id"]]
        expect = probe.get("expect", "nonzero")
        if error is not None:
            states[probe["id"]] = "fail"
            codes.append(f"{probe['id']}_{error}")
        elif (value != 0) == (expect == "nonzero"):
            states[probe["id"]] = "pass"
        else:
            states[probe["id"]] = "fail"
            codes.append(f"{probe['id']}_{value}")
    verdict = "fail" if codes else "pass"
    return verdict, codes or ["probes_met"], report_steps(readings, states)


def announce(step, seconds):
    """Prints a guided step's gesture once and rings."""
    sys.stdout.write("\a")
    log(f"  👉 GUIDED {step['id']} (up to {seconds} s): {step['gesture']}")
    if step["mode"] == "attest":
        log("     Then type y (it worked), n (it did not) or s (skip), and Enter.")
    else:
        log("     The report sees it by itself; type s and Enter to skip it.")


def run_guided_step(step, sources, poll, bound):
    """An observed or attested gesture under its bound."""
    probes, steady = step.get("probes", []), step.get("steady", [])
    baseline = read_all(probes + steady, sources)
    announce(step, bound)
    deadline = time.monotonic() + bound
    while True:
        key = answer_within(min(poll, max(0.0, deadline - time.monotonic())))
        if key == "s":
            return (
                "skip",
                ["skipped_by_person"],
                report_steps(read_all(probes + steady, sources), {}),
            )
        if step["mode"] == "attest":
            if key in ("y", "n"):
                readings = read_all(probes, sources)
                return ANSWERS[key], [f"attested_{ANSWERS[key]}"], report_steps(readings, {})
            if key is not None:
                log("     Answer y, n or s.")
        else:
            # An unreadable source may appear with the gesture (the first
            # Metrics row creates the database): it counts from 0 and is
            # named only if it never became readable.
            current = read_all(probes + steady, sources)
            rose = {
                pid
                for pid, (value, error) in current.items()
                if error is None and value > (baseline[pid][0] if baseline[pid][1] is None else 0)
            }
            if all(probe["id"] in rose for probe in probes):
                bad = [f"rose_{probe['id']}" for probe in steady if probe["id"] in rose]
                states = {pid: ("fail" if f"rose_{pid}" in bad else "pass") for pid in current}
                return (
                    ("fail" if bad else "pass"),
                    ["gesture_observed", *bad],
                    report_steps(current, states),
                )
        if time.monotonic() >= deadline:
            final = read_all(probes + steady, sources)
            errors = [f"{pid}_{err}" for pid, (_, err) in final.items() if err is not None]
            if errors:
                return "fail", errors, report_steps(final, {})
            code = "no_answer" if step["mode"] == "attest" else "gesture_not_observed"
            return "needs_person", [f"{code}_{bound}s"], report_steps(final, {})


def main(argv):
    parser = argparse.ArgumentParser(description="Collector-side guided and probe steps.")
    parser.add_argument("--steps", required=True, help="The declaration (JSON).")
    parser.add_argument("--out", required=True, help="The report folder.")
    parser.add_argument("--log", help="Today's day log (counted, never copied).")
    parser.add_argument("--metrics", help="The Metrics SQLite database (read-only).")
    args = parser.parse_args(argv)
    with open(args.steps, encoding="utf-8") as handle:
        spec = json.load(handle)
    try:
        validate(spec)
    except (ValueError, KeyError, re.error) as error:
        print(f"[field-report] ERROR: {args.steps}: {error}", file=sys.stderr)
        return 2
    override = os.environ.get("FIELD_GUIDED_SECONDS_OVERRIDE")
    sources = {"log": args.log, "metrics": args.metrics}
    folder = os.path.join(args.out, "field_guided")
    os.makedirs(folder, exist_ok=True)
    log(
        "Stay at the computer: the guided steps print a gesture here (👉 GUIDED), each waits for it, and the"
    )
    log(
        "attested ones take y, n or s then Enter. Nothing done in time is recorded needs_person, never a pass."
    )
    marks = {"pass": "✅", "fail": "❌", "skip": "⏭️", "needs_person": "🙋"}
    for index, step in enumerate(spec["steps"], start=1):
        started = time.monotonic()
        if step["mode"] == "probe":
            verdict, codes, steps = run_probe_step(step, sources)
        else:
            bound = int(override) if override else step["gesture_seconds"]
            verdict, codes, steps = run_guided_step(step, sources, spec["poll_seconds"], bound)
        document = {
            "schema": 1,
            "index": index,
            "step": step["id"],
            "kind": "guided" if step["mode"] != "probe" else "probe",
            "verdict": verdict,
            "codes": codes,
            "elapsed_ms": int((time.monotonic() - started) * 1000),
            "report": {"check": step["id"], "steps": steps},
        }
        with open(
            os.path.join(folder, f"{index:02d}_{step['id']}.json"), "w", encoding="utf-8"
        ) as handle:
            json.dump(document, handle, ensure_ascii=False)
            handle.write("\n")
        log(f"  {marks.get(verdict, '⚠️')} {step['id']}: {verdict} ({','.join(codes)})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
