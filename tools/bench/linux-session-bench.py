#!/usr/bin/env python3
# tools/bench/linux-session-bench.py
"""Latency of the Linux daemon in a real desktop session, as medians and p95.

The real daemon runs unchanged over the container kernel model
(static/ergopti_plus/linux/tests/hardware/virtual_kernel_preload.c) in an X
session (Xvfb, openbox, the accessibility bus, a focused GTK field) with a
StatusNotifier host standing in for the panel. Every path is timed from
outside the daemon, at the boundary a user feels:

- startup: process spawn to "Daemon ready", the in-daemon boot summary, the
  layout resolves a boot performs and the first key after it;
- shutdown: SIGTERM to exit (a Reload on Linux is a shutdown plus a boot);
- key: a physical key press written to the model keyboard to the matching
  press on the daemon's virtual keyboard;
- tap-hold: the release of a tap-hold key to the first row of its tap;
- hotstring: the last key of a trigger to the last row of its expansion;
- tray: the root layout, then each submenu's opened + AboutToShow + GetLayout,
  first open (rows built lazily) and re-open;
- a layout switch is not driven: the daemon applies one from its menu only (a
  system setxkbmap changes nothing it reports); its own layout.switch span is
  read from the log like the other spans;
- the daemon's own spans (PerfCounters evidence line at shutdown).

Usage (root, in a private mount namespace, as the container proofs run):
  unshare --mount --propagation private python3 tools/bench/linux-session-bench.py \
      [--runs N] [--keys N] [--json out.json]
Needs what tests/hardware/run_container_proofs.sh needs for X11 (Xvfb,
openbox, dbus-launch, at-spi2-core, luajit with luv, lgi and lfs, gcc,
python3 with Gtk 3 and Atspi). Exit 0 = report printed; 2 = no environment.
"""

import argparse
import json
import os
import pathlib
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
HARDWARE = ROOT / "static/ergopti_plus/linux/tests/hardware"
sys.path.insert(0, str(HARDWARE))

import container_session as cs  # noqa: E402

KEYBOARD = "Ergopti Bench Keyboard"
EV_KEY = 1
# Letters that start no trigger of tests/e2e/fixtures/daemon_keys.toml.
PLAIN_KEYS = (35, 36, 37, 38, 23, 24, 25)  # h j k l i o p
KEY_X, KEY_Z, KEY_SPACE, KEY_CAPSLOCK = 45, 44, 57, 58

# The panel side of the tray, in its own process: a StatusNotifierWatcher that
# waits for the daemon's item, then walks its dbusmenu as a panel does and
# prints one JSON report of timings in milliseconds.
TRAY_PROBE = r"""
import json, sys, time
from gi.repository import Gio, GLib
ready_file, rounds, settle = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
XML = '''<node><interface name="org.kde.StatusNotifierWatcher">
<method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
<method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
<property name="RegisteredStatusNotifierItems" type="as" access="read"/>
<property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
<property name="ProtocolVersion" type="i" access="read"/>
<signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
</interface></node>'''
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
items, loop, report = [], GLib.MainLoop(), {"rounds": []}
def call(name, path, iface, method, sig, values, reply=None):
    return bus.call_sync(name, path, iface, method, GLib.Variant(sig, values),
        GLib.VariantType(reply) if reply else None, Gio.DBusCallFlags.NONE, 10000, None)
def layout(name, menu, parent, depth):
    return call(name, menu, "com.canonical.dbusmenu", "GetLayout", "(iias)",
        (parent, depth, []), "(u(ia{sv}av))").unpack()[1]
def children(node):
    return [c.unpack() if hasattr(c, "unpack") else c for c in node[2]]
def walk():
    name, path = items[-1]
    menu = call(name, path, "org.freedesktop.DBus.Properties", "Get", "(ss)",
        ("org.kde.StatusNotifierItem", "Menu"), "(v)").unpack()[0]
    for index in range(rounds):
        entry = {"submenus": {}}
        t0 = time.perf_counter()
        call(name, menu, "com.canonical.dbusmenu", "AboutToShow", "(i)", (0,), "(b)")
        root = layout(name, menu, 0, 1)
        entry["root_ms"] = (time.perf_counter() - t0) * 1000
        for child in children(root):
            row_id, props = child[0], child[1]
            if props.get("children-display") != "submenu":
                continue
            label = props.get("label", str(row_id)).replace("_", "")
            t1 = time.perf_counter()
            call(name, menu, "com.canonical.dbusmenu", "Event", "(isvu)",
                (row_id, "opened", GLib.Variant("i", 0), 0))
            call(name, menu, "com.canonical.dbusmenu", "AboutToShow", "(i)", (row_id,), "(b)")
            sub = layout(name, menu, row_id, -1)
            entry["submenus"][label] = {"ms": (time.perf_counter() - t1) * 1000,
                "rows": len(children(sub))}
            call(name, menu, "com.canonical.dbusmenu", "Event", "(isvu)",
                (row_id, "closed", GLib.Variant("i", 0), 0))
        call(name, menu, "com.canonical.dbusmenu", "Event", "(isvu)",
            (0, "closed", GLib.Variant("i", 0), 0))
        report["rounds"].append(entry)
        time.sleep(0.2)
    print(json.dumps(report), flush=True)
    loop.quit()
    return False
def on_call(conn, sender, path, iface, method, params, invocation):
    if method == "RegisterStatusNotifierItem":
        service = params.unpack()[0]
        items.append((sender, service) if service.startswith("/") else (service, "/StatusNotifierItem"))
        conn.emit_signal(None, "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
            "StatusNotifierItemRegistered", GLib.Variant("(s)", (service,)))
        if len(items) == 1:
            GLib.timeout_add(int(settle * 1000), walk)
    invocation.return_value(None)
def on_get(conn, sender, path, iface, prop):
    if prop == "RegisteredStatusNotifierItems":
        return GLib.Variant("as", [n + p for n, p in items])
    if prop == "IsStatusNotifierHostRegistered":
        return GLib.Variant("b", True)
    return GLib.Variant("i", 0)
node = Gio.DBusNodeInfo.new_for_xml(XML)
def on_bus(conn, name):
    conn.register_object("/StatusNotifierWatcher", node.interfaces[0], on_call, on_get, None)
def on_name(conn, name):
    open(ready_file, "w").write("ready")
Gio.bus_own_name_on_connection(bus, "org.kde.StatusNotifierWatcher", Gio.BusNameOwnerFlags.NONE,
    on_name, None)
on_bus(bus, None)
GLib.timeout_add(120000, lambda: (print(json.dumps({"error": "no item"})), loop.quit()))
loop.run()
"""


def summarize(values):
    """{n, median, p95, max} of a list of milliseconds, rounded for a report."""
    if not values:
        return {"n": 0}
    ordered = sorted(values)
    p95 = ordered[min(len(ordered) - 1, int(round(0.95 * (len(ordered) - 1))))]
    return {
        "n": len(ordered),
        "median": round(statistics.median(ordered), 2),
        "p95": round(p95, 2),
        "max": round(ordered[-1], 2),
    }


class BenchSession(cs.Session):
    """A container session whose output rows carry their arrival time."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.stamped = []
        self.stamped_lock = threading.Lock()
        self.daemon_flags = []

    def read_uinput(self):
        pending, buffered = [], b""
        while True:
            chunk = os.read(self.uinput_reader, 4096)
            if not chunk:
                return
            arrived = time.monotonic()
            buffered += chunk
            while len(buffered) >= cs.EVENT.size:
                _, _, kind, code, value = cs.EVENT.unpack(buffered[: cs.EVENT.size])
                buffered = buffered[cs.EVENT.size :]
                if kind == cs.EV_SYN and code == 0:
                    with self.stamped_lock:
                        for row in pending:
                            self.stamped.append((arrived, row))
                    for row in pending:
                        if self.desktop_writer:
                            self.to_desktop(row)
                    pending = []
                elif kind == cs.EV_KEY:
                    pending.append("K %d %d" % (code, value))

    def rows_after(self, index):
        with self.stamped_lock:
            return list(self.stamped[index:])

    def cursor(self):
        with self.stamped_lock:
            return len(self.stamped)

    def press_at(self, code, value):
        """Writes one key frame and returns the monotonic time it was written."""
        written = time.monotonic()
        self.key(KEYBOARD, code, value)
        return written


def wait_row(session, cursor, wanted, timeout=2.0):
    """Arrival time of the first output row equal to `wanted` after `cursor`."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for arrived, row in session.rows_after(cursor):
            if row == wanted:
                return arrived
        time.sleep(0.0005)
    return None


def wait_quiet(session, cursor, quiet=0.25, timeout=3.0):
    """Arrival time of the last output row after `cursor`, once output stops."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        rows = session.rows_after(cursor)
        if rows and time.monotonic() - rows[-1][0] >= quiet:
            return rows[-1][0], [row for _, row in rows]
        time.sleep(0.005)
    rows = session.rows_after(cursor)
    return (rows[-1][0] if rows else None), [row for _, row in rows]


def start_daemon(session):
    """Spawns the daemon; returns (spawn to ready ms, Popen)."""
    session.log.write_text("")
    spawned = time.monotonic()
    session.daemon = subprocess.Popen(
        [
            "luajit",
            "ergopti_hotstrings.lua",
            "--verbose",
            *session.daemon_flags,
            "--config",
            "tests/e2e/fixtures/daemon_keys.toml",
        ],
        cwd=cs.DRIVER,
        env=dict(session.env, **session.daemon_env),
        stdout=open(session.log, "w"),
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    while "Daemon ready" not in session.log_text():
        if session.daemon.poll() is not None or time.monotonic() - spawned > 60:
            session.dump_log()
            raise cs.ProofFailure("the daemon did not report itself ready")
        time.sleep(0.002)
    return (time.monotonic() - spawned) * 1000


def stop_daemon(session):
    """SIGTERM to exit, in milliseconds."""
    started = time.monotonic()
    os.killpg(session.daemon.pid, signal.SIGTERM)
    session.daemon.wait(30)
    return (time.monotonic() - started) * 1000


BOOT_SUMMARY = re.compile(
    r"Boot summary: total=(\d+)ms \(cpu (\d+)ms\) heap=(\d+)KB(?: load=(\d+)ms| load=unknown)? stages: (.*)\.$"
)
STAGE = re.compile(r"([a-z][a-z /_-]*?)=(\d+)ms\(cpu (\d+)ms\)")
SPAN = re.compile(r"([a-z_]+\.[a-z_.]+)=(\d+)/([\d.]+)/([\d.]+)ms")


def boot_summary(log):
    for line in log.splitlines():
        match = BOOT_SUMMARY.search(line)
        if match:
            stages = {name.strip(): int(ms) for name, ms, _ in STAGE.findall(match.group(5))}
            if match.group(4):
                stages["load (before boot timing)"] = int(match.group(4))
            return {
                "total": int(match.group(1)),
                "cpu": int(match.group(2)),
                "heap_kb": int(match.group(3)),
                "stages": stages,
            }
    return None


def daemon_spans(log):
    """The daemon's own spans from its last PerfCounters interval line."""
    spans = {}
    for line in log.splitlines():
        if "[PerfCounters] Interval" in line:
            for name, n, total, peak in SPAN.findall(line):
                previous = spans.get(name, (0, 0.0, 0.0))
                spans[name] = (
                    previous[0] + int(n),
                    previous[1] + float(total),
                    max(previous[2], float(peak)),
                )
    return {
        name: {"n": n, "mean_ms": round(total / n, 3) if n else 0, "max_ms": peak}
        for name, (n, total, peak) in spans.items()
    }


LAYOUT_RESOLVE = "Resolving the active keyboard layout"


def layout_resolves_before_ready(log):
    """How many times a boot resolved the layout before it reported ready."""
    return log.split("Daemon ready", 1)[0].count(LAYOUT_RESOLVE)


def first_key(session):
    """The first key after a boot: press to output, in milliseconds, or None."""
    code = PLAIN_KEYS[0]
    cursor = session.cursor()
    written = session.press_at(code, 1)
    arrived = wait_row(session, cursor, "K %d 1" % code)
    time.sleep(0.015)
    session.press_at(code, 0)
    time.sleep(0.05)
    return None if arrived is None else (arrived - written) * 1000


def bench_keys(session, count):
    latencies = []
    for index in range(count):
        code = PLAIN_KEYS[index % len(PLAIN_KEYS)]
        cursor = session.cursor()
        written = session.press_at(code, 1)
        arrived = wait_row(session, cursor, "K %d 1" % code)
        time.sleep(0.015)
        session.press_at(code, 0)
        if arrived is not None:
            latencies.append((arrived - written) * 1000)
        time.sleep(0.03)
        # A word break now and then keeps the hotstring buffer short.
        if index % 12 == 11:
            session.tap(KEYBOARD, KEY_SPACE, hold=0.01, gap=0.03)
    return latencies


def bench_tap_hold(session, count):
    """CapsLock tapped: release to the first row the tap emits."""
    latencies, first_rows = [], None
    for _ in range(count):
        session.press_at(KEY_CAPSLOCK, 1)
        time.sleep(0.04)
        cursor = session.cursor()
        released = session.press_at(KEY_CAPSLOCK, 0)
        arrived, rows = wait_quiet(session, cursor, quiet=0.15)
        if arrived is not None and rows:
            first = session.rows_after(cursor)[0][0]
            latencies.append((first - released) * 1000)
            first_rows = first_rows or rows
        time.sleep(0.1)
    return latencies, first_rows


# The replacement of the bench trigger: its characters are typed after the erase.
REPLACEMENT = "MATCH"


def bench_hotstrings(session, count):
    """x then z (xz -> MATCH): the z press to the expansion's last row, and the
    typing cost per replacement character (first to last typed row, the
    deliberate pause between the erase and the text excluded)."""
    first_row, last_row, per_char, sample = [], [], [], None
    for _ in range(count):
        session.tap(KEYBOARD, KEY_SPACE, hold=0.01, gap=0.05)
        session.tap(KEYBOARD, KEY_X, hold=0.01, gap=0.05)
        cursor = session.cursor()
        written = session.press_at(KEY_Z, 1)
        time.sleep(0.01)
        session.press_at(KEY_Z, 0)
        arrived, rows = wait_quiet(session, cursor, quiet=0.2)
        stamped = session.rows_after(cursor)
        # An expansion erases the typed trigger: a Backspace row proves it ran.
        if arrived is not None and any(row.startswith("K 14 ") for row in rows):
            first_row.append((stamped[0][0] - written) * 1000)
            last_row.append((arrived - written) * 1000)
            erased = max(i for i, (_, row) in enumerate(stamped) if row == "K 14 0")
            if erased + 1 < len(stamped):
                typed = stamped[erased + 1 :]
                per_char.append((typed[-1][0] - typed[0][0]) * 1000 / len(REPLACEMENT))
            sample = sample or ["%+.2f %s" % ((at - written) * 1000, row) for at, row in stamped]
        time.sleep(0.1)
    return first_row, last_row, per_char, sample


def registry_ms(section, key):
    """A value of the shared timing registry, the one source of the boot budget
    and of the hot-path slow threshold."""
    import tomllib

    path = ROOT / "static/ergopti_plus/_shared/modules/timings/constants.toml"
    return tomllib.loads(path.read_text())[section][key]


def median_of(report, name):
    value = report.get(name)
    return value.get("median") if isinstance(value, dict) else None


# Budgets judged by --budgets: (what, measured value in ms, budget in ms, basis).
# Each fails on the code before the 2026-11-11 pass where the pass changed it.
def budget_rows(report):
    slow_ms = registry_ms("logger", "hotpath_slow_ms")
    reopens = [
        entry["reopen"]["median"]
        for entry in report.get("tray_submenus", {}).values()
        if entry["reopen"].get("median") is not None
    ]
    return [
        (
            "startup: spawn to ready (median)",
            median_of(report, "startup_spawn_to_ready_ms"),
            registry_ms("budgets", "boot_total_ms"),
            "[budgets] boot_total_ms",
        ),
        # Two before (the pre-grab resolve repeated the first), one after on X11.
        (
            "boot: layout resolves before ready",
            report.get("layout_resolves_per_boot"),
            1,
            "the X11 source proves the first resolve",
        ),
        (
            "key: press to output (median)",
            median_of(report, "key_press_to_output_ms"),
            slow_ms,
            "[logger] hotpath_slow_ms",
        ),
        (
            "tap-hold: release to tap (median)",
            median_of(report, "tap_hold_release_to_tap_ms"),
            slow_ms,
            "[logger] hotpath_slow_ms",
        ),
        # 1.1 ms per character before (the keymap downloaded per press), 0.45 after.
        (
            "hotstring: typing per character (median)",
            median_of(report, "hotstring_typing_per_char_ms"),
            1.5,
            "keymap reuse between XKB notifications",
        ),
        # 26 ms per re-open before (each dbusmenu call waited the 8 ms idle
        # wait), 3.5 after.
        (
            "tray: submenu re-open (median of submenus)",
            statistics.median(reopens) if reopens else None,
            12,
            "GLib descriptors in the idle wait",
        ),
        (
            "tray: root re-open (median)",
            median_of(report, "tray_root_reopen_ms"),
            12,
            "GLib descriptors in the idle wait",
        ),
    ]


def judge_budgets(report):
    """Prints each budget's verdict; returns True when all hold."""
    held = True
    for what, value, budget, basis in budget_rows(report):
        ok = value is not None and value <= budget
        held = held and ok
        # The one count among the durations is named by its label.
        unit = "" if what.startswith("boot: layout resolves") else " ms"
        print(
            "  %s %s: %s%s (budget %s%s, %s)"
            % ("ok  " if ok else "FAIL", what, value, unit, budget, unit, basis)
        )
    return held


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--runs", type=int, default=7, help="daemon boots (startup and shutdown samples)"
    )
    parser.add_argument("--keys", type=int, default=200, help="plain key presses")
    parser.add_argument("--hotstrings", type=int, default=30)
    parser.add_argument("--tap-holds", type=int, default=30)
    parser.add_argument("--tray-rounds", type=int, default=5)
    parser.add_argument("--json")
    parser.add_argument("--budgets", action="store_true", help="exit 1 when a budget is exceeded")
    args = parser.parse_args()

    session = BenchSession("x11", [{"event": 90, "name": KEYBOARD, "kind": "keyboard"}])
    report = {}
    tray = None
    try:
        session.mount_devices()
        runtime = tempfile.mkdtemp(prefix="ergopti-bench-run-")
        os.chmod(runtime, 0o700)
        session.env["XDG_RUNTIME_DIR"] = runtime
        session.start_desktop()
        session.prepare()
        python = sys.executable
        session.spawn(
            [python, str(HARDWARE / "atspi_fixture_app.py"), "editor", "--lifetime-seconds", "3600"]
        )
        time.sleep(2)

        ready_ms, stop_ms, summaries, resolves, first_keys = [], [], [], [], []
        for run in range(args.runs):
            ready_ms.append(start_daemon(session))
            time.sleep(1.0)
            summaries.append(boot_summary(session.log_text()))
            resolves.append(layout_resolves_before_ready(session.log_text()))
            first = first_key(session)
            if first is not None:
                first_keys.append(first)
            if run < args.runs - 1:
                stop_ms.append(stop_daemon(session))
                time.sleep(0.3)
        report["startup_spawn_to_ready_ms"] = summarize(ready_ms)
        report["startup_first_run_ms"] = round(ready_ms[0], 1)
        valid = [s for s in summaries if s]
        report["boot_total_ms"] = summarize([s["total"] for s in valid])
        report["boot_cpu_ms"] = summarize([s["cpu"] for s in valid])
        stages = {}
        for summary in valid:
            for name, ms in summary["stages"].items():
                stages.setdefault(name, []).append(ms)
        report["boot_stages_ms"] = {name: summarize(values) for name, values in stages.items()}
        report["shutdown_ms"] = summarize(stop_ms)
        report["layout_resolves_per_boot"] = max(resolves)
        report["first_key_after_boot_ms"] = summarize(first_keys)

        # The privacy gate admits expansions after its first focus answer.
        session.tap(KEYBOARD, KEY_SPACE)
        time.sleep(1.0)
        report["key_press_to_output_ms"] = summarize(bench_keys(session, args.keys))
        first, last, per_char, sample = bench_hotstrings(session, args.hotstrings)
        report["hotstring_last_key_to_first_row_ms"] = summarize(first)
        report["hotstring_last_key_to_last_row_ms"] = summarize(last)
        report["hotstring_typing_per_char_ms"] = summarize(per_char)
        report["hotstring_sample_rows"] = sample
        taps, rows = bench_tap_hold(session, args.tap_holds)
        report["tap_hold_release_to_tap_ms"] = summarize(taps)
        report["tap_hold_sample_rows"] = rows
        stop_ms.append(stop_daemon(session))
        report["shutdown_ms"] = summarize(stop_ms)
        report["daemon_spans"] = daemon_spans(session.log_text())

        # The tray: a fresh daemon under a panel, walked lazily then warm.
        ready = pathlib.Path(tempfile.mktemp(prefix="ergopti-bench-tray-"))
        tray = subprocess.Popen(
            [python, "-c", TRAY_PROBE, str(ready), str(args.tray_rounds), "3"],
            env=session.env,
            stdout=subprocess.PIPE,
            text=True,
        )
        cs.wait_for(ready.exists, 10)
        session.daemon_flags = ["--tray"]
        tray_ready = start_daemon(session)
        output = tray.communicate(timeout=180)[0]
        tray_report = json.loads(output.strip().splitlines()[-1])
        report["startup_with_tray_spawn_to_ready_ms"] = round(tray_ready, 1)
        rounds = tray_report.get("rounds", [])
        if rounds:
            report["tray_root_first_ms"] = round(rounds[0]["root_ms"], 2)
            report["tray_root_reopen_ms"] = summarize([r["root_ms"] for r in rounds[1:]])
            submenus = {}
            for label, entry in rounds[0]["submenus"].items():
                submenus[label] = {
                    "first_ms": round(entry["ms"], 2),
                    "rows": entry["rows"],
                    "reopen": summarize(
                        [r["submenus"][label]["ms"] for r in rounds[1:] if label in r["submenus"]]
                    ),
                }
            report["tray_submenus"] = submenus
            report["tray_all_submenus_first_ms"] = round(
                sum(e["ms"] for e in rounds[0]["submenus"].values()), 1
            )
        else:
            report["tray_error"] = tray_report
        stop_daemon(session)
        report["daemon_spans_tray"] = daemon_spans(session.log_text())
    except cs.ProofFailure as failure:
        print("FAIL " + str(failure))
        return 1
    except RuntimeError as error:
        if str(error).startswith("ENVIRONMENT:"):
            print(str(error))
            return 2
        raise
    finally:
        if tray and tray.poll() is None:
            tray.kill()
        if session.daemon and session.daemon.poll() is None:
            os.killpg(session.daemon.pid, signal.SIGKILL)
        session.stop()
    text = json.dumps(report, indent=2, ensure_ascii=False)
    print(text)
    if args.json:
        pathlib.Path(args.json).write_text(text + "\n")
    if args.budgets and not judge_budgets(report):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
