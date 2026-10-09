#!/usr/bin/env python3
# tools/diagnostics/program_actions/run_signed_query_probe.py
"""Observe the shipped signed readonly role; never import, invoke or grant consent."""

import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
import types


class Refused(RuntimeError):
    """Closed observer refusal without native stderr, identifiers or names."""


def require(value, reason="native_refused"):
    if value is not True:
        raise Refused(reason)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "invalid_reply")
        result[key] = value
    return result


LIMIT = 90000


class QueryProtocol:
    """Independent bounded protocol oracle; data remains private until both owners retire."""

    def __init__(self):
        self.buffer = bytearray()
        self.bytes = 0
        self.lines = 0
        self.held = False
        self.pending = False
        self.receipt = False
        self.status = None
        self.payload = None

    def feed(self, chunk):
        require(type(chunk) is bytes and self.bytes + len(chunk) <= LIMIT, "reply_limit")
        self.bytes += len(chunk)
        self.buffer.extend(chunk)
        events = []
        while b"\n" in self.buffer:
            line, _, after = self.buffer.partition(b"\n")
            self.buffer = bytearray(after)
            self.lines += 1
            require(self.lines <= 5 and not self.receipt, "invalid_protocol")
            if line == b"Q1 HELD":
                require(not self.held, "invalid_protocol")
                self.held = True
                events.append("held")
            elif line.startswith(b"Q1 DATA "):
                require(self.held and self.payload is None, "invalid_protocol")
                try:
                    self.payload = base64.b64decode(line[8:], validate=True)
                except ValueError:
                    raise Refused("invalid_protocol") from None
                require(0 < len(self.payload) <= 65536, "reply_limit")
            else:
                match = re.fullmatch(rb"Q1 (PENDING|RETIRED|REFUSED) (0|[1-9][0-9]*)", line)
                require(match is not None, "invalid_protocol")
                role, raw = match.groups()
                value = int(raw)
                require(value <= (255 if role == b"RETIRED" else 2147483647), "invalid_protocol")
                if role == b"PENDING":
                    require(not self.pending, "invalid_protocol")
                    self.pending = True
                    events.append("pending")
                else:
                    require(role != b"REFUSED" or not self.held, "invalid_protocol")
                    self.receipt = True
                    self.status = value if role == b"RETIRED" else None
        return events

    def decode(self, operation, nonce, identifier=None):
        """Validate actual native rows using an independent closed-envelope reference."""
        require(
            self.receipt and self.status == 0 and not self.buffer and self.payload is not None,
            "query_refused",
        )
        try:
            packet = json.loads(self.payload.decode("utf-8"), object_pairs_hook=unique)
        except (UnicodeError, ValueError):
            raise Refused("invalid_reply") from None
        require(
            type(packet) is dict
            and type(packet.get("version")) is int
            and packet["version"] == 1
            and type(packet.get("nonce")) is int
            and packet["nonce"] == nonce
            and packet.get("operation") == operation,
            "invalid_reply",
        )
        if packet.get("status") == "refused":
            require(
                set(packet) == {"version", "nonce", "operation", "status", "reason"}
                and packet["reason"]
                in {
                    "automation_permission_refused",
                    "native_refused",
                    "missing",
                    "catalogue_limit",
                },
                "invalid_reply",
            )
            raise Refused(packet["reason"])
        require(
            set(packet) == {"version", "nonce", "operation", "status", "rows", "truncated"}
            and packet["status"] == "observed"
            and type(packet["rows"]) is list
            and len(packet["rows"]) <= 64
            and type(packet["truncated"]) is bool,
            "invalid_reply",
        )
        identifiers = set()
        for row in packet["rows"]:
            require(
                type(row) is dict
                and set(row) == {"id", "name", "accepts_input"}
                and type(row["id"]) is str
                and re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", row["id"])
                is not None
                and row["id"] not in identifiers
                and type(row["name"]) is str
                and "\0" not in row["name"]
                and len(row["name"].encode("utf-8")) <= 4096
                and type(row["accepts_input"]) is bool,
                "invalid_reply",
            )
            identifiers.add(row["id"])
        if operation == "revalidate":
            require(
                len(packet["rows"]) == 1
                and packet["rows"][0]["id"] == identifier
                and not packet["truncated"],
                "stale_discovery",
            )
        return packet


class SignedQuery:
    """Never signal a live supervisor that owns a separate native query group."""

    def __init__(self, helper, ownership, native):
        self.helper = str(helper)
        self.ownership = ownership
        self.native = native
        self.group = None
        self.control_closed = False
        self.protocol = None
        self.receipts = []

    def acquire(self, arguments):
        """Register the control-pipe supervisor before deferred interruption delivery."""
        previous, pending = {}, []
        failure = None

        def deferred(signum, frame):
            pending.append((signum, frame))

        try:
            for signum in (signal.SIGTERM, signal.SIGINT):
                previous[signum] = signal.getsignal(signum)
                signal.signal(signum, deferred)
            process = subprocess.Popen(
                arguments,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            self.group = self.ownership.OwnedProcessGroup(process, self.native)
        except BaseException as error:
            failure = error
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)
        if failure is not None:
            raise failure
        for signum, frame in pending:
            handler = previous[signum]
            if callable(handler):
                handler(signum, frame)
            elif handler == signal.SIG_DFL:
                self.cancel()
                raise Refused("interrupted")

    def cancel(self):
        """EOF requests exact inner retirement; no TERM/KILL reaches the supervisor."""
        if self.group is not None and not self.control_closed:
            self.group.process.stdin.close()
            self.control_closed = True

    def _make_protocol(self):
        """Default to the unchanged business-envelope decoder."""
        return QueryProtocol()

    def query(self, operation, nonce, identifier=None, cancel_held=False):
        require(self.group is None, "cleanup_pending")
        self.control_closed = False
        self.protocol = self._make_protocol()
        arguments = [self.helper, "--automation-query-worker", operation, str(nonce)]
        if identifier is not None:
            arguments.append(identifier)
        selector = selectors.DefaultSelector()
        streams = []
        failure = None
        deadline = time.monotonic() + 35
        try:
            self.acquire(arguments)
            process = self.group.process
            for stream, role in ((process.stdout, "out"), (process.stderr, "err")):
                streams.append(stream)
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, role)
            while True:
                if time.monotonic() >= deadline:
                    self.cancel()
                    raise Refused("cleanup_pending")
                try:
                    for key, _ in selector.select(0.02):
                        chunk = os.read(key.fileobj.fileno(), 4096)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        require(key.data == "out", "native_stderr")
                        events = self.protocol.feed(chunk)
                        for event in events:
                            if event == "held" and not self.control_closed:
                                if cancel_held:
                                    self.cancel()
                                else:
                                    process.stdin.write(b"ACTIVATE\n")
                                    process.stdin.flush()
                            elif event == "pending":
                                self.cancel()
                except Exception as error:
                    failure = failure or error
                    self.cancel()
                # The outer zombie remains reserved until a complete inner
                # receipt and native census prove every owner closed. A dead
                # helper without the receipt leaves inner custody unknown.
                if self.group.observe_exit() is not None and not selector.get_map():
                    require(
                        self.protocol.receipt and not self.protocol.buffer, "inner_custody_unknown"
                    )
                    require(self.group.closed_before_reap(), "cleanup_pending")
                    require(self.group.settle(timeout=0) is True, "cleanup_pending")
                    require(process.returncode == 0, "inner_custody_unknown")
                    self.receipts.append(
                        {
                            "inner_retired": True,
                            "outer_owner": self.group.receipt(),
                            "cancel_requested": self.control_closed,
                            "payload_bytes": len(self.protocol.payload or b""),
                            "protocol_bytes": self.protocol.bytes,
                        }
                    )
                    self.cancel()
                    self.group = None
                    break
            if failure is not None:
                raise failure
            if cancel_held:
                require(
                    self.control_closed and self.protocol.payload is None, "cancellation_refused"
                )
                return None
            return self.protocol.decode(operation, nonce, identifier)
        finally:
            self.cancel()
            selector.close()
            for stream in streams:
                stream.close()


def identity(path):
    """Bind the signed route to one regular executable without path substitution."""
    info = os.lstat(path)
    require(
        stat.S_ISREG(info.st_mode)
        and bool(info.st_mode & 0o111)
        and os.path.realpath(path) == str(path),
        "identity_refused",
    )
    return (
        info.st_dev,
        info.st_ino,
        info.st_uid,
        info.st_gid,
        info.st_mode,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def verify_build_receipt(raw, source_sha, hashes, helper_hash, run_id, attempt):
    """Bind the CI build owner's evidence to observed sources, product and CI run."""
    try:
        packet = json.loads(raw.decode("utf-8"), object_pairs_hook=unique)
    except (UnicodeError, ValueError):
        raise Refused("build_provenance_refused") from None
    require(
        type(packet) is dict
        and set(packet)
        == {
            "schema",
            "contract",
            "source_sha",
            "source_hashes",
            "helper_sha256",
            "ci_run_id",
            "ci_run_attempt",
        }
        and type(packet["schema"]) is int
        and packet["schema"] == 1
        and packet["contract"] == "signed-native-query-build"
        and packet["source_sha"] == source_sha
        and packet["source_hashes"] == hashes
        and packet["helper_sha256"] == helper_hash
        and type(run_id) is str
        and re.fullmatch(r"[1-9][0-9]*", run_id) is not None
        and type(attempt) is str
        and re.fullmatch(r"[1-9][0-9]*", attempt) is not None
        and packet["ci_run_id"] == run_id
        and packet["ci_run_attempt"] == attempt,
        "build_provenance_refused",
    )
    return packet


def source_paths(root, source_sha):
    """Pin the complete tracked native package input set, including custody helpers."""
    launcher = "static/ergopti_plus/macos/launcher/"
    paths = (
        subprocess.check_output(
            ["git", "ls-tree", "-r", "--name-only", source_sha, "--", launcher], cwd=root
        )
        .decode()
        .splitlines()
    )
    require(bool(paths), "source_refused")
    selected = {
        relative
        for relative in paths
        if relative.endswith((".swift", ".c", ".h"))
        or relative.rsplit("/", 1)[-1] in {"Package.resolved", "Package.swift"}
    }
    selected.update(
        {
            "tools/diagnostics/program_actions/run_signed_query_probe.py",
            "tools/diagnostics/program_actions/permission_observation.py",
            "tools/diagnostics/program_actions/test_permission_observation.py",
            "tools/diagnostics/macos_owned_process.py",
            "static/ergopti_plus/macos/adapters/apple_shortcuts_native.lua",
            "static/ergopti_plus/macos/adapters/apple_shortcuts.lua",
        }
    )
    return sorted(selected)


def load_permission_query(root, source_sha, hashes):
    """Execute only decoder bytes authenticated by the signed build receipt."""
    relative = "tools/diagnostics/program_actions/permission_observation.py"
    path = root / relative
    raw = path.read_bytes()
    require(
        not path.is_symlink()
        and hashlib.sha256(raw).hexdigest() == hashes.get(relative)
        and subprocess.check_output(["git", "show", source_sha + ":" + relative], cwd=root) == raw,
        "source_refused",
    )
    # Bind the decoder's dependency to this already admitted observer, including
    # its exact Refused class. Never search sys.path for another copy of the owner.
    dependency = types.ModuleType("run_signed_query_probe")
    for name, value in {
        "QueryProtocol": QueryProtocol,
        "Refused": Refused,
        "SignedQuery": SignedQuery,
        "require": require,
        "unique": unique,
    }.items():
        setattr(dependency, name, value)
    was_present = "run_signed_query_probe" in sys.modules
    previous = sys.modules.get("run_signed_query_probe")
    module = types.ModuleType("signed_query_permission_observation")
    module.__file__ = str(path)
    try:
        sys.modules["run_signed_query_probe"] = dependency
        exec(compile(raw, str(path), "exec"), module.__dict__)
    finally:
        if not was_present:
            del sys.modules["run_signed_query_probe"]
        else:
            sys.modules["run_signed_query_probe"] = previous
    require(issubclass(module.PermissionQuery, SignedQuery), "source_refused")
    return module.PermissionQuery


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--build-receipt", type=Path, required=True)
    parser.add_argument("--fixture-id")
    parser.add_argument("--cancel-held", action="store_true")
    args = parser.parse_args()
    require(sys.platform == "darwin" and sys.version_info >= (3, 13), "native_unavailable")
    require(re.fullmatch("[0-9a-f]{40}", args.source_sha) is not None, "source_refused")
    require(
        args.fixture_id is None
        or re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", args.fixture_id)
        is not None,
        "fixture_refused",
    )
    root = args.source_root.resolve()
    require(
        subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root).decode().strip()
        == args.source_sha
        and os.environ.get("GITHUB_SHA") == args.source_sha,
        "source_refused",
    )
    sources = source_paths(root, args.source_sha)
    hashes = {}
    for relative in sources:
        raw = (root / relative).read_bytes()
        require(
            subprocess.check_output(["git", "show", args.source_sha + ":" + relative], cwd=root)
            == raw,
            "source_refused",
        )
        hashes[relative] = hashlib.sha256(raw).hexdigest()
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    result = {
        "schema": 1,
        "contract": "signed-native-shortcut-query",
        "source_sha": args.source_sha,
        "source_hashes": hashes,
        "result": "REFUSED",
        "reason": "native_unavailable",
        "native_query_observed": False,
        "chosen_id_revalidated": False,
        "service_invocation_available": False,
        "automation_retirement_qualified": False,
        "native_catalogue_internal_allocation_bounded": False,
        "local_retired": False,
    }
    backend = None
    interrupted = False

    def on_signal(_signum, _frame):
        nonlocal interrupted
        interrupted = True
        if backend is not None:
            backend.cancel()

    previous = {signum: signal.getsignal(signum) for signum in (signal.SIGTERM, signal.SIGINT)}
    for signum in previous:
        signal.signal(signum, on_signal)
    try:
        app = args.app.resolve()
        helper = app / "Contents/MacOS/ErgoptiAutomationQuery"
        captured = identity(helper)
        verified = subprocess.run(
            [
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                "--all-architectures",
                "--deep",
                str(app),
            ],
            capture_output=True,
            timeout=10,
        )
        require(verified.returncode == 0 and identity(helper) == captured, "signature_refused")
        result["helper_sha256"] = hashlib.sha256(helper.read_bytes()).hexdigest()
        build_raw = args.build_receipt.read_bytes()
        require(len(build_raw) <= 65536, "build_provenance_refused")
        verify_build_receipt(
            build_raw,
            args.source_sha,
            hashes,
            result["helper_sha256"],
            os.environ.get("GITHUB_RUN_ID"),
            os.environ.get("GITHUB_RUN_ATTEMPT"),
        )
        # The CI publisher must seal this exact build receipt into the app before
        # signing. Strict codesign validation above authenticates the resource.
        require(
            (app / "Contents/Resources/automation-query-build.json").read_bytes() == build_raw,
            "build_provenance_refused",
        )
        result["build_receipt_sha256"] = hashlib.sha256(build_raw).hexdigest()
        result["ci_build_provenance_observed"] = True
        result["app_signature_verified"] = True
        spec = importlib.util.spec_from_file_location(
            "signed_query_native_owner", root / "tools/diagnostics/macos_owned_process.py"
        )
        ownership = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ownership)
        require(not interrupted, "interrupted")
        if not args.cancel_held:
            permission_query = load_permission_query(root, args.source_sha, hashes)
            backend = permission_query(helper, ownership, ownership.NativeProcessGroups())
            metadata = backend.observe(3)
            require(
                not interrupted and identity(helper) == captured and backend.group is None,
                "interrupted" if interrupted else "identity_refused",
            )
            require(
                all(
                    hashlib.sha256((root / relative).read_bytes()).hexdigest() == digest
                    for relative, digest in hashes.items()
                ),
                "source_refused",
            )
            result["sdk_permission_observation"] = {
                "metadata": metadata,
                "local_retired": True,
                "operations": backend.receipts,
            }
        backend = SignedQuery(helper, ownership, ownership.NativeProcessGroups())
        observed = backend.query("discover", 1, cancel_held=args.cancel_held)
        require(
            not interrupted and identity(helper) == captured,
            "interrupted" if interrupted else "identity_refused",
        )
        if args.cancel_held:
            result["local_cancellation_observed"] = True
        else:
            result["native_query_observed"] = True
            result["observed_choices"] = len(observed["rows"])
            result["truncated"] = observed["truncated"]
            if args.fixture_id is not None:
                matching = [row for row in observed["rows"] if row["id"] == args.fixture_id]
                require(len(matching) == 1, "safe_fixture_missing")
                chosen = backend.query("revalidate", 2, args.fixture_id)
                require(chosen["rows"] == matching, "stale_discovery")
                result["chosen_id_revalidated"] = True
        result["result"], result["reason"] = "PARTIAL", "service_retirement_unqualified"
    except Refused as error:
        result["reason"] = str(error)
    except Exception:
        result["reason"] = "native_refused"
    finally:
        if backend is not None:
            backend.cancel()
            result["local_retired"] = backend.group is None
            result["operations"] = backend.receipts
            if backend.group is not None:
                result["pending_outer_owner"] = backend.group.receipt()
                result["inner_custody_unknown"] = True
        for signum, handler in previous.items():
            signal.signal(signum, handler)
        for relative in sources:
            if hashlib.sha256((root / relative).read_bytes()).hexdigest() != hashes[relative]:
                result["result"], result["reason"] = "REFUSED", "source_changed"
        (args.output / "observation.json").write_text(json.dumps(result, sort_keys=True) + "\n")
        print(json.dumps(result, sort_keys=True))
    return 2 if result["result"] == "PARTIAL" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Refused as error:
        print(
            json.dumps(
                {
                    "contract": "signed-native-shortcut-query",
                    "result": "REFUSED",
                    "reason": str(error),
                }
            )
        )
        raise SystemExit(1)
