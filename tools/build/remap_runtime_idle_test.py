"""Exercise the genuine owned Core callsites through explicit software ports.

This gate qualifies startup/disconnect admission only. It does not run native
Core, authenticate a real Console, or acknowledge physical/VHD capture release.
"""

import argparse
import hashlib
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

BUILD = Path(__file__).resolve().parent
REPOSITORY = BUILD.parent.parent
RECEIVER = "src/apps/CoreService/include/core_service/daemon/receiver.hpp"
NAMES = (
    "constructor_existing_owned_config_without_console_does_not_grab",
    "console_disconnect_existing_owned_config_stops_without_restart",
    "absent_owned_config_never_grabs",
    "authenticated_current_console_start_retains_native_start",
    "wrong_role_or_stale_scope_refuses_console_start",
)
# This is the whole published owned receiver before the idle projection. A
# local mutation or arbitrary old source is never a valid BEFORE specimen.
BEFORE_SHA256 = "c71b509236d6e70a336e57e12bb4cf26c7183c6c3f7281697da1fccc3e1936e4"


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
    return module


def receiver_source(upstream):
    # Reuse the original closed factory acquisition and all dependency pins.
    queue = load("owned_idle_factory_controls", BUILD / "remap_runtime_queue_test.py")
    queue.OPTIONS = argparse.Namespace(upstream=upstream, original_monitor=False)
    return queue.outputs()[RECEIVER].decode("utf-8")


def block(source, marker):
    if source.count(marker) != 1:
        raise RuntimeError("Expected one genuine owned receiver source boundary")
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    # These frozen boundaries contain no braces in literals or comments. Refuse
    # ambiguity rather than use this helper as a general C++ parser.
    while end < len(source) and depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    if depth:
        raise RuntimeError("Unterminated genuine receiver boundary")
    return source[start:end]


def executable_source(receiver, fixture):
    start = "    server_->async_start();\n"
    end = '    logger::get_logger()->debug("receiver is initialized");'
    if receiver.count(start) != 1 or receiver.count(end) != 1:
        raise RuntimeError("Expected genuine constructor admission boundaries")
    startup = receiver.split(start, 1)[1].split(end, 1)[0]
    loss = block(receiver, "    if (console_user_server_peer_id_ == peer_id) {")
    helper = block(receiver, "  void start_grabbing_if_system_core_configuration_file_exists() {")
    result = fixture
    replacements = {
        "// INSERT_EXACT_STARTUP_CALLSITE": startup,
        "// INSERT_EXACT_CONSOLE_LOSS_CALLSITE": "    const int peer_id = 17;\n" + loss,
        "// INSERT_EXACT_ORIGINAL_SYSTEM_CONFIG_HELPER": helper,
    }
    for before, after in replacements.items():
        if result.count(before) != 1:
            raise RuntimeError("Frozen software control insertion refused")
        result = result.replace(before, after, 1)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", required=True, type=Path)
    parser.add_argument("--before-idle", type=Path)
    options = parser.parse_args()
    compiler = shutil.which("clang++") or shutil.which("g++")
    if not compiler:
        raise RuntimeError("A real C++ compiler is mandatory for Core idle controls")
    if options.before_idle:
        raw = options.before_idle.read_bytes()
        if hashlib.sha256(raw).hexdigest() != BEFORE_SHA256:
            raise RuntimeError("Genuine published idle predecessor source refused")
        receiver = raw.decode("utf-8")
    else:
        receiver = receiver_source(options.upstream)
    fixture = (BUILD / "fixtures/owned_runtime_idle_test.cpp").read_text(encoding="utf-8")
    source = executable_source(receiver, fixture)
    with tempfile.TemporaryDirectory(prefix="ergopti-owned-idle-") as temporary:
        directory = Path(temporary)
        cpp, child = directory / "idle.cpp", directory / "idle"
        cpp.write_text(source, encoding="utf-8")
        compiled = subprocess.run(
            [
                compiler,
                "-std=c++17",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-I",
                str(BUILD),
                str(cpp),
                "-o",
                str(child),
            ],
            capture_output=True,
            timeout=60,
            check=False,
        )
        sys.stdout.buffer.write(compiled.stdout)
        sys.stderr.buffer.write(compiled.stderr)
        if compiled.returncode != 0:
            return 1
        started = time.monotonic()
        actual = subprocess.run([str(child)], capture_output=True, timeout=10, check=False)
        sys.stdout.buffer.write(actual.stdout)
        sys.stderr.buffer.write(actual.stderr)
        rows = actual.stdout.decode("utf-8", errors="strict").splitlines()
        observed = tuple(row.partition(" ")[2] for row in rows)
        if (
            actual.stderr
            or observed != NAMES
            or any(not row.startswith(("PASS ", "FAIL ")) for row in rows)
        ):
            raise RuntimeError("Exact five original Core idle controls did not execute")
        if not time.monotonic() - started < 10:
            raise RuntimeError("Core idle software control budget expired")
        return 0 if actual.returncode == 0 and rows == ["PASS " + name for name in NAMES] else 1


if __name__ == "__main__":
    raise SystemExit(main())
