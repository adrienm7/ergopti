#!/usr/bin/env python3
# tools/dev/field-log-analyse.py
"""Analyse the scrubbed day logs of one field report into analysis.md and .json.

Every field report collector (macOS, Linux, Windows) runs this on the copies
tools/dev/field-log-scrub.py wrote, never on a raw log: the copies carry no
typed text, and the analysis quotes only their lines. The three drivers write
the same record grammar ("YYYY-MM-DD HH:MM:SS:mmm [LEVEL] [module] body", a
"===== ... session opened =====" banner, an "↑ "template" repeated N more
times" summary), so one parser reads them all; the driver-specific spellings
of each measured event are listed in PATTERNS, one row per spelling.

The analysis has four parts:

- errors and warnings grouped by module and message template, with counts,
  first and last time, one example line, and the groups that are new since the
  previous report of the same OS tag in the same reports folder;
- performance: each measured duration with its count, p50, p95, max, worst
  occurrences and a budget verdict. A budget is only ever the value the code
  declares (BUDGETS reads it from its declaration at run time, or the line
  states it); a measure without one says "no budget declared";
- lifecycle: starts, stops, crashes, reloads, sleep and wake, permission
  refusals, Karabiner lease failures, network failures, update checks, event
  tap restarts, and the verdict lines of the field checks;
- what to fix first: the ten items ranked by severity weight times frequency.

tools/test/test-field-log-analyse.cjs replays one vector per driver spelling
(tools/test/fixtures/field-log-analyse/vectors.json) and fails when a driver
source no longer writes a template this analyser reads.

Python 3.8 and the standard library only: the Windows collector runs whatever
Python the PC has.
"""

import argparse
import json
import math
import pathlib
import re
import sys

SCHEMA = 1
ANALYSIS_JSON = "analysis.json"
ANALYSIS_MD = "analysis.md"
# An example line is cut here: the analysis is read on a phone too.
EXAMPLE_CHARS = 300
WORST_SHOWN = 5
LIFECYCLE_SHOWN = 10
TOP_FIXES = 10

RECORD = re.compile(
    r"^(?P<day>\d{4}-\d{2}-\d{2}) (?P<clock>\d{2}:\d{2}:\d{2})(?::(?P<ms>\d{3}))? "
    r"\[(?P<level>[A-Z]+)\] \[(?P<module>[^\]]*)\] ?(?P<body>.*)$"
)
BANNER = re.compile(
    r"^=+ (?P<stamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?::\d{3})?) \S+ (?P<app>\S+) session opened =+$"
)
# The repeat summary every logger writes when it collapses a streak.
REPEAT = re.compile(
    r"^\u2191 \"(?P<template>.*)\" repeated (?P<count>\d+) more times? between "
    r"(?P<first>\S+ \S+) and (?P<last>\S+ \S+)(?: \(last: (?P<sample>.*)\))?\.$"
)
SUPPRESSED = re.compile(r"^\u2191 (?P<count>\d+) identical (?:line|lines) suppressed")

ERROR_LEVELS = ("ERROR", "CRITICAL", "FATAL")
WARNING_LEVELS = ("WARNING", "WARN")

# Severity weights of the "what to fix first" score (weight x occurrences).
WEIGHT_CRASH = 10
WEIGHT_ERROR = 5
WEIGHT_OVER_BUDGET = 3
WEIGHT_WARNING = 1

# A message template: format directives and the variable parts of a concrete
# line become <*>, so a line and its repeat summary land in one group.
_FORMAT_DIRECTIVE = re.compile(r"%[-+ #0]*\d*(?:\.\d+)?[sdifxXgGqc]|\{\d+(?::[^}]*)?\}")
_QUOTED = re.compile(r"'[^']*'|\"[^\"]*\"|\u2018[^\u2019]*\u2019|\u00ab[^\u00bb]*\u00bb")
_HEX = re.compile(r"\b[0-9a-fA-F]{8,}\b")
_NUMBER = re.compile(r"(?<![A-Za-z_])[-+]?\d+(?:[.,:]\d+)*")
_PLACEHOLDERS = re.compile(r"(?:<\*>[\s,.:/x-]*){2,}")


def template_of(body):
    """Returns the message template of one record body or repeat template.

    Args:
        body: The record body, or the template a repeat summary quotes.

    Returns:
        The body with every variable part replaced by <*>.
    """
    text = _FORMAT_DIRECTIVE.sub("<*>", body)
    text = _QUOTED.sub(lambda match: match.group(0)[0] + "<*>" + match.group(0)[-1], text)
    text = _HEX.sub("<*>", text)
    text = _NUMBER.sub("<*>", text)
    return text.strip()


# ===========================================
# ======= 1/ Measured events ================
# ===========================================

# One row per driver spelling of one measured event: (metric, compiled regex,
# value group). A metric that ends with ":" takes its suffix from the "name"
# group. The drivers each pattern covers are named in the vectors file.
PATTERNS = (
    # Boot, the three drivers.
    ("boot.total", re.compile(r"^Boot complete in (?P<ms>\d+(?:\.\d+)?) ms\b"), "ms"),
    ("boot.cpu", re.compile(r"^Boot CPU: (?P<ms>\d+) ms of process CPU over"), "ms"),
    (
        "boot.cpu",
        re.compile(r"^Boot complete in \d+(?:\.\d+)? ms \(cpu (?P<ms>\d+(?:\.\d+)?) ms\)"),
        "ms",
    ),
    (
        "boot.stage:",
        re.compile(r"^Boot stage completed: (?P<name>.+?) in (?P<ms>\d+(?:\.\d+)?) ms \("),
        "ms",
    ),
    (
        "boot.stage:",
        re.compile(r"^Boot stage '(?P<name>[^']+)' done in (?P<ms>\d+(?:\.\d+)?) ms"),
        "ms",
    ),
    (
        "menu.usable",
        re.compile(r"^Complete configured menu usable at (?P<ms>\d+) ms since process start"),
        "ms",
    ),
    (
        "menu.tray_usable",
        re.compile(r"^Tray global commands usable at (?P<ms>\d+) ms since process start"),
        "ms",
    ),
    # Menus.
    ("menu.rebuild", re.compile(r"^Menu tree rebuilt in (?P<ms>\d+(?:\.\d+)?) ms"), "ms"),
    (
        "menu.app_exclusions",
        re.compile(
            r"^Application exclusion menu built successfully \(\d+ excluded app\(s\), (?P<ms>\d+(?:\.\d+)?) ms\)"
        ),
        "ms",
    ),
    (
        "menu.llm_staging",
        re.compile(r"^LLM_Menu_Build: pre-emit staging took (?P<ms>\d+) ms"),
        "ms",
    ),
    # Hot path: macOS and Linux write own and total time, Windows the wall clock.
    (
        "hotpath:",
        re.compile(
            r"^Slow (?P<name>[\w.]+): (?P<ms>\d+(?:\.\d+)?) ms own, \d+(?:\.\d+)? ms total, parent \S+ \(\d+ similar since the last line\)\.$"
        ),
        "ms",
    ),
    (
        "hotpath:",
        re.compile(
            r"^Slow (?P<name>[\w.]+): (?P<ms>\d+(?:\.\d+)?) ms(?: \[excl [\d.]+ ms, nested [\d.]+ ms\])? \(.*\)\.$"
        ),
        "ms",
    ),
    # Main thread (macOS): the evidence line from 250 ms, the warning from 1 s.
    (
        "main_thread.hold",
        re.compile(
            r"^Main-thread hold of (?P<ms>\d+) ms in an hs\.timer\.\w+ callback \((?P<name>[^)]*)\)"
        ),
        "ms",
    ),
    (
        "main_thread.hold",
        re.compile(
            r"^An hs\.timer\.\w+ callback \((?P<name>.*?)\) held the main thread for (?P<ms>\d+) ms"
        ),
        "ms",
    ),
    # Storage.
    ("preferences.save", re.compile(r"^Slow preferences save (?P<ms>\d+) ms"), "ms"),
    ("keystats.ingest", re.compile(r"^Slow ingest tick (?P<ms>\d+) ms"), "ms"),
    (
        "healthcheck.sync",
        re.compile(
            r"^The synchronous diagnostics took (?P<ms>\d+(?:\.\d+)?) ms, over the (?P<budget>\d+(?:\.\d+)?) ms budget"
        ),
        "ms",
    ),
    # LLM: llm.local:<backend> and llm.remote:<provider> carry the budgets of
    # their kind; a parse time (macOS) names the module's backend.
    (
        "llm.parsed:",
        re.compile(r"^\[[^\]]+\] #\d+ PARSED -> \d+ result\(s\) in (?P<ms>\d+) ?ms"),
        "ms",
    ),
    (
        "llm.remote:",
        re.compile(r"^(?:\w+ )?answer of provider '(?P<name>[^']+)' received in (?P<ms>\d+) ?ms"),
        "ms",
    ),
    (
        "llm.local:",
        re.compile(r"^(?:\w+ )?answer of the local server received in (?P<ms>\d+) ?ms"),
        "ms",
    ),
    # Windows: kind, provider and family in one line (llm_request_latency.ahk).
    (
        "llm.",
        re.compile(
            r"^LLM request: kind=(?P<kind>local|remote) provider=(?P<name>[a-z0-9_.:-]+) "
            r"family=[a-z0-9_.:-]+ outcome=ok in (?P<ms>\d+) ms\.$"
        ),
        "ms",
    ),
    ("llm.stream", re.compile(r"^\d+ prediction\(s\) received in (?P<ms>\d+) ?ms from '"), "ms"),
    ("llm.ttft", re.compile(r"^TTFT captured: (?P<ms>\d+(?:\.\d+)?) ms"), "ms"),
    (
        "llm.remote:completion",
        re.compile(r"^Remote completion received \(\d+ chars in (?P<ms>\d+) ms\)"),
        "ms",
    ),
    # macOS: the reload this boot follows, measured by the driver itself.
    ("reload.total", re.compile(r"^Reload completed in (?P<ms>\d+) ms"), "ms"),
    (
        "llm.timeout:",
        re.compile(r"^(?:curl request|Streaming) timed out after (?P<ms>\d+) ms"),
        "ms",
    ),
    ("llm.api_test", re.compile(r"^API test for '[^']*' succeeded in (?P<ms>\d+) ms"), "ms"),
    # Late key events (macOS key_event_health session totals): the line states
    # its own threshold.
    (
        "input.late_key_event",
        re.compile(r"seen (?P<budget>\d+) ms or more late \(max (?P<ms>[1-9]\d*) ms\)"),
        "ms",
    ),
)

# Summaries that carry a distribution rather than one occurrence.
PHASE_SUMMARY = re.compile(
    r"^Phase summary \[(?P<family>[^\]]+)\] over (?P<seconds>\d+) s: (?P<parts>.*)\.$"
)
PHASE_PART = re.compile(
    r"^(?P<name>\S+) n=(?P<n>\d+) mean=(?P<mean>[\d.]+) max=(?P<max>[\d.]+) total=(?P<total>[\d.]+)(?: ms)?$"
)
PHASE_COUNTER = re.compile(r"^#(?P<name>\S+)=(?P<value>\d+)$")
# Windows: one latency distribution per hot-path label and minute.
LATENCY = re.compile(
    r"^Latency '(?P<name>[^']+)': count=(?P<n>\d+), mean=(?P<mean>[\d.]+) ms, min=[\d.]+ ms, "
    r"max=(?P<max>[\d.]+) ms, slow=(?P<slow>\d+)"
)
FIELD_CHECK = re.compile(r"\bcheck=(?P<id>[a-z0-9_]+) verdict=(?P<verdict>[a-z_]+)")
# The driver's own reload, never the hotstring catalogue's rescan (Linux).
RELOAD_REQUEST = re.compile(
    r"^(?:Controlled )?[Rr]eload requested\b(?! \u2014 re-scanning)|^Reloading\b"
)
# The overrun warning every driver writes (_shared/lua/perf_budget.lua).
OVER_BUDGET = re.compile(r"^Over budget: [\w.:-]+ took \d+ ms \(budget \d+ ms\)\.$")
LEASE_TOTALS = re.compile(r"(?P<count>\d+) Karabiner lease failure\(s\)")

# Lifecycle: (category, regex on the body, minimum level or None). One record
# can fall in several categories.
LIFECYCLE = (
    # A banner opens each session; Linux writes none, so its boot line counts.
    ("start", re.compile(r"^Boot timing started\.$"), None),
    (
        "stop",
        re.compile(
            r"(?i)local teardown started|user exit '[^']*' requested|shutting down|\bexit(?:ing)? requested|daemon stopp(?:ed|ing)|driver exit"
        ),
        None,
    ),
    (
        "crash",
        re.compile(
            r"(?i)\bcrash(?:ed|es)?\b|uncaught|traceback|\bpanic\b|segmentation fault|fatal error"
        ),
        "ERROR",
    ),
    ("reload", RELOAD_REQUEST, None),
    (
        "sleep_wake",
        re.compile(
            r"(?i)wake-from-sleep detected|\bwake detected\b|\bsystem (?:will|did) (?:sleep|wake)|resumed from sleep|going to sleep"
        ),
        None,
    ),
    (
        "permission_refused",
        re.compile(
            r"(?i)permission.*\b(?:denied|refused|not granted|missing|revoked)\b|not trusted|\b(?:denied|refused)\b.*permission"
        ),
        "WARNING",
    ),
    (
        "karabiner_lease_failure",
        re.compile(
            r"(?i)\blease\b.*\b(?:fail\w*|refused|lost|expired|unread|waited [\d.]+ s|deadline|poisoned|timed out|could not|cannot|stale)\b"
        ),
        "WARNING",
    ),
    (
        "network_failure",
        re.compile(
            r"(?i)\bPAC\b|proxy|network|connection (?:failed|refused|reset)|could not resolve|hostname|timed out|\bTLS\b|certificate"
        ),
        "WARNING",
    ),
    ("update_check", re.compile(r"(?i)update check|checking for updates|release list"), None),
    (
        "event_tap_disabled",
        re.compile(
            r"(?i)event tap (?:was |found )?disabled|tap disabled by|tap (?:was )?re-?enabled|hook (?:was )?(?:removed|lost)|grab (?:lost|released unexpectedly)"
        ),
        None,
    ),
)
LEVEL_RANK = {
    "TRACE": 0,
    "DEBUG": 1,
    "INFO": 2,
    "START": 2,
    "DONE": 2,
    "SUCCESS": 2,
    "CONSOLE": 2,
    "WARN": 3,
    "WARNING": 3,
    "ERROR": 4,
    "CRITICAL": 5,
    "FATAL": 5,
}


# ===========================================
# ======= 2/ Budgets ========================
# ===========================================


# Every budget is read from the code that declares it: (metric prefix, source
# path, pattern whose first group is the value in ms, inclusive). Inclusive
# when the driver reports the event from the value on (>=), not past it (>).
def toml_key(section, key):
    """Returns the pattern of one key of one section of a TOML declaration.

    Args:
        section: The section name.
        key: The key.

    Returns:
        A pattern whose first group is the key's number.
    """
    return r"(?ms)^\[{}\]\s*$(?:(?!^\[).)*?^{}\s*=\s*(\d+(?:\.\d+)?)".format(
        re.escape(section), re.escape(key)
    )


TIMINGS = "static/ergopti_plus/_shared/modules/timings/constants.toml"
# A prefix ending with ":" covers every metric of that family.
BUDGETS = (
    ("boot.total", TIMINGS, toml_key("budgets", "boot_total_ms"), False),
    ("reload.total", TIMINGS, toml_key("budgets", "driver_reload_ms"), False),
    ("reload.request_to_boot", TIMINGS, toml_key("budgets", "driver_reload_ms"), False),
    ("menu.rebuild", TIMINGS, toml_key("budgets", "menu_rebuild_ms"), False),
    ("llm.local:", TIMINGS, toml_key("budgets", "llm_local_request_ms"), False),
    ("llm.remote:", TIMINGS, toml_key("budgets", "llm_remote_request_ms"), False),
    ("llm.ttft", TIMINGS, toml_key("budgets", "prediction_display_ms"), False),
    (
        "hotpath:",
        "static/ergopti_plus/_shared/modules/timings/constants.toml",
        r"(?ms)^\[logger\]\s*$(?:(?!^\[).)*?^hotpath_slow_ms\s*=\s*(\d+(?:\.\d+)?)",
        False,
    ),
    (
        "main_thread.hold",
        # The logger and the field run read it from this one declaration (9048f0ef).
        "static/ergopti_plus/macos/infra/main_thread_hold.lua",
        r"(?m)^\s*COUNT_MS = (\d+),",
        True,
    ),
    (
        "preferences.save",
        "static/ergopti_plus/macos/infra/preferences.lua",
        r"(?m)^local SLOW_SAVE_REPORT_MS = (\d+)",
        True,
    ),
    (
        "keystats.ingest",
        "static/ergopti_plus/macos/modules/keystats/ingest_trace.lua",
        r"(?m)^M\.REPORT_THRESHOLD_MS = (\d+)",
        True,
    ),
)
# Windows declares a slower threshold for a few hot-path labels.
WINDOWS_SEGMENT_BUDGETS = (
    "static/ergopti_plus/windows/infra/hotpath_profiler.ahk",
    r"_HOTPATH_SLOW_MS_BY_SEGMENT := Map\((?P<body>.*?)\n\)",
)


def load_budgets(repo):
    """Reads every declared budget from its source.

    Args:
        repo: The clone root.

    Returns:
        A pair: {metric prefix: (value, source, inclusive)} and
        {hot-path label: (value, source)}.

    Raises:
        SystemExit: A declaration moved; a silent "no budget" would hide it.
    """
    budgets = {}
    for prefix, relative, pattern, inclusive in BUDGETS:
        path = repo / relative
        try:
            text = path.read_text(encoding="utf-8-sig")
        except OSError as error:
            sys.exit(
                "field-log-analyse: cannot read the budget declaration {}: {}".format(
                    relative, error
                )
            )
        match = re.search(pattern, text)
        if not match:
            sys.exit(
                "field-log-analyse: {} no longer declares the {} budget.".format(relative, prefix)
            )
        budgets[prefix] = (float(match.group(1)), relative, inclusive)
    relative, pattern = WINDOWS_SEGMENT_BUDGETS
    try:
        text = (repo / relative).read_text(encoding="utf-8-sig")
    except OSError as error:
        sys.exit(
            "field-log-analyse: cannot read the budget declaration {}: {}".format(relative, error)
        )
    match = re.search(pattern, text, re.S)
    if not match:
        sys.exit(
            "field-log-analyse: {} no longer declares its per-segment budgets.".format(relative)
        )
    segments = {}
    for label, value in re.findall(r'"([\w.]+)",\s*(\d+(?:\.\d+)?)', match.group("body")):
        segments[label] = (float(value), relative)
    return budgets, segments


def budget_for(metric, budgets, segments):
    """Returns the declared budget of one metric, or None.

    Args:
        metric: The metric name.
        budgets: The first load_budgets map.
        segments: The second load_budgets map.

    Returns:
        A dict {value, source, inclusive}, or None when no budget is declared.
    """
    if metric.startswith("hotpath:") or metric.startswith("latency:"):
        label = metric.split(":", 1)[1]
        if label in segments:
            value, source = segments[label]
            return {"value": value, "source": source, "inclusive": False}
        if "hotpath:" in budgets:
            value, source, inclusive = budgets["hotpath:"]
            return {"value": value, "source": source, "inclusive": inclusive}
        return None
    for prefix, (value, source, inclusive) in budgets.items():
        if prefix == "hotpath:":
            continue
        if metric == prefix or (prefix.endswith(":") and metric.startswith(prefix)):
            return {"value": value, "source": source, "inclusive": inclusive}
    return None


# ===========================================
# ======= 3/ Parsing ========================
# ===========================================


def classify(line):
    """Classifies one log line.

    Args:
        line: One line, without its line ending.

    Returns:
        A dict: kind (record, banner, blank, continuation) and, for a record,
        time, level, module and body.
    """
    if not line.strip():
        return {"kind": "blank"}
    match = BANNER.match(line)
    if match:
        return {"kind": "banner", "time": match.group("stamp")}
    match = RECORD.match(line)
    if not match:
        return {"kind": "continuation"}
    stamp = "{} {}".format(match.group("day"), match.group("clock"))
    if match.group("ms"):
        stamp += ":" + match.group("ms")
    return {
        "kind": "record",
        "time": stamp,
        "level": match.group("level"),
        "module": match.group("module"),
        "body": match.group("body"),
    }


def backend_of(module):
    """Names the LLM backend of a module tag (llm.api_remote -> remote).

    Args:
        module: The record's module tag.

    Returns:
        The backend name.
    """
    tail = module.rsplit(".", 1)[-1]
    return tail[4:] if tail.startswith("api_") else tail


def measures(record):
    """Lists the measured durations one record carries.

    Args:
        record: A classify() record.

    Returns:
        A list of dicts {metric, value, budget (stated in the line, or None),
        context}.
    """
    body = record["body"]
    found = []
    seen = set()
    for index, (metric, pattern, group) in enumerate(PATTERNS):
        if metric in seen:
            continue
        match = pattern.search(body)
        if not match:
            continue
        seen.add(metric)
        name = match.groupdict().get("name")
        if match.groupdict().get("kind"):
            metric = "llm.{}:{}".format(match.group("kind"), name)
        elif metric.endswith(":"):
            if metric.startswith("llm."):
                suffix = name or backend_of(record["module"])
            else:
                suffix = name
            metric = metric + suffix
        stated = match.groupdict().get("budget")
        found.append(
            {
                "metric": metric,
                "value": float(match.group(group)),
                "budget": float(stated) if stated else None,
                "context": name if name and not metric.endswith(name) else "",
                "pattern": index,
            }
        )
        if metric == "menu.rebuild":
            slowest = re.search(r"Slowest: (?P<list>.*)\.$", body)
            if slowest:
                for part, value in re.findall(
                    r"([\w.]+)=(\d+(?:\.\d+)?) ?ms", slowest.group("list")
                ):
                    found.append(
                        {
                            "metric": "menu.submenu:" + part,
                            "value": float(value),
                            "budget": None,
                            "context": "",
                            "pattern": index,
                        }
                    )
    return found


def summaries(record):
    """Lists the distributions one summary record carries.

    Args:
        record: A classify() record.

    Returns:
        A list of dicts {metric, n, mean, max, slow (or None)}, and counters as
        {metric, counter}.
    """
    body = record["body"]
    found = []
    match = PHASE_SUMMARY.match(body)
    if match:
        family = match.group("family")
        for part in match.group("parts").split(" | "):
            part = part.strip()
            phase = PHASE_PART.match(part)
            if phase:
                found.append(
                    {
                        "metric": "phase:{}.{}".format(family, phase.group("name")),
                        "n": int(phase.group("n")),
                        "mean": float(phase.group("mean")),
                        "max": float(phase.group("max")),
                        "slow": None,
                    }
                )
                continue
            counter = PHASE_COUNTER.match(part)
            if counter:
                found.append(
                    {
                        "metric": "counter:{}.{}".format(family, counter.group("name")),
                        "counter": int(counter.group("value")),
                    }
                )
        return found
    match = LATENCY.match(body)
    if match:
        found.append(
            {
                "metric": "latency:" + match.group("name"),
                "n": int(match.group("n")),
                "mean": float(match.group("mean")),
                "max": float(match.group("max")),
                "slow": int(match.group("slow")),
            }
        )
    return found


def lifecycle_of(record):
    """Lists the lifecycle categories of one record.

    Args:
        record: A classify() record.

    Returns:
        The category names, in LIFECYCLE order.
    """
    rank = LEVEL_RANK.get(record["level"], 2)
    found = []
    for category, pattern, minimum in LIFECYCLE:
        if minimum is not None and rank < LEVEL_RANK[minimum]:
            continue
        if category == "karabiner_lease_failure":
            totals = LEASE_TOTALS.search(record["body"])
            if totals:
                # The key-event health totals name the failures they counted.
                if int(totals.group("count")) > 0:
                    found.append(category)
                continue
            if "karabiner" not in (record["module"] + record["body"]).lower():
                continue
        if pattern.search(record["body"]):
            found.append(category)
    return found


def explain(line):
    """Returns what the analyser reads in one line; the vectors replay it.

    Args:
        line: One log line.

    Returns:
        A JSON-serialisable dict.
    """
    item = classify(line)
    if item["kind"] != "record":
        return item
    repeat = REPEAT.match(item["body"])
    item["template"] = template_of(repeat.group("template") if repeat else item["body"])
    item["repeat"] = int(repeat.group("count")) if repeat else 0
    item["measures"] = [
        {"metric": m["metric"], "value": m["value"], "budget": m["budget"], "pattern": m["pattern"]}
        for m in measures(item)
    ]
    item["summaries"] = summaries(item)
    item["lifecycle"] = lifecycle_of(item)
    check = FIELD_CHECK.search(item["body"])
    item["field_check"] = (
        {"id": check.group("id"), "verdict": check.group("verdict")} if check else None
    )
    return item


# ===========================================
# ======= 4/ Analysis =======================
# ===========================================


def percentile(values, fraction):
    """Returns the nearest-rank percentile of a sorted list.

    Args:
        values: The sorted values.
        fraction: 0.5 for p50, 0.95 for p95.

    Returns:
        The value, or None for an empty list.
    """
    if not values:
        return None
    rank = max(1, int(math.ceil(fraction * len(values))))
    return values[rank - 1]


def clip(text):
    """Cuts one example line to EXAMPLE_CHARS."""
    return text if len(text) <= EXAMPLE_CHARS else text[: EXAMPLE_CHARS - 1] + "\u2026"


class Analysis:
    """Accumulates one report's records."""

    def __init__(self):
        self.lines = 0
        self.records = 0
        self.continuations = 0
        self.first = None
        self.last = None
        self.groups = {}
        self.samples = {}
        self.distributions = {}
        self.counters = {}
        self.lifecycle = {}
        self.checks = []
        self.reload_pending = None
        self.last_group = None
        self.perf_groups = set()
        self.banners = 0

    def _group(self, record, template, count, first, last):
        level = record["level"]
        if level not in ERROR_LEVELS and level not in WARNING_LEVELS:
            return None
        key = "{}|{}|{}".format(
            "ERROR" if level in ERROR_LEVELS else "WARNING", record["module"], template
        )
        group = self.groups.get(key)
        if group is None:
            group = self.groups[key] = {
                "key": key,
                "level": "ERROR" if level in ERROR_LEVELS else "WARNING",
                "module": record["module"],
                "template": template,
                "count": 0,
                "first": first,
                "last": last,
                "example": clip(record["line"]),
            }
        group["count"] += count
        group["first"] = min(group["first"], first)
        group["last"] = max(group["last"], last)
        return key

    def _event(self, category, record):
        entry = self.lifecycle.setdefault(
            category, {"count": 0, "first": record["time"], "events": []}
        )
        entry["count"] += 1
        entry["last"] = record["time"]
        if len(entry["events"]) < LIFECYCLE_SHOWN:
            entry["events"].append({"time": record["time"], "line": clip(record["line"])})

    def add(self, line):
        """Reads one line."""
        self.lines += 1
        item = classify(line)
        if item["kind"] == "continuation":
            self.continuations += 1
            return
        if item["kind"] == "blank":
            return
        if item["kind"] == "banner":
            self.banners += 1
            self._event("start", {"time": item["time"], "line": line})
            return
        self.records += 1
        item["line"] = line
        time = item["time"]
        self.first = time if self.first is None else min(self.first, time)
        self.last = time if self.last is None else max(self.last, time)
        body = item["body"]
        suppressed = SUPPRESSED.match(body)
        if suppressed and self.last_group:
            self.groups[self.last_group]["count"] += int(suppressed.group("count"))
            return
        repeat = REPEAT.match(body)
        if repeat:
            # A collapsed streak: its occurrences count, its sample line is the
            # last one, and its times are the streak's own.
            count = int(repeat.group("count"))
            key = self._group(
                item,
                template_of(repeat.group("template")),
                count,
                repeat.group("first"),
                repeat.group("last"),
            )
            self.last_group = key
            sample = repeat.group("sample")
            if sample and key:
                found = measures(dict(item, body=sample))
                if found:
                    self.perf_groups.add(key)
            return
        key = self._group(item, template_of(body), 1, time, time)
        self.last_group = key
        # A driver's own overrun warning is ranked through its measure, once.
        if key and OVER_BUDGET.match(body):
            self.perf_groups.add(key)
        for measure in measures(item):
            self.samples.setdefault(measure["metric"], []).append(
                {
                    "value": measure["value"],
                    "time": time,
                    "budget": measure["budget"],
                    "context": measure["context"],
                }
            )
            if key:
                self.perf_groups.add(key)
        for summary in summaries(item):
            if "counter" in summary:
                self.counters[summary["metric"]] = (
                    self.counters.get(summary["metric"], 0) + summary["counter"]
                )
                continue
            entry = self.distributions.setdefault(
                summary["metric"],
                {"n": 0, "total": 0.0, "max": 0.0, "slow": None, "worst_time": time},
            )
            entry["n"] += summary["n"]
            entry["total"] += summary["mean"] * summary["n"]
            if summary["max"] >= entry["max"]:
                entry["max"] = summary["max"]
                entry["worst_time"] = time
            if summary["slow"] is not None:
                entry["slow"] = (entry["slow"] or 0) + summary["slow"]
        for category in lifecycle_of(item):
            # The drivers that write a banner also log the boot timing start.
            self._event("boot_timing" if category == "start" else category, item)
        check = FIELD_CHECK.search(body)
        if check:
            self.checks.append(
                {
                    "id": check.group("id"),
                    "verdict": check.group("verdict"),
                    "time": time,
                    "source": "log",
                }
            )
        # A reload lasts from its request to the next boot's completion.
        if RELOAD_REQUEST.search(body) and self.reload_pending is None:
            self.reload_pending = time
        elif body.startswith("Boot complete in ") and self.reload_pending is not None:
            seconds = seconds_between(self.reload_pending, time)
            if seconds is not None:
                self.samples.setdefault("reload.request_to_boot", []).append(
                    {
                        "value": seconds * 1000.0,
                        "time": self.reload_pending,
                        "budget": None,
                        "context": "",
                    }
                )
            self.reload_pending = None

    def performance(self, budgets, segments):
        """Returns the performance rows, worst verdict first."""
        rows = []
        for metric, samples in self.samples.items():
            values = sorted(sample["value"] for sample in samples)
            budget = budget_for(metric, budgets, segments)
            stated = [sample["budget"] for sample in samples if sample["budget"] is not None]
            if budget is None and stated:
                budget = {
                    "value": min(stated),
                    "source": "stated in the log line",
                    "inclusive": False,
                }
            over = 0
            if budget is not None:
                for sample in samples:
                    limit = sample["budget"] if sample["budget"] is not None else budget["value"]
                    if sample["value"] > limit or (
                        budget["inclusive"] and sample["value"] >= limit
                    ):
                        over += 1
            worst = sorted(samples, key=lambda sample: -sample["value"])[:WORST_SHOWN]
            rows.append(
                {
                    "metric": metric,
                    "kind": "occurrences",
                    "count": len(values),
                    "p50": percentile(values, 0.5),
                    "p95": percentile(values, 0.95),
                    "max": values[-1],
                    "mean": sum(values) / len(values),
                    "worst": [
                        {"value": s["value"], "time": s["time"], "context": s["context"]}
                        for s in worst
                    ],
                    "budget": budget,
                    "over": over,
                    "verdict": "no_budget" if budget is None else ("over" if over else "within"),
                }
            )
        for metric, entry in self.distributions.items():
            budget = budget_for(metric, budgets, segments)
            over = entry["slow"] if entry["slow"] is not None else None
            if budget is not None and over is None:
                over = 1 if entry["max"] > budget["value"] else 0
            rows.append(
                {
                    "metric": metric,
                    "kind": "summaries",
                    "count": entry["n"],
                    "p50": None,
                    "p95": None,
                    "max": entry["max"],
                    "mean": entry["total"] / entry["n"] if entry["n"] else None,
                    "worst": [
                        {
                            "value": entry["max"],
                            "time": entry["worst_time"],
                            "context": "window maximum",
                        }
                    ],
                    "budget": budget,
                    "over": over or 0,
                    "verdict": "no_budget" if budget is None else ("over" if over else "within"),
                }
            )
        order = {"over": 0, "within": 1, "no_budget": 2}
        rows.sort(key=lambda row: (order[row["verdict"]], family_of(row["metric"]), -row["max"]))
        return rows


def seconds_between(first, last):
    """Returns the seconds between two stamps of the same day, or None.

    Args:
        first: "YYYY-MM-DD HH:MM:SS[:mmm]".
        last: The same.

    Returns:
        last - first in seconds, or None when they are not comparable.
    """

    def parse(stamp):
        match = re.match(r"^(\d{4}-\d{2}-\d{2}) (\d{2}):(\d{2}):(\d{2})(?::(\d{3}))?$", stamp)
        if not match:
            return None
        day, hours, minutes, seconds, millis = match.groups()
        return day, int(hours) * 3600 + int(minutes) * 60 + int(seconds) + int(millis or 0) / 1000.0

    a, b = parse(first), parse(last)
    if a is None or b is None or a[0] != b[0]:
        return None
    return b[1] - a[1]


FAMILIES = (
    ("boot", "Boot"),
    ("reload", "Reload"),
    ("menu", "Menus"),
    ("main_thread", "Main thread"),
    ("hotstrings", "Hotstrings"),
    ("tooltip", "Tooltip and prediction"),
    ("llm", "LLM requests"),
    ("storage", "Storage"),
    ("input", "Input"),
    ("hotpath", "Other hot-path segments"),
    ("phase", "Phase summaries"),
    ("other", "Other"),
)


def family_of(metric):
    """Names the family a metric is reported under."""
    name = metric.split(":", 1)[-1].lower()
    if metric.startswith("boot."):
        return "boot"
    if metric.startswith("reload."):
        return "reload"
    if metric.startswith("menu.") or name.startswith("menu"):
        return "menu"
    if metric.startswith("main_thread."):
        return "main_thread"
    if metric.startswith("llm."):
        return "llm"
    if metric in ("preferences.save", "keystats.ingest", "healthcheck.sync"):
        return "storage"
    if metric.startswith("input."):
        return "input"
    if metric.startswith("hotpath:") or metric.startswith("latency:"):
        if "hotstring" in name or name.startswith("hse.") or name == "onchar":
            return "hotstrings"
        if (
            "tooltip" in name
            or "preview" in name
            or name.startswith("llm.")
            or name.startswith("prefix.")
        ):
            return "tooltip"
        return "hotpath"
    if metric.startswith("phase:") or metric.startswith("counter:"):
        return "phase"
    return "other"


def top_fixes(groups, performance, lifecycle):
    """Ranks what to fix first by severity weight times occurrences.

    Args:
        groups: The error and warning groups.
        performance: The performance rows.
        lifecycle: The lifecycle map.

    Returns:
        At most TOP_FIXES dicts {score, kind, what, count, detail}.
    """
    items = []
    crashes = lifecycle.get("crash")
    if crashes:
        items.append(
            {
                "score": WEIGHT_CRASH * crashes["count"],
                "kind": "crash",
                "what": "crash lines",
                "count": crashes["count"],
                "detail": crashes["events"][0]["line"],
            }
        )
    for group in groups:
        if group.get("perf"):
            continue
        weight = WEIGHT_ERROR if group["level"] == "ERROR" else WEIGHT_WARNING
        items.append(
            {
                "score": weight * group["count"],
                "kind": group["level"].lower(),
                "what": "[{}] {}".format(group["module"], group["template"]),
                "count": group["count"],
                "detail": group["example"],
            }
        )
    for row in performance:
        if row["verdict"] != "over":
            continue
        worst = row["worst"][0]
        items.append(
            {
                "score": WEIGHT_OVER_BUDGET * row["over"],
                "kind": "slow",
                "what": "{} over its {} ms budget".format(
                    row["metric"], fmt(row["budget"]["value"])
                ),
                "count": row["over"],
                "detail": "max {} ms at {}".format(fmt(row["max"]), worst["time"]),
            }
        )
    items.sort(key=lambda item: (-item["score"], item["what"]))
    return items[:TOP_FIXES]


def fmt(value):
    """Formats a millisecond figure for the tables."""
    if value is None:
        return "\u2014"
    return (
        "{:.0f}".format(value) if value >= 100 else "{:.2f}".format(value).rstrip("0").rstrip(".")
    )


VERDICT_MARKS = {
    "pass": "\u2705",
    "fail": "\u274c",
    "skip": "\u23ed\ufe0f",
    "needs_typing": "\u2328\ufe0f",
}
OTHER_MARK = "\u26a0\ufe0f"


def verdict_mark(verdict):
    """Maps a check verdict to the mark every collector prints."""
    return VERDICT_MARKS.get(verdict, OTHER_MARK)


def previous_analysis(out):
    """Finds the analysis of the previous report of the same OS tag.

    Args:
        out: This report's folder, named <tag>-<stamp>.

    Returns:
        The parsed analysis.json, or None.
    """
    tag = out.name.split("-", 1)[0] + "-"
    candidates = (
        sorted(
            folder
            for folder in out.parent.iterdir()
            if folder.is_dir()
            and folder.name.startswith(tag)
            and folder.name < out.name
            and (folder / ANALYSIS_JSON).is_file()
        )
        if out.parent.is_dir()
        else []
    )
    if not candidates:
        return None
    with (candidates[-1] / ANALYSIS_JSON).open(encoding="utf-8") as handle:
        document = json.load(handle)
    document["_folder"] = candidates[-1].name
    return document


def latest_checks(history):
    """Keeps the last verdict of each check run from the logs.

    Args:
        history: Every check verdict of the logs, oldest first.

    Returns:
        One dict per check id, in first-run order, with its runs and failures.
    """
    latest = {}
    for check in history:
        entry = latest.setdefault(check["id"], {"runs": 0, "failures": 0})
        entry.update(check)
        entry["runs"] += 1
        entry["failures"] += check["verdict"] == "fail"
    return list(latest.values())


def collector_checks(out):
    """Reads the "check=<id> verdict=<v>" lines the collector's own probes wrote.

    Args:
        out: The report folder.

    Returns:
        A list of dicts {id, verdict, source}.
    """
    found = []
    for path in sorted(out.glob("*.txt")):
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = re.match(r"^check=(?P<id>[a-z0-9_]+) verdict=(?P<verdict>[a-z_]+)", line)
                if match:
                    found.append(
                        {
                            "id": match.group("id"),
                            "verdict": match.group("verdict"),
                            "source": path.stem,
                        }
                    )
    return found


def analyse(logs, out, repo):
    """Analyses the logs and returns the analysis document.

    Args:
        logs: The scrubbed day logs, oldest first.
        out: The report folder.
        repo: The clone root (budget declarations).

    Returns:
        The analysis dict.
    """
    budgets, segments = load_budgets(repo)
    analysis = Analysis()
    for path in logs:
        with path.open(encoding="utf-8-sig", errors="replace") as handle:
            for raw in handle:
                analysis.add(raw.rstrip("\r\n"))
    previous = previous_analysis(out)
    known = set(previous.get("error_keys", [])) if previous else None
    groups = sorted(
        analysis.groups.values(), key=lambda group: (group["level"] != "ERROR", -group["count"])
    )
    for group in groups:
        group["new"] = None if known is None else group["key"] not in known
        group["perf"] = group["key"] in analysis.perf_groups
    performance = analysis.performance(budgets, segments)
    boot_timing = analysis.lifecycle.pop("boot_timing", None)
    if not analysis.banners and boot_timing:
        analysis.lifecycle["start"] = boot_timing
    checks = latest_checks(analysis.checks) + collector_checks(out)
    counts = {}
    for check in checks:
        counts[check["verdict"]] = counts.get(check["verdict"], 0) + 1
    return {
        "schema": SCHEMA,
        "logs": [path.name for path in logs],
        "lines": analysis.lines,
        "records": analysis.records,
        "continuations": analysis.continuations,
        "span": {"first": analysis.first, "last": analysis.last},
        "previous": previous["_folder"] if previous else None,
        "errors": groups,
        "error_keys": [group["key"] for group in groups],
        "performance": performance,
        "counters": analysis.counters,
        "lifecycle": analysis.lifecycle,
        "field_checks": {"items": checks, "counts": counts},
        "top_fixes": top_fixes(groups, performance, analysis.lifecycle),
    }


# ===========================================
# ======= 5/ Rendering ======================
# ===========================================


def cell(text):
    """Escapes one Markdown table cell."""
    return str(text).replace("|", "\\|").replace("\n", " ")


def render(document):
    """Renders analysis.md.

    Args:
        document: The analyse() result.

    Returns:
        The Markdown text.
    """
    out = ["# Field log analysis", ""]
    span = document["span"]
    out.append(
        "Logs: {} ({} lines, {} records, {} continuation lines); span {} to {}.".format(
            ", ".join(document["logs"]) or "none",
            document["lines"],
            document["records"],
            document["continuations"],
            span["first"] or "\u2014",
            span["last"] or "\u2014",
        )
    )
    out.append(
        "Previous report compared: {}.".format(
            document["previous"] or "none of this OS tag in this folder"
        )
    )
    out += ["", "## What to fix first", ""]
    if document["top_fixes"]:
        out += ["| # | Score | Kind | What | Count | Detail |", "|---|---|---|---|---|---|"]
        for index, item in enumerate(document["top_fixes"], 1):
            out.append(
                "| {} | {} | {} | {} | {} | {} |".format(
                    index,
                    item["score"],
                    item["kind"],
                    cell(item["what"]),
                    item["count"],
                    cell(item["detail"]),
                )
            )
    else:
        out.append("Nothing to fix: no crash, no error, no warning, no measure over its budget.")
    out += [
        "",
        "Score: crash x{}, error x{}, measure over budget x{}, warning x{}, times the occurrences.".format(
            WEIGHT_CRASH, WEIGHT_ERROR, WEIGHT_OVER_BUDGET, WEIGHT_WARNING
        ),
    ]

    checks = document["field_checks"]
    out += ["", "## Check verdicts", ""]
    if checks["items"]:
        for check in checks["items"]:
            runs = ""
            if check.get("runs", 1) > 1:
                runs = ", last of {} runs, {} failed".format(check["runs"], check["failures"])
            out.append(
                "- {} {}: {} ({}{})".format(
                    verdict_mark(check["verdict"]),
                    check["id"],
                    check["verdict"],
                    check.get("time") or check["source"],
                    runs,
                )
            )
        out += ["", summary_line(checks["counts"])]
    else:
        out.append("No check verdict in the logs or the collector's probes.")

    groups = document["errors"]
    errors = [group for group in groups if group["level"] == "ERROR"]
    new = [group for group in groups if group["new"]]
    out += ["", "## Errors and warnings", ""]
    out.append(
        "{} error group(s), {} warning group(s); {} occurrence(s); {} new since the previous report.".format(
            len(errors),
            len(groups) - len(errors),
            sum(group["count"] for group in groups),
            len(new) if document["previous"] else "no previous report, so none marked",
        )
    )
    if groups:
        out += [
            "",
            "| Level | Module | Template | Count | First | Last | New |",
            "|---|---|---|---|---|---|---|",
        ]
        for group in groups:
            out.append(
                "| {} | {} | {} | {} | {} | {} | {} |".format(
                    group["level"],
                    cell(group["module"]),
                    cell(clip(group["template"])),
                    group["count"],
                    group["first"],
                    group["last"],
                    "new" if group["new"] else "",
                )
            )
        out += ["", "<details><summary>One example line per group</summary>", ""]
        for group in groups:
            out += ["```", group["example"], "```"]
        out += ["", "</details>"]

    out += ["", "## Performance", ""]
    out.append(
        "Budgets are the values the code declares (source named per row); a measure without one says so. "
        "Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; "
        "the phase summaries and the Windows latency lines give the whole distribution (mean and max)."
    )
    performance = document["performance"]
    for family, title in FAMILIES:
        rows = [row for row in performance if family_of(row["metric"]) == family]
        if not rows:
            continue
        out += [
            "",
            "### " + title,
            "",
            "| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for row in rows:
            budget = row["budget"]
            if budget is None:
                text, mark = "no budget declared", "\u2014"
            else:
                text = "{} ms ({})".format(fmt(budget["value"]), budget["source"])
                mark = (
                    "\u2705 within"
                    if row["verdict"] == "within"
                    else "\u274c over ({})".format(row["over"])
                )
            out.append(
                "| {} | {} | {} | {} | {} | {} | {} | {} |".format(
                    cell(row["metric"]),
                    row["count"],
                    fmt(row["p50"]),
                    fmt(row["p95"]),
                    fmt(row["mean"]),
                    fmt(row["max"]),
                    cell(text),
                    mark,
                )
            )
        worst = [row for row in rows if row["kind"] == "occurrences" and row["count"] > 1]
        if worst:
            out += ["", "Worst occurrences:", ""]
            for row in worst[:12]:
                items = ", ".join(
                    "{} ms at {}{}".format(
                        fmt(w["value"]),
                        w["time"],
                        " ({})".format(w["context"]) if w["context"] else "",
                    )
                    for w in row["worst"][:3]
                )
                out.append("- {}: {}".format(row["metric"], cell(items)))
    if document["counters"]:
        out += ["", "### Counters", ""]
        for name, value in sorted(document["counters"].items()):
            out.append("- {}: {}".format(name, value))

    out += ["", "## Lifecycle", ""]
    lifecycle = document["lifecycle"]
    if lifecycle:
        out += ["| Event | Count | First | Last |", "|---|---|---|---|"]
        for category, _pattern, _minimum in LIFECYCLE:
            entry = lifecycle.get(category)
            if entry:
                out.append(
                    "| {} | {} | {} | {} |".format(
                        category, entry["count"], entry["first"], entry["last"]
                    )
                )
        out += ["", "<details><summary>First lines of each event</summary>", ""]
        for category, _pattern, _minimum in LIFECYCLE:
            entry = lifecycle.get(category)
            if entry:
                out += (
                    ["**{}**".format(category), "", "```"]
                    + [event["line"] for event in entry["events"]]
                    + ["```", ""]
                )
        out.append("</details>")
    else:
        out.append("No lifecycle event in the logs.")
    return "\n".join(out) + "\n"


def summary_line(counts):
    """The one summary line every collector prints for the check verdicts."""
    other = sum(value for verdict, value in counts.items() if verdict not in VERDICT_MARKS)
    return (
        "Check verdicts summary: \u2705 {} pass, \u274c {} fail, \u23ed\ufe0f {} skip, \u2328\ufe0f {} needs_typing, "
        "\u26a0\ufe0f {} other.".format(
            counts.get("pass", 0),
            counts.get("fail", 0),
            counts.get("skip", 0),
            counts.get("needs_typing", 0),
            other,
        )
    )


def console(document):
    """Prints the short summary the collector shows."""
    prefix = "[field-report] "
    for check in document["field_checks"]["items"]:
        print(
            "{}  {} check {}: {}".format(
                prefix, verdict_mark(check["verdict"]), check["id"], check["verdict"]
            )
        )
    print(prefix + summary_line(document["field_checks"]["counts"]))
    over = [row for row in document["performance"] if row["verdict"] == "over"]
    errors = [group for group in document["errors"] if group["level"] == "ERROR"]
    print(
        "{}Log analysis: {} error group(s), {} warning group(s), {} measure(s) over budget; see {}.".format(
            prefix, len(errors), len(document["errors"]) - len(errors), len(over), ANALYSIS_MD
        )
    )
    for index, item in enumerate(document["top_fixes"][:3], 1):
        print(
            "{}  fix first #{}: {} ({} x{})".format(
                prefix, index, clip(item["what"])[:140], item["kind"], item["count"]
            )
        )


def main():
    """Writes analysis.md and analysis.json and returns the exit status."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--repo", type=pathlib.Path, required=True, help="the clone root (budget declarations)"
    )
    parser.add_argument("--out", type=pathlib.Path, help="the report folder to write into")
    parser.add_argument(
        "--explain",
        action="store_true",
        help="print what each stdin line is read as, one JSON per line (the test vectors)",
    )
    parser.add_argument(
        "--describe",
        action="store_true",
        help="print the pattern count, the lifecycle categories and the resolved budgets",
    )
    parser.add_argument(
        "logs", nargs="*", type=pathlib.Path, help="the scrubbed day logs, oldest first"
    )
    arguments = parser.parse_args()
    if arguments.describe:
        budgets, segments = load_budgets(arguments.repo)
        print(
            json.dumps(
                {
                    "patterns": len(PATTERNS),
                    "lifecycle": [category for category, _pattern, _minimum in LIFECYCLE],
                    "budgets": {
                        prefix: value for prefix, (value, _source, _inclusive) in budgets.items()
                    },
                    "segments": {label: value for label, (value, _source) in segments.items()},
                    "sources": sorted(
                        {source for _prefix, source, _pattern, _inclusive in BUDGETS}
                        | {WINDOWS_SEGMENT_BUDGETS[0]}
                    ),
                },
                sort_keys=True,
            )
        )
        return 0
    if arguments.explain:
        budgets, segments = load_budgets(arguments.repo)
        for raw in sys.stdin.buffer.read().decode("utf-8").split("\n"):
            if raw == "":
                continue
            item = explain(raw.rstrip("\r"))
            for measure in item.get("measures", []):
                declared = budget_for(measure["metric"], budgets, segments)
                measure["declared"] = declared["value"] if declared else None
            sys.stdout.write(json.dumps(item, ensure_ascii=False, sort_keys=True) + "\n")
        return 0
    if arguments.out is None:
        parser.error("--out is required unless --explain or --describe is given")
    # Only the scrubbed copies the collector wrote into the report are read:
    # a raw log outside it carries typed text.
    folder = arguments.out.resolve()
    for path in arguments.logs:
        if path.resolve().parent != folder:
            sys.exit(
                "field-log-analyse: {} is not a copy inside the report folder; only scrubbed copies "
                "are analysed.".format(path)
            )
    document = analyse(arguments.logs, arguments.out, arguments.repo)
    with (arguments.out / ANALYSIS_JSON).open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(document, handle, ensure_ascii=False, indent=1, sort_keys=True)
        handle.write("\n")
    with (arguments.out / ANALYSIS_MD).open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(render(document))
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    console(document)
    return 0


if __name__ == "__main__":
    sys.exit(main())
