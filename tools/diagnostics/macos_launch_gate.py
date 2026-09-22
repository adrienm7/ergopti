#!/usr/bin/env python3
# tools/diagnostics/macos_launch_gate.py
"""Launch an installed ErgoptiPlus.app over one realistic user state and judge it.

Three packaged-app launch failures escaped a green CI because every smoke test
started from a pristine runner: an arm64-only launcher, a legacy tilde value in
paths.toml, and a configuration folder reached through a symbolic link. Each
scenario below rebuilds one state a real user can have before the application
starts, then applies the same machine-checked verdict:

1. the native launcher acknowledged the Lua logger configuration;
2. launcher.log carries no FATAL line;
3. the driver log appears under the configured logs folder with a completed
   startup marker and no ERROR line;
4. both exact processes are still alive after the observation window;
5. a normal application Quit ends both processes within a bounded time.

Hosted runners cannot grant Accessibility without interactive approval, so a
state that contains config.toml stops at the first event tap. Every healthy
scenario therefore omits config.toml and completes at the first-run wizard,
which sits after config-path resolution, the logger handshake, and the
factory-reset recovery that all of these user states exercise.

v0.0.0-dev.128 passed every such scenario and still vanished on a real Mac
with a completed config.toml: the post-onboarding boot died after the logger
handshake, and the launcher took Hammerspoon's exit status 0 for a Quit. The
configured_symlink scenario rebuilds that user (completed config.toml in a
symlinked, Git-versioned folder) and requires the refusal the runner's missing
Accessibility must now produce: a named launcher FATAL line and the fatal line
in the fallback boot log, never a silent exit. plain_open launches the way a
double-click does, without `open -n`.
"""

import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time

READY_MARKER = "Onboarding wizard opened."
# The launcher's own fatal line; the Lua runtime writes "... FATAL at boot stage".
LAUNCHER_FATAL = "FATAL:"
LUA_FATAL = "FATAL at boot stage"
# FATAL as a word, not inside an identifier such as ERGOPTI_FATAL_REPORT_FILE,
# which the boot log names when it lists the launcher environment.
FATAL_WORD = re.compile(r"(?<![A-Za-z0-9_])FATAL(?![A-Za-z0-9_])")
FALLBACK_BOOT_LOG = Path("/tmp/ErgoptiPlus_boot.log")
CONFIG_TEMPLATE = Path(__file__).resolve().parents[2] / "static/ergopti_plus/macos/_generated/config_template.toml"
CONFIGURED_MARKER = "embedded Hammerspoon bootstrap logger configured"
STARTUP_TIMEOUT_SECONDS = 90
ALIVE_WINDOW_SECONDS = 15
QUIT_TIMEOUT_SECONDS = 10
HS_DOMAIN = "com.ergoptiplus.app.hammerspoon"
OLD_PERSONAL_SHORTCUTS = "static/ergopti_plus/macos/lib/personal_shortcuts.lua"
OLD_PERSONAL_INFO = "static/ergopti_plus/shared/config_schema/examples/personal_info.example.toml"
# Values an older release stored under its unprefixed preference keys.
LEGACY_SETTINGS = (
    ("i18n_locale", "-string", "fr"),
    ("llm.enabled", "-bool", "false"),
    ("llm_backend", "-string", "mlx"),
    ("llm_max_words", "-int", "20"),
    ("magickey_repeat_enabled", "-bool", "true"),
    ("ergopti_menubar_logo_variant", "-string", "default"),
)
SCENARIOS = (
    "clean",
    "upgraded",
    "source_logs",
    "symlink_config",
    "symlink_config_documents",
    "symlink_hammerspoon",
    "symlink_logs",
    "tilde_paths",
    "dangling_logs",
    "configured_symlink",
    "plain_open",
)
# Scenarios launched like a Finder double-click instead of `open -n`.
PLAIN_OPEN_SCENARIOS = {"plain_open"}
# A state that must be refused, and the launcher text that proves the refusal
# names the folder and its reason instead of a bare child exit code.
EXPECTED_REFUSALS = {
    "dangling_logs": ("hammerspoon/logs", "symbolic link"),
    "configured_symlink": ("boot stage 'accessibility'",),
}





# ===================================
# ===================================
# ======= 1/ User state seeding =====
# ===================================
# ===================================

def git_show(revision, path):
    """Return one historical file exactly as an older release shipped it."""
    return subprocess.run(["git", "show", f"{revision}:{path}"], capture_output=True,
        text=True, check=True).stdout


def extract_lua_template(source):
    """Extract the long-string starter an older release wrote for the user."""
    start = source.index("local TEMPLATE = [[\n") + len("local TEMPLATE = [[\n")
    return source[start:source.index("\n]]", start) + 1]


def write_source_run_logs(logs, today):
    """Leave the files a source-tree driver writes with plain Lua io (0644, no lock)."""
    logs.mkdir(parents=True, exist_ok=True)
    (logs / f"ErgoptiPlus_{today}.log").write_text(
        "\n===== source driver session =====\n2026-01-01 [INFO] [init] source run\n", encoding="utf-8")
    (logs / f"ErgoptiPlus_errors_{today}.log").write_text("", encoding="utf-8")
    (logs / "ErgoptiPlus_gestures.log").write_text("source topical line\n", encoding="utf-8")
    (logs / "ErgoptiPlus_2020-01-01.log").write_text("stale dated archive\n", encoding="utf-8")
    for entry in logs.iterdir():
        entry.chmod(0o644)


def seed_personal_files(config_dir, seed_tag):
    """Write the personal files an older release left, but never config.toml."""
    driver = config_dir / "hammerspoon"
    driver.mkdir(parents=True, exist_ok=True)
    if seed_tag:
        (driver / "personal_shortcuts.lua").write_text(
            extract_lua_template(git_show(seed_tag, OLD_PERSONAL_SHORTCUTS)), encoding="utf-8")
        (config_dir / "personal_info.toml").write_text(git_show(seed_tag, OLD_PERSONAL_INFO), encoding="utf-8")
    (config_dir / "wrap_symbols.toml").write_text("", encoding="utf-8")


def write_paths_toml(home, value):
    """Write the launcher-managed bootstrap file exactly as older releases did."""
    managed = home / "Library/Application Support/ErgoptiPlus/paths.toml"
    managed.parent.mkdir(parents=True, exist_ok=True)
    managed.write_text(
        "# Custom paths — auto-generated by ErgoptiPlus.\n"
        "# Edit this file to point to your personal configuration folder.\n"
        f"# If absent or commented out, files are looked up in: {home}/.config/ergopti_plus/\n\n"
        f'ConfigDirPath = "{value}"\n', encoding="utf-8")
    return managed


def seed(scenario, home, seed_tag, today):
    """Create one user state and return what the verdict needs to know about it."""
    default = home / ".config/ergopti_plus"
    repo = home / "gitcfg"
    state = {"config_dir": default, "symlinks": []}

    def link(path, target):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target, target_is_directory=True)
        state["symlinks"].append(str(path))

    if scenario in ("clean", "plain_open"):
        return state
    if scenario == "upgraded":
        seed_personal_files(default, seed_tag)
        for key, kind, value in LEGACY_SETTINGS:
            subprocess.run(["defaults", "write", HS_DOMAIN, key, kind, value], check=True)
    elif scenario == "source_logs":
        seed_personal_files(default, seed_tag)
        write_source_run_logs(default / "hammerspoon/logs", today)
    elif scenario == "symlink_config":
        # A versioned folder where logs/ is gitignored and therefore absent.
        seed_personal_files(repo / "ergopti_plus", seed_tag)
        link(default, repo / "ergopti_plus")
    elif scenario == "symlink_config_documents":
        target = home / "Documents/GitHub/config/ergopti_plus"
        seed_personal_files(target, seed_tag)
        write_source_run_logs(target / "hammerspoon/logs", today)
        link(default, target)
    elif scenario == "symlink_hammerspoon":
        seed_personal_files(default, seed_tag)
        repo.mkdir(parents=True, exist_ok=True)
        shutil.move(str(default / "hammerspoon"), str(repo / "hammerspoon"))
        link(default / "hammerspoon", repo / "hammerspoon")
    elif scenario == "symlink_logs":
        seed_personal_files(default, seed_tag)
        write_source_run_logs(repo / "logs", today)
        link(default / "hammerspoon/logs", repo / "logs")
    elif scenario == "tilde_paths":
        seed_personal_files(repo / "ergopti_plus", seed_tag)
        state["config_dir"] = repo / "ergopti_plus"
        state["paths_toml"] = write_paths_toml(home, "~/gitcfg/ergopti_plus/")
    elif scenario == "configured_symlink":
        # The reporting user: a Git-versioned folder that already holds a
        # completed config.toml, so the wizard is skipped and boot continues.
        target = home / "Documents/GitHub/config/ergopti_plus"
        seed_personal_files(target, seed_tag)
        shutil.copyfile(CONFIG_TEMPLATE, target / "config.toml")
        link(default, target)
    elif scenario == "dangling_logs":
        seed_personal_files(default, seed_tag)
        link(default / "hammerspoon/logs", repo / "missing-logs")
    else:
        raise RuntimeError(f"Unknown scenario {scenario!r}")
    return state





# ===================================
# ===================================
# ======= 2/ Verdict ================
# ===================================
# ===================================

def evaluate(scenario, observation):
    """Return every failed criterion for one scenario; an empty list is a pass."""
    failures = []
    launcher = observation.get("launcher_log", "")
    fatal = [line for line in launcher.splitlines() if FATAL_WORD.search(line)]
    expected = EXPECTED_REFUSALS.get(scenario)
    if expected is not None:
        launcher_fatal = [line for line in fatal if LAUNCHER_FATAL in line]
        if not launcher_fatal:
            failures.append("the refused state produced no FATAL launcher diagnostic")
        elif not all(part in launcher_fatal[-1] for part in expected):
            failures.append(f"the FATAL diagnostic does not name {expected!r}: {launcher_fatal[-1]}")
        if LUA_FATAL not in observation.get("boot_log", ""):
            failures.append("the fatal abort never reached the fallback boot log")
        if observation.get("alive_after_window"):
            failures.append("the application kept running over a refused state")
        return failures

    if CONFIGURED_MARKER not in launcher:
        failures.append("the launcher never acknowledged the Lua logger configuration")
    if fatal:
        failures.append("launcher.log carries a FATAL line: " + fatal[-1])
    driver_log = observation.get("driver_log", "")
    if not driver_log:
        failures.append("no driver log appeared under the configured logs folder")
    elif READY_MARKER not in driver_log:
        failures.append("the driver log has no completed startup marker")
    errors = [line for line in driver_log.splitlines() if "[ERROR]" in line]
    if errors:
        failures.append("the driver logged an ERROR: " + errors[0])
    if not observation.get("alive_after_window"):
        failures.append("the launcher and embedded Hammerspoon did not both survive the observation window")
    if observation.get("quit_seconds") is None:
        failures.append(f"Quit did not end both processes within {QUIT_TIMEOUT_SECONDS} s")
    for problem in observation.get("state_problems", []):
        failures.append(problem)
    return failures


def check_state(scenario, state, home):
    """Report user-state damage the application must never cause."""
    problems = []
    for path in state["symlinks"]:
        if not Path(path).is_symlink():
            problems.append(f"the user's symbolic link {path} was replaced")
    if scenario == "tilde_paths":
        text = state["paths_toml"].read_text(encoding="utf-8")
        if f'ConfigDirPath = "{home}/gitcfg/ergopti_plus/"' not in text:
            problems.append("the legacy tilde ConfigDirPath was not persisted as an absolute path")
    return problems





# ===================================
# ===================================
# ======= 3/ Launch and observe =====
# ===================================
# ===================================

def processes(executable):
    """Resolve only the exact executable command belonging to this fixture."""
    result = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True)
    found = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == str(executable):
            found.append(int(parts[0]))
    return found


def read_text(path):
    """Read one diagnostic file, tolerating its absence."""
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def driver_logs(state):
    """Return the unified driver log text under the configured logs folder."""
    logs = state["config_dir"] / "hammerspoon/logs"
    try:
        files = sorted(p for p in logs.glob("ErgoptiPlus_*.log")
            if not p.name.startswith("ErgoptiPlus_errors_") and p.name[12:13].isdigit())
    except OSError:
        return ""
    return "\n".join(read_text(p) for p in files)


def quit_application(bundle_id, executables):
    """Send the ordinary application Quit and time both processes' exit."""
    started = time.monotonic()
    subprocess.run(["osascript", "-e", f'tell application id "{bundle_id}" to quit'],
        capture_output=True, text=True, timeout=QUIT_TIMEOUT_SECONDS)
    while time.monotonic() - started < QUIT_TIMEOUT_SECONDS:
        if not any(processes(executable) for executable in executables):
            return round(time.monotonic() - started, 3)
        time.sleep(0.25)
    return None


def collect(output, state, home):
    """Retain every early log location and the state tree for the artifact."""
    for path in (home / "Library/Logs/ErgoptiPlus/launcher.log", Path("/tmp/ErgoptiPlus_boot.log"),
            Path("/tmp/ErgoptiPlus_errors_boot.log"),
            home / "Library/Application Support/ErgoptiPlus/paths.toml"):
        if path.is_file():
            shutil.copyfile(path, output / path.name)
    # Lines logged before the driver re-points its logger land in /tmp.
    for path in Path("/tmp").glob("ErgoptiPlus_*.log"):
        if path.is_file() and not (output / path.name).exists():
            shutil.copyfile(path, output / path.name)
    logs = state["config_dir"] / "hammerspoon/logs"
    if logs.is_dir():
        shutil.copytree(logs, output / "driver-logs")
    tree = subprocess.run(["ls", "-laR", str(home / ".config"), str(home / "gitcfg"),
        str(home / "Documents/GitHub")], capture_output=True, text=True)
    (output / "state-tree.txt").write_text(tree.stdout + tree.stderr, encoding="utf-8")
    # A modal window (a launcher alert, an updater prompt) changes what the
    # launcher can observe, so keep what was on screen and every window title.
    subprocess.run(["screencapture", "-x", str(output / "desktop.png")], capture_output=True, timeout=30)
    windows = subprocess.run(["osascript", "-e", 'tell application "System Events" to get '
        '{name, name of every window} of every process whose background only is false'],
        capture_output=True, text=True, timeout=30)
    (output / "windows.txt").write_text(windows.stdout + windows.stderr, encoding="utf-8")
    # Unified log and crash reports explain a child that dies or a launcher that
    # stops logging, which the file logs alone cannot distinguish.
    try:
        unified = subprocess.run(["log", "show", "--style", "syslog", "--last", "4m", "--predicate",
            'process == "ErgoptiPlus" OR process == "Hammerspoon"'],
            capture_output=True, text=True, timeout=120)
        (output / "unified.log").write_text(unified.stdout[-400000:], encoding="utf-8")
    except (OSError, subprocess.TimeoutExpired) as error:
        (output / "unified.log").write_text(f"{type(error).__name__}: {error}\n", encoding="utf-8")
    for folder in (home / "Library/Logs/DiagnosticReports", Path("/Library/Logs/DiagnosticReports")):
        if folder.is_dir():
            for report in folder.iterdir():
                if report.is_file() and ("Hammerspoon" in report.name or "ErgoptiPlus" in report.name):
                    (output / "crash-reports").mkdir(exist_ok=True)
                    shutil.copyfile(report, output / "crash-reports" / report.name)


def print_tails(output):
    """Print the relevant log tails into the job log so a red gate is readable."""
    for name in ("launcher.log", "ErgoptiPlus_boot.log", "ErgoptiPlus_errors_boot.log"):
        text = read_text(output / name)
        if text:
            print(f"----- tail {name}")
            print("\n".join(text.splitlines()[-25:]))
    for path in sorted((output / "driver-logs").glob("*.log")) if (output / "driver-logs").is_dir() else []:
        print(f"----- tail driver-logs/{path.name}")
        print("\n".join(read_text(path).splitlines()[-25:]))


def launch_command(scenario, app):
    """Return how a scenario opens the application."""
    if scenario in PLAIN_OPEN_SCENARIOS:
        return ["open", str(app)]
    return ["open", "-n", str(app)]


def run(app, output, scenario, seed_tag):
    """Seed one state, launch the application, and return the complete report."""
    home = Path.home()
    launcher = app / "Contents/MacOS/ErgoptiPlus"
    child = app / "Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon"
    if not launcher.is_file() or not child.is_file():
        raise RuntimeError("Installed application is missing its executables")
    launcher_log = home / "Library/Logs/ErgoptiPlus/launcher.log"
    if launcher_log.exists() or processes(launcher) or processes(child):
        raise RuntimeError("The launch gate requires a fresh runner")
    with (app / "Contents/Info.plist").open("rb") as handle:
        bundle_id = plistlib.load(handle)["CFBundleIdentifier"]
    arch = subprocess.run(["uname", "-m"], capture_output=True, text=True).stdout.strip()
    report = {"scenario": scenario, "machine": arch, "samples": []}
    state = seed(scenario, home, seed_tag, datetime.date.today().isoformat())
    started = time.monotonic()
    observation = {}
    try:
        result = subprocess.run(launch_command(scenario, app), capture_output=True, text=True, timeout=15)
        report["open"] = {"code": result.returncode, "stderr": result.stderr}
        ready_at = None
        while time.monotonic() - started < STARTUP_TIMEOUT_SECONDS:
            alive = bool(processes(launcher)) and bool(processes(child))
            report["samples"].append({"seconds": round(time.monotonic() - started, 1), "alive": alive})
            if ready_at is None and READY_MARKER in driver_logs(state):
                ready_at = time.monotonic()
            if ready_at is not None and time.monotonic() - ready_at >= ALIVE_WINDOW_SECONDS:
                break
            if not processes(launcher) and time.monotonic() - started > 5:
                break
            # Wait for the launcher's own verdict, which follows the Lua line.
            if LAUNCHER_FATAL in read_text(launcher_log):
                break
            time.sleep(1)
        observation["alive_after_window"] = bool(processes(launcher)) and bool(processes(child))
        observation["quit_seconds"] = (quit_application(bundle_id, (launcher, child))
            if observation["alive_after_window"] else None)
    finally:
        observation["launcher_log"] = read_text(launcher_log)
        observation["boot_log"] = read_text(FALLBACK_BOOT_LOG)
        observation["driver_log"] = driver_logs(state)
        observation["state_problems"] = check_state(scenario, state, home)
        collect(output, state, home)
        for name, executable in (("launcher", launcher), ("hammerspoon", child)):
            for pid in processes(executable):
                subprocess.run(["sample", str(pid), "2", "-file", str(output / f"sample-{name}.txt")],
                    capture_output=True, timeout=60)
        for executable in (launcher, child):
            for pid in processes(executable):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
    report["quit_seconds"] = observation["quit_seconds"]
    report["alive_after_window"] = observation["alive_after_window"]
    report["failures"] = evaluate(scenario, observation)
    return report


def main():
    """Run one scenario on a disposable runner and exit non-zero on any failure."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("app")
    parser.add_argument("output")
    parser.add_argument("scenario", choices=SCENARIOS)
    parser.add_argument("--seed-tag", default="", help="older release whose files seed personal state")
    args = parser.parse_args()
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("The launch gate mutates the user profile and needs a disposable macOS runner")
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = run(Path(args.app).resolve(), output, args.scenario, args.seed_tag)
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if report["failures"]:
        print(f"::error::macOS launch gate [{args.scenario}] failed")
        for failure in report["failures"]:
            print(f"  - {failure}")
        print_tails(output)
        return 1
    print(f"macOS launch gate [{args.scenario}] passed on {report['machine']}; "
        f"quit in {report['quit_seconds']} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
