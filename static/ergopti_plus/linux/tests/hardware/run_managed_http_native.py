#!/usr/bin/env python3
# tests/hardware/run_managed_http_native.py
"""Prove source-admitted public HTTP routing with owned native fixtures."""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import http.server
import json
import hashlib
import os
from pathlib import Path
import re
import select
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest


LEGACY_CURL = "/usr/bin/curl"
LEGACY_CURL_ENVIRONMENT = {"PATH": "/usr/bin:/bin"}


class ProxyServer(http.server.ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self):
        super().__init__(("127.0.0.1", 0), ProxyHandler)
        self.targets = []


class OriginServer(ProxyServer):
    def __init__(self, address):
        http.server.ThreadingHTTPServer.__init__(self, (address, 0), ProxyHandler)
        self.targets = []


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_CONNECT(self):
        self.server.targets.append(self.path)
        code = 407 if self.path.startswith("auth.") else 403
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def reply(self):
        self.server.targets.append(self.path)
        if "/argv-hold" in self.path:
            time.sleep(0.5)
        if self.command == "POST":
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
        code = 403 if "/origin-denial" in self.path else 200
        body = b'{"accepted":true}\n'
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    do_GET = reply
    do_POST = reply


class PacServer(http.server.ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self, proxy_port, refused_port):
        super().__init__(("127.0.0.1", 0), PacHandler)
        self.proxy_port, self.refused_port = proxy_port, refused_port
        self.paths = []
        self.slow_entered = threading.Event()


class PacHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.paths.append(self.path)
        if self.path == "/slow.pac":
            self.server.slow_entered.set()
            time.sleep(3)
        if self.path == "/direct.pac":
            selection = "DIRECT"
        elif self.path == "/relay.pac":
            selection = f"PROXY 127.0.0.1:{self.server.refused_port}; PROXY 127.0.0.1:{self.server.proxy_port}; DIRECT"
        else:
            selection = f"PROXY 127.0.0.1:{self.server.proxy_port}"
        body = ('function FindProxyForURL(url, host) { return "' + selection + '"; }').encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ns-proxy-autoconfig")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(body)


class PrivateBus:
    """Own one private bus and retire only its proven PACRunner process."""

    def __init__(self, root, env):
        self.root, self.env = root, env
        # AF_UNIX paths are bounded by the kernel; descriptive test names stay
        # in the settings directory rather than extending the native address.
        self.busroot = Path(tempfile.mkdtemp(prefix="bus-", dir=root.parent))
        self.process = subprocess.Popen(
            [
                "dbus-daemon",
                "--session",
                "--nofork",
                "--print-address=1",
                f"--address=unix:path={self.busroot / 'socket'}",
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        readable, _, _ = select.select([self.process.stdout], [], [], 2)
        self.address = self.process.stdout.readline().strip() if readable else ""
        if not self.address.startswith("unix:path="):
            self.process.kill()
            self.process.wait(2)
            self.process.stdout.close()
            self.process.stderr.close()
            shutil.rmtree(self.busroot)
            raise RuntimeError("Private D-Bus did not acknowledge its owned address")

    def close(self):
        primary_failed = False
        try:
            reply = subprocess.run(
                [
                    "dbus-send",
                    f"--bus={self.address}",
                    "--print-reply",
                    "--dest=org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus.GetConnectionUnixProcessID",
                    "string:org.gtk.GLib.PACRunner",
                ],
                capture_output=True,
                text=True,
                timeout=3,
            )
            match = re.search(r"uint32 (\d+)", reply.stdout) if reply.returncode == 0 else None
            if match:
                pid = int(match[1])
                native = Path(f"/proc/{pid}")
                process_fd = None
                try:
                    process_fd = os.pidfd_open(pid)
                    executable = (native / "exe").resolve(strict=True)
                    environment = (native / "environ").read_bytes().split(b"\0")
                except ProcessLookupError:
                    executable, environment = None, []
                except FileNotFoundError:
                    executable, environment = None, []
                ownership = any(
                    value
                    in {
                        f"DBUS_SESSION_BUS_ADDRESS={self.address}".encode(),
                        f"DBUS_STARTER_ADDRESS={self.address}".encode(),
                    }
                    for value in environment
                )
                try:
                    if executable is not None:
                        if executable != Path("/usr/libexec/glib-pacrunner") or not ownership:
                            raise RuntimeError(
                                "Private PACRunner ownership is unproved; fixture retained"
                            )
                        # The kernel descriptor pins identity even if the numeric PID
                        # is recycled between the ownership read and termination.
                        signal.pidfd_send_signal(process_fd, signal.SIGTERM)
                        retired, _, _ = select.select([process_fd], [], [], 2)
                        if not retired:
                            raise RuntimeError(
                                "Private PACRunner retirement is unacknowledged; fixture retained"
                            )
                finally:
                    if process_fd is not None:
                        os.close(process_fd)
        except BaseException:
            primary_failed = True
            raise
        finally:
            try:
                self.process.terminate()
                try:
                    self.process.wait(3)
                except subprocess.TimeoutExpired:
                    # Popen still owns this unreaped child; never signal a guessed
                    # descendant or numeric process group.
                    self.process.kill()
                    self.process.wait(3)
            finally:
                self.process.stdout.close()
                self.process.stderr.close()
            if not primary_failed:
                shutil.rmtree(self.busroot)
            else:
                (self.busroot / "RETIREMENT-REFUSAL.json").write_text(
                    json.dumps(
                        {
                            "pac_retirement": "unproven-or-unretired",
                            "owned_dbus_retirement": "acknowledged",
                        }
                    )
                    + "\n"
                )


def stage_tree(temp):
    """Copy exact immutable dependencies and one manifest-bound producer."""
    manifest = COMPOSITION / "FINAL-SOURCE-MANIFEST.json"
    if hashlib.sha256(manifest.read_bytes()).hexdigest() != EXPECTED_MANIFEST:
        raise RuntimeError("Final composition source freeze changed")
    entries = json.loads(manifest.read_text())["files"]
    base = temp / "ergopti_plus"
    immutable = REPOSITORY / "static/ergopti_plus"
    receipt = json.loads((REPOSITORY / "SOURCE-RECEIPT.json").read_text())
    if (
        receipt["dependency_commit"] != EXPECTED_DEPENDENCY_COMMIT
        or receipt["phase"] != EXPECTED_DEPENDENCY_PHASE
    ):
        raise RuntimeError("Exact original published dependency tree is required")
    inventory_bytes = DEPENDENCY_INVENTORY.read_bytes()
    if hashlib.sha256(inventory_bytes).hexdigest() != EXPECTED_INVENTORY_SHA256:
        raise RuntimeError("Exact dependency inventory source freeze changed")
    inventory = json.loads(inventory_bytes)
    if inventory["commit"] != receipt["dependency_commit"]:
        raise RuntimeError("Published dependency inventory differs")
    declared = set()
    for entry in inventory["entries"]:
        path = REPOSITORY / entry["path"]
        declared.add(path.relative_to(immutable).as_posix())
        if entry["kind"] == "symlink":
            if not path.is_symlink() or os.readlink(path) != entry["target"]:
                raise RuntimeError("Published dependency symlink changed")
        elif path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise RuntimeError("Published dependency bytes changed")
    actual = {
        path.relative_to(immutable).as_posix()
        for path in immutable.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    if actual != declared:
        raise RuntimeError("Published dependency inventory changed")
    shutil.copytree(immutable, base, symlinks=False)
    copied_actual = {
        path.relative_to(base).as_posix()
        for path in base.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    if copied_actual != declared:
        raise RuntimeError("Copied dependency inventory changed")
    for entry in inventory["entries"]:
        copied = base / (REPOSITORY / entry["path"]).relative_to(immutable)
        if entry["kind"] == "symlink":
            raise RuntimeError("Normal native snapshot does not admit dependency symlinks")
        if (
            copied.is_symlink()
            or not copied.is_file()
            or hashlib.sha256(copied.read_bytes()).hexdigest() != entry["sha256"]
        ):
            raise RuntimeError("Copied dependency bytes changed")
    for entry in entries:
        if entry["path"].startswith("candidate/"):
            path = COMPOSITION / entry["path"]
            if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
                raise RuntimeError("Manifest-bound production source changed")
            relative = path.relative_to(COMPOSITION / "candidate/static/ergopti_plus")
            target = base / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
    if (
        hashlib.sha256((base / "linux/adapters/curl_http_client.lua").read_bytes()).hexdigest()
        != EXPECTED_NATIVE_SHA256
    ):
        raise RuntimeError("Sole reviewed native engine is required")
    return base / "linux"


class NativePublicControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Descendants orphaned by a deliberately cancelled helper remain owned by
        # this fixture rather than leaking to an unrelated container init process.
        native = ctypes.CDLL(None, use_errno=True)
        native.prctl.argtypes = [
            ctypes.c_int,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
        ]
        native.prctl.restype = ctypes.c_int
        if native.prctl(36, 1, 0, 0, 0) != 0:
            raise RuntimeError("Native PR_SET_CHILD_SUBREAPER is required")
        cls.luajit = shutil.which("luajit")
        if not cls.luajit:
            raise RuntimeError("Actual LuaJIT is required")
        cls.root = Path(tempfile.mkdtemp(prefix="ergopti-managed-http-"))
        cls.retain_fixture = False
        cls.threads = []
        cls.started_servers = []
        cls.resources_closed = False
        try:
            cls.driver = stage_tree(cls.root)
            cls.proxy = ProxyServer()
            addresses = socket.getaddrinfo(
                socket.gethostname(), None, socket.AF_INET, socket.SOCK_STREAM
            )
            local_address = next(
                (entry[4][0] for entry in addresses if not entry[4][0].startswith("127.")), None
            )
            if not local_address:
                raise RuntimeError(
                    "A locally assigned non-loopback IPv4 address is required for actual PAC DIRECT qualification"
                )
            cls.origin = OriginServer(local_address)
            cls.origin_address = local_address
            with socket.socket() as vacant:
                vacant.bind(("127.0.0.1", 0))
                refused = vacant.getsockname()[1]
            cls.pac = PacServer(cls.proxy.server_port, refused)
            cls.threads = []
            for server in (cls.proxy, cls.pac, cls.origin):
                thread = threading.Thread(target=server.serve_forever)
                thread.start()
                cls.threads.append(thread)
                cls.started_servers.append(server)
        except BaseException:
            cls.retain_fixture = True
            cls.tearDownClass()
            raise

    @classmethod
    def tearDownClass(cls):
        for name in ("proxy", "pac", "origin"):
            server = getattr(cls, name, None)
            if server is not None:
                if server in cls.started_servers:
                    server.shutdown()
                server.server_close()
        for thread in cls.threads:
            thread.join(2)
            if thread.is_alive():
                cls.retain_fixture = True
                raise RuntimeError("Owned fixture server thread has not retired")
        while True:
            try:
                child, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if child == 0:
                cls.retain_fixture = True
                raise RuntimeError("Owned fixture descendant has not retired")
        if not cls.retain_fixture:
            shutil.rmtree(cls.root)
        cls.resources_closed = True

    def environment(self, config):
        env = os.environ.copy()
        for key in tuple(env):
            if key.lower().endswith("_proxy") or key in {
                "PX_DEBUG",
                "G_MESSAGES_DEBUG",
                "GIO_USE_PROXY_RESOLVER",
            }:
                env.pop(key)
        env.update(
            XDG_CONFIG_HOME=str(config),
            XDG_CACHE_HOME=str(config / "cache"),
            XDG_CURRENT_DESKTOP="GNOME",
            GSETTINGS_BACKEND="keyfile",
            ERGOPTI_HTTP_STAGE=str(self.driver),
            ERGOPTI_HTTP_REPOSITORY=str(REPOSITORY),
        )
        return env

    def invoke(
        self,
        mode="manual",
        method="get_owned",
        url=None,
        pac_name=None,
        cancel=False,
        env_proxy=False,
        dummy=False,
        extra_environment=None,
        timeout_ms=None,
        fixture_error=False,
        inspect_argv=False,
    ):
        config = self.root / self._testMethodName
        settings = config / "glib-2.0/settings/keyfile"
        settings.parent.mkdir(parents=True, exist_ok=True)
        if mode == "auto":
            settings.write_text(
                "[system/proxy]\nmode='auto'\n"
                f"autoconfig-url='http://127.0.0.1:{self.pac.server_port}/{pac_name}.pac'\n",
                encoding="utf-8",
            )
        else:
            settings.write_text(
                "[system/proxy]\nmode='manual'\nuse-same-proxy=true\n"
                f"[system/proxy/http]\nhost='127.0.0.1'\nport={self.proxy.server_port}\n",
                encoding="utf-8",
            )
        env = self.environment(config)
        bus = None
        if mode == "auto":
            bus = PrivateBus(config, env)
            env["DBUS_SESSION_BUS_ADDRESS"] = bus.address
        if env_proxy:
            env["https_proxy"] = f"http://127.0.0.1:{self.proxy.server_port}"
        if dummy:
            env["GIO_USE_PROXY_RESOLVER"] = "dummy"
        if extra_environment:
            env.update(extra_environment)
        if fixture_error:
            env.update(
                GIO_USE_PROXY_RESOLVER="ergopti-native-error", GIO_EXTRA_MODULES=str(ERROR_MODULE)
            )
        request = {
            "url": url or "http://corporate.invalid/private?token=private-token",
            "method": method,
            "cancel": cancel,
            "timeout_ms": timeout_ms,
            "inspect_argv": inspect_argv,
            "destination": str(config / "download.part"),
        }
        try:
            # File-backed private sinks remain valid if exact native debt needs
            # a retained Lua guardian after the ordinary observation timeout.
            with (
                tempfile.NamedTemporaryFile(
                    prefix="native-out-", dir=self.root, delete=False
                ) as output,
                tempfile.NamedTemporaryFile(
                    prefix="native-err-", dir=self.root, delete=False
                ) as errors,
            ):
                process = subprocess.Popen(
                    [self.luajit, str(CONTROL)],
                    env=env,
                    stdin=subprocess.PIPE,
                    stdout=output,
                    stderr=errors,
                    text=True,
                    start_new_session=True,
                )
                parent_fd = os.pidfd_open(process.pid)
                try:
                    try:
                        process.communicate(json.dumps(request), timeout=8)
                    except (subprocess.TimeoutExpired, KeyboardInterrupt) as interruption:
                        type(self).retain_fixture = True
                        # Signal only the kernel-pinned actual Lua child. Its
                        # guardian retries the production tokens it observed;
                        # no PID/PGID reconstruction or substitute kill occurs.
                        signal.pidfd_send_signal(parent_fd, signal.SIGUSR1)
                        try:
                            process.communicate(timeout=3)
                        except subprocess.TimeoutExpired:
                            (self.root / "RETAINED-GUARDIAN.json").write_text(
                                json.dumps(
                                    {
                                        "state": "failed-unretired",
                                        "pid": process.pid,
                                        "source": "owned Popen child; native tokens retained in live Lua guardian",
                                        "automatic_pid_based_cleanup": False,
                                    }
                                )
                                + "\n"
                            )
                            raise AssertionError(
                                "Exact native debt retained by live owned guardian; fixture retained"
                            )
                        if isinstance(interruption, KeyboardInterrupt):
                            raise interruption
                        raise AssertionError(
                            "Native observation timed out; owned cleanup completed but acceptance failed"
                        )
                    completed = subprocess.CompletedProcess(
                        process.args,
                        process.returncode,
                        Path(output.name).read_text(),
                        Path(errors.name).read_text(),
                    )
                finally:
                    os.close(parent_fd)
            if completed.returncode:
                # Raw child diagnostics remain in private logs only; emit no URL,
                # path, native exception or dummy credential in public reports.
                private = self.root / (self._testMethodName + ".private-child-log")
                private.write_text(completed.stdout + completed.stderr)
                type(self).retain_fixture = True
                raise AssertionError(
                    "Actual staged HTTP control failed; private child log retained"
                )
            for marker in ("private-native-error-vector", "private-user", "private-proxy-vector"):
                self.assertFalse(
                    marker in completed.stdout + completed.stderr,
                    "Private fixed marker escaped native output",
                )
            self.assertNotIn("private-token", completed.stdout + completed.stderr)
            self.assertNotIn("private-header-vector", completed.stdout + completed.stderr)
            self.assertNotIn("private-body-vector", completed.stdout + completed.stderr)
            packet = next(
                line
                for line in completed.stdout.splitlines()
                if line.startswith("ERGOPTI_PUBLIC_HTTP_RESULT:")
            )
            return json.loads(packet.split(":", 1)[1]), config
        finally:
            if bus:
                try:
                    bus.close()
                except Exception:
                    type(self).retain_fixture = True
                    raise

    def test_actual_gnome_proxy_reaches_public_get_owned(self):
        receipt, _ = self.invoke()
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["status"], 200)
        self.assertEqual(receipt["process_count"], 2)
        self.assertEqual(receipt["selection_receipt"]["native_backend"], "GProxyResolverGnome")

    def test_actual_public_post_and_stream_reach_desktop_proxy(self):
        for method in ("post", "stream"):
            receipt, _ = self.invoke(method=method)
            self.assertTrue(receipt["ok"])
            self.assertEqual(receipt["completion_count"], 1)
            if method == "stream":
                self.assertGreater(receipt["chunk_count"], 0)

    def test_actual_public_download_uses_system_proxy_and_owned_destination(self):
        receipt, config = self.invoke(method="download")
        self.assertTrue(receipt["ok"])
        self.assertEqual((config / "download.part").read_bytes(), b'{"accepted":true}\n')

    def test_actual_origin403_remains_http_unknown_source(self):
        receipt, _ = self.invoke(url="http://corporate.invalid/origin-denial")
        self.assertFalse(receipt["ok"])
        failure = receipt["failure_receipt"]
        self.assertEqual(failure["stage"], "http")
        self.assertEqual(failure["http_status"], 403)
        self.assertEqual(failure["proxy_connect_status"], 0)
        self.assertNotIn("http_response_source", failure)

    def test_actual_connect407_and403_have_distinct_native_receipts(self):
        for host, expected in (("auth", 407), ("denied", 403)):
            receipt, _ = self.invoke(
                url=f"https://{host}.corporate.invalid/private?token=private-token"
            )
            self.assertFalse(receipt["ok"])
            failure = receipt["failure_receipt"]
            self.assertEqual(failure["stage"], "proxy_connect")
            self.assertEqual(failure["proxy_connect_status"], expected)
            self.assertEqual(failure["failure_provenance"], "verified")
            self.assertEqual(failure["http_status"], 0)

    def test_actual_loopback_fast_path_bypasses_pac(self):
        receipt, _ = self.invoke(
            mode="auto", pac_name="direct", url=f"http://127.0.0.1:{self.proxy.server_port}/private"
        )
        # Explicit localhost routing must remain DIRECT without invoking PAC.
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["process_count"], 1)

    def test_actual_valid_pac_direct_remains_usable(self):
        receipt, _ = self.invoke(
            mode="auto",
            pac_name="direct",
            url=f"http://{self.origin_address}:{self.origin.server_port}/private",
        )
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["process_count"], 2)
        self.assertEqual(receipt["selection_receipt"]["proxy_resolution_status"], "direct")
        self.assertIn("/direct.pac", self.pac.paths)

    def test_actual_pac_ordered_relay_waits_and_reaches_second_proxy(self):
        receipt, _ = self.invoke(mode="auto", pac_name="relay")
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["status"], 200)
        self.assertEqual(receipt["process_count"], 3)
        self.assertIn("/relay.pac", self.pac.paths)

    def test_actual_cancellation_fences_slow_native_pac_and_retires_owned_children(self):
        self.pac.slow_entered.clear()
        receipt, _ = self.invoke(mode="auto", pac_name="slow", cancel=True)
        self.assertEqual(receipt["completion_count"], 0)
        self.assertTrue(self.pac.slow_entered.is_set())

    def test_actual_dummy_capability_does_not_disable_plain_network(self):
        receipt, _ = self.invoke(
            dummy=True, url=f"http://{self.origin_address}:{self.origin.server_port}/private"
        )
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["process_count"], 2)
        self.assertEqual(receipt["selection_receipt"]["proxy_resolution_status"], "unavailable")

    def test_actual_dummy_proxy_credentials_remain_outside_native_argv_and_reports(self):
        receipt, _ = self.invoke(
            url="http://corporate.invalid/argv-hold?token=private-token",
            inspect_argv=True,
            extra_environment={
                "http_proxy": f"http://private-user:private-proxy-vector@127.0.0.1:{self.proxy.server_port}",
            },
        )
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["process_count"], 1)
        self.assertGreaterEqual(receipt["argv_observations"], 1)

    def test_actual_environment_http_proxy_precedes_system_with_no_lookup(self):
        receipt, _ = self.invoke(
            extra_environment={
                "http_proxy": f"http://127.0.0.1:{self.proxy.server_port}",
            }
        )
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["process_count"], 1)
        self.assertEqual(receipt["status"], 200)
        self.assertNotIn("native_backend", receipt.get("selection_receipt") or {})

    def test_actual_explicit_direct_disables_inherited_proxy(self):
        receipt, _ = self.invoke(
            url=f"http://127.0.0.1:{self.proxy.server_port}/private",
            extra_environment={
                "http_proxy": "http://127.0.0.1:1",
                "ALL_PROXY": "http://127.0.0.1:1",
                "NO_PROXY": "",
            },
        )
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["process_count"], 1)
        self.assertEqual(receipt["status"], 200)

    def test_actual_selected_system_proxy_preserves_no_proxy(self):
        before = len(self.proxy.targets)
        receipt, _ = self.invoke(
            url=f"http://{self.origin_address}:{self.origin.server_port}/private",
            extra_environment={
                "NO_PROXY": self.origin_address,
            },
        )
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["process_count"], 2)
        self.assertEqual(receipt["selection_receipt"]["proxy_resolution_status"], "selected")
        self.assertEqual(len(self.proxy.targets), before)
        # Selection cannot manufacture actual transport use. Missing capability
        # is honest; if the admitted native variable is observed it must be false.
        self.assertNotEqual(receipt.get("proxy_used"), True)

    def test_actual_native_supported_gio_error_refuses_without_network_fallback(self):
        before_proxy, before_origin = len(self.proxy.targets), len(self.origin.targets)
        receipt, _ = self.invoke(
            fixture_error=True,
            url=f"http://{self.origin_address}:{self.origin.server_port}/private",
        )
        self.assertFalse(receipt["ok"])
        self.assertEqual(receipt["process_count"], 1)
        self.assertEqual(receipt["status"], 0)
        self.assertEqual(receipt["failure_receipt"]["backend"], "gio")
        self.assertEqual(receipt["failure_receipt"]["stage"], "proxy_resolve")
        self.assertEqual(receipt["failure_receipt"]["failure_provenance"], "unknown")
        self.assertEqual(len(self.proxy.targets), before_proxy)
        self.assertEqual(len(self.origin.targets), before_origin)

    def test_actual_parent_budget_spans_native_lookup_and_physical_retirement(self):
        before = len(self.proxy.targets)
        self.pac.slow_entered.clear()
        receipt, _ = self.invoke(mode="auto", pac_name="slow", timeout_ms=350)
        self.assertFalse(receipt["ok"])
        self.assertEqual(receipt["error"], "timeout")
        self.assertEqual(receipt["completion_count"], 1)
        self.assertEqual(receipt["process_count"], 1)
        self.assertTrue(self.pac.slow_entered.is_set())
        self.assertLess(receipt["elapsed_ms"], 1500)
        self.assertEqual(len(self.proxy.targets), before)

    def test_actual_older_native_curl_does_not_request_or_publish_new_metric(self):
        legacy = subprocess.run(
            [LEGACY_CURL, "--disable", "--version"],
            env=dict(os.environ, **LEGACY_CURL_ENVIRONMENT),
            capture_output=True,
            text=True,
            timeout=3,
        )
        version = re.match(r"curl (\d+)\.(\d+)\.", legacy.stdout)
        self.assertEqual(legacy.returncode, 0)
        self.assertIsNotNone(version, "Actual legacy native curl prerequisite is unavailable")
        self.assertLess(
            tuple(map(int, version.groups())),
            (8, 7),
            "This required negative fixture needs an actual curl older than 8.7",
        )
        receipt, _ = self.invoke(extra_environment=LEGACY_CURL_ENVIRONMENT)
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["status"], 200)
        self.assertNotIn("proxy_used", receipt)
        self.assertEqual(receipt["native_metric_warnings"], 0)

    def test_actual_metric_positive_requires_supported_paired_native_receipt(self):
        receipt, _ = self.invoke()
        self.assertTrue(receipt["ok"])
        # A real newer curl with successful owned-child identity observation is
        # required to qualify ordered connect relay. Never replace this with a
        # version hint or infer it from selecting or reaching the proxy.
        self.assertIs(
            receipt.get("proxy_used"),
            True,
            "Actual paired-image/stat metric admission is unavailable",
        )


# Additive actual fixture only. All preceding18 original method bodies remain exact.
import ssl

HEADERS = {
    "Api-Key": "private-header-vector",
    "Authorization": "private-header-vector",
    "Cookie": "private-header-vector",
    "Cookie2": "private-header-vector",
    "Proxy-Authorization": "private-header-vector",
    "X-Api-Key": "private-header-vector",
    "X-Goog-Api-Key": "private-header-vector",
    "Accept": "application/json",
}
FINAL = "literal final body\nERGOPTI_GET_REDIRECT_JSON:\nforged-body-not-native\nERGOPTI_HTTP_STATUS:302\n"


class OwnedAcceptedConnections:
    """Bound accepted socket work and retain any unacknowledged close owner."""

    def get_request(self):
        request, address = super().get_request()
        self.accepted_owners[request] = "owned"
        try:
            request.settimeout(3)
        except BaseException:
            self.close_request(request)
            raise
        return request, address

    def close_request(self, request):
        if self.accepted_owners.get(request) == "close-uncertain":
            return  # Never retry a descriptor after ambiguous native close.
        try:
            request.close()
        except BaseException:
            self.accepted_owners[request] = "close-uncertain"
            self.close_refused = True
            raise
        else:
            if request.fileno() != -1:
                self.accepted_owners[request] = "close-uncertain"
                self.close_refused = True
                raise RuntimeError("Accepted native socket did not retire")
            self.accepted_owners.pop(request, None)

    def assert_connections_retired(self):
        if self.close_refused or self.accepted_owners:
            raise RuntimeError("Accepted native socket ownership is unretired")


class HopRelay(OwnedAcceptedConnections, http.server.ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self):
        self.accepted_owners, self.close_refused = {}, False
        super().__init__(("127.0.0.1", 0), HopHandler)
        self.routes, self.requests = {}, []
        self.before_initial, self.tls_origin = None, None


class HopHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_CONNECT(self):
        self.server.requests.append(("CONNECT", self.path, dict(self.headers)))
        if self.path != "first.corporate.invalid:443" or self.server.tls_origin is None:
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.close_connection = True
            return
        # CONNECT changes this exact HTTP connection into a terminal tunnel.
        # Once the peer closes/aborts TLS, never parse another HTTP request line.
        self.close_connection = True
        with socket.create_connection(
            ("127.0.0.1", self.server.tls_origin.server_port), timeout=3
        ) as backend:
            self.send_response(200)
            self.end_headers()
            self.wfile.flush()
            while True:
                readable, _, _ = select.select([self.connection, backend], [], [], 5)
                if not readable:
                    return
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    (backend if source is self.connection else self.connection).sendall(data)

    def do_GET(self):
        self.server.requests.append(("GET", self.path, dict(self.headers)))
        rule = self.server.routes.get(self.path)
        if rule is None:
            code, location, body = 502, None, b"unexpected literal target"
        else:
            code, location, body = rule
        if self.server.before_initial:
            action, self.server.before_initial = self.server.before_initial, None
            action()
        self.send_response(code)
        if location is not None:
            self.send_header("Location", location)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True


class HopPac(OwnedAcceptedConnections, http.server.ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self):
        self.accepted_owners, self.close_refused = {}, False
        super().__init__(("127.0.0.1", 0), HopPacHandler)
        self.program, self.paths = b"", []
        self.slow_entered = threading.Event()


class HopPacHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.paths.append(self.path)
        if self.path == "/slow.pac":
            self.server.slow_entered.set()
            time.sleep(3)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ns-proxy-autoconfig")
        self.send_header("Content-Length", str(len(self.server.program)))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(self.server.program)


class TLSHop(OwnedAcceptedConnections, http.server.ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self):
        self.accepted_owners, self.close_refused = {}, False
        super().__init__(("127.0.0.1", 0), TLSHopHandler)
        self.requests = []

    def get_request(self):
        raw, address = super().get_request()
        wrapped = None
        try:
            wrapped = self.context.wrap_socket(raw, server_side=True, do_handshake_on_connect=False)
            self.accepted_owners[wrapped] = "owned"
            self.accepted_owners.pop(raw, None)  # Exact Python socket ownership transfer.
            wrapped.settimeout(3)
            wrapped.do_handshake()
            return wrapped, address
        except BaseException:
            if wrapped is not None:
                self.close_request(wrapped)
            elif raw.fileno() != -1:
                self.close_request(raw)
            else:
                # Constructor detached the original object without returning an
                # observable wrapper: physical absence cannot be acknowledged.
                self.accepted_owners[raw] = "close-uncertain"
                self.close_refused = True
            raise

    def handle_error(self, request, client_address):
        # Controlled failed-trust handshake diagnostics stay private fixture state.
        pass


class TLSHopHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.requests.append((self.path, dict(self.headers)))
        self.send_response(302)
        self.send_header("Location", "http://cdn.corporate.invalid/final?part=two")
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True


class PerHopControls(unittest.TestCase):
    environment = NativePublicControls.environment

    @classmethod
    def setUpClass(cls):
        cls.extra_servers, cls.extra_threads, cls.extra_retirement = [], [], {}
        cls.base_teardown_attempted = False
        NativePublicControls.setUpClass.__func__(cls)
        try:
            for name, factory in (
                ("relay_a", HopRelay),
                ("relay_b", HopRelay),
                ("hop_pac", HopPac),
                ("tls", TLSHop),
            ):
                server = factory()
                cls.extra_servers.append(
                    server
                )  # Register each socket owner before next acquisition.
                setattr(cls, name, server)
            cls.ca = cls.root / "controlled-ca.pem"
            cls.key = cls.root / "controlled-key.pem"
            with (cls.root / "certificate.private-log").open("wb") as log:
                actual = subprocess.run(
                    [
                        "openssl",
                        "req",
                        "-x509",
                        "-newkey",
                        "rsa:2048",
                        "-nodes",
                        "-keyout",
                        str(cls.key),
                        "-out",
                        str(cls.ca),
                        "-days",
                        "2",
                        "-subj",
                        "/CN=first.corporate.invalid",
                        "-addext",
                        "subjectAltName=DNS:first.corporate.invalid",
                    ],
                    stdout=log,
                    stderr=log,
                    timeout=10,
                )
            if actual.returncode != 0:
                raise RuntimeError("Controlled native TLS certificate creation refused")
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cls.ca, cls.key)
            cls.tls.context = context  # Handshake happens only on a bounded accepted owner.
            cls.relay_a.tls_origin = cls.tls
            for server in cls.extra_servers:
                thread = threading.Thread(target=server.serve_forever)
                cls.extra_threads.append(
                    (server, thread)
                )  # Independent new-owner ledger, including unstarted objects.
                cls.extra_retirement[server] = {
                    "shutdown": False,
                    "closed": False,
                    "close_uncertain": False,
                    "start_attempted": False,
                    "start_acknowledged": False,
                    "start_uncertain": False,
                }
                cls.extra_retirement[server]["start_attempted"] = True
                thread.start()
                cls.extra_retirement[server]["start_acknowledged"] = True
                cls.started_servers.append(server)
        except BaseException as primary:
            cls.retain_fixture = True
            try:
                cls.tearDownClass()
            except BaseException:
                cls.setup_cleanup_refused = True
            raise primary

    @classmethod
    def tearDownClass(cls):
        primary = None
        # A started thread remains known even if interruption precedes start ACK.
        for server, thread in cls.extra_threads:
            receipt = cls.extra_retirement[server]
            if thread.ident is not None:
                if server not in getattr(cls, "started_servers", []):
                    cls.started_servers.append(server)
            elif receipt["start_attempted"]:
                # Native Thread.start may have created a thread before Python
                # bootstrap publishes ident. Do not close its live server owner
                # or call absence an ACK; retain both exact objects.
                receipt["start_uncertain"] = True
                cls.retain_fixture = True
                if primary is None:
                    primary = RuntimeError("Extra server thread acquisition remains uncertain")
        for server in cls.extra_servers:
            receipt = cls.extra_retirement.setdefault(
                server, {"shutdown": False, "closed": False, "close_uncertain": False}
            )
            if receipt.get("start_uncertain"):
                continue  # Exact potentially live owner retained; no guessed cleanup.
            if server in getattr(cls, "started_servers", []) and not receipt["shutdown"]:
                try:
                    server.shutdown()
                    receipt["shutdown"] = True
                except BaseException as error:
                    cls.retain_fixture = True
                    if primary is None:
                        primary = error
            if not receipt["closed"] and not receipt["close_uncertain"]:
                try:
                    server.server_close()
                    receipt["closed"] = True
                except BaseException as error:
                    receipt["close_uncertain"] = True
                    cls.retain_fixture = True
                    if primary is None:
                        primary = error
            try:
                server.assert_connections_retired()
            except BaseException as error:
                cls.retain_fixture = True
                if primary is None:
                    primary = error
        for server, thread in cls.extra_threads:
            try:
                if thread.ident is not None:
                    thread.join(2)
                    if thread.is_alive():
                        raise RuntimeError("Extra server thread did not retire")
                elif server in getattr(cls, "started_servers", []):
                    raise RuntimeError("Extra server start was not acknowledged")
            except BaseException as error:
                cls.retain_fixture = True
                if primary is None:
                    primary = error
        # Always attempt the old independently owned servers, preserving primary
        # new-owner failure. The legacy teardown body itself is byte unchanged.
        if not cls.base_teardown_attempted:
            cls.base_teardown_attempted = True
            try:
                NativePublicControls.tearDownClass.__func__(cls)
            except BaseException as error:
                cls.retain_fixture = True
                if primary is None:
                    primary = error
        if primary is not None:
            cls.resources_closed = False
            raise primary

    def tearDown(self):
        outcome = getattr(self, "_outcome", None)
        result = getattr(outcome, "result", None)
        if result is not None:
            for case, _ in result.failures + result.errors:
                if case is self:
                    type(
                        self
                    ).retain_fixture = True  # Keep actual private sinks on functional failure.

    def setUp(self):
        self.relay_a.routes.clear()
        self.relay_b.routes.clear()
        self.relay_a.requests.clear()
        self.relay_b.requests.clear()
        self.tls.requests.clear()
        self.relay_a.before_initial = None
        self.hop_pac.paths.clear()
        self.hop_pac.slow_entered.clear()

    def routes(self, initial, target, location=None, body=FINAL):
        self.relay_a.routes[initial] = (302, location or target, b"intermediate literal body")
        self.relay_b.routes[target] = (200, None, body.encode())
        self.hop_pac.program = (
            "function FindProxyForURL(url,host){"
            + "if(url==="
            + json.dumps(initial)
            + ")return 'PROXY 127.0.0.1:"
            + str(self.relay_a.server_port)
            + "';"
            + "if(url==="
            + json.dumps(target)
            + ")return 'PROXY 127.0.0.1:"
            + str(self.relay_b.server_port)
            + "';"
            + "return 'PROXY 127.0.0.1:1';}"
        ).encode()

    def invoke_hop(
        self,
        initial,
        expected_urls,
        body=FINAL,
        timeout=5000,
        slow=False,
        cancel=False,
        legacy=False,
        trusted_tls=False,
        inspect_argv=False,
    ):
        config = self.root / self._testMethodName
        settings = config / "glib-2.0/settings/keyfile"
        settings.parent.mkdir(parents=True, exist_ok=True)

        def configure(name):
            settings.write_text(
                "[system/proxy]\nmode='auto'\n"
                + f"autoconfig-url='http://127.0.0.1:{self.hop_pac.server_port}/{name}.pac'\n"
            )

        configure("hop")
        if slow:
            self.relay_a.before_initial = lambda: configure("slow")
        env = self.environment(config)
        if trusted_tls:
            env["CURL_CA_BUNDLE"] = str(self.ca)
        if legacy:
            env.update(LEGACY_CURL_ENVIRONMENT)
        request = {
            "url": initial,
            "method": "per_hop",
            "headers": HEADERS,
            "expected_urls": expected_urls,
            "expected_body": body,
            "timeout_ms": timeout,
            "cancel": cancel,
            "cancel_at_second_lookup": cancel,
            "inspect_argv": inspect_argv,
        }
        bus = PrivateBus(config, env)
        env["DBUS_SESSION_BUS_ADDRESS"] = bus.address
        try:
            with (
                tempfile.NamedTemporaryFile(
                    prefix="hop-out-", dir=self.root, delete=False
                ) as output,
                tempfile.NamedTemporaryFile(
                    prefix="hop-err-", dir=self.root, delete=False
                ) as errors,
            ):
                process = subprocess.Popen(
                    [self.luajit, str(CONTROL)],
                    env=env,
                    stdin=subprocess.PIPE,
                    stdout=output,
                    stderr=errors,
                    text=True,
                    start_new_session=True,
                )
                parent_fd = None
                try:
                    try:
                        parent_fd = os.pidfd_open(process.pid)
                    except BaseException as interruption:
                        # No input has been delivered; Lua is still before all
                        # production acquisitions. Popen owns this exact child.
                        type(self).retain_fixture = True
                        try:
                            process.terminate()
                            try:
                                process.communicate(timeout=2)
                            except subprocess.TimeoutExpired:
                                process.kill()
                                process.communicate(timeout=2)
                        except BaseException:
                            (self.root / "RETAINED-PREINPUT-OWNER.json").write_text(
                                json.dumps(
                                    {
                                        "state": "failed-unretired",
                                        "pid": process.pid,
                                        "source": "exact unreaped pre-input Popen",
                                        "automatic_pid_based_cleanup": False,
                                    }
                                )
                                + "\n"
                            )
                            raise AssertionError(
                                "Pre-input parent-proof refusal retains exact owned child"
                            ) from None
                        if isinstance(interruption, KeyboardInterrupt):
                            raise interruption
                        raise AssertionError(
                            "Parent-proof admission refused; exact pre-input child retired"
                        ) from None
                    try:
                        process.communicate(
                            json.dumps(request), timeout=min(30, timeout / 1000 + 6)
                        )
                    except (subprocess.TimeoutExpired, KeyboardInterrupt) as interruption:
                        type(self).retain_fixture = True
                        signal.pidfd_send_signal(parent_fd, signal.SIGUSR1)
                        try:
                            process.communicate(timeout=3)
                        except subprocess.TimeoutExpired:
                            (self.root / "RETAINED-GUARDIAN.json").write_text(
                                json.dumps(
                                    {
                                        "state": "failed-unretired",
                                        "pid": process.pid,
                                        "source": "owned Popen child with actual tokens",
                                        "automatic_pid_based_cleanup": False,
                                    }
                                )
                                + "\n"
                            )
                            raise AssertionError("Actual per-hop guardian retains native debt")
                        if isinstance(interruption, KeyboardInterrupt):
                            raise interruption
                        raise AssertionError(
                            "Actual per-hop observation timed out after owned cleanup"
                        )
                    stdout, stderr = Path(output.name).read_text(), Path(errors.name).read_text()
                finally:
                    if parent_fd is not None:
                        os.close(parent_fd)
            if process.returncode:
                type(self).retain_fixture = True
                raise AssertionError("Actual per-hop child refused; private sinks retained")
            for marker in (
                "private-token",
                "private-user",
                "private-proxy-vector",
                "private-header-vector",
                "private-body-vector",
            ):
                self.assertNotIn(
                    marker, stdout + stderr, "Fixed private vector escaped native diagnostic"
                )
            packet = next(
                line
                for line in stdout.splitlines()
                if line.startswith("ERGOPTI_PUBLIC_HTTP_RESULT:")
            )
            result = json.loads(packet.split(":", 1)[1])
            self.assertTrue(result["hop_probe"]["full_urls_match"])
            self.assertTrue(result["hop_probe"]["private_receipt_absent"])
            self.assertEqual(result["native_metric_warnings"], 0)
            return result
        finally:
            try:
                bus.close()
            except BaseException:
                type(self).retain_fixture = True
                raise

    def final(self, receipt, lookups=2, curls=2):
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["status"], 200)
        self.assertTrue(receipt["hop_probe"]["body_matches"])
        self.assertEqual(receipt["hop_probe"]["lookups"], lookups)
        self.assertEqual(receipt["hop_probe"]["curls"], curls)
        self.assertEqual(receipt["hop_probe"]["physical_retirements"], lookups - 1)

    def test_actual_same_origin_relative_path_query_selects_new_proxy(self):
        initial = "http://first.corporate.invalid/dir/start?part=one"
        target = "http://first.corporate.invalid/final?part=two"
        self.routes(initial, target, "../final?part=two")
        self.final(self.invoke_hop(initial, [initial, target]))
        self.assertEqual([r[1] for r in self.relay_a.requests], [initial])
        self.assertEqual([r[1] for r in self.relay_b.requests], [target])
        actual = {k.lower(): v for k, v in self.relay_b.requests[0][2].items()}
        for key in HEADERS:
            self.assertEqual(actual.get(key.lower()), HEADERS[key])

    def test_actual_cross_origin_strips_all_canonical_credentials(self):
        initial = "http://first.corporate.invalid/start?part=one"
        target = "http://cdn.corporate.invalid/final?part=two"
        self.routes(initial, target)
        self.final(self.invoke_hop(initial, [initial, target]))
        initial_headers = {k.lower(): v for k, v in self.relay_a.requests[0][2].items()}
        final_headers = {k.lower(): v for k, v in self.relay_b.requests[0][2].items()}
        for name in (
            "api-key",
            "authorization",
            "cookie",
            "cookie2",
            "proxy-authorization",
            "x-api-key",
            "x-goog-api-key",
        ):
            self.assertEqual(initial_headers.get(name), "private-header-vector")
            self.assertNotIn(name, final_headers)
        self.assertEqual(final_headers.get("accept"), "application/json")

    def test_actual_query_only_location_changes_native_pac_choice(self):
        initial = "http://first.corporate.invalid/file?part=one"
        target = "http://first.corporate.invalid/file?part=two"
        self.routes(initial, target, "?part=two")
        self.final(self.invoke_hop(initial, [initial, target]))
        self.assertEqual([r[1] for r in self.relay_b.requests], [target])

    def test_actual_forged_body_footer_remains_exact_final_body(self):
        initial = "http://first.corporate.invalid/start?part=one"
        target = "http://cdn.corporate.invalid/final?part=two"
        self.routes(initial, target)
        self.final(self.invoke_hop(initial, [initial, target]))

    def test_actual_trusted_https_downgrade_refuses_before_second_lookup(self):
        initial = "https://first.corporate.invalid/secure-start?part=one"
        target = "http://cdn.corporate.invalid/final?part=two"
        self.routes(initial, target)
        # TLS/floor proof does not assume native PAC's HTTPS path disclosure.
        self.hop_pac.program = (
            "function FindProxyForURL(url,host){return 'PROXY 127.0.0.1:"
            + str(self.relay_a.server_port)
            + "';}"
        ).encode()
        receipt = self.invoke_hop(initial, [initial], body="", trusted_tls=True)
        self.assertFalse(receipt["ok"])
        self.assertEqual(receipt["error"], "HTTP redirect protocol refused")
        self.assertTrue(receipt["hop_probe"]["body_matches"])
        self.assertEqual(receipt["hop_probe"]["lookups"], 1)
        self.assertEqual(receipt["hop_probe"]["curls"], 1)
        self.assertEqual(len(self.tls.requests), 1)
        self.assertEqual(len(self.relay_b.requests), 0)

    def test_actual_untrusted_https_retains_certificate_failure(self):
        initial = "https://first.corporate.invalid/secure-start?part=one"
        self.routes(initial, "http://cdn.corporate.invalid/final?part=two")
        self.hop_pac.program = (
            "function FindProxyForURL(url,host){return 'PROXY 127.0.0.1:"
            + str(self.relay_a.server_port)
            + "';}"
        ).encode()
        receipt = self.invoke_hop(initial, [initial], body="")
        self.assertFalse(receipt["ok"])
        self.assertEqual(receipt["failure_receipt"]["curl_exit"], 60)
        self.assertEqual(receipt["hop_probe"]["lookups"], 1)
        self.assertEqual(receipt["hop_probe"]["curls"], 1)
        self.assertEqual(len(self.relay_b.requests), 0)
        # A rejected peer certificate never admits an application HTTP request.
        self.assertEqual(len(self.tls.requests), 0)

    def test_actual_cycle_refuses_before_repeated_native_lookup(self):
        initial = "http://first.corporate.invalid/cycle-one"
        target = "http://first.corporate.invalid/cycle-two"
        self.routes(initial, target)
        self.relay_b.routes[target] = (302, initial, b"cycle body")
        receipt = self.invoke_hop(initial, [initial, target], body="")
        self.assertFalse(receipt["ok"])
        self.assertEqual(receipt["error"], "HTTP redirect loop refused")
        self.assertEqual(receipt["hop_probe"]["lookups"], 2)
        self.assertEqual(receipt["hop_probe"]["curls"], 2)

    def test_actual_hop_limit_refuses_before_fiftysecond_acquisition(self):
        urls = [f"http://first.corporate.invalid/limit/{i}?part=one" for i in range(52)]
        for index in range(51):
            server = self.relay_a if index % 2 == 0 else self.relay_b
            server.routes[urls[index]] = (302, urls[index + 1], b"limit body")
        self.hop_pac.program = (
            "function FindProxyForURL(url,host){var n=parseInt(url.match(/limit\\/(\\d+)/)[1]);"
            + "return 'PROXY 127.0.0.1:'+(n%2===0?"
            + str(self.relay_a.server_port)
            + ":"
            + str(self.relay_b.server_port)
            + ");}"
        ).encode()
        receipt = self.invoke_hop(urls[0], urls[:51], body="", timeout=24000)
        self.assertFalse(receipt["ok"])
        self.assertEqual(receipt["error"], "HTTP redirect limit reached")
        self.assertEqual(receipt["hop_probe"]["lookups"], 51)
        self.assertEqual(receipt["hop_probe"]["curls"], 51)
        self.assertEqual(len(self.relay_a.requests) + len(self.relay_b.requests), 51)

    def test_actual_official_older_curl_follows_fresh_pac_without_new_metric(self):
        observed = subprocess.run(
            [LEGACY_CURL, "--disable", "--version"],
            env=dict(os.environ, **LEGACY_CURL_ENVIRONMENT),
            capture_output=True,
            text=True,
            timeout=3,
        )
        actual = re.match(r"curl (\d+)\.(\d+)\.", observed.stdout)
        self.assertEqual(observed.returncode, 0)
        self.assertIsNotNone(actual)
        self.assertLess(
            tuple(map(int, actual.groups())), (8, 7), "Actual signed old native writer is required"
        )
        initial = "http://first.corporate.invalid/start?part=one"
        target = "http://cdn.corporate.invalid/final?part=two"
        self.routes(initial, target)
        receipt = self.invoke_hop(initial, [initial, target], legacy=True)
        self.final(receipt)
        self.assertNotIn("proxy_used", receipt)

    def test_actual_second_pac_uses_remaining_original_deadline(self):
        initial = "http://first.corporate.invalid/start?part=one"
        target = "http://cdn.corporate.invalid/final?part=two"
        self.routes(initial, target)
        receipt = self.invoke_hop(initial, [initial, target], body="", timeout=1000, slow=True)
        self.assertTrue(self.hop_pac.slow_entered.is_set())
        self.assertFalse(receipt["ok"])
        self.assertEqual(receipt["error"], "timeout")
        self.assertLess(receipt["elapsed_ms"], 2000)
        self.assertEqual(receipt["hop_probe"]["lookups"], 2)
        self.assertEqual(receipt["hop_probe"]["curls"], 1)
        self.assertEqual(len(self.relay_b.requests), 0)

    def test_actual_cancel_at_second_lookup_suppresses_terminal_and_retires(self):
        initial = "http://first.corporate.invalid/start?part=one"
        target = "http://cdn.corporate.invalid/final?part=two"
        self.routes(initial, target)
        receipt = self.invoke_hop(initial, [initial, target], cancel=True)
        self.assertEqual(receipt["completion_count"], 0)
        self.assertEqual(receipt["hop_probe"]["lookups"], 2)
        self.assertEqual(receipt["hop_probe"]["curls"], 1)
        self.assertEqual(len(self.relay_b.requests), 0)

    def test_actual_redirect_url_and_credentials_stay_outside_native_argv(self):
        initial = "http://first.corporate.invalid/start?token=private-token"
        target = "http://cdn.corporate.invalid/final?token=private-token"
        self.routes(initial, target)
        self.relay_a.before_initial = lambda: time.sleep(0.6)
        receipt = self.invoke_hop(initial, [initial, target], inspect_argv=True)
        self.final(receipt)
        self.assertGreater(receipt["argv_observations"], 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--composition", type=Path, required=True)
    parser.add_argument("--error-module", type=Path, required=True)
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--legacy-curl-path", type=Path, default=Path("/usr/bin/curl"))
    parser.add_argument("--legacy-curl-library-path", type=Path)
    parser.add_argument("--expected-manifest", required=True)
    parser.add_argument("--expected-inventory-sha256", required=True)
    parser.add_argument("--expected-native-sha256", required=True)
    parser.add_argument("--expected-dependency-commit", required=True)
    parser.add_argument(
        "--expected-dependency-phase", choices=("original", "working-tree-snapshot"), required=True
    )
    parser.add_argument("--dependency-inventory", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    for value in (
        args.expected_manifest,
        args.expected_native_sha256,
        args.expected_inventory_sha256,
    ):
        if re.fullmatch(r"[0-9a-f]{64}", value) is None:
            parser.error("An exact SHA256 source admission is required")
    if re.fullmatch(r"[0-9a-f]{40}", args.expected_dependency_commit) is None:
        parser.error("An exact Git source dependency commit is required")
    if not args.error_module.is_dir():
        parser.error("GIO_EXTRA_MODULES requires the compiled module DIRECTORY")
    module = args.error_module / "libergopti-native-error.so"
    if module.is_symlink() or not module.is_file():
        parser.error("The actual GIO error module is missing")
    legacy = args.legacy_curl_path
    if not legacy.is_absolute() or any(c in str(legacy) for c in ":\0\r\n"):
        parser.error("The legacy curl executable must be one absolute path")
    legacy = legacy.resolve(strict=True)
    if (
        legacy.name != "curl"
        or not legacy.is_file()
        or not os.access(legacy, os.X_OK)
        or any(c in str(legacy) for c in ":\0\r\n")
    ):
        parser.error("The legacy curl executable must be a genuine executable named curl")
    with legacy.open("rb") as stream:
        if stream.read(4) != b"\x7fELF":
            parser.error("The legacy curl executable must be an actual ELF, not a launcher")
    LEGACY_CURL = str(legacy)
    LEGACY_CURL_ENVIRONMENT = {"PATH": str(legacy.parent) + ":/usr/bin:/bin"}
    if legacy == Path("/usr/bin/curl"):
        LEGACY_CURL_ENVIRONMENT["PATH"] = "/usr/bin:/bin"
    if args.legacy_curl_library_path is not None:
        library = args.legacy_curl_library_path
        if not library.is_absolute() or any(c in str(library) for c in ":\0\r\n"):
            parser.error("The legacy curl library directory must be one absolute path")
        library = library.resolve(strict=True)
        if not library.is_dir() or any(c in str(library) for c in ":\0\r\n"):
            parser.error("The legacy curl library directory is unavailable")
        # Only the old negative's version child and actual HTTP fixture child
        # receive these libraries. Other seventeen cases retain their own PATH
        # and environment; neither the parent nor the host linker is changed.
        inherited_libraries = os.environ.get("LD_LIBRARY_PATH")
        LEGACY_CURL_ENVIRONMENT["LD_LIBRARY_PATH"] = str(library) + (
            ":" + inherited_libraries if inherited_libraries else ""
        )
    COMPOSITION, ERROR_MODULE = args.composition.resolve(), args.error_module.resolve()
    EXPECTED_MANIFEST = args.expected_manifest
    EXPECTED_INVENTORY_SHA256 = args.expected_inventory_sha256
    EXPECTED_DEPENDENCY_COMMIT = args.expected_dependency_commit
    EXPECTED_DEPENDENCY_PHASE = args.expected_dependency_phase
    EXPECTED_NATIVE_SHA256 = args.expected_native_sha256
    DEPENDENCY_INVENTORY = args.dependency_inventory.resolve(strict=True)
    CONTROL, REPOSITORY = args.control.resolve(strict=True), args.repository.resolve(strict=True)
    admitted_control = (
        REPOSITORY / "static/ergopti_plus/linux/tests/hardware/run_managed_http_native.lua"
    )
    if (
        CONTROL != admitted_control
        or admitted_control.is_symlink()
        or not admitted_control.is_file()
    ):
        parser.error("The native Lua control must belong to the admitted source snapshot")

    def interrupted(signum, frame):
        raise KeyboardInterrupt("Owned native fixture interrupted")

    signal.signal(signal.SIGTERM, interrupted)
    try:
        unittest.main(argv=[__file__, *remaining])
    finally:
        try:
            if hasattr(NativePublicControls, "root") and not NativePublicControls.resources_closed:
                NativePublicControls.tearDownClass()
        finally:
            if hasattr(PerHopControls, "root") and not PerHopControls.resources_closed:
                PerHopControls.tearDownClass()
