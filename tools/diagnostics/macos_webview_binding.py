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


def validate(result, pid, version, nonce, source_revision):
    """Require measured native facts and exact identities, including strict boolean types."""
    require(type(result) is dict, "Native binding receipt is not an object")
    require(result.get("status") == "ok", "Native binding failed: " + str(result.get("error")))
    expected = {
        "schema_version": 1,
        "contract": "native.webview-binding",
        "nonce": nonce,
        "pid": pid,
        "version": version,
        "source_revision": source_revision,
        "runtime": "native Hammerspoon",
        "ucc_userdata_gc": "unmeasured; controllers deliberately retained",
        "features": {
            "visible_wrapper_delete": {
                "visible_before": True,
                "delete_on_close": True,
                "exact_close_count": 1,
                "userdata_consumed": True,
                "runloop_continued": True,
            },
            "callback_release": {
                "held_before_detach": True,
                "collected_after_detach": True,
                "detach_acknowledged": True,
            },
            "message_identity": {
                "rebound_b_callback": True,
                "initial_a_exact": True,
                "current_b_exact": True,
                "stale_a_rejected": True,
                "current_b_accepted": True,
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

    def exact(actual, wanted):
        if type(actual) is not type(wanted):
            return False
        if type(wanted) is dict:
            return actual.keys() == wanted.keys() and all(
                exact(actual[key], value) for key, value in wanted.items()
            )
        return actual == wanted

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
            validate(result, group.process.pid, version, nonce, source_revision)
            unchanged()
            # A result written immediately before a native exception is not
            # success. Keep the reserved child alive over another runloop interval.
            time.sleep(0.5)
            require(group.observe_exit() is None, "Native binding child exited after its receipt")
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


def qualify(repo, executable, scratch, output, version, unchanged, observe_owned, native):
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
        owner.exclusive_receipt(destination / "supervisor.json", receipt)
    return receipt
