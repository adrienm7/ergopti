#!/usr/bin/env python3
"""Compile the installed-source Lua module that ErgoptiPlus.app loads.

adapters/installed_physical_source.lua loads it from the app bundle with
package.loadlib; without it the owned runtime's capture never starts and the
tap-holds stay off (v1.0.10 shipped without it). The arguments are the module
rows of owned_runtime_product_build.compile_commands, the one roster the
runtime build compiles the module with, so no second copy of the flags exists.
This script compiles and stages only: build_macos_app.sh signs the module with
its fixed identifier before it seals the outer bundle.

Usage: build_installed_source_module.py --repository DIR --lua-build DIR
       --work DIR --output FILE
"""

import argparse
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys

PRODUCT_RELATIVE = "tools/build/owned_runtime_product_build.py"
OUTPUT_NAME = "installed_physical_source.so"


class ModuleBuildRefusal(RuntimeError):
    pass


def require(condition, reason):
    if not condition:
        raise ModuleBuildRefusal(reason)


def load_product(repository):
    """Import the runtime build's own roster owner from this repository."""
    path = Path(repository) / PRODUCT_RELATIVE
    spec = importlib.util.spec_from_file_location("owned_runtime_product_build", path)
    require(spec is not None and spec.loader is not None, "the product roster owner is missing")
    product = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(product)
    return product


def module_rows(product, repository, work, sdk, lua_headers):
    """Select the module compile, per architecture, then the universal join.

    compile_commands only builds argument vectors; it runs nothing and writes
    nothing, so asking it for the whole roster to keep three rows is safe.
    """
    roster = dict(product.compile_commands(repository, work, sdk, lua_headers))
    names = [
        *("module_" + architecture for architecture in product.ARCHITECTURES),
        "module_universal",
    ]
    missing = [name for name in names if name not in roster]
    require(not missing, "the product roster has no rows " + ", ".join(missing))
    return [(name, roster[name]) for name in names]


def sdk_path():
    """The macOS SDK the runtime build also asks xcrun for."""
    found = subprocess.run(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    require(found.endswith("\n") and found.count("\n") == 1, "xcrun did not return one SDK path")
    return Path(found[:-1]).resolve(strict=True)


def build(repository, lua_build, work, output):
    """Compile both slices, join and verify them, then stage the universal module."""
    require(sys.platform == "darwin", "the installed-source module is built on macOS only")
    repository = Path(repository).resolve(strict=True)
    product = load_product(repository)
    # The LuaSocket owner's pinned Lua archive, checked byte for byte.
    lua_headers, _ = product._lua_headers(Path(lua_build).resolve(strict=True))
    work = Path(work)
    require(not work.exists() and not work.is_symlink(), "the module work directory already exists")
    work.mkdir(mode=0o700, parents=True)
    work = work.resolve(strict=True)
    output = Path(output)
    require(output.name == OUTPUT_NAME, "the module output must be named " + OUTPUT_NAME)
    require(not output.exists() and not output.is_symlink(), "the module output already exists")
    for name, arguments in module_rows(product, repository, work, sdk_path(), lua_headers):
        print("[installed-source-module] " + name, file=sys.stderr)
        subprocess.run(arguments, check=True)
    universal = work / "module.so"
    require(universal.is_file() and not universal.is_symlink(), "the universal module is missing")
    subprocess.run(product.architecture_check_command(universal), check=True)
    output.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    shutil.copyfile(universal, output)
    output.chmod(0o755)
    return output


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for option in ("--repository", "--lua-build", "--work", "--output"):
        parser.add_argument(option, required=True)
    arguments = parser.parse_args(argv)
    build(arguments.repository, arguments.lua_build, arguments.work, arguments.output)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
