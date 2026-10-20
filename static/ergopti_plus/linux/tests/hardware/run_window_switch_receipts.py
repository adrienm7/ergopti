# tests/hardware/run_window_switch_receipts.py

"""Own exact Xvfb, Openbox and client children; observe real EWMH focus."""

import os
import pathlib
import select
import signal
import subprocess
import tempfile
import time
import json
import sys
import re
from native_fixture_family import run as run_owned_family

ROOT = pathlib.Path(__file__).resolve().parents[2]
LUA = ROOT / "tests/hardware/run_window_switch_operation.lua"


def _visible_search_failure(title, result):
    """Select closed metadata from the last completed owned visible search only."""
    titles = {"owned111_active": "active", "owned111_right": "right", "owned111_left": "left"}
    if type(title) is not str or title not in titles:
        return None
    if type(result) is not subprocess.CompletedProcess:
        return None
    if type(result.args) is not tuple or len(result.args) != 5:
        return None
    if any(type(argument) is not str for argument in result.args):
        return None
    if result.args != ("xdotool", "search", "--onlyvisible", "--name", title):
        return None
    if type(result.returncode) is not int or not -64 <= result.returncode <= 255:
        return None
    if type(result.stdout) is not str or type(result.stderr) is not str:
        return None
    diagnostic_text_char_limit = 65536
    if (
        len(result.stdout) > diagnostic_text_char_limit
        or len(result.stderr) > diagnostic_text_char_limit
    ):
        return None
    if result.stdout.strip():
        return None
    return {
        "version": 1,
        "phase": "owned-xmessage-visible-search",
        "title": titles[title],
        "status": result.returncode,
        "stdout_bytes": len(result.stdout.encode("utf-8")),
        "stderr_bytes": len(result.stderr.encode("utf-8")),
    }


def _discover_owned_xmessage(title, wait, query):
    """Retain the original deadline and ID semantics; observe only its failed search."""
    last_result = None

    def visible():
        nonlocal last_result
        last_result = query()
        return last_result.stdout.strip()

    try:
        return wait(visible)
    except AssertionError as original:
        if (
            type(original) is AssertionError
            and type(original.args) is tuple
            and len(original.args) == 1
            and type(original.args[0]) is str
            and original.args[0] == "owned native receipt deadline"
        ):
            try:
                fact = _visible_search_failure(title, last_result)
                if fact is not None:
                    print(
                        "# native_window_visible_search_failure "
                        + json.dumps(fact, sort_keys=True),
                        flush=True,
                    )
            except Exception:
                # Optional diagnostics cannot replace the original deadline.
                # Control-plane BaseExceptions still propagate through mandatory cleanup.
                pass
        raise


def _window_failure_snapshot(query, now=time.monotonic):
    """Observe only the failed owned display; no result can admit a window."""
    budget_seconds = 3.0
    query_timeout_seconds = 0.5
    max_clients = 6
    deadline = now() + budget_seconds
    output_limit = 65536
    records = []

    def observe(role, *argv):
        remaining = deadline - now()
        record = {"role": role, "argv": list(argv)}
        records.append(record)
        if remaining <= 0:
            record["state"] = "budget-exhausted"
            return ""
        try:
            result = query(argv, min(remaining, query_timeout_seconds))
            if (
                type(result) is not subprocess.CompletedProcess
                or result.args != argv
                or type(result.returncode) is not int
                or type(result.stdout) is not bytes
                or type(result.stderr) is not bytes
            ):
                raise ValueError("invalid diagnostic query receipt")
            record.update(state="completed", status=result.returncode)
            streams = (result.stdout, result.stderr)
        except subprocess.TimeoutExpired as error:
            record["state"] = "timeout"
            streams = (error.stdout or b"", error.stderr or b"")
        except Exception as error:
            record.update(state="query-error", error=type(error).__name__)
            return ""
        for name, value in zip(("stdout", "stderr"), streams):
            if type(value) is not bytes:
                record.update(state="query-error", error="invalid-output-type")
                return ""
            record[name + "_bytes"] = len(value)
            record[name + "_truncated"] = len(value) > output_limit
            record[name] = value[:output_limit].decode("utf-8", errors="replace")
        if record["state"] != "completed" or record["status"] != 0:
            return ""
        return record["stdout"]

    wm = observe("wm-root", "xprop", "-root", "_NET_SUPPORTING_WM_CHECK")
    wm_id = re.search(
        r"^_NET_SUPPORTING_WM_CHECK\(WINDOW\): window id # (0x[0-9a-fA-F]+)\s*$",
        wm,
        re.MULTILINE,
    )
    if wm_id is not None and int(wm_id.group(1), 16) != 0:
        observe(
            "wm-reciprocal",
            "xprop",
            "-id",
            wm_id.group(1),
            "_NET_SUPPORTING_WM_CHECK",
            "_NET_WM_NAME",
            "_NET_WM_PID",
        )
    clients = observe(
        "client-lists", "xprop", "-root", "_NET_CLIENT_LIST_STACKING", "_NET_CLIENT_LIST"
    )
    tree = observe("root-tree", "xwininfo", "-root", "-tree")
    # Title-bearing tree rows also expose an unmapped client absent from EWMH.
    # Other advertised client IDs are observations only, never ownership proof.
    ids = re.findall(
        r'^\s*(0x[0-9a-fA-F]+)\s+"owned111_(?:active|right|left)":',
        tree,
        re.MULTILINE,
    )
    for row in clients.splitlines():
        if re.match(r"^_NET_CLIENT_LIST(?:_STACKING)?\(WINDOW\): window id #", row):
            ids.extend(re.findall(r"0x[0-9a-fA-F]+", row))
    selected = list(dict.fromkeys(value.lower() for value in ids if int(value, 16)))
    for window_id in selected[:max_clients]:
        observe("client-map", "xwininfo", "-id", window_id)
        observe(
            "client-properties",
            "xprop",
            "-id",
            window_id,
            "WM_NAME",
            "WM_CLASS",
            "WM_STATE",
            "WM_CLIENT_MACHINE",
            "_NET_WM_NAME",
            "_NET_WM_PID",
            "_NET_WM_DESKTOP",
        )
    return {
        "version": 1,
        "phase": "owned-x11-setup-failure",
        "query_budget_seconds": budget_seconds,
        "query_timeout_seconds": query_timeout_seconds,
        "retained_bytes_per_stream": output_limit,
        "observed_client_ids": len(selected),
        "omitted_client_ids": max(0, len(selected) - max_clients),
        "queries": records,
    }


def _emit_complete_child_log(path, write):
    """Emit every retained child log byte after cleanup, without decoding or slicing."""
    with path.open("rb") as source:
        while True:
            chunk = source.read(65536)
            if not chunk:
                return
            written = write(chunk)
            if type(written) is not int or written != len(chunk):
                raise OSError("incomplete child-log write")


def main():
    with tempfile.TemporaryDirectory(prefix="ergopti111-native-") as directory:
        root = pathlib.Path(directory)
        children = []
        reader, writer = os.pipe()
        wm = None
        env = None
        log = None
        failure = None
        observations = None
        try:
            log = (root / "native.log").open("wb")
            server = subprocess.Popen(
                [
                    "Xvfb",
                    "-displayfd",
                    str(writer),
                    "-screen",
                    "0",
                    "2000x800x24",
                    "-ac",
                    "+extension",
                    "RANDR",
                ],
                pass_fds=(writer,),
                stdout=log,
                stderr=log,
            )
            children.append(server)
            os.close(writer)
            writer = None
            assert select.select([reader], [], [], 5)[0]
            display = ":" + os.read(reader, 32).decode().strip()
            assert display[1:].isdigit()
            env = dict(
                os.environ,
                DISPLAY=display,
                XDG_DATA_DIRS=os.environ.get(
                    "ERGOPTI_X11_FIXTURE_DATA_DIRS",
                    os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share"),
                ),
                LUA_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
            )

            def command(*args, check=True):
                r = subprocess.run(args, env=env, text=True, capture_output=True, timeout=3)
                if check:
                    assert r.returncode == 0, (args, r.returncode, r.stdout, r.stderr)
                return r

            def wait(test):
                end = time.monotonic() + 5
                while time.monotonic() < end:
                    value = test()
                    if value:
                        return value
                    time.sleep(0.01)
                raise AssertionError("owned native receipt deadline")

            config = root / "rc.xml"
            config.write_text(
                '<openbox_config xmlns="http://openbox.org/3.4/rc"><focus><followMouse>no</followMouse><focusNew>yes</focusNew></focus><desktops><number>2</number></desktops></openbox_config>\n'
            )
            wm = subprocess.Popen(
                ["openbox", "--sm-disable", "--config-file", str(config)],
                env=env,
                stdout=log,
                stderr=log,
            )
            children.append(wm)
            wait(
                lambda: (
                    "window id #"
                    in command("xprop", "-root", "_NET_SUPPORTING_WM_CHECK", check=False).stdout
                )
            )
            command("xrandr", "--setmonitor", "LEFT", "1000/300x800/240+0+0", "screen")
            command("xrandr", "--setmonitor", "RIGHT", "1000/300x800/240+1000+0", "none")
            assert "Monitors: 2" in command("xrandr", "--listmonitors").stdout
            # Openbox advertises itself before it has handled the RandR changes:
            # a client mapped right away stayed an unmanaged, unmapped root child
            # past the deadline (dev run 39375032517). A desktop round trip proves
            # its event loop runs before any owned client exists.
            for desktop in ("1", "0"):
                command("xdotool", "set_desktop", desktop)
                wait(
                    lambda desktop=desktop: re.search(
                        r"^_NET_CURRENT_DESKTOP\(CARDINAL\) = " + desktop + r"$",
                        command("xprop", "-root", "_NET_CURRENT_DESKTOP", check=False).stdout,
                        re.MULTILINE,
                    )
                )
            ids = {}
            for name, x in [("active", 100), ("right", 1100), ("left", 100)]:
                title = "owned111_" + name
                child = subprocess.Popen(
                    [
                        "xmessage",
                        "-name",
                        title,
                        "-title",
                        title,
                        "-buttons",
                        "",
                        "-geometry",
                        f"500x400+{x}+100",
                        "owned",
                    ],
                    env=env,
                    stdout=log,
                    stderr=log,
                )
                children.append(child)
                ids[name] = int(
                    _discover_owned_xmessage(
                        title,
                        wait,
                        lambda: command(
                            "xdotool", "search", "--onlyvisible", "--name", title, check=False
                        ),
                    )
                )

            def active():
                return int(command("xdotool", "getactivewindow").stdout.strip())

            def focus(name):
                command("xdotool", "windowactivate", "--sync", str(ids[name]))
                wait(lambda: active() == ids[name])

            binding_config = root / "binding.toml"
            binding_config.write_text('[gestures]\nenabled = true\ntap_3 = "alt_tab_monitor"\n')
            receipts = []
            write_marker = root / "write_barrier"
            causal_worker = (
                sys.argv[sys.argv.index("--causal-worker") + 1]
                if "--causal-worker" in sys.argv
                else ""
            )

            def input_focus_chain():
                focused = int(command("xdotool", "getwindowfocus", "-f").stdout.strip())
                chain = [focused]
                for _ in range(64):
                    tree = command("xwininfo", "-int", "-tree", "-id", str(chain[-1])).stdout
                    parent = next(
                        (
                            line.split(":", 1)[1].strip().split()[0]
                            for line in tree.splitlines()
                            if "Parent window id:" in line
                        ),
                        None,
                    )
                    if parent is None or int(parent) == 0:
                        break
                    parent = int(parent)
                    assert parent not in chain
                    chain.append(parent)
                return chain

            def run(name, expected, target=None, minimum=1, mode="normal"):
                binding_config.write_text('[gestures]\nenabled = true\ntap_3 = "alt_tab_monitor"\n')
                r = run_owned_family(
                    [
                        "luajit",
                        str(LUA),
                        str(expected).lower(),
                        str(minimum),
                        mode,
                        str(binding_config),
                        str(write_marker),
                        causal_worker,
                    ],
                    cwd=ROOT,
                    env=env,
                    text=True,
                    capture_output=True,
                    timeout=15,
                )
                assert r.returncode == 0, (name, r.returncode, r.stdout, r.stderr)
                if target is not None:
                    assert active() == target, (name, active(), target)
                print(r.stdout.strip())
                receipts.append(
                    {
                        "case": name,
                        "ack": expected,
                        "active": active(),
                        "target": target,
                        "input_focus_chain": input_focus_chain(),
                    }
                )

            focus("active")
            command("xdotool", "mousemove", "1500", "200")
            run("cursor_right_active_left", True, ids["right"])
            focus("active")
            run("canonical_binding_native_focus", True, ids["right"], mode="binding")
            if "--require-routing" in sys.argv:
                focus("active")
                run("actual_scoped_dispatcher_native_focus", True, ids["right"], mode="dispatch")
            focus("left")
            focus("right")
            command("xdotool", "mousemove", "200", "200")
            run("fresh_cursor_left", True, ids["left"])
            command("xdotool", "windowmove", str(ids["right"]), "800", "100")
            focus("active")
            command("xdotool", "mousemove", "1500", "200")
            run("spanning_centre_right", True, ids["right"])
            command("xdotool", "windowmove", str(ids["right"]), "1100", "100")
            command("xdotool", "windowminimize", str(ids["right"]))
            focus("active")
            run("minimized_right_refuses", False, ids["active"])
            command("xdotool", "windowmap", str(ids["right"]))
            focus("active")
            command("xdotool", "set_desktop_for_window", str(ids["right"]), "1")
            run("foreign_desktop_refuses", False, ids["active"])
            command("xdotool", "set_desktop_for_window", str(ids["right"]), "0")
            focus("active")
            os.kill(wm.pid, signal.SIGSTOP)
            old = command("xdotool", "windowactivate", str(ids["right"]))
            assert old.returncode == 0 and active() == ids["active"]
            print("old_non_sync_activation=accepted actual_focus=unchanged")
            run("native_wm_refusal_sync_readback", False, ids["active"])
            os.kill(wm.pid, signal.SIGCONT)
            focus("active")
            real = command("sh", "-c", "command -v xdotool").stdout.strip()
            wrappers = root / "wrappers"
            wrappers.mkdir()
            wrapper = wrappers / "xdotool"
            marker = root / "pointer_count"

            def install(body):
                wrapper.write_text("#!/bin/sh\nset -eu\n" + body + "\nexec " + real + ' "$@"\n')
                wrapper.chmod(493)
                env["PATH"] = str(wrappers) + os.pathsep + os.environ["PATH"]

            tree = command("xwininfo", "-int", "-tree", "-id", str(ids["right"])).stdout
            child_rows = re.split(r"(?:child|children):", tree, maxsplit=1)[1]
            child_focus = int(re.search(r"^\s+(\d+) ", child_rows, re.MULTILINE).group(1))
            focus("active")
            install(
                'if [ "$1" = windowactivate ]; then '
                + real
                + ' "$@"; '
                + real
                + " windowfocus "
                + str(child_focus)
                + "; exit 0; fi"
            )
            run("native_descendant_keyboard_focus_admitted", True, ids["right"])
            native_chain = input_focus_chain()
            assert (
                native_chain[0] == child_focus
                and child_focus != ids["right"]
                and ids["right"] in native_chain
            ), native_chain
            print("native_descendant_input_focus=" + json.dumps(native_chain))
            env["PATH"] = os.environ["PATH"]
            focus("active")
            install('if [ "$1" = getmouselocation ]; then sleep 0.2; fi')
            run("delayed_tool_pump_progress", True, ids["right"], minimum=100)
            for mode in ["pause_snapshot", "pause_focus", "source", "canonical", "physical"]:
                focus("active")
                command("xdotool", "mousemove", "1500", "200")
                run("native_" + mode + "_suppresses_late_focus", False, ids["active"], mode=mode)
            env["PATH"] = os.environ["PATH"]
            for mode in [
                "preactivation_canonical",
                "preactivation_physical",
                "preactivation_pause",
                "preactivation_set_action",
                "preactivation_program_binding",
                "preactivation_scope",
                "preactivation_foreign_initial",
                "preactivation_foreign_acknowledged",
                "preactivation_foreign_request",
                "preactivation_foreign_permit",
                "preactivation_foreign_digest",
            ]:
                focus("active")
                command("xdotool", "mousemove", "1500", "200")
                run("native_" + mode + "_refuses", False, ids["active"], mode=mode)
            focus("active")
            run(
                "foreign_initial_before_child_start_preserved",
                False,
                ids["active"],
                mode="foreign_initial_start",
            )
            for mode in ["foreign_initial_snapshot", "foreign_digest_snapshot"]:
                focus("active")
                write_marker.unlink(missing_ok=True)
                install(
                    'if [ "$1" = getmouselocation ]; then touch '
                    + str(write_marker)
                    + "; sleep 0.2; fi"
                )
                run(
                    "native_" + mode + "_preserves_foreign_contents",
                    False,
                    ids["active"],
                    mode=mode,
                )
                env["PATH"] = os.environ["PATH"]
            focus("active")
            write_marker.unlink(missing_ok=True)
            counter = root / "final_query_count"
            install(
                'if [ "$1" = getmouselocation ]; then n=0; if [ -f '
                + str(counter)
                + " ]; then n=$(cat "
                + str(counter)
                + '); fi; n=$((n+1)); printf "%s\\n" "$n" > '
                + str(counter)
                + '; if [ "$n" -eq 4 ]; then touch '
                + str(write_marker)
                + "; sleep 0.2; fi; fi"
            )
            run(
                "native_foreign_final_output_preserves_contents",
                False,
                ids["right"],
                mode="foreign_final_acknowledged",
            )
            env["PATH"] = os.environ["PATH"]
            focus("active")
            install(
                'if [ "$1" = getmouselocation ]; then if [ -f '
                + str(marker)
                + " ]; then "
                + real
                + " mousemove 200 200; else touch "
                + str(marker)
                + "; fi; fi"
            )
            run("cursor_moves_before_activation", False, ids["active"])
            env["PATH"] = os.environ["PATH"]
            focus("active")
            command("xdotool", "mousemove", "1500", "200")
            install('if [ "$1" = windowactivate ]; then exit 0; fi')
            run("zero_exit_without_focus_refuses", False, ids["active"])
            env["PATH"] = os.environ["PATH"]
            focus("active")
            before_focus = input_focus_chain()
            install(
                'if [ "$1" = windowactivate ]; then xprop -root -f _NET_ACTIVE_WINDOW 32x -set _NET_ACTIVE_WINDOW "$3" >/dev/null; exit 0; fi'
            )
            run("ewmh_property_without_keyboard_focus_refuses", False, ids["right"])
            assert input_focus_chain() == before_focus
            assert ids["active"] in before_focus and ids["right"] not in before_focus
            env["PATH"] = os.environ["PATH"]
            focus("left")
            focus("active")
            children[3].terminate()
            children[3].wait(timeout=3)
            wait(
                lambda: (
                    str(hex(ids["right"]))
                    not in command("xprop", "-root", "_NET_CLIENT_LIST_STACKING").stdout
                )
            )
            run("closed_right_refuses", False, ids["active"])
            for receipt in receipts:
                print(json.dumps(receipt))
            print("Native window receipts: " + str(len(receipts)) + " passed, 0 failed, 0 skipped")
        except Exception as error:
            failure = error
            try:
                observations = {"phase": "display-not-established", "queries": []}
                if env is not None:
                    observations = _window_failure_snapshot(
                        lambda argv, timeout: subprocess.run(
                            argv,
                            env=env,
                            stdin=subprocess.DEVNULL,
                            capture_output=True,
                            timeout=timeout,
                        )
                    )
                observations["children_before_cleanup"] = [
                    {"pid": child.pid, "status": child.poll()} for child in children
                ]
            except Exception as diagnostic_error:
                observations = {
                    "phase": "diagnostic-capture-refused",
                    "error": type(diagnostic_error).__name__,
                }
            raise
        finally:
            active_exception = sys.exc_info()[1]
            cleanup_errors = []

            def retain_cleanup_error(phase, error):
                cleanup_errors.append((phase, error))

            for descriptor in (reader, writer):
                if descriptor is not None:
                    try:
                        os.close(descriptor)
                    except Exception as error:
                        retain_cleanup_error("display-pipe-close", error)
            try:
                if wm is not None and wm.poll() is None:
                    os.kill(wm.pid, signal.SIGCONT)
            except Exception as error:
                retain_cleanup_error("wm-continue", error)
            for child in reversed(children):
                try:
                    if child.poll() is None:
                        child.terminate()
                        try:
                            child.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait(timeout=3)
                except Exception as error:
                    retain_cleanup_error("owned-child-retirement", error)
            if log is not None:
                try:
                    log.close()
                except Exception as error:
                    retain_cleanup_error("child-log-close", error)
            if failure is not None or cleanup_errors:
                try:
                    print(
                        "# native_window_setup_failure "
                        + json.dumps(
                            {
                                "observations": observations,
                                "cleanup_errors": [
                                    {"phase": phase, "error": type(error).__name__}
                                    for phase, error in cleanup_errors
                                ],
                                "children_after_cleanup": [
                                    {"pid": child.pid, "status": child.poll()} for child in children
                                ],
                            },
                            sort_keys=True,
                        ),
                        flush=True,
                    )
                except Exception:
                    # A metadata sink refusal must not suppress the complete child log.
                    pass
                if log is not None:
                    try:
                        print("# native_window_child_log_begin", flush=True)
                        _emit_complete_child_log(root / "native.log", sys.stdout.buffer.write)
                        sys.stdout.buffer.flush()
                        print("\n# native_window_child_log_end", flush=True)
                    except Exception:
                        # Optional reporting cannot replace the original failure.
                        # Control-plane BaseExceptions still propagate to the family owner.
                        pass
            if active_exception is None and cleanup_errors:
                raise cleanup_errors[0][1]


if __name__ == "__main__":
    main()
