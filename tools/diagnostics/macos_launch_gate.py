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
3. the driver log appears in the configured logs folder (~/Library/Logs/
   ergopti_plus, or LogsDirPath) with a completed startup marker and no ERROR
   line;
4. both exact processes are still alive after the observation window;
5. a normal application Quit ends both processes within a bounded time.

Hosted runners cannot grant Accessibility without interactive approval, so a
state that contains config.toml waits for that grant. Every other healthy
scenario therefore omits config.toml and completes at the first-run wizard,
which sits after config-path resolution, the logger handshake, and the
factory-reset recovery that all of these user states exercise.

v0.0.0-dev.128 passed every such scenario and still vanished on a real Mac
with a completed config.toml: the post-onboarding boot died after the logger
handshake, and the launcher took Hammerspoon's exit status 0 for a Quit. The
configured_symlink scenario rebuilds that user (completed config.toml in a
symlinked, Git-versioned folder). The runner's missing Accessibility must now
keep the application running and waiting for the grant, with that wait in the
driver log, never an exit: a user whose grant went stale with a new build was
otherwise told to relaunch into the same refusal. plain_open launches the way
a double-click does, without `open -n`.

karabiner_config uses the real packaged Hammerspoon JSON runtime and production
build, merge and conditional file publication owners for eight preset/switch
vectors. It preserves personal rules and restores the exact private source
bytes. It never initializes a remap lease, registers a guardian, installs a
Karabiner driver or publishes an active configuration to the user's file.
This qualifies private file generation, not live driver activation.

`--print-matrix {ci,release}` prints the scenario list of one gate profile as
the GitHub Actions output line that feeds the workflow matrix. It takes no
other argument and runs on any host, because it launches nothing.
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

from hs_delayed_timer_probe import (
    NativeDelayedTimerProbe,
    validate_summary,
    validate_control_summary,
)
from hs_karabiner_config_probe import (
    NativeKarabinerConfigProbe,
    validate_summary as validate_karabiner_summary,
)
from hs_native_bootstrap_probe import (
    SupplementaryNativeBootstrap,
    bounded_refusal,
    CONTRACT as BOOTSTRAP_CONTRACT,
    QUALIFICATION as BOOTSTRAP_QUALIFICATION,
)
from hs_script_scope_probe import require_summary

READY_MARKER = "Onboarding wizard opened."
# The configured boot on a runner without Accessibility waits for the grant
# (infra/accessibility_wait.lua) instead of reaching the wizard.
ACCESSIBILITY_WAIT_MARKER = "Waiting for the Accessibility permission"
# The launcher's own fatal line; the Lua runtime writes "... FATAL at boot stage".
LAUNCHER_FATAL = "FATAL:"
LUA_FATAL = "FATAL at boot stage"
# FATAL as a word, not inside an identifier such as ERGOPTI_FATAL_REPORT_FILE,
# which the boot log names when it lists the launcher environment.
FATAL_WORD = re.compile(r"(?<![A-Za-z0-9_])FATAL(?![A-Za-z0-9_])")
# The default logs folder: launcher.log, the fallback boot log and, without a
# LogsDirPath override, the driver's own logs (_shared/modules/paths/app_dirs.toml).
LOGS_RELATIVE = "Library/Logs/ergopti_plus"
LAUNCHER_LOG_NAME = "launcher.log"
FALLBACK_BOOT_LOG_NAME = "ErgoptiPlus_boot.log"
CONFIG_TEMPLATE = (
    Path(__file__).resolve().parents[2]
    / "static/ergopti_plus/macos/_generated/config_template.toml"
)
CONFIGURED_MARKER = "embedded Hammerspoon bootstrap logger configured"
STARTUP_TIMEOUT_SECONDS = 90
ALIVE_WINDOW_SECONDS = 15
QUIT_TIMEOUT_SECONDS = 10
NATIVE_FAILURE_NOTICE_CHARACTER_LIMIT = 1024
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
    "karabiner_config",
    "upgraded",
    "source_logs",
    "symlink_config",
    "symlink_config_documents",
    "symlink_hammerspoon",
    "symlink_logs",
    "symlink_logs_dir",
    "tilde_paths",
    "dangling_logs",
    "configured_symlink",
    "plain_open",
)
# The pull-request and plain-push gate has always launched every scenario but
# these two on one runner. Each repeats a state that a CI scenario already
# seeds (source-run logs: symlink_logs; a symlinked configuration root:
# symlink_config), so they stay with the release gate, which launches every
# scenario on Apple silicon and Intel. A new scenario joins both profiles.
RELEASE_ONLY_SCENARIOS = ("source_logs", "symlink_config_documents")
# The one source of the launch-gate matrix: ci-macos.yml reads a profile
# through --print-matrix instead of repeating scenario names.
PROFILES = {
    "ci": tuple(name for name in SCENARIOS if name not in RELEASE_ONLY_SCENARIOS),
    "release": SCENARIOS,
}
# Scenarios launched like a Finder double-click instead of `open -n`.
PLAIN_OPEN_SCENARIOS = {"plain_open"}
# A state that must be refused, and the launcher text that proves the refusal
# names the folder and its reason instead of a bare child exit code.
EXPECTED_REFUSALS = {
    "dangling_logs": ("gitcfg/ergopti_plus", "symbolic link"),
}
# The completed-startup marker of a scenario that does not reach the wizard.
READY_MARKERS = {
    "configured_symlink": ACCESSIBILITY_WAIT_MARKER,
}


def ready_marker(scenario):
    """Return the driver-log line that proves this scenario's startup completed."""
    return READY_MARKERS.get(scenario, READY_MARKER)


# ===================================
# ===================================
# ======= 1/ User state seeding =====
# ===================================
# ===================================


def git_show(revision, path):
    """Return one historical file exactly as an older release shipped it."""
    return subprocess.run(
        ["git", "show", f"{revision}:{path}"], capture_output=True, text=True, check=True
    ).stdout


def extract_lua_template(source):
    """Extract the long-string starter an older release wrote for the user."""
    start = source.index("local TEMPLATE = [[\n") + len("local TEMPLATE = [[\n")
    return source[start : source.index("\n]]", start) + 1]


def write_source_run_logs(logs, today):
    """Leave the files a source-tree driver writes with plain Lua io (0644, no lock)."""
    logs.mkdir(parents=True, exist_ok=True)
    (logs / f"ErgoptiPlus_{today}.log").write_text(
        "\n===== source driver session =====\n2026-01-01 [INFO] [init] source run\n",
        encoding="utf-8",
    )
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
            extract_lua_template(git_show(seed_tag, OLD_PERSONAL_SHORTCUTS)), encoding="utf-8"
        )
        (config_dir / "personal_info.toml").write_text(
            git_show(seed_tag, OLD_PERSONAL_INFO), encoding="utf-8"
        )
    (config_dir / "wrap_symbols.toml").write_text("", encoding="utf-8")


def logs_folder(home):
    """Return the default logs folder, which launcher.log never leaves."""
    return home / LOGS_RELATIVE


def write_paths_toml(home, value=None, logs_value=None):
    """Write the launcher-managed bootstrap file; with only the configuration
    folder given, exactly as older releases did."""
    managed = home / "Library/Application Support/ErgoptiPlus/paths.toml"
    managed.parent.mkdir(parents=True, exist_ok=True)
    text = (
        "# Custom paths — auto-generated by ErgoptiPlus.\n"
        "# Edit this file to point to your personal configuration folder.\n"
        f"# If absent or commented out, files are looked up in: {home}/.config/ergopti_plus/\n\n"
    )
    if value is not None:
        text += f'ConfigDirPath = "{value}"\n'
    if logs_value is not None:
        text += f'LogsDirPath = "{logs_value}"\n'
    managed.write_text(text, encoding="utf-8")
    return managed


def seed(scenario, home, seed_tag, today):
    """Create one user state and return what the verdict needs to know about it."""
    default = home / ".config/ergopti_plus"
    repo = home / "gitcfg"
    state = {"config_dir": default, "logs_dir": logs_folder(home), "symlinks": []}

    def link(path, target):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target, target_is_directory=True)
        state["symlinks"].append(str(path))

    if scenario in ("clean", "plain_open", "karabiner_config"):
        return state
    if scenario == "upgraded":
        seed_personal_files(default, seed_tag)
        for key, kind, value in LEGACY_SETTINGS:
            subprocess.run(["defaults", "write", HS_DOMAIN, key, kind, value], check=True)
    elif scenario == "source_logs":
        # A source-tree run leaves 0644 files without locks in the default folder.
        seed_personal_files(default, seed_tag)
        write_source_run_logs(logs_folder(home), today)
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
        # The legacy logs folder, versioned through a link: logs no longer go
        # there, and the application must leave the user's link alone.
        seed_personal_files(default, seed_tag)
        write_source_run_logs(repo / "logs", today)
        link(default / "hammerspoon/logs", repo / "logs")
    elif scenario == "symlink_logs_dir":
        # LogsDirPath names a folder the user picked, reached through a link:
        # the logs go to an ergopti_plus subfolder inside the link's target,
        # and the picked folder keeps its own permissions.
        seed_personal_files(default, seed_tag)
        target = repo / "synced-logs"
        target.mkdir(parents=True, exist_ok=True)
        target.chmod(0o755)
        link(home / "SyncedLogs", target)
        state["paths_toml"] = write_paths_toml(home, logs_value=f"{home}/SyncedLogs")
        state["logs_dir"] = home / "SyncedLogs/ergopti_plus"
        state["foreign_folder"] = (target, 0o755)
    elif scenario == "tilde_paths":
        seed_personal_files(repo / "ergopti_plus", seed_tag)
        state["config_dir"] = repo / "ergopti_plus"
        state["paths_toml"] = write_paths_toml(home, "~/gitcfg/ergopti_plus/")
    elif scenario == "configured_symlink":
        # The reporting user: a Git-versioned folder that already holds a
        # completed config.toml, so the wizard is skipped and boot continues.
        target = home / "Documents/GitHub/config/ergopti_plus"
        seed_personal_files(target, seed_tag)
        # The driver reads <config dir>/hammerspoon/config.toml, not the root.
        shutil.copyfile(CONFIG_TEMPLATE, target / "hammerspoon/config.toml")
        link(default, target)
    elif scenario == "dangling_logs":
        # LogsDirPath names the application folder through a link to nothing.
        seed_personal_files(default, seed_tag)
        link(repo / "ergopti_plus", repo / "missing-logs")
        state["paths_toml"] = write_paths_toml(home, logs_value=f"{home}/gitcfg/ergopti_plus")
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
    if observation.get("managed_launch_observation_error") == "observer-cleanup-unsettled":
        failures.append("the supplemental managed public observer cleanup has not settled")
    if scenario in ("clean", "karabiner_config"):
        if observation.get("native_transport_control_error"):
            failures.append(
                "the native AppleEvent control failed: "
                + observation["native_transport_control_error"]
            )
        else:
            try:
                feature_key = (
                    "native_delayed_timer" if scenario == "clean" else "native_karabiner_config"
                )
                validate_control_summary(
                    observation.get("native_transport_control"), observation.get(feature_key)
                )
            except ValueError as error:
                failures.append(f"the native AppleEvent control proof is incomplete: {error}")
    if scenario == "karabiner_config":
        if observation.get("native_karabiner_config_error"):
            failures.append(
                "the native Karabiner build/merge probe failed: "
                + observation["native_karabiner_config_error"]
            )
        else:
            try:
                validate_karabiner_summary(observation.get("native_karabiner_config"))
            except ValueError as error:
                failures.append(f"the native Karabiner build/merge proof is incomplete: {error}")
    if scenario == "clean":
        probe_error = observation.get("native_delayed_timer_error")
        if probe_error:
            failures.append(f"the native delayed-timer probe failed: {probe_error}")
        else:
            try:
                validate_summary(observation.get("native_delayed_timer"))
            except ValueError as error:
                failures.append(f"the native delayed-timer proof is incomplete: {error}")
    launcher = observation.get("launcher_log", "")
    fatal = [line for line in launcher.splitlines() if FATAL_WORD.search(line)]
    expected = EXPECTED_REFUSALS.get(scenario)
    if expected is not None:
        launcher_fatal = [line for line in fatal if LAUNCHER_FATAL in line]
        if not launcher_fatal:
            failures.append("the refused state produced no FATAL launcher diagnostic")
        elif not all(part in launcher_fatal[-1] for part in expected):
            failures.append(
                f"the FATAL diagnostic does not name {expected!r}: {launcher_fatal[-1]}"
            )
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
    elif ready_marker(scenario) not in driver_log:
        failures.append("the driver log has no completed startup marker")
    errors = [line for line in driver_log.splitlines() if "[ERROR]" in line]
    if errors:
        failures.append("the driver logged an ERROR: " + errors[0])
    if not observation.get("alive_after_window"):
        failures.append(
            "the launcher and embedded Hammerspoon did not both survive the observation window"
        )
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
    foreign = state.get("foreign_folder")
    if foreign is not None:
        folder, mode = foreign
        if (folder.stat().st_mode & 0o777) != mode:
            problems.append(f"the folder {folder} the user picked lost its permissions")
    return problems


# ===================================
# ===================================
# ======= 3/ Launch and observe =====
# ===================================
# ===================================


def processes(executable):
    """Resolve only the exact executable command belonging to this fixture."""
    result = subprocess.run(
        ["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True
    )
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
    logs = state["logs_dir"]
    try:
        files = sorted(
            p
            for p in logs.glob("ErgoptiPlus_*.log")
            if not p.name.startswith("ErgoptiPlus_errors_") and p.name[12:13].isdigit()
        )
    except OSError:
        return ""
    return "\n".join(read_text(p) for p in files)


def quit_application(bundle_id, executables):
    """Send the ordinary application Quit and time both processes' exit."""
    started = time.monotonic()
    subprocess.run(
        ["osascript", "-e", f'tell application id "{bundle_id}" to quit'],
        capture_output=True,
        text=True,
        timeout=QUIT_TIMEOUT_SECONDS,
    )
    while time.monotonic() - started < QUIT_TIMEOUT_SECONDS:
        if not any(processes(executable) for executable in executables):
            return round(time.monotonic() - started, 3)
        time.sleep(0.25)
    return None


def collect_owned_windows(output, executables):
    """Inspect owned live application PIDs; unavailable UI is diagnostic evidence.

    Window inspection needs Accessibility, which hosted runners cannot grant.
    It is independent of the five required application launch criteria. A
    refused query cannot prove that the application's windows are absent.
    """
    if not executables:
        raise ValueError("Owned window collection requires exact executable identities")
    deadline = time.monotonic() + 30
    owners = [{"executable": str(path), "pids": processes(path)} for path in executables]
    observations = []
    for owner in owners:
        for pid in owner["pids"]:
            row = {"pid": pid, "executable": owner["executable"], "status": "unavailable"}
            observations.append(row)
            try:
                if pid not in processes(Path(owner["executable"])):
                    row["cause"] = "Owned process exited before its window query"
                    continue
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Owned window collection exhausted its 30 s budget")
                # Bind the process before extracting properties: `whose` on
                # {name, window names} instead filters the materialized lists.
                script = (
                    'tell application "System Events"\n'
                    f"set ownedProcess to first process whose unix id is {pid}\n"
                    "tell ownedProcess\n"
                    "set ownedName to name\n"
                    "set ownedWindowTitles to name of every window\n"
                    "end tell\n"
                    "return {ownedName, ownedWindowTitles}\n"
                    "end tell"
                )
                result = subprocess.run(
                    ["osascript", "-e", script],
                    capture_output=True,
                    text=True,
                    timeout=remaining,
                )
                row.update(
                    exit_status=result.returncode, stdout=result.stdout, stderr=result.stderr
                )
                if result.returncode:
                    row["cause"] = f"Owned window query refused (exit {result.returncode})"
                elif pid not in processes(Path(owner["executable"])):
                    row["cause"] = "Owned process changed before window evidence admission"
                else:
                    row["status"] = "observed"
            except (OSError, subprocess.TimeoutExpired, TimeoutError) as error:
                row["cause"] = f"{type(error).__name__}: {error}"
                if isinstance(error, subprocess.TimeoutExpired):
                    row["stdout"] = (
                        (error.stdout or b"").decode(errors="replace")
                        if isinstance(error.stdout, bytes)
                        else error.stdout or ""
                    )
                    row["stderr"] = (
                        (error.stderr or b"").decode(errors="replace")
                        if isinstance(error.stderr, bytes)
                        else error.stderr or ""
                    )
    status = (
        "not_running"
        if not observations
        else (
            "observed"
            if all(row["status"] == "observed" for row in observations)
            else "unavailable"
        )
    )
    receipt = {
        "status": status,
        "ui_qualified": status == "observed",
        "owners": owners,
        "observations": observations,
        "timeout_seconds": 30,
    }
    text = json.dumps(receipt, indent=2) + "\n"
    (output / "windows.json").write_text(text, encoding="utf-8")
    (output / "windows.txt").write_text(text, encoding="utf-8")
    return receipt


def collect(output, state, home, executables):
    """Retain every early log location and the state tree for the artifact."""
    errors = []
    for path in (
        logs_folder(home) / LAUNCHER_LOG_NAME,
        home / "Library/Application Support/ErgoptiPlus/paths.toml",
    ):
        if path.is_file():
            shutil.copyfile(path, output / path.name)
    # Lines logged before the driver re-points its logger land in the default folder.
    for path in logs_folder(home).glob("ErgoptiPlus_*.log"):
        if path.is_file() and not (output / path.name).exists():
            shutil.copyfile(path, output / path.name)
    logs = state["logs_dir"]
    if logs.is_dir():
        shutil.copytree(logs, output / "driver-logs")
    tree = subprocess.run(
        ["ls", "-laR", str(home / ".config"), str(home / "gitcfg"), str(home / "Documents/GitHub")],
        capture_output=True,
        text=True,
    )
    (output / "state-tree.txt").write_text(tree.stdout + tree.stderr, encoding="utf-8")
    # A screenshot remains useful even when Accessibility cannot qualify UI.
    subprocess.run(
        ["screencapture", "-x", str(output / "desktop.png")], capture_output=True, timeout=30
    )
    windows = collect_owned_windows(output, executables)
    # Unified log and crash reports explain a child that dies or a launcher that
    # stops logging, which the file logs alone cannot distinguish.
    try:
        unified = subprocess.run(
            [
                "log",
                "show",
                "--style",
                "syslog",
                "--last",
                "4m",
                "--predicate",
                'process == "ErgoptiPlus" OR process == "Hammerspoon"',
            ],
            capture_output=True,
            text=True,
            timeout=120,
        )
        (output / "unified.log").write_text(unified.stdout[-400000:], encoding="utf-8")
    except (OSError, subprocess.TimeoutExpired) as error:
        (output / "unified.log").write_text(f"{type(error).__name__}: {error}\n", encoding="utf-8")
    for folder in (
        home / "Library/Logs/DiagnosticReports",
        Path("/Library/Logs/DiagnosticReports"),
    ):
        if folder.is_dir():
            for report in folder.iterdir():
                if report.is_file() and (
                    "Hammerspoon" in report.name or "ErgoptiPlus" in report.name
                ):
                    (output / "crash-reports").mkdir(exist_ok=True)
                    shutil.copyfile(report, output / "crash-reports" / report.name)
    return {"errors": errors, "windows": windows}


def print_native_probe_diagnostics(report):
    """Keep owned native ancestry readable beyond GitHub's annotation limit."""
    for receipt in report.get("native_probe_diagnostics", []):
        for line in receipt.get("primary_error", "").splitlines():
            print(
                f"native probe command{receipt['command']} ({receipt['phase']}): primary error: {line}"
            )
        for line in receipt["observations"].splitlines():
            # Prefix every line so a sampled symbol or refusal cannot be parsed
            # as a GitHub workflow command. The native owner bounds and redacts
            # these observations before putting them in the durable report.
            print(f"native probe command{receipt['command']} ({receipt['phase']}): {line}")
        if receipt.get("additional_commands_omitted"):
            print(
                f"native probe command{receipt['command']} ({receipt['phase']}): [additional diagnostic commands omitted]"
            )

    stage = report.get("supplementary_received_lua_stage")
    if stage is not None:
        print(
            "native probe supplementary received Lua body: "
            f"stage={stage['body_stage']}; publication_ack=unobserved; "
            "timing=unknown; qualified=false"
        )

    managed = report.get("managed_launch_observation")
    if isinstance(managed, dict):
        value = managed.get("finished_launching")
        state = "true" if value is True else "false" if value is False else "unknown"
        timing = managed.get("timing")
        if timing not in ("before_path", "overlaps_path", "after_path"):
            timing = "unknown"
        print(
            "native probe managed public launch state: "
            f"finished_launching={state}; timing={timing}; qualified=false; readiness=unobserved"
        )


def native_scripting_journal_summary(journal, pid):
    """Observe one exact-PID boot line without admitting handler entry or publication."""
    unknown = {"getter": "unknown", "allowed": "unknown", "bridge": "unknown"}
    if (
        type(pid) is not int
        or not 0 < pid < 2**53
        or type(journal) is not str
        or len(journal) > 65536
    ):
        return unknown
    pattern = (
        r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[INFO\] \[init\] "
        r"Native scripting server: pid="
        + str(pid)
        + r"; getter=(missing|error|malformed|boolean); allowed=(unknown|true|false); "
        r"bridge=(missing|callable); handler_registration=unobserved; handler_entry=unobserved\.\n"
    )
    matches = [re.fullmatch(pattern, line) for line in journal.splitlines(keepends=True)]
    matches = [match for match in matches if match is not None]
    if len(matches) != 1:
        return unknown
    getter, allowed, bridge = matches[0].groups()
    if (getter == "boolean") != (allowed in ("true", "false")):
        return unknown
    return {"getter": getter, "allowed": allowed, "bridge": bridge}


def escape_workflow_annotation(value):
    """Escape workflow data without changing the original diagnostic text."""
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def native_failure_notice(scenario, report):
    """Expose closed observed scalars; supplementary evidence never admits the original gate."""

    def record(name):
        value = report.get(name)
        return value if type(value) is dict else {}

    def choice(value, allowed, default="unknown"):
        return value if type(value) is str and value in allowed else default

    scripting = record("native_scripting_journal")
    managed = record("managed_launch_observation")
    received = record("supplementary_received_lua_stage")
    native = record("native_pid_no_prompt_control")
    finished = managed.get("finished_launching")
    finished = str(finished).lower() if type(finished) is bool else "unknown"
    status = native.get("status")
    status = str(status) if type(status) is int and -(2**31) <= status < 2**31 else "unknown"
    bootstrap = record("supplementary_native_bootstrap")
    bootstrap_error = report.get("supplementary_native_bootstrap_error")
    bootstrap_state = "unobserved"
    if bootstrap or bootstrap_error:
        bootstrap_state = "unknown"
        if not bootstrap and type(bootstrap_error) is str and bootstrap_error:
            bootstrap_state = "refused"
        elif (
            not bootstrap_error
            and bootstrap.get("contract") == "hs.startup.supplementary-feature"
            and bootstrap.get("qualification")
            == "installed native feature only; no managed boot or AppleEvent admission"
            and bootstrap.get("feature") in ("delayed_timer", "karabiner_config")
            and all(
                bootstrap.get(key) is True
                for key in ("cleanup_acknowledged", "process_retired", "preference_restored")
            )
        ):
            bootstrap_state = "feature_only"
    message = (
        "Native launch observations: scenario="
        + choice(scenario, ("clean", "karabiner_config"))
        + "; getter="
        + choice(scripting.get("getter"), ("missing", "error", "malformed", "boolean"))
        + "; allowed="
        + choice(scripting.get("allowed"), ("true", "false"))
        + "; bridge="
        + choice(scripting.get("bridge"), ("missing", "callable"))
        + "; journal_publication_ack=unobserved; handler_entry=unobserved"
        + "; finished_launching="
        + finished
        + "; launch_timing="
        + choice(managed.get("timing"), ("before_path", "overlaps_path", "after_path"))
        + "; received_lua="
        + choice(received.get("body_stage"), ("observed", "unobserved"), "unobserved")
        + "; no_prompt_status="
        + status
        + "; no_prompt_origin="
        + choice(native.get("error_origin"), ("none", "send", "handler"))
        + "; no_prompt_outcome="
        + choice(native.get("outcome"), ("acknowledged", "consent_required", "denied", "refused"))
        + "; supplementary_bootstrap="
        + bootstrap_state
        + "; diagnostics_admit_original=false"
    )
    notice = "::notice::" + escape_workflow_annotation(message)
    if len(notice) > NATIVE_FAILURE_NOTICE_CHARACTER_LIMIT:
        return "::notice::Native launch observations unavailable; diagnostics_admit_original=false"
    return notice


def print_tails(output):
    """Print the relevant log tails into the job log so a red gate is readable."""
    for name in (LAUNCHER_LOG_NAME, FALLBACK_BOOT_LOG_NAME):
        text = read_text(output / name)
        if text:
            print(f"----- tail {name}")
            print("\n".join(text.splitlines()[-25:]))
    for path in (
        sorted((output / "driver-logs").glob("*.log")) if (output / "driver-logs").is_dir() else []
    ):
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
    launcher_log = logs_folder(home) / LAUNCHER_LOG_NAME
    if launcher_log.exists() or processes(launcher) or processes(child):
        raise RuntimeError("The launch gate requires a fresh runner")
    with (app / "Contents/Info.plist").open("rb") as handle:
        bundle_id = plistlib.load(handle)["CFBundleIdentifier"]
    arch = subprocess.run(["uname", "-m"], capture_output=True, text=True).stdout.strip()
    report = {"scenario": scenario, "machine": arch, "samples": []}
    state = seed(scenario, home, seed_tag, datetime.date.today().isoformat())
    started = time.monotonic()
    observation = {}
    diagnostic_errors = []
    native_probe = None
    native_result_key = None
    native_owner_settled = False
    if scenario == "clean":
        native_probe = NativeDelayedTimerProbe(app, output, HS_DOMAIN)
        native_result_key = "native_delayed_timer"
    elif scenario == "karabiner_config":
        native_probe = NativeKarabinerConfigProbe(app, output, HS_DOMAIN)
        native_result_key = "native_karabiner_config"
    try:
        if native_probe:
            try:
                native_probe.enable()
            except Exception as error:
                observation[native_result_key + "_error"] = f"{type(error).__name__}: {error}"
        result = subprocess.run(
            launch_command(scenario, app), capture_output=True, text=True, timeout=15
        )
        report["open"] = {"code": result.returncode, "stderr": result.stderr}
        ready_at = None
        while time.monotonic() - started < STARTUP_TIMEOUT_SECONDS:
            alive = bool(processes(launcher)) and bool(processes(child))
            report["samples"].append(
                {"seconds": round(time.monotonic() - started, 1), "alive": alive}
            )
            if ready_at is None and ready_marker(scenario) in driver_logs(state):
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
        if (
            native_probe
            and observation["alive_after_window"]
            and not observation.get(native_result_key + "_error")
        ):
            try:
                child_pids = processes(child)
                if len(child_pids) != 1:
                    raise RuntimeError(
                        "The native probe requires the launcher's single exact child"
                    )
                try:
                    native_probe.start_managed_launch_observation(child_pids[0], processes)
                except Exception:
                    observation["managed_launch_observation_error"] = "observer-start-refused"
                try:
                    observation["native_transport_control"] = native_probe.control(
                        child_pids[0], processes
                    )
                except Exception as error:
                    observation["native_transport_control_error"] = (
                        f"{type(error).__name__}: {error}"
                    )
                try:
                    observation["native_descriptor_constructor"] = native_probe.constructor_control(
                        child_pids[0], processes
                    )
                except Exception as error:
                    detail = native_probe.pid_control_error_diagnostic(error)
                    observation["native_descriptor_constructor_error"] = detail
                    native_probe.retain_primary_error(error, "constructor")
                try:
                    observation["native_pid_transport_control"] = native_probe.control_pid(
                        child_pids[0], processes
                    )
                except Exception as error:
                    # This separate diagnostic cannot replace either original
                    # proof. Retained scripting-child debt refuses its dispatch.
                    detail = native_probe.pid_control_error_diagnostic(error)
                    observation["native_pid_transport_control_error"] = detail
                    native_probe.retain_primary_error(error, "pid_control")
                try:
                    observation["native_pid_no_prompt_control"] = (
                        native_probe.control_pid_no_prompt(child_pids[0], processes)
                    )
                except Exception as error:
                    observation["native_pid_no_prompt_control_error"] = (
                        native_probe.pid_control_error_diagnostic(error)
                    )
                    native_probe.retain_primary_error(error, "pid_no_prompt")
                # The control never replaces the original feature proof. Attempt
                # it independently even after refusal; retained transport debt
                # may itself refuse this call, which is a second honest failure.
                observation[native_result_key] = native_probe.observe(child_pids[0], processes)
            except Exception as error:
                observation[native_result_key + "_error"] = f"{type(error).__name__}: {error}"
            finally:
                observer = native_probe.managed_launch_observation
                if observer is not None:
                    try:
                        observation["managed_launch_observation"] = observer.finish()
                    except Exception:
                        observation["managed_launch_observation_error"] = (
                            "observer-cleanup-unsettled"
                        )
        observation["quit_seconds"] = (
            quit_application(bundle_id, (launcher, child))
            if observation["alive_after_window"]
            else None
        )
    except Exception as error:
        observation["launch_gate_error"] = f"{type(error).__name__}: {error}"
    finally:
        try:
            observation["launcher_log"] = read_text(launcher_log)
            observation["boot_log"] = read_text(logs_folder(home) / FALLBACK_BOOT_LOG_NAME)
            observation["driver_log"] = driver_logs(state)
            observation["state_problems"] = check_state(scenario, state, home)
            try:
                collected = collect(output, state, home, (launcher, child))
                diagnostic_errors.extend(collected["errors"])
                report["owned_windows"] = collected["windows"]
            except Exception as error:
                diagnostic_errors.append(
                    f"Evidence collection failed: {type(error).__name__}: {error}"
                )
            for name, executable in (("launcher", launcher), ("hammerspoon", child)):
                for pid in processes(executable):
                    try:
                        subprocess.run(
                            ["sample", str(pid), "2", "-file", str(output / f"sample-{name}.txt")],
                            capture_output=True,
                            timeout=60,
                            check=True,
                        )
                    except Exception as error:
                        diagnostic_errors.append(
                            f"{name} sample failed: {type(error).__name__}: {error}"
                        )
            for executable in (launcher, child):
                for pid in processes(executable):
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        finally:
            if native_probe:
                try:
                    # Evidence collection can itself fail. Reap the exact writer
                    # before restoring its key even when that earlier cleanup aborted.
                    for pid in processes(child):
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    deadline = time.monotonic() + QUIT_TIMEOUT_SECONDS
                    while processes(child):
                        if time.monotonic() >= deadline:
                            raise RuntimeError(
                                "The native preference writer did not stop before restoration"
                            )
                        time.sleep(0.05)
                    native_probe.restore()
                    native_owner_settled = not native_probe.scripting_commands
                    if native_result_key in observation:
                        observation[native_result_key]["preference_restored"] = True
                except Exception as error:
                    previous = observation.get(native_result_key + "_error", "")
                    observation[native_result_key + "_error"] = (
                        previous + "; " if previous else ""
                    ) + f"preference restoration failed: {error}"
    if native_probe:
        runtime_owner = native_probe.runtime_owner
        bound_pid = (
            runtime_owner[0] if type(runtime_owner) is tuple and len(runtime_owner) == 2 else None
        )
        report["native_scripting_journal"] = native_scripting_journal_summary(
            observation.get("boot_log", ""), bound_pid
        )
        report["managed_launch_observation"] = observation.get("managed_launch_observation")
        if observation.get("managed_launch_observation_error"):
            report["managed_launch_observation_error"] = observation[
                "managed_launch_observation_error"
            ]
        report["native_probe_diagnostics"] = native_probe.diagnostic_receipts
        report["supplementary_received_lua_stage"] = native_probe.observe_early_lua_stage(
            observation.get("boot_log", "")
        )
        report["native_transport_control"] = observation.get("native_transport_control")
        report["native_descriptor_constructor"] = observation.get("native_descriptor_constructor")
        if observation.get("native_descriptor_constructor_error"):
            report["native_descriptor_constructor_error"] = observation[
                "native_descriptor_constructor_error"
            ]
        report["native_pid_transport_control"] = observation.get("native_pid_transport_control")
        if observation.get("native_pid_transport_control_error"):
            report["native_pid_transport_control_error"] = observation[
                "native_pid_transport_control_error"
            ]
        report["native_pid_no_prompt_control"] = observation.get("native_pid_no_prompt_control")
        if observation.get("native_pid_no_prompt_control_error"):
            report["native_pid_no_prompt_control_error"] = observation[
                "native_pid_no_prompt_control_error"
            ]
        if observation.get("native_transport_control_error"):
            report["native_transport_control_error"] = observation["native_transport_control_error"]
        report[native_result_key] = observation.get(native_result_key)
        if observation.get(native_result_key + "_error"):
            report[native_result_key + "_error"] = observation[native_result_key + "_error"]
    report["quit_seconds"] = observation.get("quit_seconds")
    report["alive_after_window"] = observation.get("alive_after_window", False)
    report["failures"] = evaluate(scenario, observation)
    if observation.get("launch_gate_error"):
        report["failures"].append(observation["launch_gate_error"])
    if diagnostic_errors:
        report["diagnostic_errors"] = diagnostic_errors
        report["failures"].extend(diagnostic_errors)
    supplementary = None
    if native_probe:
        # This separate startup measurement cannot satisfy or overwrite any
        # required original startup, AppleEvent or feature verdict above.
        try:
            if not native_owner_settled or processes(launcher) or processes(child):
                raise RuntimeError("Original native owner debt refuses supplementary startup")
            supplementary = SupplementaryNativeBootstrap(app, output, HS_DOMAIN, processes)
            report["supplementary_native_bootstrap"] = supplementary.observe(
                "delayed_timer" if scenario == "clean" else "karabiner_config"
            )
        except Exception as error:
            report["supplementary_native_bootstrap_error"] = bounded_refusal(error)
    if scenario == "karabiner_config" and report["failures"]:
        report["supplementary_native_script_scope"] = {
            "status": "not_executed",
            "reason": "blocked by required original launch failure",
        }
    elif scenario == "karabiner_config":
        # Independent installed SDK/participant proof uses the same exact native
        # startup owner after every prior owner has retired. It cannot replace
        # the required managed launch or original feature verdict.
        try:
            if not native_owner_settled or processes(launcher) or processes(child):
                raise RuntimeError(
                    "Original native owner debt refuses supplementary script startup"
                )
            if supplementary is None:
                raise RuntimeError("Original supplementary owner unavailable for script startup")
            report["supplementary_native_script_scope"] = require_summary(
                supplementary.observe_script_scope(),
                child,
                HS_DOMAIN,
                BOOTSTRAP_CONTRACT,
                BOOTSTRAP_QUALIFICATION,
            )
        except Exception as error:
            report["supplementary_native_script_scope_error"] = bounded_refusal(error)
            report["failures"].append(
                "Required native Script SDK/participant qualification refused: "
                + bounded_refusal(error)
            )
    return report


# ===================================
# ===================================
# ======= 4/ Command line ===========
# ===================================
# ===================================


def matrix_line(profile):
    """Return the GitHub Actions output line that feeds the launch matrix of one profile."""
    return "scenarios=" + json.dumps(list(PROFILES[profile]), separators=(",", ":"))


def failure_annotations(scenario, failures):
    """Retain native refusal causes in GitHub annotations when artifacts are unavailable."""
    return [f"::error::macOS launch gate [{escape_workflow_annotation(scenario)}] failed"] + [
        "::error::" + escape_workflow_annotation(failure) for failure in failures
    ]


def parse_arguments(argv):
    """Parse either the matrix mode or the launch mode, rejecting any mix of the two."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--print-matrix",
        choices=tuple(PROFILES),
        help="print the scenarios=[...] output line of one profile and exit; takes no other argument "
        "and runs on any host",
    )
    parser.add_argument("app", nargs="?", help="installed application to launch (launch mode)")
    parser.add_argument("output", nargs="?", help="new evidence folder (launch mode)")
    parser.add_argument(
        "scenario",
        nargs="?",
        choices=SCENARIOS,
        metavar="scenario",
        help="user state to seed (launch mode): " + ", ".join(SCENARIOS),
    )
    parser.add_argument(
        "--seed-tag", default="", help="older release whose files seed personal state"
    )
    args = parser.parse_args(argv)
    launch_arguments = (args.app, args.output, args.scenario)
    if args.print_matrix is not None:
        if any(value is not None for value in launch_arguments) or args.seed_tag:
            parser.error("--print-matrix takes no launch argument")
    elif any(value is None for value in launch_arguments):
        parser.error("the launch mode needs app, output and scenario")
    return args


def main(argv=None):
    """Print one matrix profile, or run one scenario and exit non-zero on any failure."""
    args = parse_arguments(argv)
    if args.print_matrix is not None:
        print(matrix_line(args.print_matrix))
        return 0
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError(
            "The launch gate mutates the user profile and needs a disposable macOS runner"
        )
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = run(Path(args.app).resolve(), output, args.scenario, args.seed_tag)
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if report.get("supplementary_native_bootstrap"):
        print(
            "supplementary native bootstrap: installed native feature qualified; "
            "original launch and AppleEvent verdicts remain mandatory"
        )
    if report.get("supplementary_native_bootstrap_error"):
        for line in report["supplementary_native_bootstrap_error"].splitlines():
            print("supplementary native bootstrap refused: " + line)
    if report["failures"]:
        for annotation in failure_annotations(args.scenario, report["failures"]):
            print(annotation)
        if args.scenario in ("clean", "karabiner_config"):
            print(native_failure_notice(args.scenario, report))
        print_native_probe_diagnostics(report)
        print_tails(output)
        return 1
    print(
        f"macOS launch gate [{args.scenario}] passed on {report['machine']}; "
        f"quit in {report['quit_seconds']} s"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
