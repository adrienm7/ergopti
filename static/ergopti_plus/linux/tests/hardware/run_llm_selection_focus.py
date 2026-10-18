#!/usr/bin/env python3
# tests/hardware/run_llm_selection_focus.py
"""Qualify exact AI text destinations on real GTK/AT-SPI and XTest output."""

import json
import os
import pathlib
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time


TITLE = "ergopti-owned-identical-ai-title"


def stop(process):
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def gtk(root):
    import gi

    gi.require_version("Gtk", "3.0")
    from gi.repository import GLib, Gtk

    windows, fields = [], []
    for count in (3, 1):
        window = Gtk.Window(title=TITLE)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        for _ in range(count):
            entry = Gtk.Entry()
            fields.append(entry)
            box.pack_start(entry, True, True, 0)
        window.add(box)
        windows.append(window)
    fields[2].set_visibility(False)
    current = [0]

    def state(*_):
        data = {"focused": current[0], "texts": [entry.get_text() for entry in fields]}
        (root / "state.json").write_text(json.dumps(data))

    def control():
        request = json.loads((root / "control.json").read_text())
        if request.get("reset"):
            for entry, text in zip(fields, ("ORIGIN SECOND ORIGIN", "SECOND", "SECRET", "OTHER")):
                entry.set_text(text)
        current[0] = request["target"]
        windows[0 if current[0] < 3 else 1].present()
        fields[current[0]].grab_focus()
        fields[current[0]].select_region(request.get("start", 0), request.get("end", -1))
        state()
        return True

    for entry in fields:
        entry.connect("changed", state)
    for window in windows:
        window.show_all()
    control()
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, control)
    GLib.timeout_add_seconds(120, Gtk.main_quit)
    Gtk.main()


def session(root):
    driver = pathlib.Path(__file__).resolve().parents[2]
    processes = []
    worker = None
    worker_ack = False
    summary = None
    with (root / "wm.log").open("w") as wm_log, (root / "gtk.log").open("w") as gtk_log:
        wm = subprocess.Popen(["openbox"], stdout=wm_log, stderr=wm_log)
        processes.append(wm)
        (root / "control.json").write_text(json.dumps({"target": 0, "reset": True}))
        app = subprocess.Popen(
            [
                os.environ.get("ERGOPTI_ATSPI_GTK_PYTHON", "/usr/bin/python3"),
                __file__,
                "--gtk",
                str(root),
            ],
            stdout=gtk_log,
            stderr=gtk_log,
        )
        processes.append(app)
        try:
            deadline = time.monotonic() + 5
            while True:
                visible = subprocess.run(
                    ["xdotool", "search", "--onlyvisible", "--name", TITLE],
                    capture_output=True,
                    timeout=2,
                )
                if visible.returncode == 0 and len(visible.stdout.splitlines()) == 2:
                    break
                assert app.poll() is None, "owned GTK app exited before mapping both windows"
                assert time.monotonic() < deadline, "owned GTK windows did not map"
                time.sleep(0.05)
            time.sleep(1)
            worker_env = dict(os.environ)
            worker_env["LUA_PATH"] = (
                "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;"
                + os.environ.get("LUA_PATH", ";;")
            )
            with (root / "worker.log").open("w") as worker_log:
                worker = subprocess.Popen(
                    ["luajit", "tests/hardware/llm_selection_focus.lua"],
                    cwd=driver,
                    env=worker_env,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=worker_log,
                    text=True,
                    bufsize=1,
                )
                processes.append(worker)

                def command(text):
                    worker.stdin.write(text + "\n")
                    worker.stdin.flush()
                    with selectors.DefaultSelector() as selector:
                        selector.register(worker.stdout, selectors.EVENT_READ)
                        assert selector.select(10), "owned AI worker exceeded its command deadline"
                        line = worker.stdout.readline()
                    assert line.startswith("RECEIPT:"), (
                        "owned AI worker failed: " + line + (root / "worker.log").read_text()
                    )
                    return json.loads(line.removeprefix("RECEIPT:"))

                def focus(target, reset=False, start=0, end=-1):
                    (root / "control.json").write_text(
                        json.dumps({"target": target, "reset": reset, "start": start, "end": end})
                    )
                    app.send_signal(signal.SIGUSR1)
                    time.sleep(0.2)
                    state = json.loads((root / "state.json").read_text())
                    assert state["focused"] == target
                    return state["texts"]

                def unchanged(expected):
                    time.sleep(0.1)
                    actual = json.loads((root / "state.json").read_text())["texts"]
                    assert actual == expected, (
                        "AI typed into an unowned native field",
                        expected,
                        actual,
                    )

                cases = 0
                for mode in ("tone", "prediction", "translation"):
                    for name, target in (
                        ("same-field", 0),
                        ("other-field", 1),
                        ("password", 2),
                        ("other-window", 3),
                    ):
                        before = focus(0, True)
                        initial = command("reset")
                        assert (
                            initial["url_filter"] is True and initial["foreground_type"] == "table"
                        ), (
                            "native AI must exercise the enabled URL filter with the real lifecycle contract"
                        )
                        assert (
                            initial["role"] == 61 and initial["active_scope"] and initial["target"]
                        )
                        started = command("start-" + mode)
                        assert started["requests"] == 1, (mode, started)
                        focus(target)
                        moved = command("probe")
                        if target < 3:
                            assert initial["window"] == moved["window"], (
                                "field switch must stay inside one native window"
                            )
                        else:
                            assert initial["window"] != moved["window"], (
                                "second identical-title GTK window must differ"
                            )
                        assert initial["bus"] == moved["bus"], (
                            "all fields and windows belong to the same native process"
                        )
                        result = command("finish")
                        assert result["applied"] == (0 if target else 1), (mode, name, result)
                        if target == 2:
                            assert moved["role"] == 40 and "target" not in moved, (
                                "native password must never own AI output"
                            )
                            assert moved["cached_verdict"] in ("secure", "unknown"), (
                                "the resident watcher must revoke an ordinary verdict for a password"
                            )
                        elif target:
                            assert moved["path"] != initial["path"], (
                                "each native text control owns a different accessible path"
                            )
                            assert moved.get("target") != initial["target"], (
                                "an incoming or pending field cannot borrow the original text target"
                            )
                        if target:
                            assert not result["offered"], (
                                "stale completion must not publish a selectable offer"
                            )
                            unchanged(before)
                        else:
                            time.sleep(0.1)
                            texts = json.loads((root / "state.json").read_text())["texts"]
                            assert texts[0] != before[0] and texts[1:] == before[1:], (
                                "positive native output must reach only its own field"
                            )
                        cases += 1
                    before = focus(0, True)
                    command("reset")
                    focus(2)
                    refused = command("start-" + mode)
                    assert (
                        refused["role"] == 40 and refused["requests"] == 0 and refused["reads"] == 0
                    ), refused
                    unchanged(before)
                    cases += 1
                    if mode != "tone":
                        for target in (1, 2):
                            before = focus(0, True)
                            command("reset")
                            command("start-" + mode)
                            assert command("offer")["offered"]
                            focus(target)
                            result = command("accept")
                            assert not result["accepted"] and result["applied"] == 0, result
                            unchanged(before)
                            cases += 1
                    if mode != "prediction":
                        focus(0, True)
                        command("reset")
                        command("start-" + mode)
                        command("offer")
                        assert command("start-" + mode)["requests"] == 1, (
                            "second request must wait for pacing"
                        )
                        before = focus(1)
                        result = command("advance")
                        assert result["requests"] == 1, (
                            "pacing must recheck native text destination before sending"
                        )
                        unchanged(before)
                        cases += 1
                for mode in ("tone", "translation"):
                    for name, start, end in (
                        ("unchanged", 0, 6),
                        ("different-text", 7, 13),
                        ("same-text-new-range", 14, 20),
                    ):
                        before = focus(0, True, 0, 6)
                        initial = command("reset")
                        original_range = command("selection-range")
                        assert (
                            original_range["selection_first"],
                            original_range["selection_last"],
                        ) == (0, 6)
                        assert command("start-" + mode)["requests"] == 1
                        if mode == "translation":
                            assert command("offer")["offered"]
                        focus(0, False, start, end)
                        moved = command("selection-range")
                        assert (moved["selection_first"], moved["selection_last"]) == (start, end)
                        assert initial["target"] == moved["target"], (
                            "range moves must stay inside the same native field"
                        )
                        result = command("finish" if mode == "tone" else "accept")
                        assert result["applied"] == (1 if name == "unchanged" else 0), (
                            mode,
                            name,
                            result,
                        )
                        if name != "unchanged":
                            unchanged(before)
                            if mode == "translation":
                                assert not result["accepted"]
                        else:
                            time.sleep(0.1)
                            after = json.loads((root / "state.json").read_text())["texts"]
                            assert (
                                after[0] != before[0]
                                and after[0].endswith(" SECOND ORIGIN")
                                and after[1:] == before[1:]
                            ), (mode, name, after)
                        cases += 1
                for stage in ("completion", "acceptance"):
                    before = focus(0, True)
                    initial = command("reset")
                    assert initial["conclusive"] and initial["target"] and initial["role"] == 61, (
                        initial
                    )
                    started = command("start-prediction")
                    assert started["started"] and started["requests"] == 1, (stage, started)
                    assert started["conclusive"] and started["target"] == initial["target"], (
                        stage,
                        started,
                    )
                    if stage == "acceptance":
                        assert command("offer")["offered"]
                    app.send_signal(signal.SIGSTOP)
                    try:
                        result = command("finish" if stage == "completion" else "accept")
                        assert result["applied"] == 0 and not result.get("accepted"), result
                    finally:
                        app.send_signal(signal.SIGCONT)
                    unchanged(before)
                    cases += 1
                focus(0, True)
                command("reset")
                first = command("first-character")
                assert first["helper_calls"] == 0, (
                    "the AI first character cannot call a synchronous focus helper",
                    first,
                )
                assert first["first_char_target_before"] and (
                    first["heartbeat_delay_ms"] < first["barrier_budget_ms"] + 100
                ), first
                cases += 1
                print(
                    f"Native AI first character: {first['first_char_ms']:.1f}ms; synchronous helpers={first['helper_calls']}"
                )
                timing = command("benchmark")
                durations = sorted(timing["probe_ms"])
                assert len(durations) == 20 and durations[-1] < 1000
                print(
                    f"Native resident AT-SPI destination: median={durations[10]:.1f}ms max={durations[-1]:.1f}ms (20 probes)"
                )
                app.send_signal(signal.SIGSTOP)
                try:
                    timeout = command("deadline")
                    assert "deadline_target" not in timeout, (
                        "a wedged native application cannot authorize output"
                    )
                    assert 0 <= timeout["deadline_ms"] < timeout["barrier_budget_ms"] + 100, timeout
                finally:
                    app.send_signal(signal.SIGCONT)
                print(f"Native wedged AT-SPI refusal: {timeout['deadline_ms']:.1f}ms")
                focus(0, True, 0, 6)
                command("reset")
                app.send_signal(signal.SIGSTOP)
                try:
                    cold_timeout = command("selection-range")
                    assert "selection_first" not in cold_timeout
                    assert cold_timeout["selection_ms"] < 1100, cold_timeout
                finally:
                    app.send_signal(signal.SIGCONT)
                cases += 1
                print(
                    f"Native selected-range helper timeout and settlement: {cold_timeout['selection_ms']:.1f}ms"
                )
                summary = f"PASS native GTK AI text focus: {cases} cases; correct controls type; changed fields/windows and passwords refuse request/output"
        finally:
            try:
                if app.poll() is None:
                    app.send_signal(signal.SIGCONT)
                if worker is not None:
                    if worker.poll() is None:
                        try:
                            worker.stdin.close()
                        except BrokenPipeError:
                            pass
                        try:
                            worker.wait(timeout=6)
                        except subprocess.TimeoutExpired:
                            pass
                    worker_ack = worker.returncode == 0
            finally:
                for process in reversed(processes):
                    stop(process)
        assert worker_ack, "native AI worker did not acknowledge successful retirement"
        assert summary is not None
        print(summary)


def main():
    if "--gtk" in sys.argv:
        gtk(pathlib.Path(sys.argv[-1]))
        return 0
    if "--session" in sys.argv:
        session(pathlib.Path(sys.argv[-1]))
        return 0
    for tool in ("xvfb-run", "dbus-run-session", "openbox", "xdotool", "luajit"):
        if shutil.which(tool) is None:
            print(f"ENVIRONMENT: {tool} is missing", file=sys.stderr)
            return 2
    with tempfile.TemporaryDirectory(prefix="ergopti-ai-text-focus-") as temp:
        return subprocess.run(
            ["xvfb-run", "-a", "dbus-run-session", sys.executable, __file__, "--session", temp],
            timeout=120,
        ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
