"""Exercise real shared Lua test consumers under owned native POSIX prefixes."""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("driver", type=Path)
parser.add_argument("lua", type=Path)
parser.add_argument("luv", type=Path)
args = parser.parse_args()
repository = args.driver.parent.parent.parent
consumer = args.driver / "tests/hardware/run_shared_test_native_paths.lua"
assert args.lua.is_file() and args.luv.is_file()
assert args.luv.read_bytes()[:4] == b"\x7fELF", "the provider must be the actual native ELF module"
cases = (
    "outdated",
    "chords",
    "override_parser",
    "terminators",
    "migration_records",
    "scope_overrides",
    "unused_sandbox",
    "onboarding_sandbox",
    "home_classifier",
)
variants = {
    "ordinary": "ordinary",
    "backslash": "literal\\backslash",
    "linefeed": "literal\nlinefeed",
}
# The home vector must stay outside runner_home's blanket /tmp scratch allowance.
with tempfile.TemporaryDirectory(prefix="erg-shared-test-paths-", dir="/var/tmp") as directory:
    root = Path(directory)
    provider = root / "provider"
    provider.mkdir(mode=0o700)
    (provider / "luv.so").symlink_to(args.luv.resolve())
    for leaf in variants.values():
        (root / leaf).symlink_to(repository, target_is_directory=True)

    def run(case: str, variant: str) -> None:
        profile = root / (case + "-" + variant)
        profile.mkdir(mode=0o700)
        leaf = (
            "tmp\\bytes"
            if variant == "backslash"
            else "tmp\nbytes"
            if variant == "linefeed"
            else "tmp"
        )
        temporary = profile / leaf
        temporary.mkdir(mode=0o700)
        home = profile / "home"
        home.mkdir(mode=0o700)
        if case == "home_classifier" and variant == "backslash":
            temporary = profile / "home\\root"
            home = profile / "home/root/account"
            temporary.mkdir(mode=0o700)
            home.mkdir(mode=0o700, parents=True)
        env = os.environ.copy()
        env.pop("TEMP", None)
        env.pop("TMP", None)
        env.update(
            HOME=str(home),
            TMPDIR=str(temporary),
            LUA_PATH="",
            LUA_CPATH=str(provider / "?.so"),
            XDG_CONFIG_HOME=str(home / "config"),
            XDG_STATE_HOME=str(home / "state"),
            XDG_DATA_HOME=str(home / "data"),
            XDG_CACHE_HOME=str(home / "cache"),
        )
        alias = root / variants[variant]
        if case in ("unused_sandbox", "onboarding_sandbox", "home_classifier", "windows_model"):
            alias = root / variants["ordinary"]
        result = subprocess.run(
            [str(args.lua), str(consumer), str(alias), case],
            cwd=root,
            env=env,
            capture_output=True,
            check=False,
        )
        assert result.returncode == 0, (
            f"{case}/{variant}: native shared consumer failed\n"
            + result.stdout.decode("utf-8", "replace")
            + result.stderr.decode("utf-8", "replace")
        )
        assert f"Native shared test path case: {case};".encode() in result.stdout
        print(f"PASS actual shared TEST path: {case}/{variant}", flush=True)

    for case in cases:
        for variant in variants:
            run(case, variant)
    run("windows_model", "ordinary")
print("Native shared TEST paths: 27 actual POSIX groups and 1 Windows text model passed")
