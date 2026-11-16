#!/usr/bin/env python3
# tools/diagnostics/macos_app_relocation.py
"""Run the installed application from the install locations users really have.

The launcher exports its executable path and the driver accepts its Karabiner
lease, uninstall and automatic-startup helper only when that path equals the
one derived from the Lua tree it runs (platform/remap/lease_helper.lua). Both
derive from the bundle path macOS reports, so a location where the reported
path differs from the opened path can break the proof at the first lease
while the first launch looks healthy (MLC-005). Each location below is entered
for one launch-gate scenario and left exactly as it was found:

1. symlinked_applications: the application folder is reached through a link;
2. spaced_accented_path: a folder whose name holds a space and an accent;
3. translocated: macOS App Translocation. A download whose quarantine the user
   approved at the Gatekeeper prompt, opened where it was downloaded, runs
   from a read-only nullfs mount under .../AppTranslocation/<UUID>/d/. A hosted
   runner cannot answer that prompt, so the gate writes the approved
   quarantine flags itself; LaunchServices then mounts and runs the bundle
   exactly as for a user (probe run 43189848716). The private
   SecTranslocateCreateSecureDirectoryForURL is refused there with EPERM.

Every location lives under ~/gitcfg, which the runner reset owns.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid

# Folder names below the home folder; "Léa" is written precomposed (NFC), the
# form Finder and the shell produce for a typed accent.
LOCATIONS = {
    "symlinked_applications": ("gitcfg/Applications", "gitcfg/LinkedApplications"),
    "spaced_accented_path": ("gitcfg/Applications de Léa", None),
    "translocated": ("gitcfg/Downloads", None),
}
SCENARIOS = tuple(LOCATIONS)
# Quarantine flags of a browser download the user approved at the Gatekeeper
# prompt; the pending 0083 of the install step would open that prompt instead.
APPROVED_QUARANTINE_FLAGS = "00c3"
LAUNCHER_RELATIVE = "Contents/MacOS/ErgoptiPlus"
TRANSLOCATION_MARKER = "/AppTranslocation/"
NULLFS_MOUNT = re.compile(r"^(?P<source>.+) on (?P<target>.+) \(nullfs, ")


def quarantine_stamp(flags=APPROVED_QUARANTINE_FLAGS, now=time.time, identifier=uuid.uuid4):
    """A browser-download quarantine value carrying the given flags."""
    return f"{flags};{int(now()):x};Safari;{str(identifier()).upper()}"


class Relocation:
    """Moves the installed bundle to one scenario location and back."""

    def __init__(self, scenario, installed, home, runner=subprocess.run):
        if scenario not in LOCATIONS:
            raise ValueError(f"Unknown relocation scenario {scenario!r}")
        self.scenario = scenario
        self.installed = Path(installed)
        self.home = Path(home)
        self.runner = runner
        folder, link = LOCATIONS[scenario]
        self.folder = self.home / folder
        self.link = self.home / link if link else None
        self.moved = self.folder / self.installed.name

    def enter(self):
        """Return the bundle path to open; the installed path is empty until leave()."""
        if self.folder.exists() or self.folder.is_symlink():
            raise RuntimeError(f"The relocation folder already exists: {self.folder}")
        self.folder.mkdir(parents=True)
        shutil.move(str(self.installed), str(self.moved))
        if self.link is not None:
            self.link.symlink_to(self.folder, target_is_directory=True)
            return self.link / self.installed.name
        if self.scenario == "translocated":
            self.runner(
                ["xattr", "-r", "-w", "com.apple.quarantine", quarantine_stamp(), str(self.moved)],
                check=True,
            )
        return self.moved

    def candidates(self, opened):
        """Bundle paths macOS may report for the opened one: as opened, or resolved."""
        found = [Path(opened)]
        resolved = Path(os.path.realpath(opened))
        if resolved not in found:
            found.append(resolved)
        return found

    def find_running(self, opened, process_table):
        """The bundle whose launcher runs in a `ps -axo pid=,command=` table, or None.

        A translocated launch runs from a mount whose name macOS chooses, so it
        is found by shape; it must be a translocation of this bundle's name.
        """
        commands = [
            parts[1]
            for parts in (line.strip().split(None, 1) for line in process_table.splitlines())
            if len(parts) == 2
        ]
        if self.scenario == "translocated":
            suffix = f"/d/{self.installed.name}/{LAUNCHER_RELATIVE}"
            for command in commands:
                if TRANSLOCATION_MARKER in command and command.endswith(suffix):
                    return Path(command[: -len("/" + LAUNCHER_RELATIVE)])
            return None
        for bundle in self.candidates(opened):
            if str(bundle / LAUNCHER_RELATIVE) in commands:
                return bundle
        return None

    def translocation_mounts(self):
        """The nullfs mount points macOS made for the moved bundle."""
        listing = self.runner(["mount"], capture_output=True, text=True, check=True).stdout
        return [
            match.group("target")
            for match in (NULLFS_MOUNT.match(line) for line in listing.splitlines())
            if match and match.group("source") == str(self.moved)
        ]

    def leave(self):
        """Undo enter(): unmount, unquarantine, move back and remove the folders."""
        problems = []
        if self.scenario == "translocated":
            for target in self.translocation_mounts():
                result = self.runner(["umount", target], capture_output=True, text=True)
                if result.returncode != 0:
                    problems.append(f"umount {target} failed: {result.stderr.strip()}")
            if self.moved.exists():
                self.runner(["xattr", "-dr", "com.apple.quarantine", str(self.moved)], check=True)
        if self.moved.exists():
            shutil.move(str(self.moved), str(self.installed))
        if self.link is not None and self.link.is_symlink():
            self.link.unlink()
        if self.folder.is_dir():
            self.folder.rmdir()
        if problems:
            raise RuntimeError("; ".join(problems))
