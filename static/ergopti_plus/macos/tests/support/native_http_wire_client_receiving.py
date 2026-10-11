"""Actual locked HTTPX/HF clients, process ABI and genuine native Apple wire.

Compile the unchanged native worker with a separate fixture-only entry point.
No release CLI override or system proxy mutation exists. Private source hashes,
ad-hoc signing and exact launcher device/inode bind the real receiving child.
"""

import hashlib
import importlib.util
import json
import math
import re
import time
import os
from pathlib import Path
import shutil
import signal
import stat
import sys
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[5]
MAC = ROOT / "static/ergopti_plus/macos"
spec = importlib.util.spec_from_file_location(
    "native_wire_owner", Path(__file__).with_name("native_http_wire_fixture.py")
)
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)


def worker_receiving_facts(receiver):
    process = getattr(receiver, "_process", None)
    closed = getattr(receiver, "_closed", False) is True
    created = process is not None
    reaped = created and process.returncode is not None
    stdin_closed = created and process.stdin is not None and process.stdin.closed
    stdout_closed = created and process.stdout is not None and process.stdout.closed
    return {
        "created": int(created),
        "closed": int(closed),
        "reaped": int(reaped),
        "stdin_closed": int(stdin_closed),
        "stdout_closed": int(stdout_closed),
        "settled": int(closed and (not created or (reaped and stdin_closed and stdout_closed))),
        "exit_complete": int(reaped and process.returncode == 0),
        "exit_deadline": int(reaped and process.returncode == 75),
        "exit_refused": int(reaped and process.returncode == 74),
        "exit_killed": int(reaped and process.returncode == -9),
        "exit_other": int(reaped and process.returncode not in (0, 75, 74, -9)),
    }


WORKER_STAGES = (
    "entry",
    "arguments",
    "stdin_eof",
    "request",
    "settings",
    "policy",
    "execute",
    "settings_provider",
    "first_frame",
    "returned",
)


# Internal callback/source construction can interleave. These observations do
# not grant a route or impose an invented order on native callback delivery.
INNER_STAGES = (
    "proxy_copy",
    "proxy_copied",
    "pac_url",
    "pac_script",
    "pac_source",
    "pac_wait",
    "pac_callback",
    "pac_done",
    "routes_done",
    "session_resume",
    "session_wait",
    "session_invalid",
    "session_done",
)
ALL_STAGES = WORKER_STAGES + INNER_STAGES
# Exactly one compact plan token can accompany the original stages. A sole
# default-refused route differs from the authored fallback's ordered successor.
# Missing/unqualified observation is unknown, never proof of a selected endpoint.
ROUTE_STAGES = {
    "r0": "sole_direct",
    "r1": "sole_default_refused",
    "r2": "default_refused_with_successor",
    "r3": "other_http_first",
    "r4": "socks_first",
    "r5": "unknown",
}

# All unique closed labels, including mutually exclusive branches, fit the
# existing 256-byte envelope. No transport clock or byte limit is increased.
assert (
    sum(len(stage) + 1 for stage in ALL_STAGES) + max(len(token) + 1 for token in ROUTE_STAGES)
    <= 256
)


class WorkerStageReceipt:
    """Retain one exact private regular FD through its real child retirement."""

    def __init__(self, target):
        self.target = target
        self.descriptor = os.open(target, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        self.identity = os.fstat(self.descriptor)
        self.name_pending = True
        self.close_uncertain = False

    @property
    def closed(self):
        return self.descriptor is None and not self.name_pending

    def facts(self, receiver):
        if self.close_uncertain:
            return {"state": "refused", "stages": []}
        if not worker_receiving_facts(receiver)["settled"]:
            return {"state": "unsettled", "stages": []}
        current = os.fstat(self.descriptor)
        named = os.stat(self.target, follow_symlinks=False)
        if (
            (current.st_dev, current.st_ino) != (named.st_dev, named.st_ino)
            or not stat.S_ISREG(current.st_mode)
            or current.st_nlink != 1
            or current.st_uid != os.getuid()
            or stat.S_IMODE(current.st_mode) != 0o600
            or current.st_size > 256
        ):
            return {"state": "refused", "stages": []}
        os.lseek(self.descriptor, 0, os.SEEK_SET)
        raw = os.read(self.descriptor, 257)
        if len(raw) != current.st_size or (raw and not raw.endswith(b"\n")):
            return {"state": "refused", "stages": []}
        try:
            stages = raw.decode("ascii").splitlines()
            if (
                any(stage not in ALL_STAGES and stage not in ROUTE_STAGES for stage in stages)
                or len(stages) != len(set(stages))
                or sum(stage in ROUTE_STAGES for stage in stages) > 1
            ):
                return {"state": "refused", "stages": []}
            indices = [WORKER_STAGES.index(stage) for stage in stages if stage in WORKER_STAGES]
        except (UnicodeError, ValueError):
            return {"state": "refused", "stages": []}
        if indices != sorted(set(indices)):
            return {"state": "refused", "stages": []}
        return {"state": "observed" if stages else "empty", "stages": stages}

    def retire_name(self, receiver, destination):
        if self.close_uncertain:
            raise RuntimeError("Native fixture stage FD close outcome is uncertain")
        if not worker_receiving_facts(receiver)["settled"]:
            raise RuntimeError("Previous native fixture worker remains unsettled")
        named = os.stat(self.target, follow_symlinks=False)
        if (named.st_dev, named.st_ino) != (self.identity.st_dev, self.identity.st_ino):
            raise RuntimeError("Native fixture stage name identity diverged")
        os.link(self.target, destination, follow_symlinks=False)
        os.unlink(self.target)
        self.target = destination

    def close(self):
        if self.close_uncertain:
            # A failed raw close can already have retired the physical FD. A
            # reused integer, even for the same inode, grants no retry authority.
            raise RuntimeError("Native fixture stage FD close outcome is uncertain")
        if self.descriptor is not None:
            current = os.fstat(self.descriptor)
            if (current.st_dev, current.st_ino) != (
                self.identity.st_dev,
                self.identity.st_ino,
            ):
                raise RuntimeError("Native fixture stage FD identity diverged")
            # Preserve the exact FD on a refused close; the pathname cannot be
            # retired before its physical descriptor closure succeeds.
            try:
                os.close(self.descriptor)
            except BaseException:
                self.close_uncertain = True
                raise
            self.descriptor = None
        if self.name_pending:
            try:
                current = os.stat(self.target, follow_symlinks=False)
            except FileNotFoundError:
                self.name_pending = False
                return
            if (current.st_dev, current.st_ino) == (
                self.identity.st_dev,
                self.identity.st_ino,
            ):
                os.unlink(self.target)
            # A foreign replacement remains untouched. A refused unlink keeps
            # the original name debt available to the same owner's next close.
            self.name_pending = False


class NativeClockRefused(RuntimeError):
    pass


def native_clock_frame(raw, before, after):
    # Compare every actual sample; never infer a shared epoch from the endpoints.
    def finite_number(value):
        if type(value) not in (int, float):
            return False
        try:
            return math.isfinite(value)
        except OverflowError:
            return False

    if (
        type(raw) is not bytes
        or not 1 <= len(raw) <= 4096
        or not raw.endswith(b"\n")
        or raw.count(b"\n") != 1
        or not finite_number(before)
        or not finite_number(after)
        or not 0 < before <= after
        or after - before > 15
    ):
        raise NativeClockRefused("Native clock frame refused")

    def unique(pairs):
        if len({key for key, _ in pairs}) != len(pairs):
            raise NativeClockRefused("Native clock duplicate field refused")
        return dict(pairs)

    def nonfinite(value):
        raise NativeClockRefused("Native clock nonfinite field refused")

    try:
        fields = json.loads(raw.decode("ascii"), object_pairs_hook=unique, parse_constant=nonfinite)
    except (ValueError, UnicodeError) as refused:
        raise NativeClockRefused("Native clock JSON refused") from refused
    if (
        type(fields) is not dict
        or set(fields) != {"version", "system_uptime"}
        or type(fields["version"]) is not int
        or fields["version"] != 1
        or type(fields["system_uptime"]) is not list
        or len(fields["system_uptime"]) != 16
    ):
        raise NativeClockRefused("Native clock grammar refused")
    samples = fields["system_uptime"]
    for index, sample in enumerate(samples):
        if (
            not finite_number(sample)
            or not before <= sample <= after
            or (index > 0 and sample < samples[index - 1])
        ):
            raise NativeClockRefused("Native clock epoch/order refused")
    return samples


def native_clock_epoch(environment, architecture):
    if architecture not in ("arm64", "amd64"):
        raise NativeClockRefused("Native clock architecture context refused")
    names = ("GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT")
    values = [environment.get(name) for name in names]
    # A local native run can receive numeric samples without claiming CI context.
    if all(value is None for value in values):
        return None
    if (
        any(type(value) is not str for value in values)
        or re.fullmatch(r"[0-9a-f]{40}", values[0]) is None
        or re.fullmatch(r"[1-9][0-9]{0,19}", values[1]) is None
        or re.fullmatch(r"[1-9][0-9]{0,5}", values[2]) is None
    ):
        raise NativeClockRefused("Native clock run context refused")
    return {
        "candidate": values[0],
        "run_id": values[1],
        "run_attempt": values[2],
        "architecture": architecture,
        "provenance": "github_environment",
    }


def native_clock_python_loader(cache):
    # Bounded pathname admission, not an atomic freshness or interpreter attestation.
    cache = Path(cache)
    if (
        not cache.is_absolute()
        or cache.resolve() != cache
        or sys.pycache_prefix != str(cache)
        or sys.flags.isolated != 1
        or sys.flags.ignore_environment != 1
        or sys.flags.no_user_site != 1
        or sys.dont_write_bytecode is not True
        or sys.flags.safe_path is not True
    ):
        raise NativeClockRefused("Native clock Python loader context refused")
    before = cache.lstat()
    if not stat.S_ISDIR(before.st_mode) or stat.S_IMODE(before.st_mode) != 0o700:
        raise NativeClockRefused("Native clock private cache mode refused")
    if any(cache.iterdir()):
        raise NativeClockRefused("Native clock private cache contains bytecode")
    after = cache.lstat()
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        raise NativeClockRefused("Native clock private cache replaced")
    return {
        "version": 1,
        "isolated": 1,
        "ignore_environment": 1,
        "no_user_site": 1,
        "dont_write_bytecode": True,
        "safe_path": True,
        "cache_empty": True,
        "cache_device": before.st_dev,
        "cache_inode": before.st_ino,
    }


class NativeClockEvidence:
    """Passive exclusive file export; never another child or retirement owner."""

    def __init__(self, destination):
        self.root = Path(destination)
        if not self.root.is_absolute() or self.root.parent.resolve() != self.root.parent:
            raise NativeClockRefused("Native clock evidence parent refused")
        self.root.mkdir(mode=0o700)
        self.identity = self.root.lstat()
        self.records = {}
        self.refused = False
        if stat.S_IMODE(self.identity.st_mode) != 0o700:
            raise NativeClockRefused("Native clock evidence mode refused")

    def _write(self, name, raw):
        if (
            name
            not in {
                "compile.json",
                "sign.json",
                "strict_verify.json",
                "clock.json",
                "clock-frame.bin",
                "image.bin",
                "source-receipt.json",
                "clock-receipt.json",
                "python-loader.json",
            }
            or type(raw) is not bytes
            or len(raw) > 8_388_608
        ):
            raise NativeClockRefused("Native clock passive export refused")
        directory = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            current = os.fstat(directory)
            named = self.root.lstat()
            if (
                not stat.S_ISDIR(current.st_mode)
                or (current.st_dev, current.st_ino) != (self.identity.st_dev, self.identity.st_ino)
                or (named.st_dev, named.st_ino) != (current.st_dev, current.st_ino)
                or stat.S_IMODE(current.st_mode) != 0o700
            ):
                raise NativeClockRefused("Native clock evidence root changed")
            descriptor = os.open(
                name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=directory,
            )
            try:
                offset = 0
                while offset < len(raw):
                    written = os.write(descriptor, raw[offset:])
                    if written <= 0:
                        raise NativeClockRefused("Native clock evidence write refused")
                    offset += written
                acquired = os.fstat(descriptor)
                if not stat.S_ISREG(acquired.st_mode) or acquired.st_nlink != 1:
                    raise NativeClockRefused("Native clock evidence alias refused")
            finally:
                os.close(descriptor)
            final = self.root.lstat()
            if (final.st_dev, final.st_ino) != (current.st_dev, current.st_ino):
                raise NativeClockRefused("Native clock evidence root replaced")
        finally:
            os.close(directory)

    def command(self, role, fact):
        # The command boundary performs bounded memory observation only. File
        # export waits until the original clock's after reading and validation.
        try:
            if role not in ("compile", "sign", "strict_verify", "clock") or role in self.records:
                raise NativeClockRefused("Native clock passive role refused")
            received = dict(fact)
            raw = received.pop("stdout")
            if role == "clock" and (type(raw) is not bytes or len(raw) > 4096):
                raise NativeClockRefused("Native clock raw frame exceeds bound")
            self.records[role] = (received, raw if role == "clock" else None)
        except BaseException:
            self.refused = True
            raise

    def export(self, build, builder, raw, fact):
        if self.refused or set(self.records) != {"compile", "sign", "strict_verify", "clock"}:
            raise NativeClockRefused("Native clock passive records incomplete")
        if self.records["clock"][1] != raw:
            raise NativeClockRefused("Native clock raw frame changed")
        if native_clock_python_loader(self.root.parent / "private-cache") != self.loader:
            raise NativeClockRefused("Native clock private loader changed")
        for role, (record, _) in self.records.items():
            self._write(role + ".json", json.dumps(record, sort_keys=True).encode("ascii"))
        self._write("clock-frame.bin", raw)
        image = builder.regular_bytes(build.verify())[0]
        receipt = builder.regular_bytes(build.receipt_path)[0]
        if (
            hashlib.sha256(image).hexdigest() != build.image_digest
            or hashlib.sha256(receipt).hexdigest() != build.receipt_digest
        ):
            raise NativeClockRefused("Native clock original export changed")
        # These are original bytes, not reconstructed receipts or executable copies.
        self._write("image.bin", image)
        self._write("source-receipt.json", receipt)
        self._write("clock-receipt.json", json.dumps(fact, sort_keys=True).encode("ascii"))
        build.verify()
        self._write("python-loader.json", json.dumps(self.loader, sort_keys=True).encode("ascii"))


def prepare_native_clock_evidence(build):
    destination = os.environ.get("ERGOPTI_NATIVE_CLOCK_EVIDENCE")
    if destination is None:
        return
    try:
        sink = NativeClockEvidence(destination)
        sink.loader = native_clock_python_loader(sink.root.parent / "private-cache")
        build.passive_clock_evidence = sink
        build.passive_command_receiver = sink.command
    except BaseException as refused:
        if not isinstance(refused, Exception) or (
            type(refused) is wire.FixtureFailure and refused.args == ("Native fixture cancelled",)
        ):
            raise
        # Original receiving proceeds. Missing evidence never means qualification.


def export_native_clock_evidence(build, builder, raw, fact):
    try:
        sink = getattr(build, "passive_clock_evidence", None)
        if sink is not None:
            sink.export(build, builder, raw, fact)
    except BaseException as refused:
        if not isinstance(refused, Exception) or (
            type(refused) is wire.FixtureFailure and refused.args == ("Native fixture cancelled",)
        ):
            raise


def receive_native_clock(build, builder):
    if sys.platform != "darwin" or not build.fixture.native or build.fixture.groups is None:
        raise NativeClockRefused("Native clock requires the actual Darwin child owner")
    executable = build.verify()
    image, identity = builder.regular_bytes(executable)
    architecture = {"arm64": "arm64", "x86_64": "amd64"}.get(os.uname().machine)
    cpu = {"arm64": 0x0100000C, "amd64": 0x01000007}.get(architecture)
    if (
        len(image) < 32
        or image[:4] != b"\xcf\xfa\xed\xfe"
        or int.from_bytes(image[4:8], "little") != cpu
    ):
        raise NativeClockRefused("Native clock signed image architecture refused")
    epoch = native_clock_epoch(os.environ, architecture)
    receiver, _ = builder.regular_bytes(Path(__file__))
    receiver_digest = hashlib.sha256(receiver).hexdigest()
    before = time.monotonic()
    observer = getattr(build, "passive_command_receiver", None)
    if observer is None:
        status, raw = build.fixture._command(
            [str(executable), "--fixture-clock-proof"], timeout=15, deadline=before + 15
        )
    else:
        status, raw = build.fixture._command(
            [str(executable), "--fixture-clock-proof"],
            timeout=15,
            deadline=before + 15,
            passive_receiving=lambda fact: observer("clock", fact),
        )
    after = time.monotonic()
    if type(status) is not int or status != 0:
        raise NativeClockRefused("Native clock child refused")
    samples = native_clock_frame(raw, before, after)
    build.verify()
    if hashlib.sha256(builder.regular_bytes(Path(__file__))[0]).hexdigest() != receiver_digest:
        raise NativeClockRefused("Native clock receiver source changed")
    if native_clock_epoch(os.environ, architecture) != epoch:
        raise NativeClockRefused("Native clock run context changed")
    fact = {
        "version": 1,
        "state": "observed",
        "native_acceptance": "UNQUALIFIED_GIT_HEAD_CLEANLINESS_NOT_RECEIVED",
        "git_head": None,
        "tracked_clean_sources": None,
        "epoch": epoch,
        "context_bound": epoch is not None,
        "python_before": before,
        "python_after": after,
        "system_uptime": samples,
        "source_receipt_sha256": build.receipt_digest,
        "source_hashes": dict(build.source_hashes),
        "staged_hashes": dict(build.staged_hashes),
        "receiver_sha256": receiver_digest,
        "binary_sha256": build.image_digest,
        "device": identity.st_dev,
        "inode": identity.st_ino,
        "architecture": architecture,
        "signature": "existing_build_codesign_strict_verified_same_image",
    }
    encoded = json.dumps(fact, sort_keys=True)
    if len(encoded.encode("ascii")) > 16_384:
        raise NativeClockRefused("Native clock receipt bound refused")
    export_native_clock_evidence(build, builder, raw, fact)
    # This observation uses stderr; the worker stdout response ABI is unchanged.
    # Technical publication refusal is optional, genuine cancellation propagates.
    try:
        print("# native_http_clock_proof " + encoded, file=sys.stderr, flush=True)
    except BaseException as refused:
        if not isinstance(refused, Exception) or (
            type(refused) is wire.FixtureFailure and refused.args == ("Native fixture cancelled",)
        ):
            raise
    return fact


class RealNativeClientReceiving(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys.platform != "darwin":
            raise RuntimeError("Actual client/native Apple receiving requires macOS")
        import httpx
        import huggingface_hub

        if httpx.__version__ != "0.28.1" or huggingface_hub.__version__ != "1.13.0":
            raise RuntimeError("Native receiving requires the committed client dependency lock")
        # This owner supplies native WNOWAIT/group retirement for compilation,
        # signing and the fixture security commands too.
        cls.fixture = wire.WireFixture()
        cls.receiving_workers = []
        cls.root = None
        try:
            build_spec = importlib.util.spec_from_file_location(
                "owned_native_http_build",
                Path(__file__).with_name("native_http_fixture_builder.py"),
            )
            builder = importlib.util.module_from_spec(build_spec)
            build_spec.loader.exec_module(builder)
            cls.build = builder.OwnedFixtureBuild(cls.fixture)
            cls.root = cls.build.root
            prepare_native_clock_evidence(cls.build)
            cls.build.build()
            cls.clock_proof = receive_native_clock(cls.build, builder)
            cls.fixture.authorization_observation = True
            cls.app = cls.build.app
            cls.resources = cls.build.resources
            native = cls.build.native
            cls.environment = cls.build.environment
            module_spec = importlib.util.spec_from_file_location(
                "actual_native_managed_http", native / "managed_http.py"
            )
            cls.managed = importlib.util.module_from_spec(module_spec)
            module_spec.loader.exec_module(cls.managed)
            cls.httpx = httpx
        except BaseException as primary:
            root_refusal = None
            if cls.root is not None:
                try:
                    cls.build._root_owned()
                except BaseException as failure:
                    root_refusal = failure
            close_failure = None
            try:
                cls.fixture.close()
            except BaseException as failure:
                close_failure = failure
            if cls.root is not None and root_refusal is None and close_failure is None:
                try:
                    cls._root_removal_admitted()
                    shutil.rmtree(cls.root)
                except BaseException as failure:
                    root_refusal = failure
            # These are retained failure facts, never a second process owner.
            cls.root_cleanup_failures = [
                failure for failure in (close_failure, root_refusal) if failure is not None
            ]
            if cls.root_cleanup_failures:
                raise primary from cls.root_cleanup_failures[0]
            raise

    @classmethod
    def _root_removal_admitted(cls):
        # Bounded pathname identity admission, not an atomic deletion proof.
        cls.build._root_owned()
        if (
            cls.fixture.closed is not True
            or cls.fixture.command_group_debt
            or cls.fixture.command_file_debt
            or cls.fixture.trust_attempted
            or cls.fixture.keychain_created
            or cls.fixture.receiving_facts()["active"]
        ):
            raise RuntimeError("Native fixture build root cleanup remains unsettled")
        if any(not worker_receiving_facts(value)["settled"] for value in cls.receiving_workers):
            raise RuntimeError("Native fixture receiving child remains unsettled")

    @classmethod
    def tearDownClass(cls):
        root_refusal = None
        try:
            cls.build._root_owned()
        except BaseException as failure:
            root_refusal = failure
        try:
            cls.fixture.close()
        except BaseException as primary:
            if root_refusal is not None:
                raise primary from root_refusal
            raise
        finally:
            # Observe the unchanged restoration outcome, including refusal.
            # Printing never pays a cleanup debt or replaces its primary error.
            try:
                print(
                    "# native_http_fixture_closure "
                    + json.dumps(
                        {
                            "version": 1,
                            "closed": int(cls.fixture.closed),
                            "trust_unsettled": int(cls.fixture.trust_attempted),
                            "keychain_unsettled": int(cls.fixture.keychain_created),
                            "active": cls.fixture.receiving_facts()["active"],
                        },
                        sort_keys=True,
                    ),
                    flush=True,
                )
            except (OSError, ValueError):
                pass
        if root_refusal is not None:
            raise root_refusal
        cls._root_removal_admitted()
        receipt = json.loads((cls.root / "source-receipt.json").read_text())
        for relative, digest in receipt["source_hashes"].items():
            if hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() != digest:
                raise RuntimeError("Native receiving final source receipt diverged")
        if (
            hashlib.sha256(
                (Path(cls.environment["ERGOPTI_LAUNCHER_EXECUTABLE"])).read_bytes()
            ).hexdigest()
            != receipt["binary_sha256"]
        ):
            raise RuntimeError("Native receiving final signed binary receipt diverged")
        if any(
            (receipt := getattr(worker, "_fixture_stage_receipt", None)) is not None
            and not receipt.closed
            for worker in cls.receiving_workers
        ):
            raise RuntimeError("Native fixture stage receipt closure remains unsettled")
        cls._root_removal_admitted()
        shutil.rmtree(cls.root)
        if all(worker_receiving_facts(value)["settled"] for value in cls.receiving_workers):
            cls.receiving_workers.clear()

    def setUp(self):
        clean = dict(os.environ)
        for key in self.managed.Policy.ProxyPolicy().system_lookup_environment_exclusions + (
            "no_proxy",
            "NO_PROXY",
        ):
            clean.pop(key, None)
        clean.update(self.environment)
        self.environment_scope = mock.patch.dict(os.environ, clean, clear=True)
        self.environment_scope.start()
        self.addCleanup(self.environment_scope.stop)
        self.receiving_start = len(self.receiving_workers)
        original = self.managed.Native.NativeHTTPResponse._open_wire

        def observe(receiver, *arguments, **keywords):
            # This test owner retains only the exact caller object, before its
            # unchanged open/close implementation runs. It never selects a PID.
            if len(self.receiving_workers) > self.receiving_start:
                previous = self.receiving_workers[-1]
                previous_receipt = getattr(previous, "_fixture_stage_receipt", None)
                if previous_receipt is not None:
                    previous_receipt.retire_name(
                        previous,
                        self.resources / f"fixture-worker-stages-{len(self.receiving_workers)}",
                    )
            self.receiving_workers.append(receiver)
            receipt = WorkerStageReceipt(self.resources / "fixture-worker-stages")
            receiver._fixture_stage_receipt = receipt
            return original(receiver, *arguments, **keywords)

        observer = mock.patch.object(self.managed.Native.NativeHTTPResponse, "_open_wire", observe)
        observer.start()
        self.addCleanup(observer.stop)
        self.addCleanup(self.report_receiving_facts)
        self.settings(False)

    def report_receiving_facts(self):
        owners = self.receiving_workers[self.receiving_start :]
        facts = [worker_receiving_facts(value) for value in owners]
        stages = []
        for owner in owners:
            receipt = getattr(owner, "_fixture_stage_receipt", None)
            if receipt is None:
                stages.append({"state": "unavailable", "stages": []})
                continue
            try:
                stages.append(receipt.facts(owner))
            except OSError:
                stages.append({"state": "refused", "stages": []})
            finally:
                if worker_receiving_facts(owner)["settled"]:
                    try:
                        receipt.close()
                    except (OSError, RuntimeError):
                        stages[-1] = {"state": "refused", "stages": []}
        print(
            "# native_http_receiving "
            + json.dumps(
                {
                    "version": 1,
                    "peer": self.fixture.receiving_facts(),
                    "entry_stages": {
                        stage: min(65535, sum(stage in row["stages"] for row in stages))
                        for stage in ALL_STAGES
                    },
                    "selected_route": {
                        kind: min(65535, sum(token in row["stages"] for row in stages))
                        for token, kind in ROUTE_STAGES.items()
                        if kind != "unknown"
                    }
                    | {
                        "unknown": min(
                            65535,
                            sum(
                                not any(
                                    stage in ROUTE_STAGES and stage != "r5"
                                    for stage in row["stages"]
                                )
                                for row in stages
                            ),
                        )
                    },
                    "stage_receipts": {
                        state: min(65535, sum(row["state"] == state for row in stages))
                        for state in (
                            "observed",
                            "empty",
                            "unavailable",
                            "refused",
                            "unsettled",
                        )
                    },
                    "stage_closure_unsettled": min(
                        65535,
                        sum(
                            (receipt := getattr(owner, "_fixture_stage_receipt", None)) is not None
                            and not receipt.closed
                            for owner in owners
                        ),
                    ),
                    "worker_count": min(65535, len(facts)),
                    **{
                        key: min(65535, sum(value[key] for value in facts))
                        for key in (
                            "created",
                            "closed",
                            "reaped",
                            "stdin_closed",
                            "stdout_closed",
                            "settled",
                            "exit_complete",
                            "exit_deadline",
                            "exit_refused",
                            "exit_killed",
                            "exit_other",
                        )
                    },
                },
                sort_keys=True,
            ),
            flush=True,
        )

    def settings(self, pac_url):
        fields = {
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigURLString"
            if pac_url
            else "ProxyAutoConfigJavaScript": self.fixture.pac_url if pac_url else self.fixture.pac,
        }
        target = self.resources / "fixture-proxy-settings.json"
        target.write_text(json.dumps(fields), encoding="utf-8")
        os.chmod(target, 0o600)

    def url(self, path):
        return f"https://{self.fixture.host}:{self.fixture.origin_port}{path}"

    def test01RealHTTPXFullURLPACURLFallbackAndVerifiedPhysicalChildEOF(self):
        transport = self.managed.ManagedHTTPTransport(10)
        with self.httpx.Client(
            transport=transport, follow_redirects=True, timeout=10, trust_env=False
        ) as client:
            with self.assertRaises(self.httpx.ConnectError) as refusal:
                client.get(self.url("/certificate?case=seven"))
            self.assertEqual(str(refusal.exception), "Managed network request failed: certificate")
            self.assertEqual(self.fixture.stats()["active"], 0)
            self.assertEqual(
                self.fixture.stats()["records"],
                [{"event": "connect", "route": "first"}],
                "A certificate refusal never advances to another PAC relay",
            )
            self.fixture.trust(True)
            for path, pac_url in [
                ("/alpha?case=one", False),
                ("/beta?case=two", True),
                ("/fallback?case=three", False),
                ("/socks?case=ten", False),
            ]:
                self.settings(pac_url)
                response = client.get(self.url(path))
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.content, b"owned\x00native\xffwire")
                self.assertEqual(
                    transport.active,
                    set(),
                    "Every completed actual native child was reaped",
                )
                self.assertEqual(self.fixture.stats()["active"], 0)
        origins = [row for row in self.fixture.stats()["records"] if row["event"] == "origin"]
        self.assertEqual(
            [row["path"] for row in origins],
            [
                "/alpha?case=one",
                "/beta?case=two",
                "/fallback?case=three",
                "/socks?case=ten",
            ],
        )
        self.assertEqual([row["route"] for row in origins], ["first", "second", "first", "socks"])
        socks = [row for row in self.fixture.stats()["records"] if row["event"] == "socks_connect"]
        self.assertEqual(
            socks,
            [
                {
                    "event": "socks_connect",
                    "version": 5,
                    "command": 1,
                    "reserved": 0,
                    "address_type": 3,
                    "target": self.fixture.host,
                    "port": self.fixture.origin_port,
                }
            ],
        )
        greetings = [
            row for row in self.fixture.stats()["records"] if row["event"] == "socks_greeting"
        ]
        self.assertEqual(len(greetings), 1)
        self.assertEqual(greetings[0]["version"], 5)
        self.assertIn(0, greetings[0]["methods"])

    def test02ActualHFFactoryRedirectAuthRefusalAndNativeClosure(self):
        from huggingface_hub.utils import close_session, get_session

        before = len(self.fixture.stats()["records"])
        self.fixture.trust(True)
        self.managed.install_huggingface_transport()
        self.addCleanup(close_session)
        client = get_session()
        self.assertIsInstance(client._transport, self.managed.ManagedHTTPTransport)
        self.assertEqual(os.environ["HF_HUB_DISABLE_XET"], "1")
        self.assertEqual(os.environ["HF_HUB_ENABLE_HF_TRANSFER"], "0")
        from huggingface_hub import constants

        self.assertIs(constants.HF_HUB_DISABLE_XET, True)
        response = client.get(self.url("/redirect?case=five"))
        self.assertEqual(response.content, b"owned\x00native\xffwire")
        self.assertEqual(
            [str(item.url) for item in response.history],
            [self.url("/redirect?case=five")],
        )
        with self.assertRaises(self.httpx.HTTPError):
            client.get(self.url("/auth?case=four"))
        with self.assertRaises(self.httpx.UnsupportedProtocol):
            client.get(self.url("/downgrade?case=six"))
        with client.stream("GET", self.url("/held?case=eight")) as held:
            self.assertEqual(held.status_code, 200)
        self.assertEqual(
            client._transport.active,
            set(),
            "Closing an unconsumed actual response reaps its exact native child",
        )
        with self.assertRaises(self.httpx.HTTPError):
            client.get(self.url("/truncated?case=nine"))
        self.assertEqual(client._transport.active, set())
        snapshot = self.fixture.stats()
        self.assertEqual(snapshot["active"], 0)
        records = snapshot["records"][before:]
        origins = [row for row in records if row["event"] == "origin"]
        self.assertEqual(
            [row["path"] for row in origins],
            [
                "/redirect?case=five",
                "/beta?case=two",
                "/downgrade?case=six",
                "/held?case=eight",
                "/truncated?case=nine",
            ],
        )
        self.assertEqual(
            [row["route"] for row in origins],
            ["first", "second", "first", "first", "first"],
        )
        closed = [row for row in records if row["event"] == "redirect_closed"]
        self.assertEqual(
            closed,
            [
                {
                    "event": "redirect_closed",
                    "path": "/redirect?case=five",
                    "eof": True,
                },
                {
                    "event": "redirect_closed",
                    "path": "/downgrade?case=six",
                    "eof": True,
                },
            ],
        )
        self.assertEqual(
            [row for row in records if row["event"] == "held_closed"],
            [{"event": "held_closed", "eof": True}],
        )
        self.assertEqual(
            len([row for row in records if row["event"] == "connect" and row["route"] == "second"]),
            1,
            "Authentication refusal, delivered body and cancellation never fall through to a second relay",
        )


if __name__ == "__main__":
    print(
        "Selected: 2 actual locked HTTPX/HF -> exact signed native worker process -> CFNetwork/NSURLSession TLS/PAC wire cases. Missing native prerequisites fail.",
        flush=True,
    )

    def interrupted(*_):
        raise KeyboardInterrupt("Native client receiving cancelled")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        unittest.main(verbosity=2)
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        fixture = getattr(RealNativeClientReceiving, "fixture", None)
        if fixture is not None:
            fixture.close()
