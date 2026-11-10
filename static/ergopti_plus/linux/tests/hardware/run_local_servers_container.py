#!/usr/bin/env python3
# tests/hardware/run_local_servers_container.py
"""Prove that the local server detection names the servers that run.

TODO « To confirm on Linux »: with some `local_servers.json` servers
installed, the detection names them. The servers and their models cannot be
installed in a container, so a stand-in (fake_local_server.py) runs under
each server's executable name with its own flags, as /proc then shows it:
llama.cpp on a --port of its command line, vLLM as `vllm serve` with --port,
Lemonade on the port of ~/.config/lemonade/config.json, and KoboldCpp on a
port no flag or file names, found from its listening socket (ss). Every other
catalogue server stays absent. The detection itself is the production
local_servers module, driven by run_local_servers_container.lua.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest


HERE = Path(__file__).resolve().parent
DRIVER = HERE.parent.parent
SHARED = DRIVER.parent / "_shared"
CATALOGUE = json.loads((SHARED / "modules/llm/local_servers.json").read_text())
STAND_IN = HERE / "fake_local_server.py"


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class LocalServersContainer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for program in ("luajit", "curl", "ss"):
            if not shutil.which(program):
                raise RuntimeError(f"{program} is required")
        cls.home = Path(tempfile.mkdtemp(prefix="ergopti-local-servers-"))
        cls.bin = cls.home / "bin"
        cls.bin.mkdir()
        cls.ports = {name: free_port() for name in ("llamacpp", "vllm", "lemonade", "koboldcpp")}
        lemonade = cls.home / ".config/lemonade/config.json"
        lemonade.parent.mkdir(parents=True)
        lemonade.write_text(json.dumps({"port": cls.ports["lemonade"]}))
        # Each command line as the server's own documentation starts it.
        launches = {
            "llamacpp": [
                "llama-server",
                "-m",
                "model.gguf",
                "--port",
                str(cls.ports["llamacpp"]),
                "--owned-by",
                "llamacpp",
            ],
            "vllm": [
                "vllm",
                "serve",
                "Qwen/Qwen3-0.6B",
                "--port",
                str(cls.ports["vllm"]),
                "--owned-by",
                "vllm",
            ],
            "lemonade": ["lemond", "--config-port", str(lemonade), "port"],
            "koboldcpp": [
                "koboldcpp-linux-x64",
                "--model",
                "model.gguf",
                "--default-port",
                str(cls.ports["koboldcpp"]),
            ],
        }
        cls.processes = []
        for argv in launches.values():
            executable = cls.bin / argv[0]
            shutil.copy(STAND_IN, executable)
            os.chmod(executable, 0o755)
            process = subprocess.Popen(
                [str(executable), *argv[1:]],
                cwd=str(cls.home),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            cls.processes.append(process)
        for process in cls.processes:
            line = process.stdout.readline()
            if not line.startswith("listening"):
                raise RuntimeError("a stand-in did not start: " + process.stderr.read())

    @classmethod
    def tearDownClass(cls):
        for process in cls.processes:
            process.terminate()
            process.wait(5)
            process.stdout.close()
            process.stderr.close()
        shutil.rmtree(cls.home)

    def detect(self):
        config = self.home / ".config"
        env = {
            "HOME": str(self.home),
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "LANG": "C.UTF-8",
            "XDG_CONFIG_HOME": str(config),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "XDG_CACHE_HOME": str(self.home / ".cache"),
            "LUA_PATH": ";".join(
                f"{root}/?.lua;{root}/?/init.lua" for root in (DRIVER, SHARED / "lua")
            )
            + ";;",
        }
        completed = subprocess.run(
            ["luajit", str(HERE / "run_local_servers_container.lua")],
            env=env,
            cwd=str(self.home),
            capture_output=True,
            text=True,
            timeout=90,
        )
        packets = [
            line
            for line in completed.stdout.splitlines()
            if line.startswith("ERGOPTI_LOCAL_SERVERS_RESULT:")
        ]
        self.assertEqual(len(packets), 1, completed.stdout[-3000:] + completed.stderr[-2000:])
        logs = [
            line.removeprefix("PROOF_LOG ")
            for line in completed.stdout.splitlines()
            if line.startswith("PROOF_LOG ") and "local_server" in line
        ]
        print("\n--- receipt local server detection")
        for line in logs:
            print("   ", line)
        return json.loads(packets[0].split(":", 1)[1]), logs

    def test_the_detection_names_the_running_servers(self):
        result, logs = self.detect()
        self.assertTrue(result["started"] and result["finished"], result)
        views = {view["id"]: view for view in result["views"]}
        self.assertEqual(set(views), set(CATALOGUE["server_order"]))
        expected = {
            "llamacpp": "cli",
            "vllm": "cli",
            "lemonade": "config",
            "koboldcpp": "listening",
        }
        self.assertEqual(sorted(result["detected"]), sorted(expected))
        for server, source in expected.items():
            view = views[server]
            self.assertEqual(view.get("status"), "up", view)
            self.assertEqual(view["port"], self.ports[server], view)
            self.assertEqual(view["port_source"], source, view)
            self.assertEqual(view["models"], ["stand-in-model"], view)
            self.assertEqual(view["display_name"], CATALOGUE["servers"][server]["label"])
        for server in set(views) - set(expected):
            self.assertEqual(views[server].get("reason"), "not_running", views[server])
        swept = [line for line in logs if "Local servers swept:" in line]
        self.assertEqual(len(swept), 1, logs)
        for server in expected:
            self.assertIn(f"{server}=up at http://127.0.0.1:{self.ports[server]}/v1", swept[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
