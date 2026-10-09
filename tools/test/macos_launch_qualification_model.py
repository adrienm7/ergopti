#!/usr/bin/env python3
# tools/test/macos_launch_qualification_model.py
"""Execute the actual verdict/run functions with inert ports; invoke no native actor."""

import argparse
import ast
import datetime
import io
import json
from pathlib import Path
import re
import sys
from types import SimpleNamespace

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
source = Path(data["source"]).read_text(encoding="utf-8")
tree = ast.parse(source)
names = {"evaluate", "run", "parse_arguments", "read_launch_qualification"}
selected = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
assert len(selected) == 4, "Every exact source producer must exist"
scope = {
    "argparse": argparse,
    "__doc__": "Pure model",
    "__file__": data["source"],
    "Path": Path,
    "datetime": datetime,
    "json": json,
}
exec(compile(ast.Module(body=selected, type_ignores=[]), data["source"], "exec"), scope)
scope.update(
    FATAL_WORD=re.compile("FATAL"),
    EXPECTED_REFUSALS={},
    CONFIGURED_MARKER="configured",
    ready_marker=lambda scenario: "ready",
    QUIT_TIMEOUT_SECONDS=10,
    LAUNCHER_FATAL="FATAL:",
    LUA_FATAL="FATAL at boot stage",
)
good = {
    "launcher_log": "configured",
    "driver_log": "ready",
    "alive_after_window": True,
    "quit_seconds": 0.2,
    "state_problems": [],
}
scope.update(
    validate_control_summary=lambda *args: (_ for _ in ()).throw(
        ValueError("missing native control")
    ),
    validate_summary=lambda value: (_ for _ in ()).throw(ValueError("missing timer")),
    validate_karabiner_summary=lambda value: (_ for _ in ()).throw(ValueError("missing Karabiner")),
)
controls = 0


def check(condition):
    global controls
    assert condition
    controls += 1


for scenario in ["clean", "karabiner_config"]:
    check(bool(scope["evaluate"](scenario, good)))
    check(scope["evaluate"](scenario, good, defer_native=True) == [])
for update in [
    {"launcher_log": ""},
    {"driver_log": "ready [ERROR] original"},
    {"alive_after_window": False},
    {"quit_seconds": None},
]:
    check(bool(scope["evaluate"]("clean", {**good, **update}, defer_native=True)))


class InertPath:
    def __truediv__(self, other):
        return self

    def is_file(self):
        return True

    def exists(self):
        return False

    def open(self, mode):
        return io.BytesIO(b"inert")

    @staticmethod
    def home():
        return InertPath()


calls = {"launch": 0, "quit": 0, "active": False, "tick": 0}


def launch(*args, **kwargs):
    calls["launch"] += 1
    calls["active"] = True
    return SimpleNamespace(returncode=0, stderr="", stdout="arm64")


def clock():
    calls["tick"] += 1
    return calls["tick"]


def quit_port(*args):
    calls["quit"] += 1
    calls["active"] = False
    return 0.2


def native_factory(*args):
    raise RuntimeError("PURE_NATIVE_FACTORY_REACHED")


scope.update(
    Path=InertPath,
    logs_folder=lambda home: InertPath(),
    processes=lambda exe: [42] if calls["active"] else [],
    plistlib=SimpleNamespace(load=lambda handle: {"CFBundleIdentifier": "inert"}),
    subprocess=SimpleNamespace(run=launch),
    seed=lambda *args: {},
    time=SimpleNamespace(monotonic=clock, sleep=lambda delay: None),
    read_text=lambda path: "configured",
    driver_logs=lambda state: "ready",
    check_state=lambda *args: [],
    collect=lambda *args: {"errors": [], "windows": []},
    quit_application=quit_port,
    launch_command=lambda *args: ["INERT_MODEL_PORT"],
    NativeDelayedTimerProbe=native_factory,
    NativeKarabinerConfigProbe=native_factory,
    LAUNCHER_LOG_NAME="launcher",
    FALLBACK_BOOT_LOG_NAME="boot",
    HS_DOMAIN="inert",
    STARTUP_TIMEOUT_SECONDS=90,
    ALIVE_WINDOW_SECONDS=15,
    read_launch_qualification=lambda receipt, scenario: data["receipt"],
)
report = scope["run"](InertPath(), InertPath(), "clean", "inert", "explicit-record")
check(
    report["failures"] == []
    and report["qualification"] == data["receipt"]
    and report["native_qualified"] is False
)
check(calls["launch"] == 2 and calls["quit"] == 1)  # uname port plus original launch port.
try:
    scope["run"](InertPath(), InertPath(), "clean", "inert")
except RuntimeError as error:
    check(str(error) == "PURE_NATIVE_FACTORY_REACHED")
else:
    raise AssertionError("Embedded default invocation lost its original native factory")
print(
    json.dumps(
        {
            "controls": controls,
            "native_calls": 0,
            "ports": "inert",
            "actual_source_functions": sorted(names),
        }
    )
)
