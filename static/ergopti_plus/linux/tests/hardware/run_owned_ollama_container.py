#!/usr/bin/env python3
# tests/hardware/run_owned_ollama_container.py
"""Prove the owned Ollama start and its PAC-unreachable pull in a container.

TODO « To confirm on Linux »: with `ollama serve` on 11434, enabling the AI
starts Ergopti's Ollama on 11435; with the PAC unreachable, an Ollama pull
logs the WARNING and then succeeds direct.

The pinned Ollama release cannot be downloaded here, so the managed runtime
tree holds the protocol-faithful stand-in (fake_ollama_server.py) as its
binary; a second stand-in plays the user's system Ollama on the stock port,
and an `ollama` first on PATH plays its executable. Everything else is the
production driver: prediction engine, enable admission, runtime repair and
composition, managed proxy stage on the real GIO lookup (a PAC evaluated by
the real glib-pacrunner on a private D-Bus), owned process port, curl, and the
model download. Only the refusal dialog's choice and WebKit are scripted.

Run it as a normal user, as CI does: the managed runtime refuses root-owned
homes. In a root container, run it through `su` as a throwaway user.
"""

from __future__ import annotations

import http.server
import json
import os
from pathlib import Path
import pwd
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest


HERE = Path(__file__).resolve().parent
DRIVER = HERE.parent.parent
SHARED = DRIVER.parent / "_shared"
CONTROL = "linux/tests/hardware/run_owned_ollama_container.lua"
STAND_IN = HERE / "fake_ollama_server.py"
DEFAULTS = json.loads((SHARED / "modules/llm/defaults.json").read_text())
OWNED, STOCK = DEFAULTS["llm_ollama_owned_port"], DEFAULTS["llm_ollama_port"]
MODEL = "qwen3:0.6b"


def free_port():
    """A loopback port nothing listens on once this returns."""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def read_log(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


class PacServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, body):
        super().__init__(("127.0.0.1", 0), PacHandler)
        self.body = body.encode()
        self.paths = []


class PacHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.paths.append(self.path)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ns-proxy-autoconfig")
        self.send_header("Content-Length", str(len(self.server.body)))
        self.end_headers()
        self.wfile.write(self.server.body)


class OwnedOllamaContainer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for program in ("luajit", "dbus-daemon", "curl", "python3"):
            if not shutil.which(program):
                raise RuntimeError(f"{program} is required")
        if not Path("/usr/libexec/glib-pacrunner").exists():
            raise RuntimeError("glib-networking's glib-pacrunner is required")
        # The managed runtime's ancestors must be the user's or root's and not
        # writable by group or others: the sticky /tmp is refused, so the home
        # holds it all, created under a umask that grants no write bit.
        os.umask(0o022)
        cls.home = Path(tempfile.mkdtemp(prefix="ergopti-owned-ollama-", dir=Path.home()))
        os.chmod(cls.home, 0o700)
        ignore = shutil.ignore_patterns("node_modules", "*.pyc", "__pycache__")
        cls.root = cls.home / "tree"
        shutil.copytree(DRIVER, cls.root / "linux", ignore=ignore)
        shutil.copytree(SHARED, cls.root / "_shared", ignore=ignore)
        cls.stand_in = cls.home / "fake_ollama_server.py"
        shutil.copy(STAND_IN, cls.stand_in)
        # A system Ollama: its executable first on PATH and its daemon on 11434.
        cls.system_bin = cls.home / "system-bin"
        cls.system_bin.mkdir()
        cls.system_marker = cls.home / "system-ollama-ran"
        (cls.system_bin / "ollama").write_text(f"#!/bin/sh\ntouch '{cls.system_marker}'\n")
        os.chmod(cls.system_bin / "ollama", 0o755)
        cls.system_log = cls.home / "system.jsonl"
        cls.system = subprocess.Popen(
            [sys.executable, str(cls.stand_in), "--port", str(STOCK), "--log", str(cls.system_log)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 5
        while not any(e["event"] == "listening" for e in read_log(cls.system_log)):
            if cls.system.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(
                    "the system Ollama stand-in could not take port 11434: "
                    + (cls.system.stderr.read() if cls.system.poll() is not None else "timeout")
                )
            time.sleep(0.05)

    @classmethod
    def tearDownClass(cls):
        cls.system.terminate()
        cls.system.wait(5)
        cls.system.stderr.close()
        shutil.rmtree(cls.home)

    def setUp(self):
        self.case = self.home / self._testMethodName
        self.case.mkdir()
        self.owned_log = self.case / "owned.jsonl"
        # XDG_DATA_HOME, where the resolver plans the managed runtime tree.
        self.data = self.case / "data"

    def install_runtime(self, plan):
        directory = Path(plan["directory"])
        (directory / "bin").mkdir(parents=True)
        (directory / "lib/ollama").mkdir(parents=True)
        (directory / "lib/ollama/libggml-base.so").write_text("stand-in library\n")
        binary = directory / "bin/ollama"
        binary.write_text(
            "#!/bin/sh\n"
            f"exec '{sys.executable}' '{self.stand_in}' \"$@\" --log '{self.owned_log}'\n"
        )
        os.chmod(binary, 0o755)

    def environment(self, extra=None):
        env = {
            "HOME": str(self.case),
            "USER": pwd.getpwuid(os.getuid()).pw_name,
            "PATH": f"{self.system_bin}:/usr/local/bin:/usr/bin:/bin",
            "XDG_CONFIG_HOME": str(self.case / "config"),
            "XDG_DATA_HOME": str(self.data),
            "XDG_CACHE_HOME": str(self.case / "cache"),
            "XDG_STATE_HOME": str(self.case / "state"),
            "XDG_RUNTIME_DIR": str(self.case / "run"),
            "XDG_CURRENT_DESKTOP": "GNOME",
            "GSETTINGS_BACKEND": "keyfile",
            "LANG": "C.UTF-8",
            "LUA_PATH": ";".join(
                f"{self.root}/{part}"
                for part in (
                    "linux/?.lua",
                    "linux/?/init.lua",
                    "_shared/lua/?.lua",
                    "_shared/lua/?/init.lua",
                )
            )
            + ";;",
        }
        # The daemon creates its configuration folder at startup; config.toml lives there.
        (self.case / "config/ergopti").mkdir(parents=True, exist_ok=True)
        for name in ("cache", "state", "run"):
            (self.case / name).mkdir(exist_ok=True)
        os.chmod(self.case / "run", 0o700)
        env.update(extra or {})
        return env

    def plan(self, env):
        script = (
            'local r = assert(require("modules.llm.ollama_install_resolver").new())\n'
            'local p = r.plan(); io.write(require("json").encode({directory = p.directory}))\n'
        )
        completed = subprocess.run(
            ["luajit", "-e", script],
            env=env,
            cwd=str(self.case),
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout.strip().splitlines()[-1])

    def proxy_settings(self, mode, url=None):
        keyfile = self.case / "config/glib-2.0/settings/keyfile"
        keyfile.parent.mkdir(parents=True, exist_ok=True)
        text = f"[system/proxy]\nmode='{mode}'\n"
        if url:
            text += f"autoconfig-url='{url}'\n"
        keyfile.write_text(text)

    def run_control(self, env):
        # A socket path stays under the 108-byte sun_path limit outside the case tree.
        bus_dir = Path(tempfile.mkdtemp(prefix="bus-", dir="/var/tmp"))
        bus = subprocess.Popen(
            [
                "dbus-daemon",
                "--session",
                "--nofork",
                "--print-address=1",
                f"--address=unix:path={bus_dir / 'socket'}",
            ],
            env=env,
            stdout=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            readable, _, _ = select.select([bus.stdout], [], [], 3)
            address = bus.stdout.readline().strip() if readable else ""
            self.assertTrue(address.startswith("unix:path="), "private bus did not start")
            env = dict(env, DBUS_SESSION_BUS_ADDRESS=address)
            completed = subprocess.run(
                ["luajit", str(self.root / CONTROL)],
                env=env,
                cwd=str(self.case),
                capture_output=True,
                text=True,
                timeout=120,
            )
        finally:
            os.killpg(bus.pid, signal.SIGTERM)
            bus.wait(5)
            bus.stdout.close()
            shutil.rmtree(bus_dir)
        packets = [
            line
            for line in completed.stdout.splitlines()
            if line.startswith("ERGOPTI_OWNED_OLLAMA_RESULT:")
        ]
        self.assertEqual(len(packets), 1, completed.stdout[-4000:] + completed.stderr[-2000:])
        logs = [
            line.removeprefix("PROOF_LOG ")
            for line in completed.stdout.splitlines()
            if line.startswith("PROOF_LOG ")
        ]
        self.receipt(logs)
        return json.loads(packets[0].split(":", 1)[1]), logs

    def receipt(self, logs):
        """Prints the compact receipt: the lifecycle lines of the run."""
        keep = (
            "prediction_engine",
            "enable_admission",
            "managed_ollama_proxy",
            "ollama_install_state",
            "model_download",
            "runtime_repair",
        )
        print(f"\n--- receipt {self._testMethodName}")
        for line in logs:
            if any(name in line for name in keep) or line.startswith(("WARN", "ERROR")):
                print("   ", line)

    def start(self, extra=None, pull=None):
        env = self.environment(extra)
        if pull:
            env["ERGOPTI_PROOF_PULL_TAG"] = pull
        self.install_runtime(self.plan(env))
        before = len(read_log(self.system_log))
        result, logs = self.run_control(env)
        self.assertFalse(result["expired"], result)
        system_requests = [e for e in read_log(self.system_log)[before:] if e["event"] == "request"]
        self.assertEqual(
            system_requests, [], "the system Ollama on the stock port is never contacted"
        )
        self.assertFalse(self.system_marker.exists(), "the system Ollama executable is never run")
        return result, logs, read_log(self.owned_log)

    def assert_owned_started(self, result, owned):
        self.assertTrue(result["enabled"], result)
        self.assertEqual(result["base_url"], f"http://127.0.0.1:{OWNED}")
        self.assertEqual(len(result["served"]), 1, result)
        self.assertEqual(result["served"][0]["ollama_host"], [f"127.0.0.1:{OWNED}"])
        self.assertTrue(result["served"][0]["executable"].startswith(str(self.data) + "/ergopti/"))
        self.assertTrue(result["daemon_retired"], "disabling the AI ends the daemon it started")
        listening = [e["address"] for e in owned if e["event"] == "listening"]
        self.assertEqual(listening, [f"127.0.0.1:{OWNED}"])
        self.assertIn("/api/version", [e.get("path") for e in owned if e["event"] == "request"])

    def test_enabling_the_ai_starts_the_owned_ollama_beside_a_system_one(self):
        self.proxy_settings("none")
        result, _, owned = self.start()
        self.assert_owned_started(result, owned)
        self.assertEqual(result["served"][0]["proxy"], {})

    def test_unreachable_pac_warns_then_pulls_direct(self):
        # Nothing listens on the PAC's port: GIO cannot fetch the PAC.
        self.proxy_settings("auto", f"http://127.0.0.1:{free_port()}/proxy.pac")
        result, logs, owned = self.start(pull=MODEL)
        self.assert_owned_started(result, owned)
        warnings = [
            line for line in logs if line.startswith("WARN modules.llm.managed_ollama_proxy")
        ]
        self.assertTrue(
            any("lookup unusable at native_pac_download" in line for line in warnings), logs
        )
        self.assertEqual(result["direct_fallback"], "native_pac_download")
        self.assertNotIn("HTTPS_PROXY", result["served"][0]["proxy"])
        self.assertTrue(result["pull_dispatched"] and result["pull_succeeded"], result)
        pulls = [e for e in owned if e["event"] == "pull"]
        self.assertEqual([(e["model"], e["route"]) for e in pulls], [(MODEL, "direct")])

    def test_pac_answering_direct_pulls_direct_without_a_warning(self):
        # A PAC GIO downloaded and that said DIRECT is no unusable PAC.
        pac = PacServer('function FindProxyForURL(url, host) { return "DIRECT"; }')
        thread = threading.Thread(target=pac.serve_forever)
        thread.start()
        try:
            self.proxy_settings("auto", f"http://127.0.0.1:{pac.server_port}/proxy.pac")
            result, logs, owned = self.start(pull=MODEL)
        finally:
            pac.shutdown()
            pac.server_close()
            thread.join(2)
        self.assertTrue(pac.paths, "GIO fetched the PAC")
        self.assert_owned_started(result, owned)
        self.assertFalse([line for line in logs if "lookup unusable" in line], logs)
        self.assertIsNone(result.get("direct_fallback"))
        self.assertTrue(result["pull_succeeded"], result)
        self.assertEqual([e["route"] for e in owned if e["event"] == "pull"], ["direct"])

    def test_pac_naming_only_a_dead_relay_fails_the_pull_through_it(self):
        # The control case: the stand-in routes through HTTPS_PROXY like the
        # daemon, so a relay kept as the last PAC entry fails the pull.
        dead = free_port()
        pac = PacServer(
            f'function FindProxyForURL(url, host) {{ return "PROXY 127.0.0.1:{dead}"; }}'
        )
        thread = threading.Thread(target=pac.serve_forever)
        thread.start()
        try:
            self.proxy_settings("auto", f"http://127.0.0.1:{pac.server_port}/proxy.pac")
            result, _, owned = self.start(pull=MODEL)
        finally:
            pac.shutdown()
            pac.server_close()
            thread.join(2)
        self.assert_owned_started(result, owned)
        self.assertEqual(
            result["served"][0]["proxy"].get("HTTPS_PROXY"), f"http://127.0.0.1:{dead}"
        )
        self.assertFalse(result["pull_succeeded"], result)
        self.assertEqual(
            [(e["route"], e["relay_reached"]) for e in owned if e["event"] == "pull"],
            [("proxy", False)],
        )


if __name__ == "__main__":
    if os.geteuid() == 0:
        # The managed runtime is per-user and refuses a root-owned tree.
        sys.exit("run_owned_ollama_container.py: run it as a normal user, not root")
    unittest.main(verbosity=2)
