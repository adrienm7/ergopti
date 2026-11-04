#!/usr/bin/env python3
# tests/hardware/run_managed_ollama_route_plan.py
"""Prove the installed managed Ollama route plan against a real desktop PAC.

The Ollama daemon Ergopti starts reads only HTTPS_PROXY and NO_PROXY, and its
blob downloads leave the registry for another host. This harness installs the
driver as the packages lay it out, runs the shipped proxy stage on the module
path the launcher wrapper exports, from an unrelated working directory, and
answers its GIO lookups with a real PAC evaluated by the real glib-pacrunner on
a private D-Bus. Each PAC sends the registry and the blob host a different way.
"""

from __future__ import annotations

import http.server
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tempfile
import threading
import unittest


HERE = Path(__file__).resolve().parent
DRIVER = HERE.parent.parent
SHARED = DRIVER.parent / "_shared"
WRAPPER = DRIVER / "bin" / "ergopti-hotstrings"
CONTROL = HERE / "run_managed_ollama_route_plan.lua"
INVENTORY = json.loads((SHARED / "modules/network/route_origins.json").read_text())
REGISTRY_HOST = INVENTORY["clients"]["ollama"][0].removeprefix("https://")
BLOB_HOST = INVENTORY["clients"]["ollama"][1].removeprefix("https://")
RELAY_A = "127.0.0.1:3901"
RELAY_B = "127.0.0.1:3902"

# Each PAC answers the registry first, then the blob host.
PAC_RULES = {
    "split": (f"PROXY {RELAY_A}", "DIRECT"),
    "same": (f"PROXY {RELAY_A}", f"PROXY {RELAY_A}; DIRECT"),
    "registry_direct": ("DIRECT", f"PROXY {RELAY_A}"),
    "conflict": (f"PROXY {RELAY_A}", f"PROXY {RELAY_B}"),
    "direct": ("DIRECT", "DIRECT"),
}


class PacServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), PacHandler)
        self.paths = []


class PacHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.paths.append(self.path)
        name = self.path.strip("/").removesuffix(".pac")
        if name not in PAC_RULES:
            self.send_error(404)
            return
        registry, blob = PAC_RULES[name]
        body = (
            "function FindProxyForURL(url, host) {"
            f' if (host == "{REGISTRY_HOST}") return "{registry}";'
            f' if (host == "{BLOB_HOST}") return "{blob}";'
            ' return "PROXY 127.0.0.1:9";'
            " }"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ns-proxy-autoconfig")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def wrapper_lua_path(root):
    """Evaluate the wrapper's own LUA_PATH export for an installed root."""
    lines = [
        line for line in WRAPPER.read_text().splitlines() if line.startswith("export LUA_PATH=")
    ]
    if len(lines) != 1:
        raise RuntimeError("The launcher wrapper must export LUA_PATH exactly once")
    script = (
        f'DRIVER_ROOT="{root}/linux"; SHARED_LUA="{root}/_shared/lua"\n'
        + lines[0]
        + '\nprintf %s "$LUA_PATH"'
    )
    return subprocess.run(["bash", "-c", script], check=True, capture_output=True, text=True).stdout


class InstalledRoutePlan(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for program in ("luajit", "dbus-daemon"):
            if not shutil.which(program):
                raise RuntimeError(f"{program} is required")
        if not Path("/usr/libexec/glib-pacrunner").exists():
            raise RuntimeError("glib-networking's glib-pacrunner is required")
        cls.temp = Path(tempfile.mkdtemp(prefix="ergopti-route-plan-"))
        # The deb, rpm and install.sh lay the driver out as <root>/{linux,_shared}.
        cls.root = cls.temp / "usr/lib/ergopti"
        ignore = shutil.ignore_patterns("tests", "node_modules", "*.pyc")
        shutil.copytree(DRIVER, cls.root / "linux", ignore=ignore)
        shutil.copytree(SHARED, cls.root / "_shared", ignore=ignore)
        cls.lua_path = wrapper_lua_path(cls.root)
        cls.pac = PacServer()
        cls.thread = threading.Thread(target=cls.pac.serve_forever)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.pac.shutdown()
        cls.pac.server_close()
        cls.thread.join(2)
        shutil.rmtree(cls.temp)

    def run_stage(self, pac=None, mode="auto", extra=None):
        config = self.temp / self._testMethodName
        keyfile = config / "glib-2.0/settings/keyfile"
        keyfile.parent.mkdir(parents=True)
        if mode == "auto":
            keyfile.write_text(
                "[system/proxy]\nmode='auto'\n"
                f"autoconfig-url='http://127.0.0.1:{self.pac.server_port}/{pac}.pac'\n"
            )
        else:
            keyfile.write_text("[system/proxy]\nmode='none'\n")
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.lower().endswith("_proxy")
            and key not in {"GIO_USE_PROXY_RESOLVER", "LUA_PATH", "LUA_INIT"}
        }
        env.update(
            XDG_CONFIG_HOME=str(config),
            XDG_CACHE_HOME=str(config / "cache"),
            XDG_CURRENT_DESKTOP="GNOME",
            GSETTINGS_BACKEND="keyfile",
            LUA_PATH=self.lua_path,
            ERGOPTI_INSTALLED_ROOT=str(self.root),
        )
        env.update(extra or {})
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
            env["DBUS_SESSION_BUS_ADDRESS"] = address
            # An unrelated working directory: nothing may resolve from the CWD.
            completed = subprocess.run(
                ["luajit", str(CONTROL)],
                env=env,
                cwd=str(config),
                capture_output=True,
                text=True,
                timeout=20,
            )
        finally:
            # glib-pacrunner is activated inside the bus's session group.
            os.killpg(bus.pid, signal.SIGTERM)
            bus.wait(5)
            bus.stdout.close()
            shutil.rmtree(bus_dir)
        self.assertEqual(completed.returncode, 0, completed.stderr[-2000:])
        packet = [
            line
            for line in completed.stdout.splitlines()
            if line.startswith("ERGOPTI_ROUTE_PLAN_RESULT:")
        ]
        self.assertEqual(len(packet), 1, completed.stdout[-2000:])
        result = json.loads(packet[0].split(":", 1)[1])
        self.assertTrue(result["finished"] and result["settled"], result)
        # Logs name outcomes only: never a relay, a PAC address or an origin.
        for secret in (RELAY_A, RELAY_B, REGISTRY_HOST, BLOB_HOST, f":{self.pac.server_port}/"):
            self.assertNotIn(secret, completed.stderr)
        return result

    def test_installed_inventory_is_the_shipped_one(self):
        result = self.run_stage(mode="none")
        self.assertEqual(result["origins"], INVENTORY["clients"]["ollama"])

    def test_blob_host_sent_direct_joins_no_proxy(self):
        result = self.run_stage("split")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["lookup_hosts"], [REGISTRY_HOST, BLOB_HOST])
        self.assertEqual(result["environment"]["HTTPS_PROXY"], f"http://{RELAY_A}")
        self.assertEqual(result["environment"]["NO_PROXY"], BLOB_HOST)
        self.assertEqual(result["environment"]["no_proxy"], BLOB_HOST)

    def test_same_relay_for_both_hosts_exports_it_once(self):
        result = self.run_stage("same")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["environment"], {"HTTPS_PROXY": f"http://{RELAY_A}"})

    def test_registry_sent_direct_keeps_the_blob_relay(self):
        result = self.run_stage("registry_direct")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["environment"]["HTTPS_PROXY"], f"http://{RELAY_A}")
        self.assertEqual(result["environment"]["NO_PROXY"], REGISTRY_HOST)

    def test_two_relays_refuse_the_start(self):
        result = self.run_stage("conflict")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "proxy_route_plan_refused")
        self.assertEqual(result["lookups"], 2)

    def test_pac_direct_for_both_adds_nothing(self):
        result = self.run_stage("direct")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["environment"], {})

    def test_user_bypass_entries_are_kept_ahead_of_the_plan(self):
        result = self.run_stage("split", extra={"no_proxy": "intranet.example"})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["environment"]["NO_PROXY"], f"intranet.example,{BLOB_HOST}")

    def test_exported_relay_skips_every_lookup(self):
        result = self.run_stage("conflict", extra={"HTTPS_PROXY": "http://127.0.0.1:3999"})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["lookups"], 0)
        self.assertEqual(result["environment"], {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
