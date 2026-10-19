# tools/diagnostics/macos_action_picker_pool.py
"""Qualify the real ActionPicker using an explicit private source-pinned observer."""

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

CONTRACT = "native.action-picker-controller-pool"
OBSERVATION = "private source-pinned observer; read-only Lua upvalue inspection"
GC_SCOPE = "unmeasured; actual controller deliberately retained"
INPUT_SCOPE = "not attempted; no physical input, synthetic key or AppleEvent"
BUSINESS_SCOPE = "program and automation discovery controlled; no user assignment executed"
DEPENDENCIES = (
    "static/ergopti_plus/macos/ui/action_picker/init.lua",
    "static/ergopti_plus/macos/ui/webview_controller_pool.lua",
    "static/ergopti_plus/macos/ui/ui_builder.lua",
    "static/ergopti_plus/macos/ui/webview_close_owner.lua",
    "static/ergopti_plus/macos/adapters/timer_scheduler.lua",
    "static/ergopti_plus/macos/infra/deferred_work.lua",
    "static/ergopti_plus/_shared/lua/program_provider_picker.lua",
    "static/ergopti_plus/_shared/ui/action_picker/index.html",
    "static/ergopti_plus/_shared/ui/action_picker/script.js",
    "static/ergopti_plus/_shared/ui/action_picker/style.css",
    "static/ergopti_plus/_shared/ui/host_bridge.js",
)


def validate(result, pid, version, nonce, source_revision, architecture, source_digest):
    """Require all native observations and retain the private-observer qualification."""
    require(type(result) is dict, "ActionPicker receipt is not an object")
    require(
        result.get("status") == "ok",
        "ActionPicker observation failed: " + str(result.get("errors")),
    )
    fixed = {
        "schema_version": 1,
        "contract": CONTRACT,
        "observation": OBSERVATION,
        "nonce": nonce,
        "source_revision": source_revision,
        "source_manifest_digest": source_digest,
        "pid": pid,
        "version": version,
        "arch": architecture,
        "status": "ok",
        "errors": [],
        "native_input": INPUT_SCOPE,
        "business_scope": BUSINESS_SCOPE,
        "ucc_userdata_gc": GC_SCOPE,
        "native_apis_unmodified": True,
        "business_ports_restored": True,
        "a_retired_before_b_open": True,
        "same_ucc_exact": True,
        "distinct_views": True,
        "a_confirmation_count_unchanged": True,
    }
    require(
        result.keys() == fixed.keys() | {"product_timer_baseline", "product_timer_final", "a", "b"},
        "ActionPicker receipt schema differs",
    )
    for key, value in fixed.items():
        require(
            exact(result[key], value), "ActionPicker native identity or measurement differs: " + key
        )
    require(architecture in ("arm64", "x86_64"), "ActionPicker architecture unsupported")
    baseline = result["product_timer_baseline"]
    require(type(baseline) is int and baseline >= 0, "ActionPicker timer baseline missing")
    require(
        type(result["product_timer_final"]) is int and result["product_timer_final"] == baseline,
        "ActionPicker product timer cleanup debt remains",
    )
    wanted = {
        "host_pid": pid,
        "visible_before": True,
        "native_policy_observed": True,
        "retained_before": True,
        "business_confirmations": 1,
        "expected_id_received": True,
        "javascript_completed": True,
        "ax_close_ack": True,
        "userdata_consumed": True,
        "callback_collected": True,
        "sentinel_collected": True,
        "product_timer_retired": True,
    }
    for name in ("a", "b"):
        case = result[name]
        require(
            type(case) is dict and case.keys() == wanted.keys() | {"window_id"},
            "ActionPicker case schema differs: " + name,
        )
        require(
            type(case["window_id"]) is int and case["window_id"] > 0,
            "ActionPicker native window identity missing",
        )
        for key, value in wanted.items():
            require(
                exact(case[key], value),
                "ActionPicker case observation differs: " + name + "." + key,
            )


def source_identity(repo):
    """Hash the concrete owners; the parent additionally freezes the complete driver/assets."""
    sources = {}
    for relative in DEPENDENCIES:
        path = repo / relative
        require(
            path.is_file() and not path.is_symlink(), "ActionPicker source unavailable: " + relative
        )
        sources[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    encoded = json.dumps(sources, sort_keys=True, separators=(",", ":")).encode()
    return sources, hashlib.sha256(encoded).hexdigest()


def check_logs(output):
    """Reject actual native binding failures and retain every diagnostic byte."""
    for name in ("launch.stdout", "launch.stderr", "console.txt"):
        path = output / name
        require(
            path.is_file() and not path.is_symlink(), "ActionPicker native log missing: " + name
        )
        require(path.stat().st_size <= 1024 * 1024, "ActionPicker native log exceeds its bound")
        text = path.read_text(encoding="utf-8")
        require(
            re.search(
                r"\b(?:error|exception|ERRRUN)\b|NOREF/REFNIL|C stack overflow|\bNS\w*Exception\b|assertion failure",
                text,
                re.I,
            )
            is None,
            "ActionPicker native runtime failure in " + name,
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
        require(group.observe_exit() is None, "ActionPicker native owner exited before observation")
        path = output / "result.json"
        if path.exists():
            require(
                not path.is_symlink() and path.stat().st_size <= 32768,
                "ActionPicker result redirected or oversized",
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
            require(group.observe_exit() is None, "ActionPicker native owner exited after receipt")
            require(
                not path.is_symlink() and path.read_bytes() == captured,
                "ActionPicker result changed after observation",
            )
            check_logs(output)
            unchanged()
            return {
                "native_execution": "executed",
                "native_process_observed": True,
                "result": result,
            }
        require(
            time.monotonic() < deadline, "ActionPicker native observation exceeded its deadline"
        )
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
        "ActionPicker native owner retirement incomplete",
    )
    require(
        receipt.get("status") == "ok"
        and receipt.get("native_execution") == "executed"
        and receipt.get("native_process_observed") is True
        and receipt.get("operation_error") is None
        and receipt.get("cleanup_errors") == [],
        "ActionPicker observation or cleanup incomplete",
    )
    return retired["worker_pid"]


def qualify(repo, executable, scratch, output, version, unchanged, observe_owned, native):
    """Use the existing disposable profile/exact process-group supervisor without a new workflow."""
    source_revision = revision(repo)
    architecture = platform.machine()
    require(
        architecture in ("arm64", "x86_64"), "ActionPicker native host architecture unavailable"
    )
    sources, source_digest = source_identity(repo)
    work, destination = scratch / "action-picker-pool", output / "action-picker-pool"
    work.mkdir(mode=0o700)
    destination.mkdir(mode=0o700)
    module = work / "macos_action_picker_pool.lua"
    shutil.copyfile(Path(__file__).with_suffix(".lua"), module)
    observer = work / "macos_action_picker_pool_observer.lua"
    shutil.copyfile(Path(__file__).with_name(observer.name), observer)
    nonce = secrets.token_hex(16)
    context = work / "action-picker-config.json"
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
    startup = work / "picker-start.lua"
    startup.write_text(
        'local directory=assert(debug.getinfo(1,"S").source:match("^@(.+)/[^/]+$"))\n'
        'local json=require("hs.json")\n'
        'local config=assert(json.read(directory.."/action-picker-config.json"))\n'
        "local output=assert(config.output_dir)\n"
        'dofile(directory.."/macos_action_picker_pool.lua").run(config,function(result,evaluations)\n'
        ' local file=assert(io.open(output.."/console.txt","wb"))\n'
        " assert(file:write(hs.console.getConsole())); assert(file:close())\n"
        ' assert(json.write(evaluations,output.."/evaluations.json",true,true))\n'
        ' assert(json.write(result,output.."/result.json.tmp",true,true))\n'
        ' assert(os.rename(output.."/result.json.tmp",output.."/result.json"))\n'
        "end)\n",
        encoding="utf-8",
    )
    payload = {
        path: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in (module, observer, context, startup)
    }

    def frozen():
        unchanged()
        require(
            revision(repo) == source_revision and source_identity(repo) == (sources, source_digest),
            "ActionPicker production source changed",
        )
        require(
            all(
                not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest() == digest
                for path, digest in payload.items()
            ),
            "ActionPicker diagnostic payload changed",
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
            observation=OBSERVATION,
        )
        try:
            check_logs(destination)
        except Exception as error:
            receipt.update(status="error", final_log_error=str(error))
        owner.exclusive_receipt(destination / "supervisor.json", receipt)
    require(receipt.get("status") == "ok", "ActionPicker final native logs refused")
    return receipt
