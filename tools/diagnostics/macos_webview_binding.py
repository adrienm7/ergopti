# tools/diagnostics/macos_webview_binding.py
"""Separate native WebView/UCC binding receipt; never qualifies UCC userdata GC."""

import hashlib
import json
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import time

import macos_owned_process as owner


def require(condition, message):
    """Reject absent native evidence without a skip or modeled-success fallback."""
    if not condition:
        raise ValueError(message)


def revision(repo):
    """Capture the exact source revision independently of caller-provided receipt fields."""
    result = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        timeout=10,
        check=True,
    )
    value = result.stdout.strip()
    require(re.fullmatch(r"[0-9a-f]{40}", value) is not None, "Source revision is not exact")
    return value


def native_errors(output):
    """Retain native runtime failures even when Cocoa only writes them to stderr."""
    failures = []
    for name in ("launch.stdout", "launch.stderr"):
        path = output / name
        require(path.is_file() and not path.is_symlink(), "Native runtime log unavailable: " + name)
        require(path.stat().st_size <= 1024 * 1024, "Native runtime log exceeds its bound: " + name)
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if re.search(
                r"\b(?:error|exception|ERRRUN|assertion failure)\b|C stack overflow|NOREF/REFNIL",
                line,
                re.I,
            ):
                failures.append({"source": name, "line": number, "text": line})
    return failures


def require_clean_native_logs(output):
    """Refuse errors before and after receipt delivery, including after process retirement."""
    failures = native_errors(output)
    require(not failures, "Native runtime error: " + str(failures))


def exact(actual, wanted):
    """Compare native primitive receipts without Python bool/integer coercion."""
    if type(actual) is not type(wanted):
        return False
    if type(wanted) is dict:
        return actual.keys() == wanted.keys() and all(
            exact(actual[key], value) for key, value in wanted.items()
        )
    return actual == wanted


def validate(result, pid, version, nonce, source_revision):
    """Require measured native facts and exact identities, including strict boolean types."""
    require(type(result) is dict, "Native binding receipt is not an object")
    require(result.get("status") == "ok", "Native binding failed: " + str(result.get("error")))
    identity = result.get("window_identity")
    require(
        type(identity) is dict
        and identity.keys() == {"explicit", "user", "host_pid"}
        and type(identity["explicit"]) is int
        and identity["explicit"] > 0
        and type(identity["user"]) is int
        and identity["user"] > 0
        and identity["explicit"] != identity["user"]
        and type(identity["host_pid"]) is int
        and identity["host_pid"] == pid,
        "Native binding window identities differ",
    )
    expected = {
        "schema_version": 3,
        "contract": "native.webview-binding",
        "nonce": nonce,
        "pid": pid,
        "version": version,
        "source_revision": source_revision,
        "runtime": "native Hammerspoon",
        "scope": "production ui.ui_builder.show_webview; native WebView/UCC bindings",
        "window_identity": identity,
        "ucc_userdata_gc": "unmeasured; controllers deliberately retained",
        "features": {
            "explicit_product_close": {
                "visible_before": True,
                "native_auto_delete_disabled": True,
                "exact_close_count": 1,
                "userdata_consumed": True,
                "runloop_continued": True,
                "sibling_survived": True,
            },
            "user_product_close": {
                "visible_before": True,
                "native_auto_delete_disabled": True,
                "native_close_button_requested": True,
                "exact_close_count": 1,
                "userdata_consumed": True,
            },
            "callback_release": {
                "held_before_detach": True,
                "collected_after_detach": True,
                "detach_acknowledged": True,
            },
            "message_identity": {
                "rebound_b_callback": True,
                "b_after_a_gc_source_exact": True,
                "b_after_a_gc_accepted": True,
                "b_after_a_gc_evaluated": True,
                "initial_a_exact": True,
                "current_b_exact": True,
                "stale_a_rejected": True,
                "current_b_accepted": True,
                "a_close_preserved_b": True,
                "a_closes": 1,
                "b_closes": 1,
            },
        },
        "cleanup": {
            "windows_consumed": True,
            "callbacks_detached": True,
            "timers_stopped": True,
            "console_checked": True,
        },
    }

    require(
        result.keys() == expected.keys() | {"status"}
        and all(exact(result[key], value) for key, value in expected.items()),
        "Native binding receipt identities, measurements or schema differ",
    )


def supervise(group, output, version, nonce, source_revision, unchanged, timeout=60):
    """Observe the reserved native child and a later live-process interval before retirement."""
    deadline = time.monotonic() + timeout
    while True:
        require(group.observe_exit() is None, "Native binding child exited before observation")
        result_path = output / "result.json"
        if result_path.exists():
            require(not result_path.is_symlink(), "Redirected native binding result refused")
            require(result_path.stat().st_size <= 32768, "Native binding result exceeds its bound")
            captured = result_path.read_bytes()
            result = json.loads(captured)
            require_clean_native_logs(output)
            validate(result, group.process.pid, version, nonce, source_revision)
            unchanged()
            # A result written immediately before a native exception is not
            # success. Keep the reserved child alive over another runloop interval.
            time.sleep(0.5)
            require(group.observe_exit() is None, "Native binding child exited after its receipt")
            require_clean_native_logs(output)
            require(
                not result_path.is_symlink() and result_path.read_bytes() == captured,
                "Native binding result changed after observation",
            )
            unchanged()
            return {
                "native_execution": "executed",
                "native_process_observed": True,
                "result": result,
            }
        require(time.monotonic() < deadline, "Native binding observation exceeded its deadline")
        time.sleep(0.05)


def qualify_product(repo, executable, scratch, output, version, unchanged, observe_owned, native):
    """Reuse the canvas runner's exact executable and nonreaping native ownership boundary."""
    source_revision = revision(repo)
    work = scratch / "webview-binding"
    work.mkdir(mode=0o700)
    destination = output / "webview-binding"
    destination.mkdir(mode=0o700)
    source = Path(__file__).with_suffix(".lua")
    config = work / source.name
    shutil.copyfile(source, config)
    nonce = secrets.token_hex(16)
    owner.exclusive_receipt(
        work / "webview-config.json",
        {
            "nonce": nonce,
            "expected_version": version,
            "source_revision": source_revision,
            "production_root": str(repo / "static/ergopti_plus"),
            "webview_result_path": str(
                repo / "static/ergopti_plus/macos/adapters/webview_result.lua"
            ),
            "output_dir": str(destination.resolve()),
        },
    )
    payload = (config, work / "webview-config.json")
    before = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in payload}

    def frozen():
        unchanged()
        require(revision(repo) == source_revision, "Native binding source revision changed")
        require(
            all(
                not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest() == expected
                for path, expected in before.items()
            ),
            "Native binding payload changed",
        )

    receipt = {}
    try:
        frozen()
        receipt = observe_owned(
            executable,
            config,
            destination,
            lambda group: supervise(group, destination, version, nonce, source_revision, frozen),
            native,
        )
        receipt.update(
            source_revision=source_revision,
            ucc_userdata_gc="unmeasured; controllers deliberately retained",
        )
        require(
            receipt.get("status") == "ok", "Native binding observation or owner retirement failed"
        )
        require_clean_native_logs(destination)
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
            "Native binding owner retirement is incomplete",
        )
        require(
            receipt.get("native_execution") == "executed"
            and receipt.get("native_process_observed") is True
            and receipt.get("operation_error") is None
            and receipt.get("cleanup_errors") == [],
            "Native binding observation is incomplete",
        )
        validate(receipt.get("result"), retired["worker_pid"], version, nonce, source_revision)
        frozen()
    except BaseException as error:
        receipt.update(status="error", qualification_error=str(error) or type(error).__name__)
        raise
    finally:
        receipt.update(
            source_revision=source_revision,
            ucc_userdata_gc="unmeasured; controllers deliberately retained",
        )
        try:
            receipt["native_log_errors"] = native_errors(destination)
            if receipt["native_log_errors"]:
                receipt.update(
                    status="error",
                    log_admission_error="Native runtime error during final collection: "
                    + str(receipt["native_log_errors"]),
                )
        except Exception as error:
            receipt.update(status="error", log_admission_error=str(error))
        owner.exclusive_receipt(destination / "supervisor.json", receipt)
    require(receipt.get("status") == "ok", "Native binding final log admission failed")
    return receipt


def validate_raw(result, pid, version, nonce, source_revision):
    """Admit only the isolated public operation, never a product success receipt."""
    expected = {
        "schema_version": 1,
        "contract": "native.webview-raw-delete",
        "status": "observed",
        "nonce": nonce,
        "source_revision": source_revision,
        "pid": pid,
        "version": version,
        "runtime": "native Hammerspoon",
        "features": {
            "visible_before": True,
            "native_opt_in": True,
            "close_callback_count": 1,
            "userdata_consumed": True,
            "runloop_continued": True,
        },
        "cleanup": {"windows_consumed": True, "timers_stopped": True},
        "ucc_userdata_gc": "unmeasured; no controller constructed",
    }
    require(exact(result, expected), "Raw native control identities, observation or schema differ")


def known_raw_failure(errors, pid):
    """Recognize only the two pinned stderr lines observed in CI39171054196."""
    expected = {
        "hs.webview:error invoking _gc for deleteOnClose:C stack overflow",
        "logForLuaSkin: error, state ERRRUN: C stack overflow",
    }
    bodies = []
    for entry in errors:
        match = re.fullmatch(
            r".+ Hammerspoon\[" + str(pid) + r":\d+\] BREADCRUMB: (.+)", entry["text"]
        )
        require(
            entry["source"] == "launch.stderr" and match is not None,
            "Raw native control reported a foreign or unknown failure: " + str(errors),
        )
        bodies.append(match.group(1))
    require(
        len(bodies) == 2 and set(bodies) == expected,
        "Raw native control did not reproduce only the pinned failure: " + str(errors),
    )


def supervise_raw(group, output, version, nonce, source_revision, unchanged, timeout=60):
    """Retain the known raw failure in its own process before any product observation."""
    deadline = time.monotonic() + timeout
    while True:
        require(group.observe_exit() is None, "Raw native child exited before observation")
        path = output / "result.json"
        if path.exists():
            require(
                not path.is_symlink() and path.stat().st_size <= 32768, "Raw native result refused"
            )
            captured = path.read_bytes()
            result = json.loads(captured)
            validate_raw(result, group.process.pid, version, nonce, source_revision)
            known_raw_failure(native_errors(output), group.process.pid)
            unchanged()
            time.sleep(0.5)
            require(group.observe_exit() is None, "Raw native child exited after its receipt")
            require(
                not path.is_symlink() and path.read_bytes() == captured,
                "Raw native receipt changed",
            )
            known_raw_failure(native_errors(output), group.process.pid)
            unchanged()
            return {
                "native_execution": "executed",
                "native_process_observed": True,
                "result": result,
            }
        require(time.monotonic() < deadline, "Raw native observation exceeded its deadline")
        time.sleep(0.05)


def qualify_raw(repo, executable, scratch, output, version, unchanged, observe_owned, native):
    """Expected negative has its own source, nonce, PID, logs and retirement receipt."""
    source_revision = revision(repo)
    work, destination = scratch / "webview-raw-delete", output / "webview-raw-delete"
    work.mkdir(mode=0o700)
    destination.mkdir(mode=0o700)
    source = Path(__file__).with_name("macos_webview_raw_delete.lua")
    config = work / source.name
    shutil.copyfile(source, config)
    require(config.read_bytes() == source.read_bytes(), "Raw native source copy differs")
    nonce = secrets.token_hex(16)
    settings = work / "webview-config.json"
    owner.exclusive_receipt(
        settings,
        {
            "nonce": nonce,
            "expected_version": version,
            "source_revision": source_revision,
            "output_dir": str(destination.resolve()),
        },
    )
    before = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in (config, settings)}

    def frozen():
        unchanged()
        require(revision(repo) == source_revision, "Raw native source revision changed")
        require(
            all(
                not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest() == value
                for path, value in before.items()
            ),
            "Raw native payload changed",
        )

    receipt = {}
    try:
        frozen()
        receipt = observe_owned(
            executable,
            config,
            destination,
            lambda group: supervise_raw(
                group, destination, version, nonce, source_revision, frozen
            ),
            native,
        )
        require(
            receipt.get("status") == "ok"
            and receipt.get("operation_error") is None
            and receipt.get("cleanup_errors") == [],
            "Raw native observation or retirement failed",
        )
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
            "Raw native retirement is incomplete",
        )
        require(
            receipt.get("native_execution") == "executed"
            and receipt.get("native_process_observed") is True,
            "Raw native observation is incomplete",
        )
        validate_raw(receipt.get("result"), retired["worker_pid"], version, nonce, source_revision)
        known_raw_failure(native_errors(destination), retired["worker_pid"])
        frozen()
        receipt.update(
            status="expected_native_failure",
            expected_failure="pinned deleteOnClose C stack overflow",
        )
    except BaseException as error:
        receipt.update(status="error", qualification_error=str(error) or type(error).__name__)
        raise
    finally:
        receipt.update(
            source_revision=source_revision, ucc_userdata_gc="unmeasured; no controller constructed"
        )
        try:
            receipt["native_log_errors"] = native_errors(destination)
            known_raw_failure(
                receipt["native_log_errors"], receipt.get("native_owner", {}).get("worker_pid")
            )
        except Exception as error:
            receipt.update(status="error", log_admission_error=str(error))
        owner.exclusive_receipt(destination / "supervisor.json", receipt)
    require(
        receipt.get("status") == "expected_native_failure", "Raw native final classification failed"
    )
    return receipt


def qualify(repo, executable, scratch, output, version, unchanged, observe_owned, native):
    """Keep the expected-negative control separate from mandatory clean product evidence."""
    raw = qualify_raw(repo, executable, scratch, output, version, unchanged, observe_owned, native)
    product = qualify_product(
        repo, executable, scratch, output, version, unchanged, observe_owned, native
    )
    product["raw_negative_control"] = raw
    return product
