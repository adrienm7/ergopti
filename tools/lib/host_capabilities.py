# tools/lib/host_capabilities.py

"""
==============================================================================
MODULE: Host Capability Probes (Python)
DESCRIPTION:
Lets a unittest case that needs a symbolic link either execute or report an
explicit skip with its reason, never pass without its assertion.

FEATURES & RATIONALE:
1. Windows grants symlink creation only with Developer Mode or the
   SeCreateSymbolicLinkPrivilege; without it os.symlink raises WinError 1314.
   Hosted runners hold the privilege.
2. Only that exact refusal on a local Windows host skips. On GitHub Actions or
   another OS any error propagates, so every CI lane executes the case.
3. Import with the repository root on sys.path:
   ``from tools.lib.host_capabilities import require_symlinks``.
==============================================================================
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

# Win32 ERROR_PRIVILEGE_NOT_HELD, raised by CreateSymbolicLinkW.
ERROR_PRIVILEGE_NOT_HELD = 1314
SYMLINK_SKIP_REASON = (
    "not executed: this Windows account lacks the symlink privilege (WinError 1314); "
    "enable Developer Mode to run it here; hosted CI lanes execute it"
)

_symlink_probe: bool | None = None


def is_local_windows_host() -> bool:
    """Return True on a developer's Windows machine, False on every CI runner."""
    return sys.platform == "win32" and os.environ.get("GITHUB_ACTIONS") != "true"


def can_create_symlinks() -> bool:
    """Probe once whether this process may create a file symlink."""
    global _symlink_probe
    if _symlink_probe is not None:
        return _symlink_probe
    with tempfile.TemporaryDirectory(prefix="ergopti-symlink-probe-") as directory:
        target = Path(directory) / "target"
        target.write_bytes(b"")
        try:
            os.symlink(target, Path(directory) / "link")
            _symlink_probe = True
        except OSError as error:
            if not (
                is_local_windows_host()
                and getattr(error, "winerror", None) == ERROR_PRIVILEGE_NOT_HELD
            ):
                raise
            _symlink_probe = False
    return _symlink_probe


def require_symlinks() -> None:
    """Skip the running unittest case when a local Windows host refuses symlinks."""
    if not can_create_symlinks():
        raise unittest.SkipTest(SYMLINK_SKIP_REASON)
