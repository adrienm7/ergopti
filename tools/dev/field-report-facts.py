#!/usr/bin/env python3
# tools/dev/field-report-facts.py

# ==============================================================================
# MODULE: Field report facts, environment summary and timeline
# DESCRIPTION:
# Turns the machine-readable fact lines the three collectors write into the
# step outputs (macOS, Linux, Windows) into env.json, and their step timings,
# the field run's step results and the driver's own timed log lines into
# timeline.txt and timeline.json. tools/dev/field-log-analyse.py reads both and
# adds the findings a log alone cannot give: two drivers at once, another
# remapper, a missing permission, the process that spent the idle CPU, and the
# slowest steps. Shared by the three collectors, run before the analysis.
#
# FEATURES & RATIONALE:
# 1. One grammar for every OS: a step output line
#    "fact<TAB><type><TAB>key=value<TAB>key=value..." (types in FACT_TYPES).
#    The rest of a step output stays the raw evidence a person reads. The
#    2026-11-15 macOS report could not tell whether two Ergopti drivers ran
#    (release and developer app) nor which process spent the 785 ms of idle CPU
#    no timer explained: the instance and CPU facts answer both.
# 2. step_times.tsv (one line per collector step: name, kind, start, end,
#    status, budget; epoch seconds) is written by the collector's step runner
#    (tools/dev/field-report-steps.sh, the Windows Invoke-Step); a step over its
#    budget is listed, the slowest first.
# 3. The field run's results carry started_at, elapsed_ms and deadline_ms; a
#    step over its deadline or timed out is over budget.
# 4. The driver's own boot, slow and over-budget lines of the run window come
#    from the scrubbed day logs in the report folder, never from a raw log.
# 5. The CPU each driver process spent during the field run's idle window is
#    computed from the sampler's cumulative CPU times around that window.
# 6. Only facts the collectors already reduced travel: no address, no serial,
#    no typed text; field-report-redact.py still rewrites both files after.
#
# USAGE:
#   python3 tools/dev/field-report-facts.py build <report folder> --os mac|linux|win
#   python3 tools/dev/field-report-facts.py karabiner <karabiner.json> [<devices.json>]
#
# Python 3.8 and the standard library only: the Windows collector runs
# whatever Python the PC has.
# ==============================================================================

import argparse
import datetime
import json
import pathlib
import re
import sys

SCHEMA = 1
ENV_JSON = "env.json"
TIMELINE_TXT = "timeline.txt"
TIMELINE_JSON = "timeline.json"
STEP_TIMES = "step_times.tsv"
FACT_PREFIX = "fact\t"
FACT_TYPES = ("env", "instance", "sample", "remapper", "permission", "device", "layout", "cpu")
# How many rows the "slowest" summaries keep.
SLOWEST_SHOWN = 15
# The field run step whose window the per-process idle CPU is computed over.
IDLE_STEPS = ("field_idle_cost", "idle_cost")
# The driver's own timed lines placed on the timeline (scrubbed day logs only).
DRIVER_TIMED = re.compile(
    r"Boot complete|Boot completed with|Boot CPU|Over budget: |Slow |Main-thread hold of|\[HotPath\]"
)
LOG_RECORD = re.compile(
    r"^(?P<day>\d{4}-\d{2}-\d{2}) (?P<clock>\d{2}:\d{2}:\d{2})(?::\d{3})? \[(?P<level>[A-Z]+)\] (?P<rest>.*)$"
)
# A driver line on the timeline is cut here.
LINE_CHARS = 200
# The day log lines placed on the timeline at most, the slowest kept.
DRIVER_LINES_KEPT = 200


# ===========================================
# ======= 1/ Fact lines =====================
# ===========================================


def parse_fact(line):
    """Parses one fact line.

    Args:
        line: One line of a step output, without its line end.

    Returns:
        A (type, fields dict) pair, or None when the line is not a fact.
    """
    if not line.startswith(FACT_PREFIX):
        return None
    parts = line.split("\t")
    if len(parts) < 2 or parts[1] not in FACT_TYPES:
        return None
    fields = {}
    for part in parts[2:]:
        key, sep, value = part.partition("=")
        if sep and key:
            fields[key.strip()] = value.strip()
    return parts[1], fields


def read_facts(folder):
    """Reads every fact line of the step outputs of a report folder.

    Args:
        folder: The report folder (flat, or sorted by field-report-tidy.py).

    Returns:
        A list of (type, fields, source file stem) triples, in file order.
    """
    facts = []
    for path in sorted(folder.rglob("*.txt")):
        relative = path.relative_to(folder).parts
        if relative[0] in ("1_logs",) or relative[0].startswith("field_run"):
            continue
        with path.open(encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                parsed = parse_fact(raw.rstrip("\r\n"))
                if parsed:
                    facts.append((parsed[0], parsed[1], path.stem))
    return facts


def number(value, default=None):
    """Returns a float from a fact value, or default when it is not one."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


# ===========================================
# ======= 2/ Environment summary ============
# ===========================================


def instance_key(fields):
    """Identifies one process across samples: pid and start time."""
    return "{}@{}".format(fields.get("pid", "?"), fields.get("started", "?"))


def summarise_instances(facts):
    """Groups the instance facts by phase and finds overlapping drivers.

    Args:
        facts: The read_facts() list.

    Returns:
        The env.json "instances" dict.
    """
    phases = {}
    snapshots = {}
    sample_times = set()
    for kind, fields, _source in facts:
        if kind == "sample":
            sample_times.add((fields.get("phase", "?"), fields.get("t", "?")))
            continue
        if kind != "instance":
            continue
        phase = fields.get("phase", "?")
        phases.setdefault(phase, [])
        if phase != "sample":
            phases[phase].append(fields)
        snapshots.setdefault((phase, fields.get("t", "?")), []).append(fields)
    worst = {"count": 0, "phase": None, "t": None, "drivers": []}
    # Launchers and engines are counted apart: a sample that sees only the
    # engine is not a restart of the launcher.
    seen = {"driver": {}, "engine": {}}
    concurrent = {"driver": 0, "engine": 0}
    for (phase, t), rows in sorted(snapshots.items(), key=lambda item: str(item[0][1])):
        by_role = {}
        for role in seen:
            by_role[role] = {instance_key(row): row for row in rows if row.get("role") == role}
            seen[role].update(by_role[role])
            concurrent[role] = max(concurrent[role], len(by_role[role]))
        # A macOS driver is a launcher and the Hammerspoon engine it runs: an
        # engine left without its launcher still remaps, so the larger count
        # of the two is the number of drivers.
        drivers = (
            by_role["engine"]
            if len(by_role["engine"]) > len(by_role["driver"])
            else by_role["driver"]
        )
        if len(drivers) > worst["count"]:
            worst = {
                "count": len(drivers),
                "phase": phase,
                "t": t,
                "drivers": list(drivers.values()),
            }
    driver_keys = dict(seen["engine"], **seen["driver"]) if seen["driver"] else seen["engine"]
    restarts = max(
        [len(seen[role]) - max(concurrent[role], 1) for role in seen if seen[role]] or [0]
    )
    origins = sorted({row.get("origin", "?") for row in driver_keys.values()})
    return {
        "phases": {phase: rows for phase, rows in phases.items() if rows},
        "samples": len({t for phase, t in sample_times if phase == "sample"}),
        "max_drivers": worst["count"],
        "max_drivers_at": {"phase": worst["phase"], "t": worst["t"]},
        "overlapping_drivers": worst["drivers"] if worst["count"] > 1 else [],
        "drivers_seen": list((seen["driver"] or seen["engine"]).values()),
        "driver_origins": origins,
        # A launcher or engine pid that changed between snapshots is a restart
        # (or a second instance that replaced the first).
        "driver_restarts": max(0, restarts),
    }


def cpu_samples(facts):
    """Returns the cumulative CPU samples per process: {key: [(t, cpu_s, row)]}."""
    series = {}
    for kind, fields, _source in facts:
        if kind != "instance":
            continue
        t, cpu = number(fields.get("t")), number(fields.get("cpu_s"))
        if t is None or cpu is None:
            continue
        series.setdefault(instance_key(fields), []).append((t, cpu, fields))
    for rows in series.values():
        rows.sort(key=lambda row: row[0])
    return series


def window_cpu(series, start, end):
    """Computes each process's CPU over [start, end] from cumulative samples.

    The samples nearest outside the window bound it, so the figure covers at
    least the window (the sampler period is the error bar).

    Args:
        series: The cpu_samples() dict.
        start: Window start, epoch seconds.
        end: Window end, epoch seconds.

    Returns:
        A list of dicts {name, pid, role, cpu_ms, span_ms, percent}, highest first.
    """
    rows = []
    for samples in series.values():
        before = [s for s in samples if s[0] <= start]
        after = [s for s in samples if s[0] >= end]
        if not before or not after:
            continue
        first, last = before[-1], after[0]
        span = last[0] - first[0]
        if span <= 0:
            continue
        used = max(0.0, last[1] - first[1])
        fields = last[2]
        rows.append(
            {
                "name": fields.get("name", "?"),
                "pid": fields.get("pid", "?"),
                "role": fields.get("role", "?"),
                "cpu_ms": round(used * 1000),
                "span_ms": round(span * 1000),
                "percent": round(100.0 * used / span, 2),
            }
        )
    rows.sort(key=lambda row: -row["cpu_ms"])
    return rows


def iso_epoch(text):
    """Returns the epoch seconds of an ISO UTC time ("...Z"), or None."""
    if not text:
        return None
    try:
        moment = datetime.datetime.strptime(text.rstrip("Z"), "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    return moment.replace(tzinfo=datetime.timezone.utc).timestamp()


def field_run_results(folder):
    """Reads every field run step result of the report (attempts included).

    Args:
        folder: The report folder.

    Returns:
        A list of result dicts, each with its attempt folder name.
    """
    results = []
    for directory in sorted(
        p for p in folder.iterdir() if p.is_dir() and p.name.startswith("field_run")
    ):
        for path in sorted(directory.glob("[0-9][0-9]_*.json")):
            try:
                document = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(document, dict) and document.get("step"):
                document["_attempt"] = directory.name
                results.append(document)
    return results


def build_env(folder, os_tag, facts, results):
    """Builds the env.json document.

    Args:
        folder: The report folder.
        os_tag: mac, linux or win.
        facts: The read_facts() list.
        results: The field_run_results() list.

    Returns:
        The env.json dict.
    """
    environment = {}
    remappers, permissions, devices, layouts, cpu = [], [], [], [], []
    for kind, fields, source in facts:
        if kind == "env":
            environment.update(fields)
        elif kind == "remapper":
            remappers.append(fields)
        elif kind == "permission":
            permissions.append(fields)
        elif kind == "device":
            devices.append(fields)
        elif kind == "layout":
            layouts.append(fields)
        elif kind == "cpu":
            cpu.append(dict(fields, source=source))
    idle = None
    series = cpu_samples(facts)
    for result in results:
        if result.get("step") in IDLE_STEPS:
            start = iso_epoch(result.get("started_at"))
            end = iso_epoch(result.get("finished_at"))
            if start is not None and end is not None:
                idle = {
                    "step": result["step"],
                    "verdict": result.get("verdict"),
                    "started_at": result.get("started_at"),
                    "finished_at": result.get("finished_at"),
                    "processes": window_cpu(series, start, end),
                }
    return {
        "schema": SCHEMA,
        "os": os_tag,
        "report": folder.name,
        "environment": environment,
        "instances": summarise_instances(facts),
        "remappers": remappers,
        "permissions": permissions,
        "devices": devices,
        "layouts": layouts,
        "cpu": cpu,
        "idle_window_cpu": idle,
    }


# ===========================================
# ======= 3/ Timeline =======================
# ===========================================


def read_step_times(folder):
    """Reads step_times.tsv: one dict per collector step or phase."""
    events = []
    for path in [folder / STEP_TIMES, folder / "0_main" / STEP_TIMES]:
        if not path.is_file():
            continue
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = raw.split("\t")
            if len(parts) < 6 or parts[0] == "name":
                continue
            start, end, budget = number(parts[2]), number(parts[3]), number(parts[5], 0.0)
            if start is None or end is None:
                continue
            events.append(
                {
                    "source": parts[1] or "collector",
                    "name": parts[0],
                    "start": start,
                    "end": end,
                    "duration_s": round(end - start, 3),
                    "status": parts[4],
                    "budget_s": budget or None,
                    "over": bool(budget) and end - start >= budget,
                }
            )
        break
    return events


def result_events(results):
    """Turns the field run results into timeline events."""
    events = []
    for result in results:
        end = iso_epoch(result.get("finished_at"))
        elapsed = number(result.get("elapsed_ms"), 0.0) / 1000.0
        start = iso_epoch(result.get("started_at"))
        if end is None and start is None:
            continue
        if start is None:
            start = end - elapsed
        if end is None or end - start < elapsed:
            end = start + elapsed
        deadline = number(result.get("deadline_ms"), 0.0) / 1000.0
        verdict = result.get("verdict", "?")
        events.append(
            {
                "source": "field_run" if result["_attempt"] == "field_run" else result["_attempt"],
                "name": result["step"],
                "start": start,
                "end": end,
                "duration_s": round(elapsed, 3),
                "status": verdict,
                "budget_s": deadline or None,
                "over": verdict == "timeout" or (deadline > 0 and elapsed > deadline),
            }
        )
    return events


def driver_events(folder, start, end):
    """The driver's timed lines inside [start, end] from the scrubbed day logs."""
    events = []
    logs = sorted(folder.glob("*.log")) + sorted((folder / "1_logs").glob("*.log"))
    for path in logs:
        with path.open(encoding="utf-8-sig", errors="replace") as handle:
            for raw in handle:
                if not DRIVER_TIMED.search(raw):
                    continue
                match = LOG_RECORD.match(raw.rstrip("\r\n"))
                if not match:
                    continue
                try:
                    moment = datetime.datetime.strptime(
                        match.group("day") + " " + match.group("clock"), "%Y-%m-%d %H:%M:%S"
                    ).timestamp()
                except ValueError:
                    continue
                if start is not None and not start - 60 <= moment <= end + 60:
                    continue
                ms = re.search(r"(\d+(?:\.\d+)?) ?ms\b", match.group("rest"))
                events.append(
                    {
                        "source": "driver",
                        "name": match.group("rest")[:LINE_CHARS],
                        "start": moment,
                        "end": moment,
                        "duration_s": round(float(ms.group(1)) / 1000.0, 3) if ms else 0.0,
                        "status": match.group("level").lower(),
                        "budget_s": None,
                        "over": "Over budget" in raw,
                    }
                )
    events.sort(key=lambda event: -event["duration_s"])
    return events[:DRIVER_LINES_KEPT]


def clock(epoch):
    """Formats an epoch in this machine's local time."""
    return datetime.datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M:%S")


def build_timeline(folder, results):
    """Builds the timeline document and its text.

    Args:
        folder: The report folder.
        results: The field_run_results() list.

    Returns:
        A (timeline dict, text) pair.
    """
    steps = read_step_times(folder)
    runs = result_events(results)
    span = [e["start"] for e in steps + runs] + [e["end"] for e in steps + runs]
    start, end = (min(span), max(span)) if span else (None, None)
    driver = driver_events(folder, start, end)
    events = sorted(steps + runs + driver, key=lambda event: (event["start"], event["source"]))
    timed = [e for e in steps + runs]
    slowest = sorted(timed, key=lambda event: -event["duration_s"])[:SLOWEST_SHOWN]
    over = [e for e in steps + runs + driver if e["over"]]
    document = {
        "schema": SCHEMA,
        "span": {"start": start, "end": end, "seconds": round(end - start, 1) if span else None},
        "events": events,
        "slowest": slowest,
        "over_budget": over,
        "collector_seconds": round(
            sum(e["duration_s"] for e in steps if e["source"] == "collector"), 1
        ),
    }
    lines = ["# Timeline of field report " + folder.name, ""]
    if span:
        lines.append(
            "Run: {} to {} ({:.0f} s); collector steps {:.0f} s in all.".format(
                clock(start), clock(end), end - start, document["collector_seconds"]
            )
        )
    lines += ["", "## Slowest steps", ""]
    for index, event in enumerate(slowest, 1):
        lines.append(
            "{:>2}. {:>9.1f} s  [{}] {}{}{}".format(
                index,
                event["duration_s"],
                event["source"],
                event["name"],
                "  (budget {:.0f} s)".format(event["budget_s"]) if event["budget_s"] else "",
                "  OVER BUDGET" if event["over"] else "",
            )
        )
    if not slowest:
        lines.append("No timed step.")
    lines += ["", "## Over budget", ""]
    lines += [
        "- [{}] {}: {:.1f} s{}".format(
            e["source"],
            e["name"],
            e["duration_s"],
            " (budget {:.0f} s)".format(e["budget_s"]) if e["budget_s"] else "",
        )
        for e in over
    ] or ["Nothing over its budget."]
    lines += ["", "## Chronological", ""]
    for event in events:
        offset = "+{:.0f} s".format(event["start"] - start) if start is not None else ""
        lines.append(
            "{} {:>8}  [{}] {}  {:.1f} s  {}{}".format(
                clock(event["start"]),
                offset,
                event["source"],
                event["name"],
                event["duration_s"],
                event["status"],
                "  OVER BUDGET" if event["over"] else "",
            )
        )
    return document, "\n".join(lines) + "\n"


def build(folder, os_tag):
    """Writes env.json, timeline.json and timeline.txt into the report folder."""
    facts = read_facts(folder)
    results = field_run_results(folder)
    env = build_env(folder, os_tag, facts, results)
    timeline, text = build_timeline(folder, results)
    for name, document in ((ENV_JSON, env), (TIMELINE_JSON, timeline)):
        with (folder / name).open("w", encoding="utf-8", newline="\n") as handle:
            json.dump(document, handle, ensure_ascii=False, indent=1, sort_keys=True)
            handle.write("\n")
    (folder / TIMELINE_TXT).write_text(text, encoding="utf-8", newline="\n")
    instances = env["instances"]
    print(
        "[field-report] Facts: {} driver instance(s) at most at once, {} remapper fact(s), {} permission fact(s), "
        "{} timed step(s); see {} and {}.".format(
            instances["max_drivers"],
            len(env["remappers"]),
            len(env["permissions"]),
            len(timeline["events"]),
            ENV_JSON,
            TIMELINE_TXT,
        )
    )
    return 0


# ===========================================
# ======= 4/ Karabiner-Elements summary =====
# ===========================================

# Device identifier keys that are safe to publish; a Bluetooth address or a
# serial number never leaves the machine.
DEVICE_KEYS = ("vendor_id", "product_id", "is_keyboard", "is_pointing_device", "is_game_pad")


def karabiner_summary(config_path, devices_path):
    """Prints a summary of a Karabiner-Elements configuration, with no user text.

    Profile names, rule descriptions and shell commands are the user's own and
    stay out: only counts, the selected profile's index and the per-device
    flags (which devices Karabiner grabs or ignores) are printed.

    Args:
        config_path: karabiner.json.
        devices_path: The `karabiner_cli --list-connected-devices` JSON, or None.

    Returns:
        The exit status.
    """
    try:
        config = json.loads(pathlib.Path(config_path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print("karabiner.json unreadable: {}".format(type(error).__name__))
        return 1
    profiles = config.get("profiles", []) if isinstance(config, dict) else []
    print("profiles: {}".format(len(profiles)))
    for index, profile in enumerate(profiles):
        complex_rules = profile.get("complex_modifications", {}).get("rules", [])
        manipulators = sum(len(rule.get("manipulators", [])) for rule in complex_rules)
        shell = sum(
            1
            for rule in complex_rules
            for manipulator in rule.get("manipulators", [])
            for target in manipulator.get("to", []) + manipulator.get("to_if_alone", [])
            if isinstance(target, dict) and "shell_command" in target
        )
        devices = profile.get("devices", [])
        print(
            "profile {}: selected={} simple_modifications={} fn_function_keys={} complex_rules={} "
            "manipulators={} shell_commands={} device_entries={} virtual_keyboard_type={}".format(
                index,
                bool(profile.get("selected")),
                len(profile.get("simple_modifications", [])),
                len(profile.get("fn_function_keys", [])),
                len(complex_rules),
                manipulators,
                shell,
                len(devices),
                profile.get("virtual_hid_keyboard", {}).get("keyboard_type_v2", "default"),
            )
        )
        if not profile.get("selected"):
            continue
        for device in devices:
            identifiers = device.get("identifiers", {})
            print(
                "  device {}: ignore={} simple_modifications={} disable_built_in_keyboard_if_exists={}".format(
                    " ".join(
                        "{}={}".format(key, identifiers[key])
                        for key in DEVICE_KEYS
                        if key in identifiers
                    ),
                    device.get("ignore", "default"),
                    len(device.get("simple_modifications", [])),
                    device.get("disable_built_in_keyboard_if_exists", False),
                )
            )
    if devices_path:
        try:
            connected = json.loads(pathlib.Path(devices_path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            print("connected devices unreadable: {}".format(type(error).__name__))
            return 0
        selected = next((p for p in profiles if p.get("selected")), {})
        ignored = {
            (d.get("identifiers", {}).get("vendor_id"), d.get("identifiers", {}).get("product_id"))
            for d in selected.get("devices", [])
            if d.get("ignore") is True
        }
        for device in connected if isinstance(connected, list) else []:
            identifiers = device.get("device_identifiers", {})
            pair = (identifiers.get("vendor_id"), identifiers.get("product_id"))
            keyboard = bool(identifiers.get("is_keyboard"))
            grabbed = "no" if pair in ignored else ("yes" if keyboard else "default_off")
            print(
                "\t".join(
                    [
                        "fact",
                        "device",
                        "source=karabiner",
                        "name={}".format(str(device.get("product", "?"))[:60]),
                        "vendor_id={}".format(identifiers.get("vendor_id", "?")),
                        "product_id={}".format(identifiers.get("product_id", "?")),
                        "keyboard={}".format("yes" if keyboard else "no"),
                        "builtin={}".format("yes" if device.get("is_built_in_keyboard") else "no"),
                        "grabbed={}".format(grabbed),
                    ]
                )
            )
    return 0


# The IOHIDDevice keys that are safe to publish; SerialNumber and the
# Bluetooth address stay on the Mac.
HID_KEYS = ("Product", "Manufacturer", "VendorID", "ProductID", "Transport", "Built-In")


def hid_summary(plist_path):
    """Prints the keyboards of an `ioreg -a -r -c IOHIDDevice` dump as facts.

    Args:
        plist_path: The ioreg XML output.

    Returns:
        The exit status.
    """
    import plistlib

    try:
        with open(plist_path, "rb") as handle:
            devices = plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print("ioreg output unreadable: {}".format(type(error).__name__))
        return 0
    keyboards = 0
    for device in devices if isinstance(devices, list) else []:
        if device.get("PrimaryUsagePage") != 1 or device.get("PrimaryUsage") != 6:
            continue
        keyboards += 1
        values = {key: device.get(key, "?") for key in HID_KEYS}
        virtual = "VirtualHID" in str(values["Product"]) or "Karabiner" in str(values["Product"])
        print(
            "\t".join(
                [
                    "fact",
                    "device",
                    "source=ioreg",
                    "name={}".format(str(values["Product"])[:60]),
                    "manufacturer={}".format(str(values["Manufacturer"])[:40]),
                    "vendor_id={}".format(values["VendorID"]),
                    "product_id={}".format(values["ProductID"]),
                    "transport={}".format(values["Transport"]),
                    "builtin={}".format("yes" if values["Built-In"] is True else "no"),
                    "keyboard=yes",
                    "virtual={}".format("yes" if virtual else "no"),
                    "grabbed=unknown",
                ]
            )
        )
    print("\t".join(["fact", "env", "keyboards={}".format(keyboards)]))
    return 0


def main():
    """Runs one subcommand and returns the exit status."""
    parser = argparse.ArgumentParser(
        description="Field report facts, environment summary and timeline"
    )
    sub = parser.add_subparsers(dest="command", required=True)
    build_parser = sub.add_parser("build", help="write env.json, timeline.json and timeline.txt")
    build_parser.add_argument("folder", type=pathlib.Path)
    build_parser.add_argument("--os", required=True, choices=("mac", "linux", "win"))
    karabiner_parser = sub.add_parser(
        "karabiner", help="summarise a Karabiner-Elements configuration"
    )
    karabiner_parser.add_argument("config")
    karabiner_parser.add_argument("devices", nargs="?")
    hid_parser = sub.add_parser("hid", help="list the keyboards of an ioreg -a IOHIDDevice dump")
    hid_parser.add_argument("plist")
    arguments = parser.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if arguments.command == "build":
        if not arguments.folder.is_dir():
            print(
                "field-report-facts: {} is not a folder.".format(arguments.folder), file=sys.stderr
            )
            return 2
        return build(arguments.folder, arguments.os)
    if arguments.command == "hid":
        return hid_summary(arguments.plist)
    return karabiner_summary(arguments.config, arguments.devices or None)


if __name__ == "__main__":
    sys.exit(main())
