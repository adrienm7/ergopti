# modules/llm/managed_ollama_pull.py
"""Receive one source-qualified daemon pull without releasing unknown work."""

import argparse
import importlib.util
import math
import os
from pathlib import Path
import re
import select
import signal
import sys
import time

DRIVER = Path(__file__).resolve().parents[2]
SHARED = DRIVER.parent / "_shared"


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


RUNTIME = load("ergopti_pull_native_runtime", Path(__file__).with_name("managed_ollama_runtime.py"))
PULL = load("ergopti_pull_owner", SHARED / "python/managed_ollama_pull.py")
SESSIONS = load("ergopti_pull_sessions", SHARED / "python/managed_ollama_sessions.py")
RECEIPT = load("ergopti_pull_private_receipt", SHARED / "python/managed_operation_receipt.py")
PORTS = load("ergopti_pull_native_ports", DRIVER / "platform/network/native_ollama_api.py")
AUTH = load("ergopti_pull_authority", SHARED / "python/managed_ollama_operation_authority.py")
CLEANUP = load("ergopti_pull_cleanup", Path(__file__).with_name("managed_ollama_cleanup.py"))
POLICY = PULL.POLICY


class Cancelled(BaseException):
    """Owner cancellation; native ports join before this reaches their caller."""


class Cancellation:
    def __init__(self):
        self.requested = False
        self.retiring = False

    def signal(self, signum, frame):
        self.requested = True
        # Repeated cancellation cannot abandon a retirement request which is
        # already physically closing native helpers under its original clock.
        if not self.retiring:
            raise Cancelled()


def request(deadline):
    data = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise POLICY.RuntimeRefusal("deadline")
        if not select.select([sys.stdin.fileno()], [], [], remaining)[0]:
            raise POLICY.RuntimeRefusal("deadline")
        chunk = os.read(sys.stdin.fileno(), 4096)
        if not chunk:
            break
        data.extend(chunk)
        if len(data) > 65536:
            raise POLICY.RuntimeRefusal("protocol")
    value = POLICY.metadata_bytes(bytes(data))
    if (
        set(value) != {"version", "model", "port", "nonce", "receipt_path", "anchor"}
        or type(value["version"]) is not int
        or value["version"] != 2
        or type(value["port"]) is not int
        or not 1024 <= value["port"] <= 65535
        or not isinstance(value["model"], str)
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9./_:-]*", value["model"]) is None
        or not isinstance(value["nonce"], str)
        or re.fullmatch(r"[A-Za-z0-9-]{36}", value["nonce"]) is None
        or not isinstance(value["receipt_path"], str)
        or not Path(value["receipt_path"]).is_absolute()
    ):
        raise POLICY.RuntimeRefusal("protocol")
    return value


def select_owner(value, deadline, idle_timeout, maximum_bytes):
    contract_bytes, catalogue_bytes, host, contract, asset = RUNTIME.inputs()
    binary = RUNTIME.native_verify(
        RUNTIME.owned_directory(),
        contract,
        asset,
        RUNTIME.POLICY.receipt(contract_bytes, catalogue_bytes, host, asset),
        deadline,
    )
    actual = binary.stat(follow_symlinks=False)
    expected = {
        "source_commit": asset["source_commit"],
        "binary_sha256": asset["binary_sha256"],
        "asset_sha256": asset["sha256"],
        "device": str(actual.st_dev),
        "inode": str(actual.st_ino),
    }

    def authenticate(session, remaining):
        owner = PULL.PullOwner(session, str(binary), PORTS, idle_timeout, maximum_bytes)
        try:
            owner.admit(remaining)
        except (POLICY.RuntimeRefusal, PORTS.ENGINE.NativeHTTPError, OSError):
            raise SESSIONS.POLICY.RuntimeRefusal("session") from None
        return owner

    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise POLICY.RuntimeRefusal("deadline")
    owner = SESSIONS.select(
        binary.parent.parent / "ollama-native-sessions",
        value["port"],
        expected,
        authenticate,
        remaining,
    )
    owner.contract_sha256 = AUTH.digest(contract_bytes)
    owner.catalogue_sha256 = AUTH.digest(catalogue_bytes)
    return owner


def execute(
    value,
    *,
    owner_factory,
    idle_timeout,
    maximum_bytes,
    deadline,
    retirement_timeout,
    cancellation,
    emit,
    private_receipt,
    before_submit=None,
    on_retirement_clock=None,
    on_completion=None,
):
    """Own local request closure separately from authenticated daemon retirement."""
    owner = None
    status = 78
    try:
        owner = owner_factory(value, deadline, idle_timeout, maximum_bytes)
        if cancellation.requested:
            raise Cancelled()
        if before_submit is not None:
            before_submit(owner)
        status = 0 if owner.pull(value["model"], emit, timeout=None) else 1
    except Cancelled:
        status = 130
    except Exception:
        status = 78
    finally:
        cancellation.retiring = True
        retired = owner is None or not owner.submitted
        if owner is not None and owner.pending:
            retirement_deadline = time.monotonic() + retirement_timeout
            try:
                if on_retirement_clock is not None:
                    on_retirement_clock(retirement_deadline)
                while True:
                    remaining = retirement_deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    if owner.retirement(remaining):
                        retired = True
                        break
                    time.sleep(min(0.1, max(0, retirement_deadline - time.monotonic())))
            except Exception:
                retired = False
        # A canceled/malformed constructor is physically joined by the native
        # port before returning. It cannot prove an unknown daemon operation.
        local_closed = owner is None or not owner.submitted or owner.request_finished
        if not retired or not local_closed:
            status = 78
        session = owner.session if owner is not None else {}
        proof = {
            "version": 1,
            "nonce": value["nonce"],
            "state": "retired" if retired and local_closed else "pending",
            "worker_status": status,
            "source_admitted": owner is not None and owner.admitted,
            "listener_bound": owner is not None and owner.listener is not None,
            "request_reaped": local_closed,
            "daemon_operation_retired": retired,
            "operation": owner.operation if owner is not None and owner.submitted else "",
            "source_commit": session.get("source_commit", ""),
            "binary_sha256": session.get("binary_sha256", ""),
            "asset_sha256": session.get("asset_sha256", ""),
        }
        if on_completion is not None:
            on_completion(proof)
        private_receipt.publish(proof)
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--admission-timeout", type=float, required=True)
    parser.add_argument("--idle-timeout", type=float, required=True)
    parser.add_argument("--retirement-timeout", type=float, required=True)
    parser.add_argument("--maximum-bytes", type=int, required=True)
    options = parser.parse_args()
    if (
        any(
            not math.isfinite(value) or value <= 0
            for value in (
                options.admission_timeout,
                options.idle_timeout,
                options.retirement_timeout,
            )
        )
        or not 1 <= options.maximum_bytes <= 65536
    ):
        return 64
    cancellation = Cancellation()
    for name in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(name, cancellation.signal)
    deadline = time.monotonic() + options.admission_timeout
    try:
        value = request(deadline)
        with RECEIPT.ReservedReceipt(value["receipt_path"]) as private_receipt:

            def emit(progress):
                # Native error/status strings may include request URLs. UI
                # receives only independent bounded byte progress or a scalar.
                if "completed" in progress and "total" in progress:
                    print(
                        "OLLAMA_PULL_BYTES "
                        + str(progress["completed"])
                        + " "
                        + str(progress["total"]),
                        flush=True,
                    )
                elif progress.get("status") == "success":
                    print("OLLAMA_PULL_COMPLETE", flush=True)

            files = AUTH.OperationFiles(value["anchor"], value["nonce"])
            try:
                policy = {
                    "retirement_ms": math.ceil(options.retirement_timeout * 1000),
                    "idle_ms": math.ceil(options.idle_timeout * 1000),
                    "maximum_bytes": options.maximum_bytes,
                }
                if max(policy["retirement_ms"], policy["idle_ms"]) > (1 << 31) - 1:
                    raise AUTH.AuthorityRefusal()
                result = execute(
                    value,
                    owner_factory=select_owner,
                    idle_timeout=options.idle_timeout,
                    maximum_bytes=options.maximum_bytes,
                    deadline=deadline,
                    retirement_timeout=options.retirement_timeout,
                    cancellation=cancellation,
                    emit=emit,
                    private_receipt=private_receipt,
                    before_submit=lambda owner: files.bind(
                        owner, policy, POLICY.private_session, PORTS.listener
                    ),
                    on_retirement_clock=lambda stop: files.seal_window(stop, CLEANUP.boot_session),
                    on_completion=lambda proof: (
                        files.remove() if proof["state"] == "retired" and not files.sealed else None
                    ),
                )
                return result
            finally:
                files.close()
    except Cancelled:
        return 130
    except Exception:
        print("Managed Ollama pull admission refused.", file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
