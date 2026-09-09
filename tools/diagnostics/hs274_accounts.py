# tools/diagnostics/hs274_accounts.py
"""Own a temporary administrator for normal approval on disposable CI macOS."""

from contextlib import contextmanager
import os
from pathlib import Path
import secrets
import subprocess
import sys


def account_command(command, password):
    """Run directory commands without exposing a password through exceptions."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
    except subprocess.TimeoutExpired:
        raise RuntimeError("Temporary approval account command timed out") from None
    if result.returncode:
        detail = (result.stderr + result.stdout).replace(password, "<redacted>")[-1200:]
        raise RuntimeError(f"Temporary approval account command failed ({result.returncode}): {detail}")
    return result.stdout


@contextmanager
def approval_account(output, report):
    """Create, verify and remove only the account owned by this observation."""
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("Temporary approval accounts require a disposable macOS Actions runner")
    root = Path(os.environ["RUNNER_TEMP"]).resolve()
    if output.resolve() != root:
        raise RuntimeError("Approval account home must belong to the current runner temporary directory")
    name = "hs274_" + secrets.token_hex(6)
    password = "Hs274!" + secrets.token_urlsafe(24)
    home = root / ("hs274-approval-home-" + name)
    record = "/Users/" + name
    print("::add-mask::" + password, flush=True)

    def users():
        return account_command(["dscl", ".", "-list", "/Users"], password).splitlines()

    def verify_home():
        result = account_command(["dscl", ".", "-read", record, "NFSHomeDirectory"], password)
        if result.partition(":")[2].strip() != str(home):
            raise RuntimeError("Cannot prove ownership of temporary approval account")

    if name in users() or home.exists() or home.is_symlink():
        raise RuntimeError("Temporary approval account or home already exists")
    report["approval_account_name"] = name
    report["approval_account_verified"] = False
    report["approval_account_removed"] = False
    try:
        account_command([
            "sudo", "-n", "sysadminctl", "-addUser", name,
            "-fullName", "HS274 CI Approval", "-password", password,
            "-home", str(home), "-admin",
        ], password)
        if name not in users():
            raise RuntimeError("Temporary approval account was not created")
        verify_home()
        membership = account_command(["dseditgroup", "-o", "checkmember", "-m", name, "admin"], password)
        if not membership.startswith("yes "):
            raise RuntimeError("Temporary approval account is not an administrator")
        account_command(["dscl", ".", "-authonly", name, password], password)
        report["approval_account_verified"] = True
        yield name, password
    finally:
        if name in users():
            verify_home()
            account_command(["sudo", "-n", "sysadminctl", "-deleteUser", name, "-keepHome"], password)
        if name in users():
            raise RuntimeError("Temporary approval account cleanup did not complete")
        report["approval_account_removed"] = True
        report["approval_home_retained_until_runner_disposal"] = True
