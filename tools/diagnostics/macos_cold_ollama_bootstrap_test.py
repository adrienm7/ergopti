# tools/diagnostics/macos_cold_ollama_bootstrap_test.py
"""Independent receiving rejection cases; these do not emulate native macOS."""

import copy
import ast
import json
import tempfile
import io
import tarfile
from pathlib import Path
import unittest
import errno
import os
import socket
import subprocess
from unittest import mock

import macos_cold_ollama_bootstrap as cold

from macos_cold_ollama_bootstrap import (
    SOURCE_PATHS,
    compare_installed_archive,
    digest,
    sandbox_profile,
    validate,
)


class ColdReceiptTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        driver = Path(self.root.name) / "driver"
        source = driver / "modules/llm/ensure-ollama-deps.sh"
        source.parent.mkdir(parents=True)
        source.write_text("independent source bytes\n")
        self.config = {
            "driver": str(driver),
            "architecture": "x86_64",
            "denied_runtime_paths": ["/usr/bin/python3"],
            "install_dir": str(Path(self.root.name) / "install"),
        }
        self.result = {
            "success": True,
            "python_resolver": "unmodified production resolver",
            "ollama_resolver": "unmodified production resolver",
            "python_state": "python_missing",
            "native_python_candidates_count": 0,
            "denied_runtime_paths": ["/usr/bin/python3"],
            "daemon_validation": "not-executed",
            "native_environment": {
                "PROJECT_ROOT": str(driver),
                "ERGOPTI_NATIVE_ARCH": "x86_64",
                "ERGOPTI_NATIVE_PYTHONS": "",
                "ERGOPTI_BOOTSTRAP_OLLAMA_RESOLVED_BIN": "",
                "ERGOPTI_BOOTSTRAP_OLLAMA_INSTALL_DIR": self.config["install_dir"],
                "ERGOPTI_BOOTSTRAP_PYTHON": "",
            },
            "state": "ready",
            "runtime_installed": True,
            "runtime": "native Hammerspoon",
            "tasks": 1,
            "absent_python_selected": True,
            "receipt_retired": True,
            "receipt_removed": True,
            "worker_status": 0,
            "nonce": "independent-nonce",
            "source_sha256": digest(source),
            "native_cli": ["--managed-pty-worker", "1800000"],
            "worker_pid": 123,
            "receipt_path": str(Path(self.root.name) / "removed-receipt"),
            "physical_receipt": {
                "version": 1,
                "nonce": "independent-nonce",
                "state": "retired",
                "group_retired": True,
                "guardian_reaped": True,
                "pty_eof": True,
                "handles_closed": True,
                "status_valid": True,
                "exit_status": 0,
                "worker_status": 0,
                "source_admitted": True,
            },
        }

    def test_real_source_inventory_contains_the_loadable_shared_receipt(self):
        self.assertIn("_shared/lua/core/llm/native_pty_receipt.lua", SOURCE_PATHS)
        self.assertNotIn("_shared/core/llm/native_pty_receipt.lua", SOURCE_PATHS)
        self.assertIn("macos/modules/llm/ensure-ollama-deps.sh", SOURCE_PATHS)
        self.assertNotIn("macos/modules/llm/ensure-mlx-deps.sh", SOURCE_PATHS)
        self.assertIn("macos/modules/llm/ollama_binary.lua", SOURCE_PATHS)
        self.assertIn("macos/modules/llm/ollama-release.sh", SOURCE_PATHS)

    def test_independently_authored_complete_receipt(self):
        validate(self.result, self.config)

    def test_every_physical_closure_fence_required(self):
        for name in (
            "group_retired",
            "guardian_reaped",
            "pty_eof",
            "handles_closed",
            "status_valid",
            "source_admitted",
        ):
            for value in (False, None, 1, "true"):
                with self.subTest(name=name, value=value):
                    changed = copy.deepcopy(self.result)
                    changed["physical_receipt"][name] = value
                    with self.assertRaises(RuntimeError):
                        validate(changed, self.config)

    def test_source_callback_cli_and_receipt_retirement_are_independent(self):
        for name, value in (
            ("source_sha256", "0" * 64),
            ("worker_status", False),
            ("worker_status", 74),
            ("tasks", True),
            ("nonce", "foreign"),
            ("native_cli", ["--managed-pty-worker", "600000"]),
            ("receipt_retired", False),
            ("receipt_removed", False),
        ):
            with self.subTest(name=name):
                changed = copy.deepcopy(self.result)
                changed[name] = value
                with self.assertRaises(RuntimeError):
                    validate(changed, self.config)
        path = Path(self.result["receipt_path"])
        path.touch()
        with self.assertRaises(RuntimeError):
            validate(self.result, self.config)

    def test_six_actual_official_inputs_and_explicit_selection_required(self):
        for key in tuple(self.result["native_environment"]):
            changed = copy.deepcopy(self.result)
            changed["native_environment"][key] = "foreign"
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                validate(changed, self.config)
        for key, value in (
            ("daemon_validation", "passed"),
            ("python_resolver", "forced-missing-adapter"),
        ):
            changed = copy.deepcopy(self.result)
            changed[key] = value
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                validate(changed, self.config)

    def test_actual_isolation_resolvers_and_denied_paths_required(self):
        for key, value in (
            ("python_resolver", "forced-missing"),
            ("ollama_resolver", "managed-only"),
            ("native_python_candidates_count", True),
            ("native_python_candidates_count", 1),
            ("denied_runtime_paths", []),
            ("python_state", "ready"),
        ):
            changed = copy.deepcopy(self.result)
            changed[key] = value
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                validate(changed, self.config)
        lua = Path(__file__).with_name("macos_cold_ollama_bootstrap.lua").read_text()
        self.assertNotIn("python.resolve =", lua)
        self.assertNotIn("python.native_candidates =", lua)
        self.assertNotIn("binary.candidates =", lua)
        self.assertIn("local selected, state = python.resolve()", lua)
        self.assertIn("assert(binary.resolve() == nil", lua)

    def test_exact_literal_scoped_kernel_deny_profile(self):
        self.assertEqual(
            sandbox_profile(["/usr/bin/python3", "/opt/homebrew/bin/ollama"]),
            "(version 1)\n(allow default)\n(deny file-read* process-exec\n"
            '  (literal "/usr/bin/python3")\n'
            '  (literal "/opt/homebrew/bin/ollama")\n)\n',
        )


class InstalledArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / "installed"
        self.directory.mkdir()
        self.archive = self.root / "official.tgz"
        self.bytes = b"independent Mach-O stand-in bytes for portable member policy only\n"
        with tarfile.open(self.archive, "w:gz") as output:
            member = tarfile.TarInfo("./ollama")
            member.mode, member.size = 0o755, len(self.bytes)
            output.addfile(member, io.BytesIO(self.bytes))
            member = tarfile.TarInfo("./lib")
            member.type, member.mode = tarfile.DIRTYPE, 0o755
            output.addfile(member)
            member = tarfile.TarInfo("./lib/example.dylib")
            member.mode, member.size = 0o644, 3
            output.addfile(member, io.BytesIO(b"lib"))
            member = tarfile.TarInfo("./lib/alias.dylib")
            member.type, member.linkname = tarfile.SYMTYPE, "example.dylib"
            output.addfile(member)
        # The tiny archive is independently authored; never invoke production
        # extraction, native codesign or claim this fixture is a real binary.
        (self.directory / "ollama").write_bytes(self.bytes)
        (self.directory / "ollama").chmod(0o755)
        (self.directory / "lib").mkdir(mode=0o755)
        (self.directory / "lib").chmod(0o755)
        (self.directory / "lib/example.dylib").write_bytes(b"lib")
        (self.directory / "lib/example.dylib").chmod(0o644)
        (self.directory / "lib/alias.dylib").symlink_to("example.dylib")

    def test_independent_member_bytes_links_and_inventory(self):
        files = compare_installed_archive(self.archive, self.directory)
        self.assertEqual(set(files), {"ollama", "lib/example.dylib"})
        self.assertEqual(files["ollama"], digest(self.directory / "ollama"))

    def test_changed_library_refuses(self):
        (self.directory / "lib/example.dylib").write_bytes(b"bad")
        with self.assertRaises(RuntimeError):
            compare_installed_archive(self.archive, self.directory)

    def test_extra_runtime_file_refuses(self):
        (self.directory / "injected.dylib").write_bytes(b"extra")
        with self.assertRaises(RuntimeError):
            compare_installed_archive(self.archive, self.directory)

    def test_symlink_external_bytes_refuse(self):
        outside = self.root / "external"
        outside.write_bytes(b"lib")
        link = self.directory / "lib/alias.dylib"
        link.unlink()
        link.symlink_to(outside)
        with self.assertRaises(RuntimeError):
            compare_installed_archive(self.archive, self.directory)

    def test_wrong_executable_mode_refuses(self):
        (self.directory / "ollama").chmod(0o644)
        with self.assertRaises(RuntimeError):
            compare_installed_archive(self.archive, self.directory)


class OfficialClientVersionProbeTests(unittest.TestCase):
    """Actual loopback lease tests; mocked CLI output gives no native Mac credit."""

    def assert_port_released(self, address):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as successor:
            successor.bind(address)

    def test_inherited_foreign_host_is_overridden_only_for_the_actual_probe_child(self):
        foreign = "http://foreign-daemon.invalid:11434"
        with mock.patch.dict(os.environ, {"OLLAMA_HOST": foreign}):
            environment = os.environ.copy()
            before = environment.copy()
            observed = {}

            def run(arguments, **options):
                route = options["env"]["OLLAMA_HOST"]
                self.assertTrue(route.startswith("http://127.0.0.1:"))
                observed["address"] = ("127.0.0.1", int(route.rsplit(":", 1)[1]))
                self.assertEqual(
                    arguments,
                    [
                        "/usr/bin/sandbox-exec",
                        "-f",
                        "/owned/isolation.sb",
                        "/owned/ollama",
                        "--version",
                    ],
                )
                self.assertEqual(
                    {key: value for key, value in options["env"].items() if key != "OLLAMA_HOST"},
                    {key: value for key, value in environment.items() if key != "OLLAMA_HOST"},
                )
                self.assertEqual(options["timeout"], 30)
                self.assertIs(options["check"], True)
                return subprocess.CompletedProcess(
                    arguments,
                    0,
                    stdout="Warning: could not connect to a running Ollama instance\nWarning: client version is 0.24.0\n",
                    stderr="",
                )

            with mock.patch.object(cold.subprocess, "run", side_effect=run):
                receipt = cold.probe_installed_client_version(
                    Path("/owned/ollama"), Path("/owned/isolation.sb"), environment
                )
            self.assertEqual(environment, before)
            self.assertEqual(os.environ["OLLAMA_HOST"], foreign)
            self.assertEqual(
                receipt,
                {
                    "kind": "retained non-listening loopback socket",
                    "address": "127.0.0.1",
                    "port": observed["address"][1],
                    "environment_scope": "version child only",
                    "command_closed": True,
                    "lease_closed": True,
                    "client_version": "0.24.0",
                },
            )
            self.assert_port_released(observed["address"])

    def test_real_non_listening_socket_blocks_rebind_and_refuses_connections_until_command_returns(
        self,
    ):
        observed = {}

        def run(arguments, **options):
            observed["address"] = (
                "127.0.0.1",
                int(options["env"]["OLLAMA_HOST"].rsplit(":", 1)[1]),
            )
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as competitor:
                with self.assertRaises(OSError) as conflict:
                    competitor.bind(observed["address"])
                self.assertEqual(conflict.exception.errno, errno.EADDRINUSE)
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
                client.settimeout(0.2)
                self.assertEqual(client.connect_ex(observed["address"]), errno.ECONNREFUSED)
            return subprocess.CompletedProcess(
                arguments,
                0,
                stdout="Warning: could not connect to a running Ollama instance\nWarning: client version is 0.24.0\n",
                stderr="",
            )

        with mock.patch.object(cold.subprocess, "run", side_effect=run):
            cold.probe_installed_client_version(
                Path("/owned/ollama"), Path("/owned/isolation.sb"), {}
            )
        self.assert_port_released(observed["address"])

    def test_literal_local_version_refuses_foreign_server_wrong_version_and_substring_spoof(
        self,
    ):
        for text in (
            "ollama version is 0.24.0\n",
            "unexpected startup output\nWarning: could not connect to a running Ollama instance\nWarning: client version is 0.24.0\n",
            "Warning: could not connect to a running Ollama instance\nWarning: client version is 0.24.1\n",
            "Warning: could not connect to a running Ollama instance\nWarning: client version is 0.24.0-foreign\n",
            "Warning: client version is 0.24.0\n",
            "ollama version is 0.24.0\nWarning: could not connect to a running Ollama instance\nWarning: client version is 0.24.0\n",
        ):
            observed = {}
            with self.subTest(text=text):

                def run(arguments, **options):
                    observed["address"] = (
                        "127.0.0.1",
                        int(options["env"]["OLLAMA_HOST"].rsplit(":", 1)[1]),
                    )
                    return subprocess.CompletedProcess(arguments, 0, stdout=text, stderr="")

                with mock.patch.object(cold.subprocess, "run", side_effect=run):
                    with self.assertRaisesRegex(RuntimeError, "pinned local version"):
                        cold.probe_installed_client_version(
                            Path("/owned/ollama"), Path("/owned/isolation.sb"), {}
                        )
                self.assert_port_released(observed["address"])

    def test_timeout_and_command_refusal_release_only_the_owned_socket(self):
        for reason in ("timeout", "exit"):
            observed = {}
            with self.subTest(reason=reason):

                def run(arguments, **options):
                    observed["address"] = (
                        "127.0.0.1",
                        int(options["env"]["OLLAMA_HOST"].rsplit(":", 1)[1]),
                    )
                    if reason == "timeout":
                        raise subprocess.TimeoutExpired(arguments, options["timeout"])
                    raise subprocess.CalledProcessError(77, arguments)

                with mock.patch.object(cold.subprocess, "run", side_effect=run):
                    with self.assertRaises(
                        (subprocess.TimeoutExpired, subprocess.CalledProcessError)
                    ):
                        cold.probe_installed_client_version(
                            Path("/owned/ollama"), Path("/owned/isolation.sb"), {}
                        )
                self.assert_port_released(observed["address"])


class ColdIsolationLipoGrammarTests(unittest.TestCase):
    """Portable argv regression against Apple's published grammar, not native credit."""

    def test_input_file_precedes_greedy_verify_arch_arguments(self):
        # Apple cctools misc/lipo.c, Git blob f7b0fd6ddea7d3c5e77b1789d547542ca7ba74ae,
        # consumes EVERY argument after -verify_arch as an architecture. Its usage
        # is lipo <input_file> <command>; a file after arm64 is not a native probe.
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "stock runtime"
            file.write_bytes(b"portable argv boundary only; not a native binary\n")
            profile = Path(directory) / "profile"
            calls = []

            def probe(argv, **_kwargs):
                calls.append(argv)
                if argv[0] == "/usr/bin/lipo":
                    self.assertEqual(argv, ["/usr/bin/lipo", str(file), "-verify_arch", "arm64"])
                denied = argv[0] == "/usr/bin/sandbox-exec"
                return cold.subprocess.CompletedProcess(
                    argv,
                    126 if denied else 0,
                    stdout="",
                    stderr="Operation not permitted" if denied else "",
                )

            with (
                mock.patch.object(cold.subprocess, "run", side_effect=probe),
                mock.patch.object(cold.platform, "machine", return_value="arm64"),
            ):
                result = cold.qualify_runtime_isolation([str(file)], profile)
            self.assertEqual(len(result), 1)
            self.assertIs(result[0]["read_denied"], True)
            self.assertIs(result[0]["native"], True)
            self.assertIs(result[0]["exec_denied"], True)
            self.assertEqual(
                calls,
                [
                    [
                        "/usr/bin/sandbox-exec",
                        "-f",
                        str(profile),
                        "/bin/cat",
                        str(file),
                    ],
                    ["/usr/bin/lipo", str(file), "-verify_arch", "arm64"],
                    [str(file), "--version"],
                    [
                        "/usr/bin/sandbox-exec",
                        "-f",
                        str(profile),
                        str(file),
                        "--version",
                    ],
                ],
            )


class ColdIdentityReceiptTests(unittest.TestCase):
    """Frozen APFS identities must survive Python JSON and JavaScript transport."""

    def observation_expression(self):
        tree = ast.parse(Path(cold.__file__).read_text())
        expressions = [
            value
            for node in ast.walk(tree)
            if isinstance(node, ast.Dict)
            for key, value in zip(node.keys, node.values)
            if isinstance(key, ast.Constant) and key.value == "observations"
        ]
        self.assertEqual(len(expressions), 1)
        return compile(ast.Expression(expressions[0]), "receipt-observations", "eval")

    def test_actual_apfs_inode_survives_json_as_exact_decimal_string(self):
        isolation = [
            {
                "device": 16777230,
                "inode": 1152921500312523020,
                "bytes": 118864,
                "native": False,
                "path": "/usr/bin/python3",
            }
        ]
        receipt = eval(self.observation_expression(), {"isolation": isolation})
        received = json.loads(json.dumps(receipt))
        self.assertEqual(received[0]["device"], "16777230")
        self.assertEqual(received[0]["inode"], "1152921500312523020")
        self.assertEqual(received[0]["bytes"], 118864)
        self.assertIs(received[0]["native"], False)
        self.assertEqual(received[0]["path"], "/usr/bin/python3")
        # Physical post-install comparisons retain their original Python ints.
        self.assertEqual(isolation[0]["inode"], 1152921500312523020)
        self.assertIs(type(isolation[0]["inode"]), int)
        self.assertEqual(isolation[0]["device"], 16777230)
        self.assertIs(type(isolation[0]["device"]), int)
        self.assertIsNot(receipt[0], isolation[0])

    def test_uint64_boundary_stays_exact_without_float_conversion(self):
        isolation = [{"device": 9007199254740993, "inode": 18446744073709551615}]
        receipt = json.loads(
            json.dumps(eval(self.observation_expression(), {"isolation": isolation}))
        )
        self.assertEqual(receipt, [{"device": "9007199254740993", "inode": "18446744073709551615"}])


class OfficialVersionTimeoutDiscriminatorTests(unittest.TestCase):
    """Actual POSIX socket routes and redacted captured timeout boundaries only."""

    def test_actual_route_refusal_does_not_accept_a_listening_peer(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as lease:
            lease.bind(("127.0.0.1", 0))
            self.assertEqual(
                cold.qualify_version_probe_route(lease.getsockname()),
                {"kind": "actual kernel loopback connection", "result": "ECONNREFUSED"},
            )
            lease.listen(1)
            with self.assertRaisesRegex(RuntimeError, "did not refuse.*0"):
                cold.qualify_version_probe_route(lease.getsockname())

    def test_refused_route_prevents_cli_invocation_and_retains_lease_cleanup(self):
        diagnostics = {}
        with mock.patch.object(
            cold, "qualify_version_probe_route", side_effect=RuntimeError("route refused")
        ):
            with mock.patch.object(cold.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "route refused"):
                    cold.probe_installed_client_version(
                        Path("/owned/ollama"), Path("/owned/policy"), {}, diagnostics
                    )
        run.assert_not_called()
        self.assertIs(diagnostics["lease_closed"], True)

    def test_timeout_keeps_primary_exception_and_only_fingerprints_captured_prefix(self):
        diagnostics = {}
        expected = b"Warning: could not connect to a running Ollama instance\nWarning: client version is 0.24.0\n"
        refusal = subprocess.TimeoutExpired(["/owned/ollama"], 30, output=expected, stderr=b"")
        with mock.patch.object(cold.subprocess, "run", side_effect=refusal):
            with self.assertRaises(subprocess.TimeoutExpired) as observed:
                cold.probe_installed_client_version(
                    Path("/owned/ollama"), Path("/owned/policy"), {}, diagnostics
                )
        self.assertIs(observed.exception, refusal)
        self.assertIs(diagnostics["lease_closed"], True)
        self.assertEqual(diagnostics["route"]["result"], "ECONNREFUSED")
        self.assertIs(diagnostics["failure"]["expected_version_lines_complete"], True)
        self.assertEqual(diagnostics["failure"]["output"]["stdout"]["sample_bytes"], len(expected))
        self.assertNotIn(expected.decode(), json.dumps(diagnostics))

    def test_oversized_and_unicode_captured_outputs_have_bounded_redacted_samples(self):
        for payload in (b"private-unrelated-output" * 10000, "💡" * 10000, "\ud800" * 10000):
            with self.subTest(kind=type(payload).__name__):
                refusal = subprocess.TimeoutExpired(
                    ["/owned/ollama"], 30, output=payload, stderr=None
                )
                observation = cold.version_timeout_observation(refusal)
                self.assertIs(observation["expected_version_lines_complete"], False)
                self.assertLessEqual(observation["output"]["stdout"]["sample_bytes"], 4096)
                self.assertIs(observation["output"]["stdout"]["sample_truncated"], True)
                self.assertEqual(observation["output"]["stdout"]["captured_size"], len(payload))
                self.assertNotIn("private-unrelated-output", json.dumps(observation))

    def test_unclosed_or_foreign_version_lines_cannot_credit_completed_version_output(self):
        for payload in (
            b"Warning: client version is 0.24.0\n",
            b"Warning: could not connect to a running Ollama instance\nWarning: client version is 0.24.1\n",
            b"Warning: could not connect to a running Ollama instance\nWarning: client version is 0.24.0",
        ):
            with self.subTest(output=payload):
                refusal = subprocess.TimeoutExpired(
                    ["/owned/ollama"], 30, output=payload, stderr=b""
                )
                self.assertIs(
                    cold.version_timeout_observation(refusal)["expected_version_lines_complete"],
                    False,
                )


if __name__ == "__main__":
    unittest.main()
