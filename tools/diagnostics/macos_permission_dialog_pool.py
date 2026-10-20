# tools/diagnostics/macos_permission_dialog_pool.py
"""Qualify the real PermissionDialog using an explicit private source-pinned observer."""

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

CONTRACT = "native.permission-dialog-controller-pool"
OBSERVATION = "private source-pinned observer; read-only Lua upvalue inspection"
GC_SCOPE = "unmeasured; actual controller deliberately retained"
INPUT_SCOPE = "not attempted; no physical input, synthetic key or AppleEvent"
BUSINESS_SCOPE = "open_settings callback recorded; no System Settings opened or permission granted"
IDENTITY_SCOPE = "private read-only dispatch stack; raw native name and exact webView observed"
WEAK_SCOPE = "per-window lease receiver, settings callback and sentinel; pooled dispatcher retained"
DEPENDENCIES = (
    "static/ergopti_plus/macos/ui/permission_dialog/init.lua",
    "static/ergopti_plus/macos/ui/webview_controller_pool.lua",
    "static/ergopti_plus/macos/ui/ui_builder.lua",
    "static/ergopti_plus/macos/ui/webview_close_owner.lua",
    "static/ergopti_plus/macos/adapters/timer_scheduler.lua",
    "static/ergopti_plus/macos/infra/deferred_work.lua",
    "static/ergopti_plus/macos/infra/i18n.lua",
    "static/ergopti_plus/macos/adapters/webview_result.lua",
)


def validate(result, pid, version, nonce, source_revision, architecture, source_digest):
    """Require all native observations and retain the private-observer qualification."""
    require(type(result) is dict, "PermissionDialog receipt is not an object")
    require(
        result.get("status") == "ok",
        "PermissionDialog observation failed: " + str(result.get("errors")),
    )
    fixed = {
        "schema_version": 1,
        "contract": CONTRACT,
        "observation": OBSERVATION,
        "native_identity": IDENTITY_SCOPE,
        "weak_scope": WEAK_SCOPE,
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
        "settings_callbacks_collected": True,
        "a_retired_before_b_open": True,
        "same_ucc_exact": True,
        "distinct_views": True,
        "a_settings_count_unchanged": True,
    }
    require(
        result.keys() == fixed.keys() | {"product_timer_baseline", "product_timer_final", "a", "b"},
        "PermissionDialog receipt schema differs",
    )
    for key, value in fixed.items():
        require(
            exact(result[key], value),
            "PermissionDialog native identity or measurement differs: " + key,
        )
    require(architecture in ("arm64", "x86_64"), "PermissionDialog architecture unsupported")
    baseline = result["product_timer_baseline"]
    require(
        type(baseline) is int and baseline >= 0,
        "PermissionDialog timer baseline missing",
    )
    require(
        type(result["product_timer_final"]) is int and result["product_timer_final"] == baseline,
        "PermissionDialog product timer cleanup debt remains",
    )
    wanted = {
        "host_pid": pid,
        "visible_before": True,
        "native_policy_observed": True,
        "retained_before": True,
        "business_settings": 1,
        "javascript_completed": True,
        "ax_close_ack": True,
        "userdata_consumed": True,
        "receiver_collected": True,
        "callback_collected": True,
        "sentinel_collected": True,
        "owner_closed_once": True,
        "product_timer_retired": True,
    }
    for name in ("a", "b"):
        case = result[name]
        require(
            type(case) is dict and case.keys() == wanted.keys() | {"window_id", "native_message"},
            "PermissionDialog case schema differs: " + name,
        )
        require(
            type(case["window_id"]) is int and case["window_id"] > 0,
            "PermissionDialog native window identity missing",
        )
        for key, value in wanted.items():
            require(
                exact(case[key], value),
                "PermissionDialog case observation differs: " + name + "." + key,
            )
        require(
            exact(
                case["native_message"],
                {
                    "name": "permission_dialog_bridge",
                    "webview_type": "userdata",
                    "webview_exact": True,
                    "dispatcher_exact": True,
                    "message_parameter_observed": True,
                },
            ),
            "PermissionDialog actual native message observation differs: " + name,
        )


def source_identity(repo):
    """Hash the concrete owners; the parent additionally freezes the complete driver/assets."""
    sources = {}
    for relative in DEPENDENCIES:
        path = repo / relative
        require(
            path.is_file() and not path.is_symlink(),
            "PermissionDialog source unavailable: " + relative,
        )
        sources[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    encoded = json.dumps(sources, sort_keys=True, separators=(",", ":")).encode()
    return sources, hashlib.sha256(encoded).hexdigest()


def check_logs(output):
    """Reject actual native binding failures and retain every diagnostic byte."""
    for name in ("launch.stdout", "launch.stderr", "console.txt"):
        path = output / name
        require(
            path.is_file() and not path.is_symlink(),
            "PermissionDialog native log missing: " + name,
        )
        require(
            path.stat().st_size <= 1024 * 1024,
            "PermissionDialog native log exceeds its bound",
        )
        text = path.read_text(encoding="utf-8")
        require(
            re.search(
                r"\b(?:error|exception|ERRRUN)\b|NOREF/REFNIL|C stack overflow|\bNS\w*Exception\b|assertion failure",
                text,
                re.I,
            )
            is None,
            "PermissionDialog native runtime failure in " + name,
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
        require(
            group.observe_exit() is None,
            "PermissionDialog native owner exited before observation",
        )
        path = output / "result.json"
        if path.exists():
            require(
                not path.is_symlink() and path.stat().st_size <= 32768,
                "PermissionDialog result redirected or oversized",
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
            require(
                group.observe_exit() is None,
                "PermissionDialog native owner exited after receipt",
            )
            require(
                not path.is_symlink() and path.read_bytes() == captured,
                "PermissionDialog result changed after observation",
            )
            check_logs(output)
            unchanged()
            return {
                "native_execution": "executed",
                "native_process_observed": True,
                "result": result,
            }
        require(
            time.monotonic() < deadline,
            "PermissionDialog native observation exceeded its deadline",
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
        "PermissionDialog native owner retirement incomplete",
    )
    require(
        receipt.get("status") == "ok"
        and receipt.get("native_execution") == "executed"
        and receipt.get("native_process_observed") is True
        and receipt.get("operation_error") is None
        and receipt.get("cleanup_errors") == [],
        "PermissionDialog observation or cleanup incomplete",
    )
    return retired["worker_pid"]


def qualify(repo, executable, scratch, output, version, unchanged, observe_owned, native):
    """Use the existing disposable profile/exact process-group supervisor without a new workflow."""
    source_revision = revision(repo)
    architecture = platform.machine()
    require(
        architecture in ("arm64", "x86_64"),
        "PermissionDialog native host architecture unavailable",
    )
    sources, source_digest = source_identity(repo)
    work, destination = (
        scratch / "permission-dialog-pool",
        output / "permission-dialog-pool",
    )
    work.mkdir(mode=0o700)
    destination.mkdir(mode=0o700)
    module = work / "macos_permission_dialog_pool.lua"
    shutil.copyfile(Path(__file__).with_suffix(".lua"), module)
    observer = work / "macos_permission_dialog_pool_observer.lua"
    shutil.copyfile(Path(__file__).with_name(observer.name), observer)
    nonce = secrets.token_hex(16)
    context = work / "permission-dialog-config.json"
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
    startup = work / "permission-start.lua"
    startup.write_text(
        'local directory=assert(debug.getinfo(1,"S").source:match("^@(.+)/[^/]+$"))\n'
        'local json=require("hs.json")\n'
        'local config=assert(json.read(directory.."/permission-dialog-config.json"))\n'
        "local output=assert(config.output_dir)\n"
        'dofile(directory.."/macos_permission_dialog_pool.lua").run(config,function(result,evaluations)\n'
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
            "PermissionDialog production source changed",
        )
        require(
            all(
                not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest() == digest
                for path, digest in payload.items()
            ),
            "PermissionDialog diagnostic payload changed",
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
            receipt.get("result"),
            pid,
            version,
            nonce,
            source_revision,
            architecture,
            source_digest,
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
    require(receipt.get("status") == "ok", "PermissionDialog final native logs refused")
    return receipt
