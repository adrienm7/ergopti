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
names = {
    "evaluate",
    "run",
    "parse_arguments",
    "read_launch_qualification",
    "native_failures",
    "qualify_native_features",
    "feature_proof",
}
selected = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
assert len(selected) == len(names), "Every exact source producer must exist"
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
    NATIVE_FEATURES={
        "clean": ("delayed_timer",),
        "karabiner_config": ("karabiner_config", "script_scope"),
    },
    FEATURE_PROOF_KEYS={
        "clean": "native_delayed_timer",
        "karabiner_config": "native_karabiner_config",
    },
    INSTALLED_EXECUTABLE="inert",
    BOOTSTRAP_CONTRACT="inert",
    BOOTSTRAP_QUALIFICATION="inert",
    HS_DOMAIN="inert",
    bounded_refusal=str,
)
# Validators accept only what the active model step admits.
accepted = {"features": False, "transport": False}


def admitted(kind, message):
    def validate(*args):
        if not accepted[kind]:
            raise ValueError(message)
        return args[0] if args else None

    return validate


PRODUCT = {"product": "inert"}
good = {
    "launcher_log": "configured",
    "driver_log": "ready",
    "alive_after_window": True,
    "quit_seconds": 0.2,
    "state_problems": [],
    "installed_product": PRODUCT,
    "native_child_pid": 42,
}
features = {
    "native_startup_bootstrap": {"installed_product": PRODUCT},
    "native_script_scope": {"installed_product": PRODUCT},
}
scope.update(
    validate_consent_boundary=admitted("transport", "missing consent boundary"),
    validate_summary=admitted("features", "missing timer"),
    validate_karabiner_summary=admitted("features", "missing Karabiner"),
    require_summary=admitted("features", "missing Script"),
    scripting_state_failures=lambda *args: [],
)
controls = 0


def check(condition):
    global controls
    assert condition
    controls += 1


for scenario in ["clean", "karabiner_config"]:
    # A deferral receipt never excuses a missing startup-file feature proof.
    check(bool(scope["evaluate"](scenario, good)))
    check(bool(scope["evaluate"](scenario, good, defer_native=True)))
    accepted["features"] = True
    complete = {**good, **features}
    # It defers only the consent-free AppleEvent boundary.
    check(scope["evaluate"](scenario, complete, defer_native=True) == [])
    check(bool(scope["evaluate"](scenario, complete)))
    accepted["transport"] = True
    check(scope["evaluate"](scenario, complete) == [])
    accepted.update(features=False, transport=False)
accepted["features"] = True
for update in [
    {"launcher_log": ""},
    {"driver_log": "ready [ERROR] original"},
    {"alive_after_window": False},
    {"quit_seconds": None},
]:
    check(bool(scope["evaluate"]("clean", {**good, **features, **update}, defer_native=True)))
accepted["features"] = False


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


calls = {"launch": 0, "quit": 0, "active": False, "tick": 0, "boundary": [], "features": []}


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


class InertPreference:
    def __init__(self, domain):
        pass

    def enable(self):
        pass

    def restore(self):
        pass


def boundary(sender, pid, executable):
    calls["boundary"].append(pid)
    return {"pid": pid}


def native_factory(*args):
    class Owner:
        def observe(self, feature):
            calls["features"].append(feature)
            raise RuntimeError("PURE_NATIVE_FACTORY_REACHED")

    return Owner()


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
    installed_product=lambda *args: PRODUCT,
    build_consent_sender=lambda output: "inert-sender",
    observe_consent_boundary=boundary,
    AppleScriptPreference=InertPreference,
    NativeStartupBootstrap=native_factory,
    LAUNCHER_LOG_NAME="launcher",
    FALLBACK_BOOT_LOG_NAME="boot",
    STARTUP_TIMEOUT_SECONDS=90,
    ALIVE_WINDOW_SECONDS=15,
    read_launch_qualification=lambda receipt, scenario: data["receipt"],
)
report = scope["run"](InertPath(), InertPath(), "clean", "inert", "explicit-record")
# The deferred run still reaches the required startup-file feature owner.
check(
    report["qualification"] == data["receipt"]
    and report["native_qualified"] is False
    and calls["features"] == ["delayed_timer"]
    and any("PURE_NATIVE_FACTORY_REACHED" in failure for failure in report["failures"])
)
check(calls["launch"] == 2 and calls["quit"] == 1)  # uname port plus original launch port.
check(calls["boundary"] == [42])
calls.update(features=[], boundary=[])
report = scope["run"](InertPath(), InertPath(), "karabiner_config", "inert")
# Script scope runs even after the Karabiner feature refused.
check(calls["features"] == ["karabiner_config", "script_scope"])
check(
    "qualification" not in report
    and any("missing consent boundary" in failure for failure in report["failures"])
)
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
