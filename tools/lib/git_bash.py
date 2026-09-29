# tools/lib/git_bash.py

"""
==============================================================================
MODULE: The Bash A Python Tool Spawns
DESCRIPTION:
The Python counterpart of tools/lib/git-bash.cjs: the bash that Python build
and test scripts spawn.

WHY A PATH LOOKUP IS WRONG ON WINDOWS:
From PowerShell or cmd, shutil.which("bash") answers WSL's launcher
(System32\\bash.exe or WindowsApps\\bash.exe). The script then runs inside a
Linux distribution with /mnt/<drive> paths and none of the host's tools:
measured on 2026-09-26, seven Karabiner package tests failed that way from
PowerShell and passed from Git Bash, where PATH lists Git's bash first.

FEATURES & RATIONALE:
1. Windows resolves Git for Windows' own bin/bash.exe from `git --exec-path`,
   whatever PATH says.
2. Elsewhere /bin/bash, the interpreter the replayed scripts' shebangs name
   (bash 3.2 on macOS, even when Homebrew's bash comes first on PATH); a host
   with no /bin/bash takes PATH's bash.
3. Missing is loud: no git, no Git bash, or no bash on PATH raises, so a test
   that needs bash fails instead of skipping.
4. Import-anywhere: scripts add the repo root to sys.path, then
   ``from tools.lib.git_bash import bash_executable``.
==============================================================================
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess

# The interpreter the repository's `#!/bin/bash` scripts name.
SYSTEM_BASH = "/bin/bash"


def git_for_windows_root() -> Path:
    """Finds the Git for Windows installation root.

    Returns:
            The nearest ancestor of `git --exec-path` carrying usr/bin/sh.exe.

    Raises:
            RuntimeError: When git cannot run or has no MSYS userland above it.
    """
    result = subprocess.run(["git", "--exec-path"], capture_output=True, text=True, check=False)
    if result.returncode != 0 or not result.stdout.strip():
        raise RuntimeError(
            "git --exec-path failed, so Git for Windows' bash cannot be located: " + result.stderr
        )
    exec_path = Path(result.stdout.strip()).resolve()
    for candidate in (exec_path, *exec_path.parents):
        if (candidate / "usr" / "bin" / "sh.exe").is_file():
            return candidate
    raise RuntimeError("no Git for Windows MSYS userland above " + str(exec_path))


def bash_executable() -> str:
    """Resolves the bash executable to spawn.

    Returns:
            Git for Windows' bin/bash.exe on Windows; elsewhere /bin/bash, or the
            bash on PATH when the host has no /bin/bash.

    Raises:
            RuntimeError: When that bash does not exist.
    """
    if os.name != "nt":
        if Path(SYSTEM_BASH).is_file():
            return SYSTEM_BASH
        found = shutil.which("bash")
        if found is None:
            raise RuntimeError("bash is not on PATH")
        return found
    bash = git_for_windows_root() / "bin" / "bash.exe"
    if not bash.is_file():
        raise RuntimeError("Git for Windows has no " + str(bash))
    return str(bash)
