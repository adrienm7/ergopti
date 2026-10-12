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


def main():
    with tempfile.TemporaryDirectory(prefix="ergopti111-native-") as directory:
        root = pathlib.Path(directory)
        children = []
        reader, writer = os.pipe()
        wm = None
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
                    wait(
                        lambda: command(
                            "xdotool", "search", "--onlyvisible", "--name", title, check=False
                        ).stdout.strip()
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
        except Exception:
            log.flush()
            print((root / "native.log").read_text())
            print("owned child statuses", [(p.pid, p.poll()) for p in children])
            print(command("xprop", "-root", "_NET_CLIENT_LIST_STACKING", check=False).stdout)
            raise
        finally:
            os.close(reader)
            if writer is not None:
                os.close(writer)
            if wm is not None and wm.poll() is None:
                os.kill(wm.pid, signal.SIGCONT)
            for child in reversed(children):
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=3)


if __name__ == "__main__":
    main()
