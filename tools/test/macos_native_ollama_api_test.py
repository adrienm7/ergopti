# tools/test/macos_native_ollama_api_test.py
"""Receive native API wire lifecycle with actual portable fixture processes.

The peer controls framing only. Darwin listener provenance and real daemon
pull/inference remain separate mandatory native receiving tests.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
API = ROOT / "static/ergopti_plus/macos/platform/network/native_ollama_api.py"
ENGINE = API.with_name("native_http.py")
IDENTITY = {
    "pid": 42,
    "uid": os.geteuid(),
    "start_seconds": "1234",
    "start_microseconds": "999999",
    "device": "123",
    "inode": "456",
}
PEER = r"""
import json,os,struct,sys,time
raw=sys.stdin.buffer.readline()
with open(os.environ['ERGOPTI_PEER_RECEIPT'],'x') as f:
 json.dump({'raw':raw.decode('ascii'),'argv':sys.argv[1:],'pid':os.getpid()},f)
if not raw.endswith(b'\n'):sys.exit(64)
request=json.loads(raw)
mode=os.environ['ERGOPTI_PEER_MODE']
identity={'pid':42,'uid':os.geteuid(),'start_seconds':'1234',
 'start_microseconds':'999999','device':'123','inode':'456'}
def frame(tag,value):
 data=tag+(value if isinstance(value,bytes) else json.dumps(value).encode())
 sys.stdout.buffer.write(struct.pack('>I',len(data))+data);sys.stdout.buffer.flush()
if mode=='wait':time.sleep(60)
if request.get('method'):
 frame(b'H',{'version':1,'status':200,'headers':[['Content-Type','application/json']]})
 frame(b'D',b'{"status":"success"}\n')
 if mode=='body_wait':time.sleep(60)
if mode=='pid_change':identity['pid']=43
if mode=='boolean_pid':identity['pid']=True
if mode=='noncanonical_start':identity['start_seconds']='01234'
receipt={'version':1,'success':mode!='admission','reason':'admission' if mode=='admission' else 'complete',
 'listener':None if mode=='admission' else identity}
if mode=='duplicate':
 frame(b'C',b'{"version":1,"version":1,"success":true,"reason":"complete","listener":null}')
else:frame(b'C',receipt)
if mode=='trailing':sys.stdout.buffer.write(b'x');sys.stdout.buffer.flush()
if mode=='exit':sys.exit(74)
"""


class WireReceiving(unittest.TestCase):
    def setUp(self):
        self.owner = tempfile.TemporaryDirectory(prefix="ergopti-native-ollama-wire-")
        self.addCleanup(self.owner.cleanup)
        self.directory = Path(self.owner.name)
        shutil.copyfile(ENGINE, self.directory / "native_http.py")
        shutil.copyfile(API, self.directory / "native_ollama_api.py")
        specification = importlib.util.spec_from_file_location(
            "ollama_wire_receiver", self.directory / "native_ollama_api.py"
        )
        self.api = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(self.api)
        self.assertTrue(
            hasattr(self.api.ENGINE.NativeHTTPResponse, "_open_wire"),
            "actual adopted role engine required",
        )
        self.peer = self.directory / "peer"
        self.peer.write_text("#!" + sys.executable + "\n" + PEER, encoding="utf-8")
        self.peer.chmod(0o700)
        self.receipt = self.directory / "receipt.json"
        self.children = []
        original = subprocess.Popen

        def spawn(*args, **kwargs):
            process = original(*args, **kwargs)
            self.children.append(process)
            return process

        self.addCleanup(patch.stopall)
        patch.object(self.api.ENGINE, "_resolve_worker", return_value=str(self.peer)).start()
        patch.object(self.api.ENGINE.subprocess, "Popen", side_effect=spawn).start()
        fixture_children = self.children

        class RetainedPopen(original):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                fixture_children.append(self)

        self.original_popen = original
        patch.object(self.api.ENGINE, "_ROLE_POPEN", RetainedPopen, create=True).start()
        patch.dict(
            os.environ, ERGOPTI_PEER_RECEIPT=str(self.receipt), ERGOPTI_PEER_MODE="good"
        ).start()

    def tearDown(self):
        for process in self.children:
            if process.poll() is None:
                process.kill()
                process.wait()
                self.fail("native role fixture child survived caller completion")
            self.assertTrue(process.stdin.closed)
            self.assertTrue(process.stdout.closed)

    def discover(self):
        return self.api.discover("/private/verified/ollama", "123", "456", 11434, 2, 1)

    def request(self):
        body = '{"model":"fixture"}'
        headers = [
            ["Accept-Encoding", "identity"],
            ["Content-Type", "application/json"],
            ["X-Ergopti-Native-Session", "f" * 64],
            ["X-Ergopti-Native-Challenge", "e" * 64],
            ["X-Ergopti-Native-Body-SHA256", hashlib.sha256(body.encode()).hexdigest()],
            ["X-Ergopti-Native-Operation", "d" * 32],
        ]
        return self.api.open_request(
            "/private/verified/ollama",
            "123",
            "456",
            11434,
            dict(IDENTITY),
            "POST",
            "/api/pull",
            headers,
            body,
            2,
            1,
        )

    def test_discovery_line_and_public_argv_publish_only_reaped_identity(self):
        self.assertEqual(self.discover(), IDENTITY)
        observed = json.loads(self.receipt.read_text())
        self.assertTrue(observed["raw"].endswith("\n"))
        request = json.loads(observed["raw"])
        self.assertEqual(
            set(request), {"version", "executable", "device", "inode", "port", "timeout_ms"}
        )
        self.assertEqual(observed["argv"], ["--managed-ollama-listener-probe", "2000"])
        self.assertEqual(self.children[0].returncode, 0)

    def test_api_body_and_private_headers_require_terminal_identity_before_publication(self):
        with self.request() as response:
            self.assertEqual(response.status, 200)
            with self.assertRaises(self.api.ENGINE.NativeHTTPError):
                _ = response.listener
            self.assertEqual(response.read(), b'{"status":"success"}\n')
            self.assertEqual(response.read(), b"")
            self.assertEqual(response.listener, IDENTITY)
        observed = json.loads(self.receipt.read_text())
        self.assertNotIn("f" * 64, " ".join(observed["argv"]))
        self.assertEqual(observed["argv"], ["--managed-ollama-api-worker", "1000", "2000"])
        private = dict(json.loads(observed["raw"])["headers"])
        self.assertEqual(private["X-Ergopti-Native-Session"], "f" * 64)
        self.assertNotIn("Accept-Encoding", private)
        self.assertNotIn("Content-Type", private)

    def test_progressing_pull_preserves_idle_without_invented_absolute_budget(self):
        headers = [
            ["X-Ergopti-Native-Session", "f" * 64],
            ["X-Ergopti-Native-Challenge", "e" * 64],
            ["X-Ergopti-Native-Body-SHA256", hashlib.sha256(b"{}").hexdigest()],
            ["X-Ergopti-Native-Operation", "d" * 32],
        ]
        with self.api.open_request(
            "/private/verified/ollama",
            "123",
            "456",
            11434,
            dict(IDENTITY),
            "POST",
            "/api/pull",
            headers,
            "{}",
            None,
            1,
        ) as response:
            self.assertEqual(response.read(), b'{"status":"success"}\n')
            self.assertEqual(response.read(), b"")
        observed = json.loads(self.receipt.read_text())
        self.assertEqual(observed["argv"], ["--managed-ollama-api-worker", "1000", "none"])
        self.assertIsNone(json.loads(observed["raw"])["timeout_ms"])

    def test_pid_change_is_typed_admission_refusal_after_exact_child_retirement(self):
        os.environ["ERGOPTI_PEER_MODE"] = "pid_change"
        with self.request() as response:
            response.read()
            with self.assertRaises(self.api.NativeOllamaError) as raised:
                response.read()
            self.assertEqual(raised.exception.reason, "admission")
            self.assertFalse(response._complete)

    def test_native_admission_refusal_retains_closed_reason(self):
        os.environ["ERGOPTI_PEER_MODE"] = "admission"
        with self.assertRaises(self.api.NativeOllamaError) as raised:
            self.discover()
        self.assertEqual(raised.exception.reason, "admission")

    def test_invalid_identity_duplicate_trailing_and_exit_never_publish(self):
        for mode in ("boolean_pid", "noncanonical_start", "duplicate", "trailing", "exit"):
            with self.subTest(mode=mode):
                self.receipt.unlink(missing_ok=True)
                os.environ["ERGOPTI_PEER_MODE"] = mode
                with self.assertRaises(self.api.ENGINE.NativeHTTPError):
                    self.discover()

    def test_initial_deadline_reaps_actual_sleeping_peer(self):
        os.environ["ERGOPTI_PEER_MODE"] = "wait"
        with self.assertRaises(self.api.ENGINE.NativeHTTPError) as raised:
            self.api.discover("/private/verified/ollama", "123", "456", 11434, 1, 0.5)
        self.assertEqual(raised.exception.reason, "deadline")

    def test_incomplete_body_close_kills_and_waits_before_caller_can_restart(self):
        os.environ["ERGOPTI_PEER_MODE"] = "body_wait"
        with self.request() as response:
            self.assertEqual(response.read(), b'{"status":"success"}\n')
        self.assertIsNotNone(self.children[0].returncode)
        self.assertFalse(response._complete)

    def test_role_registers_before_selector_and_physically_closes_original_child(self):
        retained = []
        original_selector = self.api.ENGINE.selectors.DefaultSelector

        def selector():
            self.assertEqual(len(retained), 1)
            self.assertIsNone(retained[0]._selector)
            self.assertIsNone(retained[0]._process)
            return original_selector()

        def register(response):
            retained.append(response)
            return True

        with patch.object(self.api.ENGINE.selectors, "DefaultSelector", side_effect=selector):
            self.assertEqual(
                self.api.discover(
                    "/private/verified/ollama", "123", "456", 11434, 2, 1, register=register
                ),
                IDENTITY,
            )
        self.assertTrue(retained[0]._closed)
        self.assertEqual(retained[0]._process.returncode, 0)
        self.assertTrue(retained[0]._process.stdin.closed)
        self.assertTrue(retained[0]._process.stdout.closed)

    def test_registration_refusal_acquires_no_selector_or_process(self):
        retained = []

        def register(response):
            retained.append(response)
            return False

        with patch.object(self.api.ENGINE.selectors, "DefaultSelector") as selector:
            with self.assertRaises(self.api.ENGINE.NativeHTTPError):
                self.api.discover(
                    "/private/verified/ollama", "123", "456", 11434, 2, 1, register=register
                )
            selector.assert_not_called()
        self.assertEqual(len(retained), 1)
        self.assertTrue(retained[0]._closed)
        self.assertEqual(self.children, [])

    def test_expired_original_absolute_deadline_never_acquires_native_child(self):
        retained = []
        with patch.object(self.api.ENGINE.selectors, "DefaultSelector") as selector:
            with self.assertRaises(self.api.ENGINE.NativeHTTPError) as raised:
                self.api.discover(
                    "/private/verified/ollama",
                    "123",
                    "456",
                    11434,
                    2,
                    1,
                    register=lambda value: retained.append(value) is None,
                    absolute_deadline=1.0,
                )
            selector.assert_not_called()
        self.assertEqual(raised.exception.reason, "deadline")
        self.assertEqual(self.children, [])
        self.assertTrue(retained[0]._closed)

    def test_original_progress_refusal_retains_exact_exception_before_acquisition(self):
        primary = RuntimeError("independent cancellation identity")
        retained = []

        def progress():
            raise primary

        with patch.object(self.api.ENGINE.selectors, "DefaultSelector") as selector:
            with self.assertRaises(RuntimeError) as raised:
                self.api.discover(
                    "/private/verified/ollama",
                    "123",
                    "456",
                    11434,
                    2,
                    1,
                    register=lambda value: retained.append(value) is None,
                    absolute_deadline=1000000000000.0,
                    progress=progress,
                )
            selector.assert_not_called()
        self.assertIs(raised.exception, primary)
        self.assertEqual(self.children, [])
        self.assertTrue(retained[0]._closed)

    def test_registration_close_reentry_never_acquires_a_successor_child(self):
        retained = []

        def register(response):
            retained.append(response)
            response.close()
            return True

        try:
            with patch.object(
                self.api.ENGINE.selectors,
                "DefaultSelector",
                wraps=self.api.ENGINE.selectors.DefaultSelector,
            ) as selector:
                with self.assertRaises(self.api.ENGINE.NativeHTTPError):
                    self.api.discover(
                        "/private/verified/ollama", "123", "456", 11434, 2, 1, register=register
                    )
                selector.assert_not_called()
            self.assertEqual(len(retained), 1)
            self.assertTrue(retained[0]._closed)
            self.assertIsNone(retained[0]._selector)
            self.assertIsNone(retained[0]._process)
            self.assertEqual(self.children, [])
        finally:
            # The exact no-fence mutant can acquire after our close callback.
            # Cleanup uses only these fixture-owned resources; no retry against
            # an uncertain production close or guessed child identity occurs.
            for response in retained:
                if response._selector is not None:
                    response._selector.close()
                process = response._process
                if process is not None:
                    if process.poll() is None:
                        process.kill()
                    process.wait()
                    for stream in (process.stdin, process.stdout):
                        if stream is not None and not stream.closed:
                            stream.close()

    def test_progress_close_return_refuses_before_selector_or_child(self):
        retained = []

        def progress():
            retained[0].close()

        with patch.object(self.api.ENGINE.selectors, "DefaultSelector") as selector:
            with self.assertRaises(self.api.ENGINE.NativeHTTPError) as raised:
                self.api.discover(
                    "/private/verified/ollama",
                    "123",
                    "456",
                    11434,
                    2,
                    1,
                    register=lambda response: retained.append(response) is None,
                    progress=progress,
                )
            selector.assert_not_called()
        self.assertEqual(raised.exception.reason, "protocol")
        self.assertTrue(retained[0]._closed)
        self.assertIsNone(retained[0]._selector)
        self.assertIsNone(retained[0]._process)
        self.assertEqual(self.children, [])

    def test_resolution_source_withdrawal_refuses_before_child(self):
        retained, selectors = [], []
        primary = RuntimeError("independent post-resolution source withdrawal")
        state = {"withdrawn": False}
        original_selector = self.api.ENGINE.selectors.DefaultSelector

        def selector():
            owned = original_selector()
            selectors.append(owned)
            return owned

        def resolve():
            state["withdrawn"] = True
            return str(self.peer)

        def progress():
            if state["withdrawn"]:
                raise primary

        with patch.object(self.api.ENGINE, "_resolve_worker", side_effect=resolve):
            with patch.object(self.api.ENGINE.selectors, "DefaultSelector", side_effect=selector):
                with self.assertRaises(RuntimeError) as raised:
                    self.api.discover(
                        "/private/verified/ollama",
                        "123",
                        "456",
                        11434,
                        2,
                        1,
                        register=lambda response: retained.append(response) is None,
                        progress=progress,
                    )
        self.assertIs(raised.exception, primary)
        self.assertTrue(state["withdrawn"])
        self.assertEqual(len(selectors), 1)
        self.assertIs(retained[0]._selector, selectors[0])
        self.assertIsNone(selectors[0].get_map())
        self.assertTrue(retained[0]._closed)
        self.assertIsNone(retained[0]._process)
        self.assertEqual(self.children, [])

    def test_post_resolution_progress_close_refuses_successor_process(self):
        retained = []
        state = {"resolved": False}

        def resolve():
            state["resolved"] = True
            return str(self.peer)

        def progress():
            if state["resolved"]:
                retained[0].close()

        with patch.object(self.api.ENGINE, "_resolve_worker", side_effect=resolve):
            with self.assertRaises(self.api.ENGINE.NativeHTTPError) as raised:
                self.api.discover(
                    "/private/verified/ollama",
                    "123",
                    "456",
                    11434,
                    2,
                    1,
                    register=lambda response: retained.append(response) is None,
                    progress=progress,
                )
        self.assertEqual(raised.exception.reason, "protocol")
        self.assertTrue(retained[0]._closed)
        self.assertIsNone(retained[0]._selector.get_map())
        self.assertIsNone(retained[0]._process)
        self.assertEqual(self.children, [])

    def test_real_child_then_constructor_error_retains_and_reaps_exact_child(self):
        retained, created = [], []
        primary = RuntimeError("independent after-real-child construction failure")
        original = self.original_popen
        fixture_children = self.children

        class InterruptedPopen(original):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                created.append(self)
                fixture_children.append(self)
                self.assert_retained = retained[0]._process is self
                raise primary

        with patch.object(self.api.ENGINE, "_ROLE_POPEN", InterruptedPopen):
            with self.assertRaises(RuntimeError) as raised:
                self.api.discover(
                    "/private/verified/ollama",
                    "123",
                    "456",
                    11434,
                    2,
                    1,
                    register=lambda response: retained.append(response) is None,
                )
        self.assertIs(raised.exception, primary)
        self.assertEqual(len(created), 1)
        self.assertTrue(created[0].assert_retained)
        self.assertIs(retained[0]._process, created[0])
        self.assertTrue(created[0]._child_created)
        self.assertIsNotNone(created[0].poll())
        self.assertEqual(created[0].wait(), created[0].returncode)
        self.assertTrue(created[0].stdin.closed)
        self.assertTrue(created[0].stdout.closed)
        self.assertTrue(retained[0]._closed)

    def test_incomplete_constructor_without_child_retains_unknown_debt_and_primary(self):
        retained, allocated = [], []
        primary = RuntimeError("independent pre-child construction failure")
        original = self.original_popen

        class IncompletePopen(original):
            def __init__(self, *args, **kwargs):
                allocated.append(self)
                raise primary

        with patch.object(self.api.ENGINE, "_ROLE_POPEN", IncompletePopen):
            with self.assertRaises(RuntimeError) as raised:
                self.api.discover(
                    "/private/verified/ollama",
                    "123",
                    "456",
                    11434,
                    2,
                    1,
                    register=lambda response: retained.append(response) is None,
                )
        self.assertIs(raised.exception, primary)
        self.assertEqual(len(allocated), 1)
        self.assertIs(retained[0]._process, allocated[0])
        self.assertFalse(getattr(allocated[0], "_child_created", False))
        self.assertFalse(retained[0]._closed)
        self.assertIsNone(retained[0]._selector.get_map())
        self.assertEqual(self.children, [])
        with self.assertRaises(self.api.ENGINE.NativeHTTPError) as refused:
            retained[0].close()
        self.assertEqual(refused.exception.reason, "unavailable")
        self.assertFalse(retained[0]._closed)

    def test_pre_acquire_close_return_refuses_without_successor_child(self):
        retained, calls = [], []

        def pre_acquire():
            calls.append(retained[0])
            retained[0].close()

        with self.assertRaises(self.api.ENGINE.NativeHTTPError) as raised:
            self.api.discover(
                "/private/verified/ollama",
                "123",
                "456",
                11434,
                2,
                1,
                register=lambda response: retained.append(response) is None,
                pre_acquire=pre_acquire,
            )
        self.assertEqual(raised.exception.reason, "protocol")
        self.assertEqual(calls, retained)
        self.assertTrue(retained[0]._closed)
        self.assertIsNone(retained[0]._selector.get_map())
        self.assertIsNone(retained[0]._process)
        self.assertEqual(self.children, [])

    def test_pre_acquire_runs_once_before_real_child_not_during_reads(self):
        retained, calls = [], []

        def pre_acquire():
            self.assertIsNone(retained[0]._process)
            self.assertFalse(retained[0]._closed)
            calls.append(retained[0])

        self.assertEqual(
            self.api.discover(
                "/private/verified/ollama",
                "123",
                "456",
                11434,
                2,
                1,
                register=lambda response: retained.append(response) is None,
                pre_acquire=pre_acquire,
            ),
            IDENTITY,
        )
        self.assertEqual(calls, retained)
        self.assertEqual(len(calls), 1)
        self.assertEqual(retained[0]._process.returncode, 0)
        self.assertTrue(retained[0]._process.stdin.closed)
        self.assertTrue(retained[0]._process.stdout.closed)
        self.assertTrue(retained[0]._closed)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, default=ENGINE)
    options, remaining = parser.parse_known_args()
    ENGINE = options.engine.resolve(strict=True)
    unittest.main(argv=[__file__, *remaining])
