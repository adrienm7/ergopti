# modules/llm/managed_ollama_cleanup.py
"""Fresh GET-only retirement of one original source-bound managed operation."""

import argparse
import importlib.util
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

DRIVER = Path(__file__).resolve().parents[2]
SHARED = DRIVER.parent / "_shared"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


AUTH = load("ergopti_pending_authority", SHARED / "python/managed_ollama_operation_authority.py")
RUNTIME = load("ergopti_pending_runtime", Path(__file__).with_name("managed_ollama_runtime.py"))
PORTS = load("ergopti_pending_ports", DRIVER / "platform/network/native_ollama_api.py")
RECEIPT = load("ergopti_pending_receipt", SHARED / "python/managed_operation_receipt.py")
POLICY = RUNTIME.POLICY
ADMISSION_PATH = "/api/ergopti-native-http-admission"


class Cancelled(BaseException):
    """Native context cleanup must join before the separate callback receipt."""


def boot_session(timeout):
    if sys.platform != "darwin" or not math.isfinite(timeout) or timeout <= 0:
        raise AUTH.AuthorityRefusal()
    try:
        result = subprocess.run(
            ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=True,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        raise AUTH.AuthorityRefusal() from None
    if len(result.stdout) > 64:
        raise AUTH.AuthorityRefusal()
    value = result.stdout.decode("ascii").strip().lower()
    if re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value) is None:
        raise AUTH.AuthorityRefusal()
    return value


def verify_runtime(authority, deadline):
    contract_bytes, catalogue_bytes, host, contract, asset = RUNTIME.inputs()
    if (
        AUTH.digest(contract_bytes) != authority["contract_sha256"]
        or AUTH.digest(catalogue_bytes) != authority["catalogue_sha256"]
        or any(
            authority["session"][name] != asset[field]
            for name, field in (
                ("source_commit", "source_commit"),
                ("binary_sha256", "binary_sha256"),
                ("asset_sha256", "sha256"),
            )
        )
    ):
        raise AUTH.AuthorityRefusal()
    alias = authority["source_alias"]
    keywords = (
        {
            "source_alias": alias,
            "source_identity": {
                "device": authority["session"]["device"],
                "inode": authority["session"]["inode"],
            },
        }
        if alias is not None
        else {}
    )
    binary = RUNTIME.native_verify(
        RUNTIME.owned_directory(),
        contract,
        asset,
        POLICY.receipt(contract_bytes, catalogue_bytes, host, asset),
        deadline,
        **keywords,
    )
    actual = binary.stat(follow_symlinks=False)
    if (
        str(binary) != authority["executable"]
        or str(actual.st_dev) != authority["session"]["device"]
        or str(actual.st_ino) != authority["session"]["inode"]
    ):
        raise AUTH.AuthorityRefusal()


def receive(
    value,
    *,
    mode,
    timeout,
    ports=PORTS,
    verify=verify_runtime,
    boot=boot_session,
    now_ns=time.monotonic_ns,
    started_ns=None,
):
    """Read one immutable handoff and send one freshly authenticated GET only."""
    AUTH.exact(
        value,
        {
            "version",
            "nonce",
            "original_nonce",
            "original_worker_status",
            "operation",
            "anchor",
            "receipt_path",
        },
    )
    if (
        type(value["version"]) is not int
        or value["version"] != 1
        or type(value["original_worker_status"]) is not int
        or value["original_worker_status"] != 78
        or AUTH.nonce(value["nonce"]) == AUTH.nonce(value["original_nonce"])
    ):
        raise AUTH.AuthorityRefusal()
    AUTH.hexadecimal(value["operation"], 32)
    if (
        mode not in ("original-window", "explicit-cleanup")
        or type(timeout) not in (float, int)
        or not math.isfinite(timeout)
        or timeout <= 0
    ):
        raise AUTH.AuthorityRefusal()
    proof = {
        "version": 1,
        "nonce": value["nonce"],
        "original_nonce": value["original_nonce"],
        "original_worker_status": 78,
        "operation": value["operation"],
        "authority_sha256": "",
        "window_sha256": "",
        "state": "pending",
        "worker_status": 78,
        "request_reaped": True,
        "daemon_operation_retired": False,
        "source_admitted": False,
        "listener_bound": False,
    }
    store = None
    try:
        store = AUTH.ReadOperation(
            value["anchor"],
            value["original_nonce"],
            value["operation"],
            POLICY.private_session,
            ports.listener,
        )
        proof["authority_sha256"] = store.handoff["authority"]["sha256"]
        proof["window_sha256"] = store.handoff["window"]["sha256"]
        authority, clock = store.value, store.clock
        current = now_ns()
        if current < AUTH.decimal(clock["started_monotonic_ns"]):
            raise AUTH.AuthorityRefusal()
        if mode == "original-window":
            deadline_ns = AUTH.decimal(clock["deadline_monotonic_ns"])
        else:
            budget_ms = int(timeout * 1000)
            if timeout * 1000 != budget_ms or budget_ms != authority["policy"]["retirement_ms"]:
                raise AUTH.AuthorityRefusal()
            start = current if started_ns is None else started_ns
            if type(start) is not int or start > current:
                raise AUTH.AuthorityRefusal()
            deadline_ns = start + budget_ms * 1_000_000

        def remaining():
            left = (deadline_ns - now_ns()) / 1_000_000_000
            if left <= 0:
                raise AUTH.AuthorityRefusal()
            return left

        if boot(remaining()) != clock["boot_session"]:
            raise AUTH.AuthorityRefusal()
        verify(authority, deadline_ns / 1_000_000_000)
        store.fence()
        headers, challenge = POLICY.authenticated_headers(
            authority["session"], "GET", ADMISSION_PATH, b"", authority["operation"]
        )
        arguments = [
            authority["executable"],
            authority["session"]["device"],
            authority["session"]["inode"],
            int(authority["session"]["port"]),
            authority["listener"],
            "GET",
            ADMISSION_PATH,
            headers,
            "",
            remaining(),
            authority["policy"]["idle_ms"] / 1000,
        ]
        alias = authority["source_alias"]
        response = ports.open_request(
            *arguments, **({"source_alias": alias} if alias is not None else {})
        )
        proof["source_admitted"] = True
        with response:
            if response.status != 200:
                raise AUTH.AuthorityRefusal()
            payload = bytearray()
            while chunk := response.read():
                payload.extend(chunk)
                if len(payload) > authority["policy"]["maximum_bytes"]:
                    raise AUTH.AuthorityRefusal()
            observed = response.listener
            if observed != authority["listener"]:
                raise AUTH.AuthorityRefusal()
            receipt = POLICY.authenticated_receipt(
                authority["session"],
                response.headers,
                bytes(payload),
                challenge,
                observed,
                authority["operation"],
            )
        # The native listener property already requires exact C + EOF + reap0;
        # context exit must also succeed before an ACK can authorize this proof.
        proof["listener_bound"] = True
        store.fence()
        remaining()
        if receipt["operation_state"] != "retired":
            return proof
        proof["daemon_operation_retired"] = True
        # The original task owner must first receive this immutable proof and
        # actual child callback, then close its exact handoff files in phases.
        # Never consume authenticated authority before that owner can retry a
        # partial filesystem closure without another network request.
        proof["state"], proof["worker_status"] = "retired", 0
    except Cancelled:
        proof["worker_status"] = 130
    except Exception:
        pass
    finally:
        if store is not None:
            store.close()
    return proof


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("original-window", "explicit-cleanup"), required=True)
    parser.add_argument("--timeout", type=float, required=True)
    options = parser.parse_args()
    if not math.isfinite(options.timeout) or options.timeout <= 0:
        return 64
    started_ns = time.monotonic_ns()
    deadline = started_ns / 1_000_000_000 + options.timeout

    def cancel(signum, frame):
        raise Cancelled()

    for kind in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(kind, cancel)
    try:
        # Import the actual bounded original input reader; cleanup parsing uses
        # its own exact schema, never the original pull JSON decoder.
        data = bytearray()
        import select

        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([sys.stdin.fileno()], [], [], remaining)[0]:
                return 78
            chunk = os.read(sys.stdin.fileno(), 4096)
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > 65536:
                return 78
        value = AUTH.document(bytes(data))
        AUTH.exact(
            value,
            {
                "version",
                "nonce",
                "original_nonce",
                "original_worker_status",
                "operation",
                "anchor",
                "receipt_path",
            },
        )
        with RECEIPT.ReservedReceipt(value["receipt_path"]) as receipt:
            proof = receive(
                value, mode=options.mode, timeout=options.timeout, started_ns=started_ns
            )
            receipt.publish(proof)
            return proof["worker_status"]
    except Cancelled:
        return 130
    except Exception:
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
