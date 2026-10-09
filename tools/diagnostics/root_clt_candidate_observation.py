"""TEST ONLY: fixed ordinary CLT metadata; never selects or admits a toolchain.

This is not ACL, full SDK tree, ABI, compiler, root or installation qualification.
An absent candidate is an observation, not a fallback or an installed capability.
Only the existing external Guardian launches this helper. No tool is launched here.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import stat
import sys

_SDK = re.compile(r"MacOSX(?:[0-9]{1,3}(?:\.[0-9]{1,3}){0,3})?\.sdk\Z")
_CLANG = re.compile(r"clang(?:-[0-9]{1,3}(?:\.[0-9]{1,3}){0,3})?\Z")
_VERSION = re.compile(r"(?:default|[0-9]{1,3}(?:\.[0-9]{1,3}){0,3})\Z")
_ROLES = {
    "xcrun",
    "xcode_select",
    "clt",
    "clt_usr",
    "clt_bin",
    "compiler",
    "sdk_directory",
    "sdk",
    "compiler_target",
    "sdk_target",
}
_REASONS = {
    "arguments",
    "platform",
    "io",
    "kind",
    "currentness",
    "alias_namespace",
    "alias_cycle",
    "alias_hops",
    "alias_bytes",
    "sdk_entries",
    "rows",
    "schema",
    "output_bytes",
    "close",
}
_ROW_KEYS = {
    "role",
    "version",
    "hop",
    "state",
    "kind",
    "uid",
    "mode",
    "executable",
    "alias",
    "current",
}
_REPORT_KEYS = {
    "schema",
    "kind",
    "platform",
    "authority",
    "root_admission",
    "toolchain_selected",
    "native_verdict",
    "rows",
}


class ObservationRefused(Exception):
    """Closed reason only; never retain a private path or exception payload."""

    def __init__(self, reason):
        self.reason = reason if reason in _REASONS else "io"
        super().__init__(self.reason)


@dataclass(frozen=True)
class _Layout:
    """Internal test mapping; the production CLI accepts no layout override."""

    clt: Path
    system: Path


def _stamp(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_uid,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _identity(stamp):
    return stamp[0], stamp[1], stat.S_IFMT(stamp[3])


def _version(name):
    if name.startswith("MacOSX"):
        return name[6:-4] or "default"
    return name[6:] if name.startswith("clang-") else "default"


class _Observer:
    def __init__(self, layout):
        self.layout = layout
        self._held = {}
        self._names = {}
        self._aliases = {}
        self._rows = []

    def _named(self, path):
        try:
            info = self._lstat(path)
        except FileNotFoundError:
            info = None
        value = None if info is None else _stamp(info)
        if path in self._names and self._names[path] != value:
            raise ObservationRefused("currentness")
        self._names[path] = value
        return info

    def _lstat(self, path):
        if path.parent == path:
            return os.lstat(path)
        return os.lstat(path.name, dir_fd=self._held[path.parent][0])

    def _readlink(self, path):
        return os.readlink(path.name, dir_fd=self._held[path.parent][0])

    def _hold(self, path, info, directory):
        if path in self._held:
            if _stamp(os.fstat(self._held[path][0])) != _stamp(info):
                raise ObservationRefused("currentness")
            return
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
        if directory:
            flags |= os.O_DIRECTORY
        descriptor = (
            os.open(path, flags)
            if path.parent == path
            else os.open(path.name, flags, dir_fd=self._held[path.parent][0])
        )
        # Record ownership immediately, including acquisition/currentness refusal.
        self._held[path] = (descriptor, _stamp(info))
        if _stamp(os.fstat(descriptor)) != _stamp(info):
            raise ObservationRefused("currentness")
        self._named(path)

    def _directory(self, path):
        if path in self._names and self._names[path] is None:
            return False
        if path.parent != path and not self._directory(path.parent):
            return False
        info = self._named(path)
        if info is None:
            return False
        if not stat.S_ISDIR(info.st_mode):
            raise ObservationRefused("kind")
        self._hold(path, info, True)
        return True

    def _append(self, row):
        if len(self._rows) >= 32:
            raise ObservationRefused("rows")
        self._rows.append(row)

    def _alias_target(self, path, role):
        raw = self._readlink(path)
        if len(os.fsencode(raw)) > 512:
            raise ObservationRefused("alias_bytes")
        if path in self._aliases and self._aliases[path] != raw:
            raise ObservationRefused("currentness")
        self._aliases[path] = raw
        # Lexical validation precedes any target access; never resolve an outside alias.
        target = Path(os.path.normpath(raw if os.path.isabs(raw) else str(path.parent / raw)))
        if role in ("sdk", "sdk_target"):
            admitted = target.parent == self.layout.clt / "SDKs" and _SDK.fullmatch(target.name)
        elif role in ("compiler", "compiler_target"):
            admitted = target.parent == self.layout.clt / "usr/bin" and _CLANG.fullmatch(
                target.name
            )
        else:
            admitted = False
        if not admitted:
            raise ObservationRefused("alias_namespace")
        return target

    def _subject(self, path, role, directory, version="default", hop=0, visited=None):
        visited = set() if visited is None else visited
        if path in visited:
            raise ObservationRefused("alias_cycle")
        visited.add(path)
        row = {
            "role": role,
            "version": version,
            "hop": hop,
            "state": "blocked",
            "kind": "blocked",
            "uid": None,
            "mode": None,
            "executable": False,
            "alias": "none",
            "current": True,
        }
        if not self._directory(path.parent):
            self._append(row)
            return
        info = self._named(path)
        if info is None:
            row.update(state="missing", kind="missing")
            self._append(row)
            return
        mode = info.st_mode
        if stat.S_ISLNK(mode):
            kind = "symlink"
        elif directory and stat.S_ISDIR(mode):
            kind = "directory"
        elif not directory and stat.S_ISREG(mode):
            kind = "regular"
        else:
            raise ObservationRefused("kind")
        row.update(
            state="present",
            kind=kind,
            uid=info.st_uid,
            mode=stat.S_IMODE(mode),
            executable=bool(mode & 0o111),
        )
        if kind != "symlink":
            self._hold(path, info, directory)
            self._append(row)
            return
        if hop >= 8:
            raise ObservationRefused("alias_hops")
        target = self._alias_target(path, role)
        self._named(path)
        row["alias"] = "within_clt"
        self._append(row)
        target_role = "sdk_target" if role in ("sdk", "sdk_target") else "compiler_target"
        self._subject(target, target_role, directory, _version(target.name), hop + 1, visited)

    def _validate_names_and_descriptors(self):
        for path, expected in self._names.items():
            try:
                info = self._lstat(path)
            except FileNotFoundError:
                info = None
            if (None if info is None else _stamp(info)) != expected:
                raise ObservationRefused("currentness")
        for descriptor, expected in self._held.values():
            if _stamp(os.fstat(descriptor)) != expected:
                raise ObservationRefused("currentness")

    def _validate(self):
        self._validate_names_and_descriptors()
        for path, expected in self._aliases.items():
            if self._readlink(path) != expected:
                raise ObservationRefused("currentness")
        # One finite recut covers a namespace replacement during the alias reads.
        # Sequential observation cannot promise an atomic global snapshot or ABA detection.
        self._validate_names_and_descriptors()

    def _close(self):
        failed = False
        # Pop before attempting close; an uncertain close is never retried.
        while self._held:
            _, (descriptor, expected) = self._held.popitem()
            try:
                if _identity(_stamp(os.fstat(descriptor))) != _identity(expected):
                    failed = True  # A reused foreign descriptor is not ours to close.
                    continue
                os.close(descriptor)
            except OSError:
                failed = True
        if failed:
            raise ObservationRefused("close")

    def observe(self):
        primary = None
        try:
            clt = self.layout.clt
            for path in (clt, self.layout.system):
                if not path.is_absolute() or Path(os.path.normpath(str(path))) != path:
                    raise ObservationRefused("schema")
            fixed = [
                (self.layout.system / "xcrun", "xcrun", False),
                (self.layout.system / "xcode-select", "xcode_select", False),
                (clt, "clt", True),
                (clt / "usr", "clt_usr", True),
                (clt / "usr/bin", "clt_bin", True),
                (clt / "usr/bin/clang", "compiler", False),
                (clt / "SDKs", "sdk_directory", True),
            ]
            for path, role, directory in fixed:
                self._subject(path, role, directory)
            names = set()
            sdk_path = clt / "SDKs"
            if self._directory(sdk_path):
                with os.scandir(self._held[sdk_path][0]) as entries:
                    for entry in entries:
                        if _SDK.fullmatch(entry.name):
                            names.add(entry.name)
                            if len(names) > 16:
                                raise ObservationRefused("sdk_entries")
            self._subject(sdk_path / "MacOSX.sdk", "sdk", True)
            for name in sorted(names - {"MacOSX.sdk"}):
                self._subject(sdk_path / name, "sdk", True, _version(name))
            self._validate()
        except ObservationRefused as error:
            primary = error
        except OSError:
            primary = ObservationRefused("io")
        try:
            self._close()
        except ObservationRefused as error:
            primary = primary or error
        if primary is not None:
            raise primary
        return {
            "schema": 1,
            "kind": "clt_candidate_metadata_observation",
            "platform": sys.platform,
            "authority": False,
            "root_admission": False,
            "toolchain_selected": False,
            "native_verdict": "unchanged",
            "rows": self._rows,
        }


def _encode(report):
    valid = (
        type(report) is dict
        and set(report) == _REPORT_KEYS
        and type(report["schema"]) is int
        and report["schema"] == 1
        and report["kind"] == "clt_candidate_metadata_observation"
        and report["platform"] in ("darwin", "linux")
        and all(
            report[key] is False for key in ("authority", "root_admission", "toolchain_selected")
        )
        and report["native_verdict"] == "unchanged"
        and type(report["rows"]) is list
        and 8 <= len(report["rows"]) <= 32
    )
    if not valid:
        raise ObservationRefused("schema")
    for row in report["rows"]:
        valid = (
            type(row) is dict
            and set(row) == _ROW_KEYS
            and row["role"] in _ROLES
            and type(row["version"]) is str
            and _VERSION.fullmatch(row["version"])
            and type(row["hop"]) is int
            and 0 <= row["hop"] <= 8
            and row["state"] in ("present", "missing", "blocked")
            and row["kind"] in ("regular", "directory", "symlink", "missing", "blocked")
            and row["alias"] in ("none", "within_clt")
            and type(row["executable"]) is bool
            and row["current"] is True
        )
        if valid and row["state"] == "present":
            valid = (
                row["kind"] in ("regular", "directory", "symlink")
                and type(row["uid"]) is int
                and 0 <= row["uid"] <= 4294967295
                and type(row["mode"]) is int
                and 0 <= row["mode"] <= 0o7777
                and row["executable"] == bool(row["mode"] & 0o111)
                and (row["alias"] == "within_clt") == (row["kind"] == "symlink")
            )
        elif valid:
            valid = (
                row["kind"] == row["state"]
                and row["uid"] is None
                and row["mode"] is None
                and row["executable"] is False
                and row["alias"] == "none"
            )
        if not valid:
            raise ObservationRefused("schema")
    encoded = (json.dumps(report, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    if len(encoded) > 8192:
        raise ObservationRefused("output_bytes")
    return encoded


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    reason = None
    status = 1
    if arguments:
        reason, status = "arguments", 64
    elif sys.platform != "darwin":
        reason, status = "platform", 69
    else:
        try:
            report = _Observer(
                _Layout(Path("/Library/Developer/CommandLineTools"), Path("/usr/bin"))
            ).observe()
            encoded = _encode(report)
            if os.write(1, encoded) != len(encoded):
                raise ObservationRefused("io")
            return 0
        except ObservationRefused as error:
            reason = error.reason
        except OSError:
            reason = "io"
    # Closed reason is at most 512 bytes. No traceback, exception text or private path.
    sys.stderr.write("CLT_CANDIDATE_OBSERVATION_REFUSED " + reason + "\n")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
