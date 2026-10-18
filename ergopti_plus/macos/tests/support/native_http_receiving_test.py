"""Receive real HTTPX/HF calls and actual pipe/process protocol boundaries.

The authored helper is a protocol peer, not CFNetwork or Apple network evidence.
Native PAC/WPAD/system trust acceptance must run separately on macOS.
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import signal
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).absolute().parents[2]
NETWORK = ROOT / "platform/network"


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


NATIVE = load("receiving_native", NETWORK / "native_http.py")
POLICY = load("receiving_policy", ROOT.parent / "_shared/python/network_proxy_policy.py")


HELPER = r"""
import json,os,struct,sys,time
from urllib.parse import urlsplit
request=json.load(sys.stdin)
mode=urlsplit(request['url']).path.strip('/')
if os.environ.get('RECEIVING_LEDGER'):
    with open(os.environ['RECEIVING_LEDGER'],'a') as ledger:
        ledger.write(json.dumps(request)+'\n')
def frame(tag,payload):
    payload=tag+(json.dumps(payload).encode() if isinstance(payload,dict) else payload)
    framed=struct.pack('>I',len(payload))+payload
    if mode=='split':
        for byte in framed: os.write(1,bytes([byte]))
    else: os.write(1,framed)
headers=[]
status=200
if mode=='redirect':
    status=302; headers=[['Location','https://second.example/next?route=two']]
if mode=='downgrade':
    status=302; headers=[['Location','http://second.example/blocked?route=insecure']]
if mode=='boolean-version':
    frame(b'H',{'version':True,'status':200,'headers':[]});sys.exit(0)
if mode=='oversize':
    os.write(1,struct.pack('>I',65537));sys.exit(0)
if mode=='early-failure':
    frame(b'C',{'version':1,'success':False,'reason':'certificate'});sys.exit(74)
if mode=='hold-before-header': time.sleep(30)
frame(b'H',{'version':1,'status':status,'headers':headers})
if mode=='hold': time.sleep(30)
if mode=='progress':
    for _ in range(30): frame(b'D',b'x');time.sleep(.03)
elif mode not in ('redirect','truncated'): frame(b'D',b'N\x00LF')
if mode=='truncated': sys.exit(0)
if mode=='invalid-terminal':
    frame(b'C',{'version':1,'success':True,'reason':'certificate'});sys.exit(0)
if mode=='extra-terminal':
    frame(b'C',{'version':1,'success':True,'reason':'complete','listener':None});sys.exit(0)
if mode=='admission-terminal':
    frame(b'C',{'version':1,'success':False,'reason':'admission'});sys.exit(74)
frame(b'C',{'version':1,'success':True,'reason':'complete'})
if mode=='trailing': os.write(1,b'x')
sys.exit(3 if mode=='bad-exit' else 0)
"""


class NativePipeReceiving(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ergopti-native-http-")
        self.helper = Path(self.temporary.name) / "worker"
        self.helper.write_text("#!" + sys.executable + "\n" + HELPER, encoding="utf-8")
        self.helper.chmod(0o700)
        self.resolver = mock.patch.object(NATIVE, "_resolve_worker", return_value=str(self.helper))
        self.resolver.start()

    def tearDown(self):
        self.resolver.stop()
        self.temporary.cleanup()

    def open(self, mode, **kwargs):
        return NATIVE.open_request("https://fixture.example/" + mode, idle_timeout=1, **kwargs)

    def test_split_frames_and_binary_body_require_terminal_and_physical_reap(self):
        with self.open("split") as response:
            self.assertEqual(response.status, 200)
            body = []
            while data := response.read(2):
                body.append(data)
            self.assertEqual(b"".join(body), b"N\x00LF")
            self.assertEqual(response._process.poll(), 0)
            self.assertTrue(response._complete)
            self.assertEqual(response.read(), b"")

    def test_protocol_failures_cannot_be_successful_eof(self):
        for mode in (
            "truncated",
            "trailing",
            "bad-exit",
            "invalid-terminal",
            "boolean-version",
            "oversize",
            "extra-terminal",
            "admission-terminal",
        ):
            with self.subTest(mode=mode), self.assertRaises(NATIVE.NativeHTTPError) as failure:
                with self.open(mode) as response:
                    while response.read():
                        pass
            self.assertEqual(failure.exception.reason, "protocol")

    def test_verified_native_error_contains_only_fixed_cause(self):
        with self.assertRaises(NATIVE.NativeHTTPError) as failure:
            self.open("early-failure")
        self.assertEqual(failure.exception.reason, "certificate")
        self.assertNotIn("fixture.example", str(failure.exception))

    def test_close_kills_and_reaps_a_held_physical_peer(self):
        response = self.open("hold")
        process = response._process
        self.assertIsNone(process.poll())
        response.close()
        self.assertIsNotNone(process.poll())
        response.close()

    def test_signal_during_constructor_reaps_peer_before_owner_cancel_escapes(self):
        class OwnerCancelled(BaseException):
            pass

        spawned = []
        original_spawn = subprocess.Popen

        def spawn(*arguments, **keywords):
            child = original_spawn(*arguments, **keywords)
            spawned.append(child)
            return child

        def cancelled(*_):
            raise OwnerCancelled()

        native_signal = hasattr(signal, "SIGALRM") and hasattr(signal, "setitimer")
        previous = signal.signal(signal.SIGALRM, cancelled) if native_signal else None
        try:
            with mock.patch.object(NATIVE.subprocess, "Popen", side_effect=spawn):
                if native_signal:
                    signal.setitimer(signal.ITIMER_REAL, 0.1)
                    with self.assertRaises(OwnerCancelled):
                        self.open("hold-before-header")
                else:
                    # Windows has no POSIX alarm. The same exception boundary
                    # still owns the actual pipe child; no signal is credited.
                    with mock.patch.object(
                        NATIVE.NativeHTTPResponse, "_ready", side_effect=cancelled
                    ):
                        with self.assertRaises(OwnerCancelled):
                            self.open("hold-before-header")
        finally:
            if native_signal:
                signal.setitimer(signal.ITIMER_REAL, 0)
                signal.signal(signal.SIGALRM, previous)
        self.assertEqual(len(spawned), 1)
        self.assertIsNotNone(spawned[0].poll())

    def test_idle_timeout_physically_closes_peer(self):
        with NATIVE.open_request("https://fixture.example/hold", idle_timeout=0.1) as response:
            process = response._process
            with self.assertRaises(NATIVE.NativeHTTPError) as failure:
                response.read()
            self.assertEqual(failure.exception.reason, "deadline")
            self.assertIsNotNone(process.poll())

    def test_progress_does_not_renew_an_existing_absolute_budget(self):
        started = time.monotonic()
        with self.open("progress", timeout=0.2) as response:
            process = response._process
            with self.assertRaises(NATIVE.NativeHTTPError) as failure:
                while response.read():
                    pass
            self.assertEqual(failure.exception.reason, "deadline")
            self.assertIsNotNone(process.poll())
        self.assertLess(time.monotonic() - started, 1)

    def test_bad_input_does_not_resolve_or_launch_a_native_child(self):
        for arguments in ({"timeout": True}, {"idle_timeout": None}, {"method": "POST"}):
            with (
                self.subTest(arguments=arguments),
                mock.patch.object(NATIVE, "_resolve_worker") as resolver,
            ):
                with self.assertRaises(NATIVE.NativeHTTPError):
                    NATIVE.open_request("https://fixture.example/test", **arguments)
                resolver.assert_not_called()


class SharedPolicyReceiving(unittest.TestCase):
    def setUp(self):
        self.policy = POLICY.ProxyPolicy()

    def test_literal_environment_and_loopback_routes(self):
        vectors = (
            (
                "https://origin.example/a",
                {"https_proxy": "http://first:1", "HTTPS_PROXY": "http://second:2"},
                ("environment", "http://first:1"),
            ),
            (
                "https://origin.example/a",
                {"ALL_PROXY": "http://all:3"},
                ("environment", "http://all:3"),
            ),
            ("http://origin.example/a", {"HTTP_PROXY": "http://ignored:4"}, ("native", None)),
            ("https://127.22.33.44/a", {"https_proxy": "http://outside:1"}, ("direct", None)),
            ("https://[0:0:0:0:0:0:0:1]/a", {"https_proxy": "http://outside:1"}, ("direct", None)),
            ("https://child.LOCALHOST./a", {"https_proxy": "http://outside:1"}, ("direct", None)),
            ("https://origin.example/a", {}, ("native", None)),
            (
                "https://origin.example/a",
                {"no_proxy": "origin.example:443", "https_proxy": "http://outside:1"},
                ("direct", None),
            ),
            (
                "https://10.2.3.4/a",
                {"NO_PROXY": "10.0.0.0/8", "https_proxy": "http://outside:1"},
                ("direct", None),
            ),
            (
                "https://child.example/a",
                {"no_proxy": "*.example", "https_proxy": "http://outside:1"},
                ("direct", None),
            ),
            (
                "https://notexample/a",
                {"no_proxy": "example", "https_proxy": "http://outside:1"},
                ("environment", "http://outside:1"),
            ),
        )
        for url, environment, expected in vectors:
            with self.subTest(url=url, environment=environment):
                self.assertEqual(self.policy.route(url, environment), expected)

    def test_malformed_selectors_never_become_direct(self):
        vectors = (
            "https://name:secret@origin.example/a",
            "https://origin.example:0/a",
            "https://origin.example/a\n",
            "file:///tmp/a",
        )
        for url in vectors:
            with self.subTest(url=url), self.assertRaises(POLICY.ProxyPolicyError) as failure:
                self.policy.route(url, {})
            self.assertEqual(str(failure.exception), "proxy-policy-invalid")
        with self.assertRaises(POLICY.ProxyPolicyError):
            self.policy.route(
                "https://origin.example/a", {"HTTPS_PROXY": "http://relay.example/path"}
            )


class ActualHTTPXReceiving(unittest.TestCase):
    def setUp(self):
        NativePipeReceiving.setUp(self)
        self.managed = load("receiving_managed", NETWORK / "managed_http.py")
        self.native_resolver = mock.patch.object(
            self.managed.Native, "_resolve_worker", return_value=str(self.helper)
        )
        self.native_resolver.start()
        self.environment = mock.patch.dict(os.environ, {}, clear=True)
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.native_resolver.stop()
        NativePipeReceiving.tearDown(self)

    def test_actual_httpx_redirect_uses_full_target_and_strips_cross_origin_auth(self):
        import httpx

        ledger = Path(self.temporary.name) / "requests.jsonl"
        os.environ["RECEIVING_LEDGER"] = str(ledger)
        with httpx.Client(
            transport=self.managed.ManagedHTTPTransport(1), follow_redirects=True
        ) as client:
            response = client.get(
                "https://first.example/redirect?route=one",
                headers={"Authorization": "Bearer reserved-fixture-token"},
            )
            self.assertEqual(response.content, b"N\x00LF")
        rows = [json.loads(line) for line in ledger.read_text().splitlines()]
        self.assertEqual(
            [row["url"] for row in rows],
            ["https://first.example/redirect?route=one", "https://second.example/next?route=two"],
        )
        self.assertTrue(any(name.lower() == "authorization" for name, _ in rows[0]["headers"]))
        self.assertFalse(any(name.lower() == "authorization" for name, _ in rows[1]["headers"]))
        self.assertTrue(
            all(
                [name.lower(), value] == ["accept-encoding", "identity"]
                for row in rows
                for name, value in row["headers"]
                if name.lower() == "accept-encoding"
            )
        )
        with httpx.Client(
            transport=self.managed.ManagedHTTPTransport(1), follow_redirects=True
        ) as client:
            with self.assertRaises(httpx.UnsupportedProtocol):
                client.get("https://first.example/downgrade")
        final_rows = [json.loads(line) for line in ledger.read_text().splitlines()]
        self.assertEqual(
            [row["url"] for row in final_rows],
            [
                "https://first.example/redirect?route=one",
                "https://second.example/next?route=two",
                "https://first.example/downgrade",
            ],
            "HTTPS downgrade is refused before a receiving child or insecure request exists",
        )

    def test_actual_huggingface_factory_installs_owned_transport_and_disables_both_rust_clients(
        self,
    ):
        from huggingface_hub.utils._http import close_session, get_session

        self.managed.install_huggingface_transport()
        try:
            client = get_session()
            self.assertIsInstance(client._transport, self.managed.ManagedHTTPTransport)
            self.assertEqual(client.max_redirects, 50)
            self.assertEqual(client.get("https://fixture.example/split").content, b"N\x00LF")
            self.assertEqual(os.environ["HF_HUB_DISABLE_XET"], "1")
            self.assertEqual(os.environ["HF_HUB_ENABLE_HF_TRANSFER"], "0")
            from huggingface_hub import constants

            self.assertIs(constants.HF_HUB_DISABLE_XET, True)
        finally:
            close_session()


class ManagedTransportAdmissionReceiving(unittest.TestCase):
    def setUp(self):
        import httpcore
        import httpx

        self.httpx = httpx
        self.managed = load("receiving_relay_managed", NETWORK / "managed_http.py")
        self.environment = mock.patch.dict(
            os.environ, {"http_proxy": "http://relay.invalid:3128"}, clear=True
        )
        self.environment.start()
        self.owner = self.managed.ManagedHTTPTransport(1)
        self.connections = []
        self.pool_closed = threading.Event()
        outer = self

        class Backend(httpcore.MockBackend):
            def connect_tcp(self, *args, **kwargs):
                outer.connections.append(outer.pool_closed.is_set())
                return super().connect_tcp(*args, **kwargs)

        self.explicit = httpx.HTTPTransport(proxy="http://relay.invalid:3128", trust_env=False)
        self.explicit._pool._network_backend = Backend(
            [b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ntest"]
        )
        self.original_handle = self.explicit.handle_request
        original_close = self.explicit.close

        def close():
            original_close()
            self.pool_closed.set()

        self.explicit.close = close
        self.factory = mock.patch.object(httpx, "HTTPTransport", return_value=self.explicit)
        self.factory_mock = self.factory.start()

    def tearDown(self):
        self.owner.close()
        self.factory.stop()
        self.environment.stop()

    def test_shutdown_cannot_finish_before_inflight_relay_header_acquisition(self):
        entered = threading.Event()
        release = threading.Event()
        classified = threading.Event()
        admission = []
        close_done = threading.Event()
        errors = []
        response = []

        def handle(request):
            entered.set()
            if not release.wait(5):
                raise AssertionError("test gate was not released")
            return self.original_handle(request)

        def sender():
            try:
                response.append(
                    self.owner.handle_request(self.httpx.Request("GET", "http://origin.invalid/a"))
                )
            except BaseException as error:
                errors.append(error)

        def closer():
            try:
                self.owner.close()
            except BaseException as error:
                errors.append(error)
            finally:
                close_done.set()

        class ObservedLock:
            def __init__(self):
                self.inner = threading.RLock()

            def __enter__(self):
                if threading.current_thread() is closing:
                    acquired = self.inner.acquire(blocking=False)
                    admission.append(acquired)
                    classified.set()
                    if not acquired:
                        self.inner.acquire()
                else:
                    self.inner.acquire()
                return self

            def __exit__(self, *unused):
                self.inner.release()

        self.owner.lock = ObservedLock()
        self.explicit.handle_request = handle
        sending = threading.Thread(target=sender)
        closing = threading.Thread(target=closer)
        sending.start()
        try:
            self.assertTrue(entered.wait(5))
            closing.start()
            self.assertTrue(classified.wait(5))
            if admission == [True]:
                # The original lets close finish first; only then admit the
                # actual HTTPX acquisition. No scheduling delay decides this.
                self.assertTrue(close_done.wait(5))
        finally:
            release.set()
            sending.join(5)
            if closing.ident is not None:
                closing.join(5)
            for item in response:
                item.close()
        self.assertFalse(sending.is_alive())
        self.assertFalse(closing.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(len(response), 1)
        self.assertEqual(response[0].status_code, 200)
        self.assertTrue(close_done.is_set())
        self.assertEqual(
            self.connections,
            [False],
            "the actual HTTPX pool acquired a connection after close returned",
        )
        self.assertEqual(admission, [False], "shutdown did not wait for admitted relay headers")

    def test_relay_header_acquisition_retains_shutdown_admission(self):
        acquired = []

        def probe():
            held = self.owner.lock.acquire(blocking=False)
            acquired.append(held)
            if held:
                self.owner.lock.release()

        def handle(request):
            contender = threading.Thread(target=probe)
            contender.start()
            contender.join(5)
            self.assertFalse(contender.is_alive())
            return self.original_handle(request)

        self.explicit.handle_request = handle
        response = self.owner.handle_request(self.httpx.Request("GET", "http://origin.invalid/a"))
        response.close()
        self.assertEqual(
            acquired,
            [False],
            "shutdown admission was free while the explicit pool could acquire a connection",
        )

    def test_already_closed_owner_never_constructs_a_relay(self):
        self.owner.close()
        with self.assertRaises(self.httpx.ConnectError):
            self.owner.handle_request(self.httpx.Request("GET", "http://origin.invalid/a"))
        self.factory_mock.assert_not_called()
        self.assertEqual(self.connections, [])

    def test_relay_failure_releases_serialization_for_close(self):
        def fail(request):
            raise self.httpx.ConnectError("inert receiving refusal", request=request)

        self.explicit.handle_request = fail
        with self.assertRaises(self.httpx.ConnectError):
            self.owner.handle_request(self.httpx.Request("GET", "http://origin.invalid/a"))
        self.owner.close()
        self.assertTrue(self.pool_closed.is_set())
        self.assertEqual(self.connections, [])

    def _capture_timeouts(self, request):
        captured = []
        original = self.explicit.handle_request

        def handle(request):
            captured.append(dict(request.extensions["timeout"]))
            return original(request)

        self.explicit.handle_request = handle
        response = self.owner.handle_request(request)
        response.close()
        self.assertEqual(len(captured), 1)
        return captured[0]

    def test_explicit_none_timeouts_use_the_admitted_idle_bound(self):
        with self.httpx.Client(timeout=None, trust_env=False) as client:
            request = client.build_request("GET", "http://origin.invalid/a")
        original = request.extensions["timeout"]
        self.assertEqual(original, dict.fromkeys(("connect", "read", "write", "pool")))
        self.assertEqual(self._capture_timeouts(request), dict.fromkeys(original, 1))
        self.assertEqual(original, dict.fromkeys(original))

    def test_explicit_positive_caller_timeouts_are_preserved(self):
        supplied = {"connect": 0.25, "read": 0.5, "write": 0.75, "pool": 0.125}
        request = self.httpx.Request(
            "GET", "http://origin.invalid/a", extensions={"timeout": supplied}
        )
        self.assertEqual(self._capture_timeouts(request), supplied)

    def test_explicit_deadline_caps_the_original_operation_allowances(self):
        supplied = {"connect": 8, "read": 0.25, "write": None, "pool": None}
        request = self.httpx.Request(
            "GET",
            "http://origin.invalid/a",
            extensions={"timeout": supplied, "ergopti_native_deadline": 102},
        )
        with mock.patch.object(self.managed.time, "monotonic", return_value=100):
            self.assertEqual(
                self._capture_timeouts(request),
                {"connect": 2, "read": 0.25, "write": 1, "pool": 1},
            )
        self.assertEqual(supplied, {"connect": 8, "read": 0.25, "write": None, "pool": None})

    def test_explicit_deadline_is_rechecked_after_shutdown_admission(self):
        clock = [100]

        class AdvancingLock:
            def __init__(self):
                self.inner = threading.RLock()
                self.entries = 0

            def __enter__(self):
                self.inner.acquire()
                self.entries += 1
                if self.entries == 2:
                    clock[0] = 103
                return self

            def __exit__(self, *unused):
                self.inner.release()

        self.owner.lock = AdvancingLock()
        request = self.httpx.Request(
            "GET", "http://origin.invalid/a", extensions={"ergopti_native_deadline": 102}
        )
        with mock.patch.object(self.managed.time, "monotonic", side_effect=lambda: clock[0]):
            with self.assertRaises(self.httpx.ReadTimeout):
                self.owner.handle_request(request)
        self.factory_mock.assert_not_called()
        self.assertEqual(self.connections, [])

    def test_explicit_invalid_timeout_refuses_before_pool_admission(self):
        for value in (True, False, 0, -1, float("inf"), float("nan"), "1"):
            for operation in ("connect", "read", "write", "pool"):
                with self.subTest(value=value, operation=operation):
                    request = self.httpx.Request(
                        "GET", "http://origin.invalid/a", extensions={"timeout": {operation: value}}
                    )
                    with self.assertRaises(self.httpx.ReadTimeout):
                        self.owner.handle_request(request)
        request = self.httpx.Request("GET", "http://origin.invalid/a", extensions={"timeout": []})
        with self.assertRaises(self.httpx.ReadTimeout):
            self.owner.handle_request(request)
        self.factory_mock.assert_not_called()
        self.assertEqual(self.connections, [])

    def test_explicit_invalid_or_expired_deadline_refuses_before_pool_admission(self):
        for value in (True, False, 0, -1, float("inf"), float("nan"), "102", 99, 100):
            with self.subTest(value=value):
                request = self.httpx.Request(
                    "GET", "http://origin.invalid/a", extensions={"ergopti_native_deadline": value}
                )
                with mock.patch.object(self.managed.time, "monotonic", return_value=100):
                    with self.assertRaises(self.httpx.ReadTimeout):
                        self.owner.handle_request(request)
        self.factory_mock.assert_not_called()
        self.assertEqual(self.connections, [])

    def _observe_native_deadline_after_admission(self, admission_clock, *, expired):
        clock = [100]
        calls = []
        closes = []

        class AdvancingLock:
            def __init__(self):
                self.inner = threading.RLock()
                self.entries = 0

            def __enter__(self):
                self.inner.acquire()
                self.entries += 1
                if self.entries == 2:
                    clock[0] = admission_clock
                return self

            def __exit__(self, *unused):
                self.inner.release()

        class InertNativeResponse:
            status = 200
            headers = []

            def close(self):
                closes.append(True)

        def observe(url, headers, method, timeout, idle, direct):
            calls.append({"timeout": timeout, "idle": idle, "direct": direct})
            return InertNativeResponse()

        self.owner.lock = AdvancingLock()
        request = self.httpx.Request(
            "GET", "https://origin.invalid/a", extensions={"ergopti_native_deadline": 102}
        )
        with mock.patch.dict(os.environ, {}, clear=True):
            with mock.patch.object(self.managed.time, "monotonic", side_effect=lambda: clock[0]):
                with mock.patch.object(self.managed.Native, "open_request", side_effect=observe):
                    if expired:
                        with self.assertRaises(self.httpx.ReadTimeout):
                            self.owner.handle_request(request)
                    else:
                        response = self.owner.handle_request(request)
                        response.close()
        self.assertEqual(request.extensions["ergopti_native_deadline"], 102)
        self.factory_mock.assert_not_called()
        self.assertEqual(self.connections, [])
        if expired:
            self.assertEqual(calls, [])
            self.assertEqual(closes, [])
        else:
            self.assertEqual(
                calls, [{"timeout": 102 - admission_clock, "idle": 1, "direct": False}]
            )
            self.assertEqual(closes, [True])
            self.assertEqual(self.owner.active, set())

    def test_native_expired_deadline_refuses_after_admission_before_acquisition(self):
        self._observe_native_deadline_after_admission(103, expired=True)

    def test_native_acquisition_receives_only_the_budget_remaining_after_admission(self):
        self._observe_native_deadline_after_admission(101.5, expired=False)

    def test_normal_actual_httpx_pool_preserves_body_and_retirement(self):
        response = self.owner.handle_request(self.httpx.Request("GET", "http://origin.invalid/a"))
        try:
            self.assertEqual(response.read(), b"test")
        finally:
            response.close()
        self.owner.close()
        self.assertTrue(self.pool_closed.is_set())
        self.assertEqual(self.connections, [False])


if __name__ == "__main__":
    if sys.argv[1:] == ["--policy-only"]:
        print(
            "Selected: shared-policy receiving. POSIX pipe protocol, actual HTTPX/HF clients and native Apple networking: not executed.",
            flush=True,
        )
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(SharedPolicyReceiving)
    elif sys.argv[1:] == ["--protocol-only"]:
        print(
            "Selected: standard-library protocol/shared-policy receiving. Actual HTTPX/HF clients and native Apple networking: not executed.",
            flush=True,
        )
        suite = unittest.TestSuite(
            unittest.defaultTestLoader.loadTestsFromTestCase(case)
            for case in (NativePipeReceiving, SharedPolicyReceiving)
        )
    elif sys.argv[1:] == ["--client-only"]:
        print(
            "Selected: actual HTTPX 0.28.1/HF 1.13.0 client receiving over authored native protocol peers. Native Apple networking: not executed.",
            flush=True,
        )
        suite = unittest.TestSuite(
            unittest.defaultTestLoader.loadTestsFromTestCase(case)
            for case in (ActualHTTPXReceiving, ManagedTransportAdmissionReceiving)
        )
    elif not sys.argv[1:]:
        print(
            "Selected: protocol/shared-policy and actual HTTPX/HF client receiving. Native Apple networking: not executed.",
            flush=True,
        )
        suite = unittest.TestSuite(
            unittest.defaultTestLoader.loadTestsFromTestCase(case)
            for case in (
                NativePipeReceiving,
                SharedPolicyReceiving,
                ActualHTTPXReceiving,
                ManagedTransportAdmissionReceiving,
            )
        )
    else:
        raise SystemExit(
            "Usage: native_http_receiving_test.py [--policy-only|--protocol-only|--client-only]"
        )
    print("Planned cases: " + str(suite.countTestCases()), flush=True)
    result = unittest.TextTestRunner().run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
