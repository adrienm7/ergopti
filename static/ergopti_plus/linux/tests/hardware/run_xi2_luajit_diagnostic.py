#!/usr/bin/env python3
"""Private sibling diagnostic: unchanged C3 prerequisite, then actual LuaJIT receiver."""

import importlib.util
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
import uuid


CANDIDATE_SHA = "97444bb6613176d384f166e7836a2df3ec831a6f91e89d95d07d3619c1c58b5a"
FAMILY_SHA = "7545c2d6aa8d48e5d48557b2b218e6d8a864eeb42ae761e055d4f917cdf06334"
HERE = Path(__file__).resolve().parent


def validate_native(native):
    """Closed portable receiver; native status is never inferred from case counts."""
    assert set(native) == {
        "qualified",
        "stage",
        "abi_comparisons",
        "native_cases",
        "cleanup",
        "input_injections",
        "native_epoch_claim",
        "runtime_projection",
        "cases",
    }
    assert native["qualified"] is True and native["cleanup"] is True
    for name, value in [
        ("stage", 4),
        ("abi_comparisons", 29),
        ("native_cases", 3),
        ("input_injections", 0),
    ]:
        assert type(native[name]) is int and native[name] == value
    assert native["native_epoch_claim"] is False and native["runtime_projection"] == "CONTROLLED"
    assert type(native["cases"]) is list and len(native["cases"]) == 3
    for index, row in enumerate(native["cases"]):
        assert set(row) == {"phase", "deviceid", "property", "what"}
        assert all(type(value) is int for value in row.values())
        assert row["phase"] == index and 0 <= row["deviceid"] <= 2147483647
        assert 0 < row["property"] <= 4294967295 and row["what"] in (0, 1, 2)
    assert len({row["property"] for row in native["cases"]}) == 1
    assert len({row["deviceid"] for row in native["cases"]}) == 1
    assert len({row["what"] for row in native["cases"]}) == 3


def load_original(root):
    path = root / "static/ergopti_plus/linux/tests/hardware/run_xi2_property_cookies.py"
    spec = importlib.util.spec_from_file_location("original_xi2_c3", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.digest(module.FAMILY) == FAMILY_SHA
    return module


def leader(directory, config_path):
    """Runs only inside the original full-family helper; owns its exact display."""
    config = json.loads(config_path.read_text())
    server, server_fd, reader, writer = None, None, None, None
    selector = selectors.DefaultSelector()
    receipt = {"qualified": False, "native": "UNRUN", "display_retired": False, "rescue": 0}
    status = 1
    try:
        reader, writer = os.pipe()
        with (
            (directory / "xvfb.stdout").open("xb") as stdout,
            (directory / "xvfb.stderr").open("xb") as stderr,
        ):
            server = subprocess.Popen(
                [
                    config["xvfb"],
                    "-displayfd",
                    str(writer),
                    "-screen",
                    "0",
                    "800x600x24",
                    "-nolisten",
                    "tcp",
                ],
                stdout=stdout,
                stderr=stderr,
                pass_fds=(writer,),
            )
            server_fd = os.pidfd_open(server.pid)
        os.close(writer)
        writer = None
        selector.register(reader, selectors.EVENT_READ)
        deadline = time.monotonic() + 10
        display = b""
        while b"\n" not in display:
            assert server.poll() is None
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError("owned display admission deadline")
            if selector.select(min(left, 0.1)):
                block = os.read(reader, 32)
                assert block
                display += block
                assert len(display) <= 16
        assert display.endswith(b"\n") and display[:-1].isdigit() and len(display[:-1]) <= 5
        environment = dict(os.environ)
        environment.update(DISPLAY=":" + display[:-1].decode("ascii"), XDG_SESSION_TYPE="x11")
        environment.pop("WAYLAND_DISPLAY", None)
        command = [
            config["luajit"],
            config["lua"],
            config["candidate"],
            config["logger"],
            config["runtime"],
            config["witness"],
            config["xi"],
            config["x11"],
            config["bridge"],
            config["xkb"],
            config["xkb11"],
            str(server.pid),
            str(os.getuid()),
            config["nonce"],
        ]
        # No parent-side timeout/kill of this child: the unchanged family owner
        # retains its deadline and all descendants until exact physical settlement.
        child = subprocess.Popen(
            command,
            cwd=config["driver"],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        stdout, stderr = child.communicate()
        (directory / "luajit.stdout").write_bytes(stdout)
        (directory / "luajit.stderr").write_bytes(stderr)
        receipt["native_exit"] = child.returncode
        assert len(stdout) <= 4096 and len(stdout.splitlines()) == 1
        native = json.loads(stdout)
        receipt["native"] = native
        assert child.returncode == 0 and not stderr and server.poll() is None
        validate_native(native)
        status = 0
    except BaseException as error:
        receipt["failure_type"] = type(error).__name__
    finally:
        selector.close()
        for descriptor in [reader, writer]:
            if descriptor is not None:
                os.close(descriptor)
        if server is not None:
            if server.poll() is not None:
                receipt["premature_display_exit"] = True
                status = 1
            else:
                try:
                    assert server_fd is not None
                    signal.pidfd_send_signal(server_fd, signal.SIGTERM)
                    receipt["termination_requested"] = True
                except (OSError, AssertionError):
                    receipt["termination_refused"] = True
                    status = 1
            try:
                receipt["display_exit"] = server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                receipt["rescue"] += 1
                status = 1
                if server_fd is not None:
                    signal.pidfd_send_signal(server_fd, signal.SIGKILL)
                else:
                    server.kill()  # Exact retained direct child only.
                receipt["display_exit"] = server.wait(timeout=3)
            receipt["display_retired"] = True
            if receipt.get("termination_requested") is not True or receipt["display_exit"] not in (
                0,
                -15,
            ):
                status = 1
        if server_fd is not None:
            os.close(server_fd)
            receipt["display_pidfd_closed"] = True
        receipt["qualified"] = status == 0 and receipt["rescue"] == 0
        (directory / "display.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return status


def execute(directory, root, candidate):
    original = load_original(root)
    assert candidate.is_file() and original.digest(candidate) == CANDIDATE_SHA
    assert directory.is_absolute() and not directory.exists()
    # Private preparation is inactive: future hosted admission must put these
    # exact test sources in the tested Git tree before any compiler/server run.
    source_sha = os.environ["GITHUB_SHA"]
    inputs = [
        HERE / "xi2_luajit_abi.c",
        HERE / "xi2_luajit_receiver.lua",
        Path(__file__),
        candidate,
        root / "static/ergopti_plus/_shared/lua/logger/shim.lua",
        root / "static/ergopti_plus/linux/_generated/native_runtime.lua",
        original.FAMILY,
        root / "static/ergopti_plus/linux/infra/display_server.lua",
        root / "static/ergopti_plus/_shared/lua/logger/init.lua",
    ]
    for path in inputs:
        relative = str(path.resolve(strict=True).relative_to(root))
        committed = subprocess.check_output(
            ["git", "show", source_sha + ":" + relative], cwd=root, timeout=5
        )
        assert original.digest(path) == original.hashlib.sha256(committed).hexdigest()
    directory.mkdir(mode=0o700)
    # Execute the original C3 entry point byte-exact, with a separate fresh namespace.
    previous = sys.argv
    try:
        sys.argv = [str(original.__file__), str(directory / "original-c3")]
        assert original.main() == 0, "original three C cases remain mandatory"
    finally:
        sys.argv = previous
    config = {
        "candidate": str(candidate),
        "lua": str(HERE / "xi2_luajit_receiver.lua"),
        "logger": str(root / "static/ergopti_plus/_shared/lua/logger/shim.lua"),
        "runtime": str(root / "static/ergopti_plus/linux/_generated/native_runtime.lua"),
        "driver": str(root / "static/ergopti_plus/linux"),
        "nonce": uuid.uuid4().hex,
    }
    for key, path in {
        "luajit": "/usr/bin/luajit",
        "xvfb": "/usr/bin/Xvfb",
        "xi": "/usr/lib/x86_64-linux-gnu/libXi.so",
        "x11": "/usr/lib/x86_64-linux-gnu/libX11.so",
        "bridge": "/usr/lib/x86_64-linux-gnu/libX11-xcb.so.1",
        "xkb": "/usr/lib/x86_64-linux-gnu/libxkbcommon.so.0",
        "xkb11": "/usr/lib/x86_64-linux-gnu/libxkbcommon-x11.so.0",
    }.items():
        config[key] = str(original.system_file(path))
    compiler = original.system_file("/usr/bin/gcc")
    pins = {str(path): original.digest(path) for path in inputs}
    libraries = {
        config[key]: original.digest(Path(config[key]))
        for key in ["xi", "x11", "bridge", "xkb", "xkb11", "luajit", "xvfb"]
    }
    for name in [
        str(compiler),
        "/usr/include/X11/Xlib.h",
        "/usr/include/X11/extensions/XInput2.h",
        "/usr/include/X11/extensions/XI2.h",
    ]:
        system_input = original.system_file(name)
        libraries[str(system_input)] = original.digest(system_input)
    environment = dict(os.environ)
    for key in [
        "LD_PRELOAD",
        "LD_AUDIT",
        "LD_LIBRARY_PATH",
        "LD_DEBUG",
        "LD_DEBUG_OUTPUT",
        "LIBRARY_PATH",
        "CPATH",
        "C_INCLUDE_PATH",
        "CPLUS_INCLUDE_PATH",
        "GCC_EXEC_PREFIX",
        "COMPILER_PATH",
        "LUA_INIT",
        "LUA_INIT_5_1",
    ]:
        environment.pop(key, None)
    config["witness"] = str(directory / "abi.so")
    compile_receipt = original.family_run(
        directory,
        "abi-compile",
        [
            str(compiler),
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-shared",
            "-fPIC",
            str(HERE / "xi2_luajit_abi.c"),
            config["x11"],
            "-ldl",
            "-o",
            config["witness"],
        ],
        60,
        environment,
    )
    pins[config["witness"]] = original.digest(Path(config["witness"]))
    config_path = directory / "config.json"
    original.record(config_path, config)
    pins[str(config_path)] = original.digest(config_path)
    native = directory / "lua-native"
    native.mkdir(mode=0o700)
    family = original.family_run(
        directory,
        "lua-native",
        [sys.executable, str(Path(__file__)), "--leader", str(native), str(config_path)],
        25,
        environment,
    )
    result = json.loads((native / "display.json").read_text())
    assert result["qualified"] is True and result["display_retired"] is True
    assert result["display_pidfd_closed"] is True and result["rescue"] == 0
    assert all(
        original.digest(Path(name)) == value for name, value in {**pins, **libraries}.items()
    )
    return {
        "qualified": True,
        "source_sha": os.environ["GITHUB_SHA"],
        "run_id": os.environ["GITHUB_RUN_ID"],
        "attempt": os.environ["GITHUB_RUN_ATTEMPT"],
        "candidate_sha": CANDIDATE_SHA,
        "runtime_projection": "CONTROLLED",
        "input_output_grant": False,
        "native_epoch_claim": False,
        "source_pins": pins,
        "system_pins": libraries,
        "compile": compile_receipt,
        "native_family": family,
        "display": result,
    }


def main(directory, root, candidate):
    assert directory.is_absolute() and not directory.exists()
    result = {
        "qualified": False,
        "runtime_projection": "CONTROLLED",
        "input_output_grant": False,
        "native_epoch_claim": False,
        "native": "UNRUN",
    }
    status = 1
    try:
        result = execute(directory, root, candidate)
        status = 0
    except BaseException as error:
        result["failure_type"] = type(error).__name__
    finally:
        if directory.is_dir():
            with (directory / "receiving.json").open("x", encoding="utf-8") as output:
                output.write(json.dumps(result, indent=2) + "\n")
                output.flush()
                os.fsync(output.fileno())
    print(
        ("PASS" if status == 0 else "FAIL")
        + " isolated LuaJIT XI2 ABI29/cookies3; CONTROLLED runtime"
    )
    return status


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--leader":
        sys.exit(
            leader(Path(sys.argv[2]).resolve(strict=True), Path(sys.argv[3]).resolve(strict=True))
        )
    assert len(sys.argv) == 4, (
        "fresh absolute directory, repository root and exact private candidate required"
    )
    sys.exit(
        main(
            Path(sys.argv[1]),
            Path(sys.argv[2]).resolve(strict=True),
            Path(sys.argv[3]).resolve(strict=True),
        )
    )
