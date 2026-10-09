"""Actual locked HTTPX/HF clients, process ABI and genuine native Apple wire.

Compile the unchanged native worker with a separate fixture-only entry point.
No release CLI override or system proxy mutation exists. Private source hashes,
ad-hoc signing and exact launcher device/inode bind the real receiving child.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import sys
import tempfile
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
            cls.root = Path(tempfile.mkdtemp(prefix="ergopti-native-client-app-"))
            os.chmod(cls.root, 0o700)
            cls.app = cls.root / "OwnedNativeHTTPFixture.app"
            contents = cls.app / "Contents"
            executable = contents / "MacOS/ErgoptiPlus"
            executable.parent.mkdir(parents=True)
            cls.resources = contents / "Resources"
            payload = cls.resources / "static/ergopti_plus"
            native = payload / "macos/platform/network"
            native.mkdir(parents=True)
            shared = payload / "_shared/python"
            shared.mkdir(parents=True)
            contract = payload / "_shared/modules/network/proxy_policy.json"
            contract.parent.mkdir(parents=True)
            shutil.copy2(
                ROOT / "static/ergopti_plus/_shared/modules/network/proxy_policy.json",
                contract,
            )
            shutil.copy2(
                ROOT / "static/ergopti_plus/_shared/python/network_proxy_policy.py",
                shared,
            )
            for name in ("native_http.py", "managed_http.py"):
                shutil.copy2(MAC / "platform/network" / name, native)
            source = MAC / "launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift"
            certificate_source = source.with_name("ManagedCertificateAuthorities.swift")
            bootstrap_source = source.with_name("ManagedBootstrapPolicy.generated.swift")
            fixture_source = Path(__file__).with_name("native_http_fixture_main.swift")
            compatibility_headers = MAC / "launcher/Sources/CPOSIXCompatibility/include"
            compatibility_sources = tuple(
                compatibility_headers / name
                for name in (
                    "CPOSIXCompatibility.h",
                    "OwnedProgramCompatibility.h",
                    "LoopbackListenerCompatibility.h",
                    "OwnedImageAliasCompatibility.h",
                    "OwnedSuspendedImageCompatibility.h",
                )
            )
            # Retain exact compiler inputs in the private packet. A concurrent edit
            # refuses qualification, even if swiftc itself returned success.
            observed = {
                str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (
                    source,
                    certificate_source,
                    bootstrap_source,
                    fixture_source,
                    *compatibility_sources,
                    MAC / "platform/network/native_http.py",
                    MAC / "platform/network/managed_http.py",
                    ROOT / "static/ergopti_plus/_shared/python/network_proxy_policy.py",
                    ROOT / "static/ergopti_plus/_shared/modules/network/proxy_policy.json",
                )
            }
            worker_copy = cls.root / source.name
            certificate_copy = cls.root / certificate_source.name
            bootstrap_copy = cls.root / bootstrap_source.name
            main_copy = cls.root / fixture_source.name
            swift_inputs = (
                (source, worker_copy),
                (certificate_source, certificate_copy),
                (bootstrap_source, bootstrap_copy),
                (fixture_source, main_copy),
            )
            for original, copied in swift_inputs:
                shutil.copy2(original, copied)
            # SwiftPM supplies this real Clang module to the release launcher.
            # Standalone receiving must import the identical public C headers,
            # including the explicit public macOS DHCP declarations.
            compatibility_module = cls.root / "CPOSIXCompatibility"
            compatibility_module.mkdir(mode=0o700)
            for header in compatibility_sources:
                destination = compatibility_module / header.name
                shutil.copy2(header, destination)
                relative = str(header.relative_to(ROOT))
                if hashlib.sha256(destination.read_bytes()).hexdigest() != observed[relative]:
                    raise RuntimeError("Native compatibility source changed before compilation")
            (compatibility_module / "module.modulemap").write_text(
                "module CPOSIXCompatibility {\n"
                '  umbrella header "CPOSIXCompatibility.h"\n'
                "  export *\n"
                "}\n",
                encoding="utf-8",
            )
            for original, copied in swift_inputs:
                if (
                    hashlib.sha256(copied.read_bytes()).hexdigest()
                    != observed[str(original.relative_to(ROOT))]
                ):
                    raise RuntimeError("Native Swift source changed before compilation")
            cls.fixture._command(
                [
                    "/usr/bin/xcrun",
                    "swiftc",
                    "-parse-as-library",
                    "-D",
                    "ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS",
                    "-I",
                    str(compatibility_module),
                    "-framework",
                    "SystemConfiguration",
                    str(worker_copy),
                    str(certificate_copy),
                    str(bootstrap_copy),
                    str(main_copy),
                    "-o",
                    str(executable),
                ],
                timeout=60,
            )
            for original, copied in swift_inputs:
                if (
                    hashlib.sha256(copied.read_bytes()).hexdigest()
                    != observed[str(original.relative_to(ROOT))]
                ):
                    raise RuntimeError("Native Swift source changed during compilation")
            for relative, digest in observed.items():
                if hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() != digest:
                    raise RuntimeError("Native receiving source changed during compilation")
            cls.fixture._command(["/usr/bin/codesign", "--force", "--sign", "-", str(executable)])
            cls.fixture._command(["/usr/bin/codesign", "--verify", "--strict", str(executable)])
            cls.fixture.trust_query_executable = executable
            cls.fixture.authorization_observation = True
            identity = executable.stat()
            (cls.root / "source-receipt.json").write_text(
                json.dumps(
                    {
                        "version": 1,
                        "source_hashes": observed,
                        "binary_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                        "device": identity.st_dev,
                        "inode": identity.st_ino,
                    }
                ),
                encoding="utf-8",
            )
            cls.environment = {
                "ERGOPTI_LAUNCHER_EXECUTABLE": str(executable),
                "ERGOPTI_LAUNCHER_DEVICE": str(identity.st_dev),
                "ERGOPTI_LAUNCHER_INODE": str(identity.st_ino),
            }
            module_spec = importlib.util.spec_from_file_location(
                "actual_native_managed_http", native / "managed_http.py"
            )
            cls.managed = importlib.util.module_from_spec(module_spec)
            module_spec.loader.exec_module(cls.managed)
            cls.httpx = httpx
        except BaseException:
            cls.fixture.close()
            if cls.root is not None:
                shutil.rmtree(cls.root)
            raise

    @classmethod
    def tearDownClass(cls):
        try:
            cls.fixture.close()
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
