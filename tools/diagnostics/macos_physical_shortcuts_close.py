# tools/diagnostics/macos_physical_shortcuts_close.py
"""Qualify the actual PhysicalShortcuts host in a separately reserved native process."""

import hashlib
import json
from pathlib import Path
import platform
import re
import secrets
import shutil
import time

import macos_owned_process as owner
from macos_webview_binding import exact, require, revision

CONTRACT = "native.physical-shortcuts-close"
GC_SCOPE = "unmeasured; actual controllers deliberately retained"
INPUT_SCOPE = "not attempted; no physical capture, eventtap, synthetic key or AppleEvent"
DEPENDENCIES = (
    "static/ergopti_plus/macos/ui/physical_shortcuts/init.lua",
    "static/ergopti_plus/macos/ui/ui_builder.lua",
    "static/ergopti_plus/macos/ui/webview_close_owner.lua",
    "static/ergopti_plus/macos/adapters/timer_scheduler.lua",
    "static/ergopti_plus/macos/infra/deferred_work.lua",
    "static/ergopti_plus/_shared/lua/shortcuts/physical_editor_window.lua",
    "static/ergopti_plus/_shared/lua/shortcuts/physical_editor.lua",
    "static/ergopti_plus/_shared/lua/shortcuts/physical_entries.lua",
)


def validate(result, pid, version, nonce, source_revision, architecture, source_digest):
    """Reject missing native facts, coercions and unknown evidence fields."""
    require(type(result) is dict, "Physical receipt is not an object")
    require(
        result.get("status") == "ok",
        "Physical native observation failed: " + str(result.get("errors")),
    )
    expected = {
        "schema_version",
        "contract",
        "nonce",
        "source_revision",
        "source_manifest_digest",
        "pid",
        "version",
        "arch",
        "status",
        "errors",
        "ucc_userdata_gc",
        "native_input",
        "product_timer_baseline",
        "product_timer_final",
        "ax_close_ack",
        "public_close_initial_return",
        "observers_restored",
        "ax_user_close",
        "public_close",
    }
    require(result.keys() == expected, "Physical receipt schema differs")
    for key, value in {
        "schema_version": 1,
        "contract": CONTRACT,
        "nonce": nonce,
        "source_revision": source_revision,
        "source_manifest_digest": source_digest,
        "pid": pid,
        "version": version,
        "arch": architecture,
        "errors": [],
        "ucc_userdata_gc": GC_SCOPE,
        "native_input": INPUT_SCOPE,
        "ax_close_ack": True,
        "observers_restored": True,
    }.items():
        require(
            exact(result[key], value), "Physical native identity or acknowledgement differs: " + key
        )
    require(architecture in ("arm64", "x86_64"), "Physical native architecture unsupported")
    require(
        type(result["public_close_initial_return"]) is bool, "Public close result was not observed"
    )
    baseline = result["product_timer_baseline"]
    require(type(baseline) is int and baseline >= 0, "Physical timer baseline absent")
    require(
        type(result["product_timer_final"]) is int and result["product_timer_final"] == baseline,
        "Physical native timer cleanup debt remains",
    )
    for name in ("ax_user_close", "public_close"):
        case = result[name]
        fields = {
            "window_id",
            "host_pid",
            "native_delete_requests",
            "notifications",
            "userdata_consumed",
            "visible_before",
            "native_auto_delete_disabled",
            "callback_retained_before",
            "exact_bridge_detach",
            "consumed_before_detach",
            "callback_collected",
            "product_timer_retired",
        }
        require(
            type(case) is dict and case.keys() == fields, "Physical case schema differs: " + name
        )
        require(
            type(case["window_id"]) is int and case["window_id"] > 0,
            "Physical native window ID absent",
        )
        require(exact(case["native_delete_requests"], 1), "Physical native delete count differs")
        require(exact(case["host_pid"], pid), "Physical native window belongs to another process")
        for key in fields - {"window_id", "host_pid", "native_delete_requests", "notifications"}:
            require(case[key] is True, "Physical required observation missing: " + name + "." + key)
        events = case["notifications"]
        require(
            type(events) is list and 1 <= len(events) <= 8,
            "Physical native notifications absent or unbounded",
        )
        for event in events:
            require(
                type(event) is dict
                and event.keys() == {"action", "visible_read", "visible", "userdata_live_before"},
                "Physical native notification schema differs",
            )
            require(
                event["action"] == "closing"
                and event["visible_read"] is True
                and type(event["visible"]) is bool
                and type(event["userdata_live_before"]) is bool,
                "Physical native notification observations unavailable",
            )


def source_identity(repo):
    """Hash the concrete owners; the parent additionally freezes the complete driver/assets."""
    sources = {}
    for relative in DEPENDENCIES:
        path = repo / relative
        require(
            path.is_file() and not path.is_symlink(), "Physical source unavailable: " + relative
        )
        sources[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    encoded = json.dumps(sources, sort_keys=True, separators=(",", ":")).encode()
    return sources, hashlib.sha256(encoded).hexdigest()


def check_logs(output):
    """Reject actual native binding failures and retain every diagnostic byte."""
    for name in ("launch.stdout", "launch.stderr", "console.txt"):
        path = output / name
        require(path.is_file() and not path.is_symlink(), "Physical native log missing: " + name)
        require(path.stat().st_size <= 1024 * 1024, "Physical native log exceeds its bound")
        text = path.read_text(encoding="utf-8")
        require(
            re.search(
                r"\b(?:error|exception|ERRRUN)\b|NOREF/REFNIL|C stack overflow|NS\w*Exception|assertion failure",
                text,
                re.I,
            )
            is None,
            "Physical native runtime failure in " + name,
        )


def supervise(
    group,
    output,
    version,
    nonce,
    source_revision,
    architecture,
    source_digest,
    unchanged,
    timeout=45,
):
    """Require the receipt from the live reserved child, then another live runloop interval."""
    deadline = time.monotonic() + timeout
    while True:
        require(group.observe_exit() is None, "Physical native owner exited before observation")
        path = output / "result.json"
        if path.exists():
            require(
                not path.is_symlink() and path.stat().st_size <= 32768,
                "Physical result redirected or oversized",
            )
            captured = path.read_bytes()
            result = json.loads(captured)
            validate(
                result,
                group.process.pid,
                version,
                nonce,
                source_revision,
                architecture,
                source_digest,
            )
            check_logs(output)
            unchanged()
            time.sleep(0.5)
            require(group.observe_exit() is None, "Physical native owner exited after receipt")
            require(
                not path.is_symlink() and path.read_bytes() == captured,
                "Physical result changed after observation",
            )
            check_logs(output)
            unchanged()
            return {
                "native_execution": "executed",
                "native_process_observed": True,
                "result": result,
            }
        require(time.monotonic() < deadline, "Physical native observation exceeded its deadline")
        time.sleep(0.05)


def validate_retirement(receipt):
    """An accepted receipt cannot erase live native-process or cleanup debt."""
    retired = receipt.get("native_owner")
    require(
        type(retired) is dict
        and retired.get("closed") is True
        and retired.get("reservation_lost") is False
        and retired.get("live_group_members") == []
        and type(retired.get("worker_pid")) is int
        and retired["worker_pid"] > 0
        and type(retired.get("group_id")) is int
        and retired["group_id"] == retired["worker_pid"],
        "Physical native owner retirement incomplete",
    )
    require(
        receipt.get("status") == "ok"
        and receipt.get("native_execution") == "executed"
        and receipt.get("native_process_observed") is True
        and receipt.get("operation_error") is None
        and receipt.get("cleanup_errors") == [],
        "Physical observation or cleanup incomplete",
    )
    return retired["worker_pid"]


def qualify(repo, executable, scratch, output, version, unchanged, observe_owned, native):
    """Use the existing disposable profile/exact process-group supervisor without a new workflow."""
    source_revision = revision(repo)
    architecture = platform.machine()
    require(architecture in ("arm64", "x86_64"), "Physical native host architecture unavailable")
    sources, source_digest = source_identity(repo)
    work, destination = scratch / "physical-shortcuts-close", output / "physical-shortcuts-close"
    work.mkdir(mode=0o700)
    destination.mkdir(mode=0o700)
    module = work / "macos_physical_shortcuts_close.lua"
    shutil.copyfile(Path(__file__).with_suffix(".lua"), module)
    nonce = secrets.token_hex(16)
    context = work / "physical-config.json"
    owner.exclusive_receipt(
        context,
        {
            "production_root": str(repo / "static/ergopti_plus"),
            "expected_version": version,
            "nonce": nonce,
            "source_revision": source_revision,
            "source_manifest_digest": source_digest,
            "output_dir": str(destination),
        },
    )
    startup = work / "physical-start.lua"
    startup.write_text(
        'local directory=assert(debug.getinfo(1,"S").source:match("^@(.+)/[^/]+$"))\n'
        'local json=require("hs.json")\n'
        'local config=assert(json.read(directory.."/physical-config.json"))\n'
        "local output=assert(config.output_dir)\n"
        'dofile(directory.."/macos_physical_shortcuts_close.lua").run(config,function(result)\n'
        ' local file=assert(io.open(output.."/console.txt","wb"))\n'
        " assert(file:write(hs.console.getConsole())); assert(file:close())\n"
        ' assert(json.write(result,output.."/result.json.tmp",true,true))\n'
        ' assert(os.rename(output.."/result.json.tmp",output.."/result.json"))\n'
        "end)\n",
        encoding="utf-8",
    )
    payload = {
        path: hashlib.sha256(path.read_bytes()).hexdigest() for path in (module, context, startup)
    }

    def frozen():
        unchanged()
        require(
            revision(repo) == source_revision and source_identity(repo) == (sources, source_digest),
            "Physical production source changed",
        )
        require(
            all(
                not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest() == digest
                for path, digest in payload.items()
            ),
            "Physical diagnostic payload changed",
        )

    receipt = {}
    try:
        frozen()
        receipt = observe_owned(
            executable,
            startup,
            destination,
            lambda group: supervise(
                group,
                destination,
                version,
                nonce,
                source_revision,
                architecture,
                source_digest,
                frozen,
            ),
            native,
        )
        pid = validate_retirement(receipt)
        validate(
            receipt.get("result"), pid, version, nonce, source_revision, architecture, source_digest
        )
        check_logs(destination)
        frozen()
    except BaseException as error:
        receipt.update(status="error", qualification_error=str(error) or type(error).__name__)
        raise
    finally:
        receipt.update(
            source_revision=source_revision,
            architecture=architecture,
            source_manifest=sources,
            source_manifest_digest=source_digest,
            ucc_userdata_gc=GC_SCOPE,
        )
        try:
            check_logs(destination)
        except Exception as error:
            receipt.update(status="error", final_log_error=str(error))
        owner.exclusive_receipt(destination / "supervisor.json", receipt)
    require(receipt.get("status") == "ok", "Physical final native logs refused")
    return receipt
