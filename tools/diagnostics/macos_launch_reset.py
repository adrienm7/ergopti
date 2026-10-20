#!/usr/bin/env python3
# tools/diagnostics/macos_launch_reset.py
"""Return a launch runner to its fresh state between two launch-gate scenarios.

One launch job runs several scenarios of macos_launch_gate.py in turn. Each
scenario must still start from a fresh runner, so before the first install the
job records the runner's state and, after each scenario, this tool removes
everything the install, the seeded user state and the launched application left
behind, then proves the owned state equals that record. Any leftover it cannot
remove fails the job instead of leaking into the next scenario.

`snapshot <record>` writes the record of the fresh runner (it must not exist).
`restore <record>` resets the runner to it and prints what it removed.

Owned state is a closed list: the installed application, the folders the
scenarios seed (macos_launch_gate.seed) or the application writes, its
preference domains and its launchd jobs. Other new entries are reported, never
removed, so unrelated runner activity is neither deleted nor mistaken for a
leftover.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

APPLICATION = Path("/Applications/ErgoptiPlus.app")
# The folders whose direct entries are compared with the fresh record.
WATCHED = (
    "",
    ".config",
    "Documents",
    "Library/Application Support",
    "Library/Caches",
    "Library/HTTPStorages",
    "Library/LaunchAgents",
    "Library/Logs",
    "Library/Preferences",
    "Library/Saved Application State",
    "Library/WebKit",
)
# A new direct entry of a watched folder is owned when its name matches.
OWNED_NAME = re.compile(r"ergopti|hammerspoon|karabiner", re.IGNORECASE)
# Seeded entries whose names say nothing of the application.
OWNED_PATHS = ("gitcfg", "SyncedLogs", "Documents/GitHub")
OWNED_DOMAIN = re.compile(r"ergopti|hammerspoon", re.IGNORECASE)
OWNED_LABEL = re.compile(r"ergopti", re.IGNORECASE)
QUIT_TIMEOUT_SECONDS = 10


def run(command):
    """Run one system command and return its standard output."""
    return subprocess.run(command, capture_output=True, text=True, check=True).stdout


def owned(relative):
    """Whether a new entry, relative to the home folder, belongs to the launch."""
    return relative in OWNED_PATHS or bool(OWNED_NAME.search(Path(relative).name))


def entries(home):
    """The direct entries of every watched folder, relative to the home folder."""
    found = []
    for folder in WATCHED:
        root = home / folder
        if not root.is_dir() or root.is_symlink():
            continue
        for entry in sorted(root.iterdir()):
            found.append(str(entry.relative_to(home)).replace(os.sep, "/"))
    return sorted(found)


def domains(runner):
    """The owned preference domains the preference daemon knows."""
    text = runner(["defaults", "domains"])
    return sorted(name.strip() for name in text.split(",") if OWNED_DOMAIN.search(name.strip()))


def labels(runner):
    """The owned launchd job labels of the user's domain."""
    found = []
    for line in runner(["launchctl", "list"]).splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) == 3 and OWNED_LABEL.search(parts[2]):
            found.append(parts[2])
    return sorted(found)


def application_processes(runner, application=APPLICATION):
    """The pids of every process running from the installed application."""
    found = []
    for line in runner(["ps", "-axo", "pid=,command="]).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].startswith(str(application) + "/"):
            found.append(int(parts[0]))
    return found


def state(home, runner, application=APPLICATION):
    """The owned and observed state the reset compares with the fresh record."""
    return {
        "schema": 1,
        "home": str(home),
        "entries": entries(home),
        "domains": domains(runner),
        "labels": labels(runner),
        "application": application.exists() or application.is_symlink(),
    }


def snapshot(record, home, runner, application=APPLICATION):
    """Record the fresh runner; a runner that already holds launch state refuses."""
    fresh = state(home, runner, application)
    if fresh["application"]:
        raise RuntimeError("The fresh runner already holds the installed application")
    if application_processes(runner, application):
        raise RuntimeError("The fresh runner already runs the application")
    with open(record, "x", encoding="utf-8") as stream:
        json.dump(fresh, stream, indent=2, sort_keys=True)
        stream.write("\n")
    return fresh


def remove(path):
    """Remove one file, link or folder without following a link."""
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def stop_processes(runner, application, killer=os.kill, sleep=time.sleep):
    """Kill every process of the installed application and wait for its exit."""
    for pid in application_processes(runner, application):
        try:
            killer(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + QUIT_TIMEOUT_SECONDS
    while application_processes(runner, application):
        if time.monotonic() >= deadline:
            raise RuntimeError("An application process survived the reset")
        sleep(0.1)


def restore(record, home, runner, application=APPLICATION, killer=os.kill, sleep=time.sleep):
    """Reset the runner to the fresh record, or refuse with every leftover."""
    with open(record, encoding="utf-8") as stream:
        fresh = json.load(stream)
    if fresh.get("schema") != 1 or fresh.get("home") != str(home):
        raise RuntimeError("The fresh runner record belongs to another home")
    removed = []
    stop_processes(runner, application, killer, sleep)
    for label in sorted(set(labels(runner)) - set(fresh["labels"])):
        runner(["launchctl", "remove", label])
        removed.append("launchd:" + label)
    if application.exists() or application.is_symlink():
        remove(application)
        removed.append(str(application))
    # Through the preference daemon first: removing a plist under it would
    # leave its cached values for the next scenario.
    for domain in sorted(set(domains(runner)) - set(fresh["domains"])):
        runner(["defaults", "delete", domain])
        removed.append("defaults:" + domain)
    foreign = []
    # Deepest first, so a removed owned folder never hides a later entry.
    for relative in sorted(set(entries(home)) - set(fresh["entries"]), key=len, reverse=True):
        if owned(relative):
            remove(home / relative)
            removed.append(relative)
        else:
            foreign.append(relative)
    after = state(home, runner, application)
    leftovers = [
        name
        for key in ("entries", "domains", "labels")
        for name in sorted(set(after[key]) - set(fresh[key]))
        if key != "entries" or owned(name)
    ]
    missing = [
        name
        for key in ("entries", "domains", "labels")
        for name in sorted(set(fresh[key]) - set(after[key]))
        if key != "entries" or owned(name)
    ]
    if after["application"]:
        leftovers.append(str(application))
    if application_processes(runner, application):
        leftovers.append("running application process")
    if leftovers or missing:
        raise RuntimeError(
            "The runner differs from its fresh record: leftovers="
            + json.dumps(leftovers)
            + " missing="
            + json.dumps(missing)
        )
    return {"removed": removed, "foreign_unowned": foreign}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=("snapshot", "restore"))
    parser.add_argument("record")
    arguments = parser.parse_args(argv)
    home = Path.home()
    if arguments.command == "snapshot":
        fresh = snapshot(arguments.record, home, run)
        print(f"Fresh runner recorded: {len(fresh['entries'])} watched entries.")
        return 0
    try:
        report = restore(arguments.record, home, run)
    except RuntimeError as error:
        print(f"::error::Launch reset refused: {error}", file=sys.stderr)
        return 1
    print("Launch runner reset: " + json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
