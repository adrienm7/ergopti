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
            ROOT / "static/ergopti_plus/_shared/modules/network/proxy_policy.json", contract
        )
        shutil.copy2(ROOT / "static/ergopti_plus/_shared/python/network_proxy_policy.py", shared)
        for name in ("native_http.py", "managed_http.py"):
            shutil.copy2(MAC / "platform/network" / name, native)
        source = MAC / "launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift"
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
                fixture_source,
                *compatibility_sources,
                MAC / "platform/network/native_http.py",
                MAC / "platform/network/managed_http.py",
                ROOT / "static/ergopti_plus/_shared/python/network_proxy_policy.py",
                ROOT / "static/ergopti_plus/_shared/modules/network/proxy_policy.json",
            )
        }
        worker_copy = cls.root / source.name
        main_copy = cls.root / fixture_source.name
        shutil.copy2(source, worker_copy)
        shutil.copy2(fixture_source, main_copy)
        try:
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
            cls.fixture._command(
                [
                    "/usr/bin/xcrun",
                    "swiftc",
                    "-parse-as-library",
                    "-I",
                    str(compatibility_module),
                    "-framework",
                    "SystemConfiguration",
                    str(worker_copy),
                    str(main_copy),
                    "-o",
                    str(executable),
                ],
                timeout=60,
            )
            for relative, digest in observed.items():
                if hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() != digest:
                    raise RuntimeError("Native receiving source changed during compilation")
            cls.fixture._command(["/usr/bin/codesign", "--force", "--sign", "-", str(executable)])
            cls.fixture._command(["/usr/bin/codesign", "--verify", "--strict", str(executable)])
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
            shutil.rmtree(cls.root)
            raise

    @classmethod
    def tearDownClass(cls):
        cls.fixture.close()
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
        shutil.rmtree(cls.root)

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
        self.settings(False)

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
                    transport.active, set(), "Every completed actual native child was reaped"
                )
                self.assertEqual(self.fixture.stats()["active"], 0)
        origins = [row for row in self.fixture.stats()["records"] if row["event"] == "origin"]
        self.assertEqual(
            [row["path"] for row in origins],
            ["/alpha?case=one", "/beta?case=two", "/fallback?case=three", "/socks?case=ten"],
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
            [str(item.url) for item in response.history], [self.url("/redirect?case=five")]
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
            [row["route"] for row in origins], ["first", "second", "first", "first", "first"]
        )
        closed = [row for row in records if row["event"] == "redirect_closed"]
        self.assertEqual(
            closed,
            [
                {"event": "redirect_closed", "path": "/redirect?case=five", "eof": True},
                {"event": "redirect_closed", "path": "/downgrade?case=six", "eof": True},
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
