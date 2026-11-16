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
3. translocated: macOS App Translocation, the read-only randomized mount that
   Gatekeeper runs a quarantined download from. Security.framework creates the
   same mount with SecTranslocateCreateSecureDirectoryForURL, which this module
   calls directly because a hosted runner cannot answer the Gatekeeper prompt
   that would otherwise precede it.

Every location lives under ~/gitcfg, which the runner reset owns.
"""

import ctypes
import os
from pathlib import Path
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
SECURITY = "/System/Library/Frameworks/Security.framework/Security"
CORE_FOUNDATION = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
UTF8 = 0x08000100
PATH_LIMIT = 4096


class Translocation:
    """The private Security.framework calls that create and retire one mount."""

    def __init__(self):
        self.security = ctypes.cdll.LoadLibrary(SECURITY)
        self.cf = ctypes.cdll.LoadLibrary(CORE_FOUNDATION)
        self.cf.CFURLCreateFromFileSystemRepresentation.restype = ctypes.c_void_p
        self.cf.CFURLCreateFromFileSystemRepresentation.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_long,
            ctypes.c_bool,
        ]
        self.cf.CFURLGetFileSystemRepresentation.restype = ctypes.c_bool
        self.cf.CFURLGetFileSystemRepresentation.argtypes = [
            ctypes.c_void_p,
            ctypes.c_bool,
            ctypes.c_char_p,
            ctypes.c_long,
        ]
        self.cf.CFCopyDescription.restype = ctypes.c_void_p
        self.cf.CFCopyDescription.argtypes = [ctypes.c_void_p]
        self.cf.CFStringGetCString.restype = ctypes.c_bool
        self.cf.CFStringGetCString.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_long,
            ctypes.c_uint32,
        ]
        self.cf.CFRelease.argtypes = [ctypes.c_void_p]
        create = self.security.SecTranslocateCreateSecureDirectoryForURL
        create.restype = ctypes.c_void_p
        create.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        delete = self.security.SecTranslocateDeleteSecureDirectory
        delete.restype = ctypes.c_bool
        delete.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        check = self.security.SecTranslocateIsTranslocatedURL
        check.restype = ctypes.c_bool
        check.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_bool),
            ctypes.POINTER(ctypes.c_void_p),
        ]

    def url(self, path):
        raw = os.fsencode(path)
        url = self.cf.CFURLCreateFromFileSystemRepresentation(None, raw, len(raw), True)
        if not url:
            raise RuntimeError(f"CoreFoundation refused the path {path}")
        return url

    def describe(self, reference):
        text = ctypes.create_string_buffer(PATH_LIMIT)
        description = self.cf.CFCopyDescription(reference)
        self.cf.CFStringGetCString(description, text, PATH_LIMIT, UTF8)
        self.cf.CFRelease(description)
        return text.value.decode("utf-8", "replace")

    def create(self, original):
        """Mount one translocation of original and return the mounted bundle path."""
        source = self.url(original)
        error = ctypes.c_void_p()
        mounted = self.security.SecTranslocateCreateSecureDirectoryForURL(
            source, None, ctypes.byref(error)
        )
        self.cf.CFRelease(source)
        if not mounted:
            detail = self.describe(error.value) if error.value else "no error object"
            raise RuntimeError(f"SecTranslocateCreateSecureDirectoryForURL refused: {detail}")
        buffer = ctypes.create_string_buffer(PATH_LIMIT)
        resolved = self.cf.CFURLGetFileSystemRepresentation(mounted, True, buffer, PATH_LIMIT)
        self.cf.CFRelease(mounted)
        if not resolved:
            raise RuntimeError("The translocated bundle has no file-system path")
        path = Path(os.fsdecode(buffer.value))
        flag = ctypes.c_bool(False)
        error = ctypes.c_void_p()
        url = self.url(path)
        answered = self.security.SecTranslocateIsTranslocatedURL(
            url, ctypes.byref(flag), ctypes.byref(error)
        )
        self.cf.CFRelease(url)
        if not answered or not flag.value:
            raise RuntimeError(f"Security.framework does not report {path} as translocated")
        return path

    def delete(self, mounted):
        """Unmount one translocation; refuse instead of leaving a mount behind."""
        url = self.url(mounted)
        error = ctypes.c_void_p()
        deleted = self.security.SecTranslocateDeleteSecureDirectory(url, ctypes.byref(error))
        self.cf.CFRelease(url)
        if not deleted:
            detail = self.describe(error.value) if error.value else "no error object"
            raise RuntimeError(f"SecTranslocateDeleteSecureDirectory refused: {detail}")


def quarantine_stamp(now=time.time, identifier=uuid.uuid4):
    """A browser-download quarantine value the user has not approved yet."""
    return f"0083;{int(now()):x};Safari;{str(identifier()).upper()}"


class Relocation:
    """Moves the installed bundle to one scenario location and back."""

    def __init__(self, scenario, installed, home, runner=subprocess.run, translocation=None):
        if scenario not in LOCATIONS:
            raise ValueError(f"Unknown relocation scenario {scenario!r}")
        self.scenario = scenario
        self.installed = Path(installed)
        self.home = Path(home)
        self.runner = runner
        self.translocation = translocation
        folder, link = LOCATIONS[scenario]
        self.folder = self.home / folder
        self.link = self.home / link if link else None
        self.moved = self.folder / self.installed.name
        self.mounted = None

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
            if self.translocation is None:
                self.translocation = Translocation()
            self.mounted = self.translocation.create(self.moved)
            return self.mounted
        return self.moved

    def candidates(self, opened):
        """Bundle paths macOS may report for the opened one: as opened, or resolved."""
        found = [Path(opened)]
        resolved = Path(os.path.realpath(opened))
        if resolved not in found:
            found.append(resolved)
        return found

    def leave(self):
        """Undo enter(): unmount, unquarantine, move back and remove the folders."""
        problems = []
        if self.mounted is not None:
            try:
                self.translocation.delete(self.mounted)
            except Exception as error:
                problems.append(f"{type(error).__name__}: {error}")
        if self.moved.exists():
            if self.scenario == "translocated":
                self.runner(["xattr", "-dr", "com.apple.quarantine", str(self.moved)], check=True)
            shutil.move(str(self.moved), str(self.installed))
        if self.link is not None and self.link.is_symlink():
            self.link.unlink()
        if self.folder.is_dir():
            self.folder.rmdir()
        if problems:
            raise RuntimeError("; ".join(problems))
