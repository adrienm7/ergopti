# tools/diagnostics/run_installed_sdk_software_controls.py
"""Receive the original installed-SDK software actors with authenticated inputs.

The original factory admits pristine upstream and all SDK dependencies without
materializing a second source tree. Actors compile actual source ranges against
genuine vendor headers; IOKit and capture ports remain finite models. On macOS,
invoke this worker through macos_owned_process.py for inherited-PGID retirement.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import time
from types import SimpleNamespace
import unittest


PROVENANCE_SHA256 = "0e354e63b8eb2fc97c6c1dc8b4e0c58cab70b8c7f58f6c8f965b1359f1b4a214"
INPUTS = {
    "tools/build/core_sdk/operational_core_source.py": "be55de91f9c4c31e4ea920faa4086ab1b5634b3bdfb2716fbef28cb4d0d3842e",
    "tools/build/core_sdk/installed_cli_frontend.py": "2196da7a6681dd7b89ba2a6da3f2c819389b4d9b02f133b1db22648e3fbd2b58",
    "tools/diagnostics/installed_cli_frontend_test.py": "bc29b7d9dffee160c5f70cbc87dffbfe3e315924068335c7c227b73167d5db26",
    "tools/diagnostics/installed_hid_stop_test.py": "acd95fb054ed1ddcf692f9dc77191e45f8b04f3dcc1b721a497642bb79af6244",
    "tools/diagnostics/installed_hid_startup_test.py": "90769154e812911c02b5d0a3a6742af7678c641ea265930d5f87d2dbb1c4d8d7",
}
PREFIX = "tools/build/core_sdk/source/vendor/vendor/include/pqrs/osx/"
FIXTURE_PREFIX = "tools/diagnostics/fixtures/installed_sdk/"
COUNTS = {"cli": 8, "hid-stop": 6, "hid-startup": 8}


def require(condition, message):
    """Refuse changed source or incomplete controls without a success receipt."""
    if not condition:
        raise RuntimeError(message)


def identity(info):
    """Keep input identity without treating ordinary read access as mutation."""
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


def ordinary_input(path, expected):
    """Retain one exact owned ordinary source input, without redirected paths."""
    require(path.resolve(strict=True) == path, "Software input redirects")
    before = path.lstat()
    require(
        stat.S_ISREG(before.st_mode)
        and before.st_nlink == 1
        and before.st_uid == os.getuid()
        and stat.S_IMODE(before.st_mode) == 0o644,
        "Software input is not one ordinary owned source file",
    )
    data = path.read_bytes()
    require(
        hashlib.sha256(data).hexdigest() == expected and identity(path.lstat()) == identity(before),
        "Frozen software input changed",
    )
    return data


def load(path, data, name):
    """Load only bytes already admitted by their original fixed source hash."""
    specification = importlib.util.spec_from_loader(name, loader=None)
    module = importlib.util.module_from_spec(specification)
    module.__file__ = str(path)
    sys.modules[name] = module
    exec(compile(data, str(path), "exec"), module.__dict__)
    return module


def main():
    """Run exact unchanged actors and revalidate their real source epoch."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--pristine", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument("--blocks-library", type=Path, required=True)
    parser.add_argument("--suite", choices=["all", *COUNTS], default="all")
    options = parser.parse_args()
    repository = options.repository.resolve(strict=True)
    pristine = options.pristine.resolve(strict=True)
    require(repository.is_dir() and pristine.is_dir(), "Actual source roots are required")
    compiler = options.compiler.resolve(strict=True)
    blocks = options.blocks_library.resolve(strict=True)
    require(compiler.is_file() and blocks.is_file(), "Blocks compiler/runtime are unavailable")
    default_compiler = shutil.which("c++")
    require(default_compiler is not None, "Original CLI and stop compiler is unavailable")
    default_compiler = Path(default_compiler).resolve(strict=True)
    tool_inputs = {
        path: (identity(path.stat()), path.read_bytes())
        for path in (compiler, default_compiler, blocks)
    }
    deadline = time.monotonic() + 300
    fixture_root = repository / FIXTURE_PREFIX
    manifest_bytes = ordinary_input(fixture_root / "provenance.json", PROVENANCE_SHA256)
    manifest = json.loads(manifest_bytes)
    require(
        manifest["schema"] == 1 and len(manifest["fixtures"]) == 4,
        "Frozen fixture provenance is incomplete",
    )
    fixed = dict(INPUTS)
    for row in manifest["fixtures"]:
        require(Path(row["path"]).name == row["path"], "Fixture path escapes")
        path = FIXTURE_PREFIX + row["path"]
        require(path not in fixed and row["mode"] == "100644", "Fixture roster repeats")
        fixed[path] = row["sha256"]
        require(
            len(ordinary_input(repository / path, row["sha256"])) == row["bytes"],
            "Frozen fixture size changed",
        )
    fixed[FIXTURE_PREFIX + "provenance.json"] = PROVENANCE_SHA256
    inputs = {path: ordinary_input(repository / path, digest) for path, digest in fixed.items()}
    helper_path = "tools/build/core_sdk/operational_core_source.py"
    helper = load(repository / helper_path, inputs[helper_path], "installed_sdk_software_source")
    build, factory, _, _, _ = helper._load_build(repository, deadline)
    projection = factory.prepare_sdk_owned_source(repository, pristine, deadline)
    require(
        len(projection.replacements) == 101 and len(projection.sdk_dependencies) == 54,
        "Original authenticated SDK source roster changed",
    )
    base = factory.prepare_owned_source(repository, pristine, deadline)
    legacy = inputs[FIXTURE_PREFIX + "legacy_cli_before.cpp.txt"]
    require(
        dict(base.replacements)["src/bin/cli/src/main.cpp"] == legacy,
        "Frozen original CLI differs from the authentic legacy factory output",
    )
    current = {row.path: row for row in projection.sdk_dependencies}
    for relative in ("iokit_hid_manager.hpp", "iokit_service_monitor.hpp"):
        path = PREFIX + relative
        require(path in current, "Original SDK manager or monitor is absent")
        # The actual factory owns these inputs' complete identity and mode.
        # Private source files need not share frozen fixture publication modes.
        require(
            factory.read_input(repository, path, 8 * 1024 * 1024, deadline) == current[path],
            "Original factory SDK header incarnation changed",
        )
    vendor = pristine / "vendor/vendor/include"
    definitions = {
        "cli": (
            "installed_cli_frontend_test.py",
            SimpleNamespace(
                supplier=repository / "tools/build/core_sdk/installed_cli_frontend.py",
                legacy=fixture_root / "legacy_cli_before.cpp.txt",
                parser_include=vendor,
            ),
        ),
        "hid-stop": (
            "installed_hid_stop_test.py",
            SimpleNamespace(
                before=fixture_root / "hid_stop_manager_before.hpp.txt",
                current=repository / (PREFIX + "iokit_hid_manager.hpp"),
                vendor_include=vendor,
            ),
        ),
        "hid-startup": (
            "installed_hid_startup_test.py",
            SimpleNamespace(
                before_manager=fixture_root / "hid_startup_manager_before.hpp.txt",
                before_monitor=fixture_root / "hid_startup_monitor_before.hpp.txt",
                current_manager=repository / (PREFIX + "iokit_hid_manager.hpp"),
                current_monitor=repository / (PREFIX + "iokit_service_monitor.hpp"),
                vendor_include=vendor,
                compiler=compiler,
                blocks_library=blocks,
            ),
        ),
    }
    selected = COUNTS if options.suite == "all" else {options.suite: COUNTS[options.suite]}
    total = 0
    for name, count in selected.items():
        factory.revalidate_owned_source(projection, deadline)
        for path, digest in fixed.items():
            require(
                ordinary_input(repository / path, digest) == inputs[path],
                "Software source changed before execution",
            )
        filename, arguments = definitions[name]
        path = "tools/diagnostics/" + filename
        actor = load(repository / path, inputs[path], "installed_sdk_software_" + name)
        actor.OPTIONS = arguments
        suite = unittest.defaultTestLoader.loadTestsFromModule(actor)
        require(suite.countTestCases() == count, "Original software control count changed")
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        require(
            result.testsRun == count
            and result.wasSuccessful()
            and not result.skipped
            and not result.expectedFailures
            and not result.unexpectedSuccesses,
            "Installed SDK software controls failed or were incomplete",
        )
        total += count
        build.check_deadline(deadline)
        factory.revalidate_owned_source(projection, deadline)
        for path, digest in fixed.items():
            require(
                ordinary_input(repository / path, digest) == inputs[path],
                "Software source changed while controls executed",
            )
        for path, (info, data) in tool_inputs.items():
            require(
                identity(path.stat()) == info and path.read_bytes() == data,
                "Compiler or Blocks runtime changed while controls executed",
            )
    print(f"PASS installed SDK finite software controls: {total}; native/shipping unqualified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
