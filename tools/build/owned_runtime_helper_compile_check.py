# tools/build/owned_runtime_helper_compile_check.py
"""Compile the live owned-runtime installer helper roster, unsigned, on a Mac.

The signed runtime build (`remap_runtime_build.py --package-owned`) needs the
stable signing identity and an hour of hosted time, so a roster change of the
helper (`owned_runtime_product_build.py`) would otherwise be proven only by a
manual signed dispatch. This check runs the exact compile commands that
builder issues for the live (daemon-report) profile, the C objects and the
installer for both architectures, plus the universal link, in a private
temporary folder. It signs, packages and runs nothing, and it never builds the
validator or the Lua module, which need inputs only the signed build fetches.
Exit 0 means every command succeeded; any failure prints the command's name
and exits 1.
"""

from pathlib import Path
import importlib.util
import subprocess
import sys
import tempfile


REPOSITORY = Path(__file__).resolve().parents[2]


def load_product():
    spec = importlib.util.spec_from_file_location(
        "owned_runtime_product_build_compile_check",
        REPOSITORY / "tools/build/owned_runtime_product_build.py",
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    if sys.platform != "darwin":
        print("owned runtime helper compile check: requires macOS", file=sys.stderr)
        return 1
    product = load_product()
    sdk_path = subprocess.run(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    sdk = Path(sdk_path).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="ergopti-helper-compile-") as temporary:
        root = Path(temporary).resolve(strict=True)
        work = root / "work"
        lua_headers = root / "unused-lua-headers"
        work.mkdir(mode=0o700)
        lua_headers.mkdir(mode=0o700)
        commands = product.compile_commands(REPOSITORY, work, sdk, lua_headers, daemon_report=True)
        # The builder writes the module map after the roster is fixed, as here.
        (work / "report.modulemap").write_bytes(product.report_module_map(REPOSITORY))
        selected = [
            (name, argv)
            for name, argv in commands
            if name.startswith(("lifecycle_", "report_", "installer_"))
        ]
        for name, argv in selected:
            print("compile " + name, flush=True)
            completed = subprocess.run(argv, cwd=work, check=False)
            if completed.returncode != 0:
                print(
                    "owned runtime helper compile check: "
                    + name
                    + " failed with exit "
                    + str(completed.returncode),
                    file=sys.stderr,
                )
                return 1
        print("owned runtime helper compile check: " + str(len(selected)) + " commands passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
