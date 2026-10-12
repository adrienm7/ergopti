"""Receive pinned bootstrap inputs without claiming native PAC qualification."""

import hashlib
import ast
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools.lib.git_bash import bash_executable  # noqa: E402 (direct-file test needs repository root)

SOURCE = ROOT / "static/ergopti_plus/macos/modules/llm/managed_bootstrap_http.py"
SPEC = importlib.util.spec_from_file_location("bootstrap_under_test", SOURCE)
BOOTSTRAP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOOTSTRAP)


class Response:
    def __init__(self, status=200, body=b"payload", headers=(), terminal=True):
        self.status = status
        self.headers = list(headers)
        self.body = io.BytesIO(body)
        self.terminal = terminal
        self.closed = False
        self.complete = False

    def read(self):
        chunk = self.body.read(3)
        if not chunk:
            if not self.terminal:
                raise BOOTSTRAP.BootstrapFailure("protocol")
            self.complete = True
        return chunk

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.closed = True


class BootstrapDownloadTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ergopti-bootstrap-receive-")
        self.output = Path(self.directory.name) / "asset"
        self.digest = hashlib.sha256(b"payload").hexdigest()
        self.deadline = time.monotonic() + 5

    def tearDown(self):
        self.directory.cleanup()

    def receive(self, request, **overrides):
        parameters = dict(
            url="https://origin.invalid/path?q=one",
            output=self.output,
            digest=self.digest,
            size=7,
            deadline=self.deadline,
            idle_timeout=1,
            request=request,
        )
        parameters.update(overrides)
        return BOOTSTRAP.download(**parameters)

    def test_full_url_identity_hash_and_physical_terminal_before_publication(self):
        response = Response()
        calls = []

        def request(url, **options):
            calls.append((url, options))
            return response

        self.receive(request)
        self.assertEqual(self.output.read_bytes(), b"payload")
        self.assertTrue(response.complete)
        self.assertTrue(response.closed)
        self.assertEqual(calls[0][0], "https://origin.invalid/path?q=one")
        self.assertEqual(calls[0][1]["headers"], (("Accept-Encoding", "identity"),))
        self.assertFalse(calls[0][1]["direct"])
        self.assertLessEqual(calls[0][1]["timeout"], 5)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)

    def test_redirect_closes_first_owner_and_reselects_entire_url_under_same_clock(self):
        first = Response(302, headers=(("Location", "https://next.invalid/new?q=two"),))
        second = Response()
        calls = []

        def request(url, **options):
            calls.append((url, options))
            if len(calls) == 1:
                return first
            self.assertTrue(first.closed)
            self.assertLess(options["timeout"], calls[0][1]["timeout"])
            return second

        self.receive(request)
        self.assertEqual(
            [call[0] for call in calls],
            ["https://origin.invalid/path?q=one", "https://next.invalid/new?q=two"],
        )
        self.assertTrue(second.complete)
        self.assertTrue(second.closed)

    def test_redirect_refusals_retire_owned_output_and_never_start_second_request(self):
        for headers in [
            (),
            (("Location", "http://next.invalid/"),),
            (("Location", "https://user:secret@next.invalid/"),),
            (("Location", "https://next.invalid/#fragment"),),
            (("Location", "/x"), ("location", "/y")),
        ]:
            with self.subTest(headers=headers):
                response = Response(302, headers=headers)
                calls = []
                with self.assertRaises(BOOTSTRAP.BootstrapFailure):
                    self.receive(lambda *args, **kwargs: calls.append(args) or response)
                self.assertEqual(len(calls), 1)
                self.assertTrue(response.closed)
                self.assertFalse(self.output.exists())

    def test_redirect_cycle_is_a_failure_with_no_remaining_owner(self):
        response = Response(307, headers=(("Location", "https://origin.invalid/path?q=one"),))
        with self.assertRaisesRegex(BOOTSTRAP.BootstrapFailure, "redirect"):
            self.receive(lambda *args, **kwargs: response)
        self.assertTrue(response.closed)
        self.assertFalse(self.output.exists())

    def test_complete_hash_never_admits_missing_terminal_or_wrong_bytes(self):
        for response in [
            Response(terminal=False),
            Response(body=b"corrupt"),
            Response(body=b"payloadextra"),
            Response(body=b"short"),
            Response(503),
        ]:
            with self.subTest(response=response):
                with self.assertRaises(BOOTSTRAP.BootstrapFailure):
                    self.receive(lambda *args, **kwargs: response)
                self.assertTrue(response.closed)
                self.assertFalse(self.output.exists())

    def test_exclusive_destination_preserves_existing_file_and_symlink_target(self):
        target = Path(self.directory.name) / "foreign"
        target.write_bytes(b"foreign bytes")
        for symbolic in (False, True):
            with self.subTest(symbolic=symbolic):
                if symbolic:
                    self.output.symlink_to(target)
                else:
                    self.output.write_bytes(b"prior")
                with self.assertRaises(FileExistsError):
                    self.receive(
                        lambda *args, **kwargs: self.fail(
                            "request acquired after exclusive refusal"
                        )
                    )
                self.assertEqual(target.read_bytes(), b"foreign bytes")
                if not symbolic:
                    self.assertEqual(self.output.read_bytes(), b"prior")
                self.output.unlink()

    def test_fsync_failure_cannot_publish_success(self):
        response = Response()
        with patch.object(BOOTSTRAP.os, "fsync", side_effect=OSError("private path")):
            with self.assertRaises(OSError):
                self.receive(lambda *args, **kwargs: response)
        self.assertTrue(response.closed)
        self.assertFalse(self.output.exists())

    def test_absolute_deadline_does_not_start_request(self):
        with self.assertRaisesRegex(BOOTSTRAP.BootstrapFailure, "deadline"):
            self.receive(
                lambda *args, **kwargs: self.fail("expired request acquired"),
                deadline=time.monotonic() - 1,
            )
        self.assertFalse(self.output.exists())

    def test_all_shared_loopback_families_request_direct(self):
        for host in ("localhost", "x.localhost", "127.8.3.2", "[::1]"):
            with self.subTest(host=host):
                calls = []
                self.receive(
                    lambda *args, **kwargs: calls.append(kwargs) or Response(),
                    url="http://" + host + "/resource?q=local",
                )
                self.assertTrue(calls[0]["direct"])
                self.output.unlink()

    def test_explicit_no_proxy_survives_system_export_provenance(self):
        for environment, direct in [
            ({"no_proxy": "origin.invalid", "NO_PROXY": "else.invalid"}, True),
            ({"no_proxy": "else.invalid", "NO_PROXY": "origin.invalid"}, False),
            ({"NO_PROXY": ".invalid:443"}, True),
            ({"NO_PROXY": "origin.invalid:444"}, False),
        ]:
            with self.subTest(environment=environment):
                clean = {
                    key: value for key, value in os.environ.items() if key.lower() != "no_proxy"
                }
                clean.update(environment)
                clean["HTTPS_PROXY"] = "http://system-exported.invalid:3128"
                calls = []
                with patch.dict(os.environ, clean, clear=True):
                    self.receive(lambda *args, **kwargs: calls.append(kwargs) or Response())
                self.assertEqual(calls[0]["direct"], direct)
                self.output.unlink()

    def test_uv_failure_and_deadline_physically_reap_exact_child(self):
        for command in ["raise SystemExit(12)", "import time; time.sleep(30)"]:
            with self.subTest(command=command):
                import sys

                observed = []
                original = subprocess.Popen

                def process(*args, **kwargs):
                    child = original(*args, **kwargs)
                    observed.append(child)
                    return child

                with patch.object(BOOTSTRAP.subprocess, "Popen", side_effect=process):
                    with self.assertRaises(BOOTSTRAP.BootstrapFailure):
                        BOOTSTRAP._run_uv([sys.executable, "-c", command], time.monotonic() + 0.2)
                self.assertEqual(len(observed), 1)
                self.assertIsNotNone(observed[0].poll())
                self.assertTrue(observed[0].stdout.closed)

    def test_managed_interpreter_uses_pinned_cache_and_offline_uv_extraction(self):
        captures = []
        downloads = []

        def download(url, output, digest, size, deadline, idle_timeout):
            downloads.append((url, Path(output).name, digest, size, deadline, idle_timeout))
            Path(output).write_bytes(b"controlled archive; not native extraction proof")

        def run(arguments, deadline, environment):
            metadata = json.loads(Path(arguments[-1]).read_text())
            captures.append((arguments, metadata, deadline, environment))
            self.assertTrue(Path(environment["UV_PYTHON_CACHE_DIR"]).is_dir())
            return b""

        with (
            patch.object(BOOTSTRAP, "download", side_effect=download),
            patch.object(BOOTSTRAP, "_run_uv", side_effect=run),
        ):
            BOOTSTRAP.install_python(
                "/native/uv", "cpython-3.11-macos-aarch64-none", self.deadline, 1
            )
        self.assertEqual(len(downloads), 1)
        self.assertEqual(
            downloads[0][1],
            "53141f31b-cpython-3.11.16-20260929-aarch64-apple-darwin-install_only_stripped.tar.gz",
        )
        self.assertEqual(
            downloads[0][2], "53141f31b7cfb2bccf89c2a877827128657dbb8650db06a9a08c7886c28a45ed"
        )
        self.assertEqual(downloads[0][4], self.deadline)
        self.assertEqual(len(captures), 1)
        arguments, metadata, deadline, environment = captures[0]
        self.assertEqual(
            arguments[:6],
            [
                "/native/uv",
                "python",
                "install",
                "cpython-3.11.16-macos-aarch64-none",
                "--offline",
                "--no-config",
            ],
        )
        self.assertEqual(arguments[6], "--python-downloads-json-url")
        self.assertEqual(list(metadata), ["cpython-3.11.16-darwin-aarch64-none"])
        self.assertEqual(deadline, self.deadline)
        self.assertFalse(Path(environment["UV_PYTHON_CACHE_DIR"]).exists())

    def test_unsupported_interpreter_cannot_acquire_network_or_uv(self):
        with (
            patch.object(BOOTSTRAP, "download", side_effect=AssertionError("network acquired")),
            patch.object(BOOTSTRAP, "_run_uv", side_effect=AssertionError("uv acquired")),
        ):
            with self.assertRaisesRegex(BOOTSTRAP.BootstrapFailure, "dependency"):
                BOOTSTRAP.install_python(
                    "/native/uv", "cpython-3.11-macos-x86_64_v3-none", self.deadline, 1
                )

    def test_intel_interpreter_uses_independent_pin_cache_and_exact_offline_metadata(self):
        captures = []
        expected_key = "cpython-3.11.16-darwin-x86_64-none"
        expected = {
            "name": "cpython",
            "arch": {"family": "x86_64", "variant": None},
            "os": "darwin",
            "libc": "none",
            "major": 3,
            "minor": 11,
            "patch": 16,
            "prerelease": "",
            "variant": None,
            "build": "20260929",
            "url": "https://github.com/astral-sh/python-build-standalone/releases/download/20260929/cpython-3.11.16%2B20260929-x86_64-apple-darwin-install_only_stripped.tar.gz",
            "sha256": "d1143a947050fbbd17edc0d66ff3f7a63205c8364ef108bddfeece5f360096f8",
        }

        def download(url, output, digest, size, deadline, idle_timeout):
            self.assertEqual(url, expected["url"])
            self.assertEqual(digest, expected["sha256"])
            self.assertEqual(
                Path(output).name,
                "d1143a947-cpython-3.11.16-20260929-x86_64-apple-darwin-install_only_stripped.tar.gz",
            )
            self.assertIsNone(size)
            self.assertEqual(deadline, self.deadline)
            self.assertEqual(idle_timeout, 1)
            Path(output).write_bytes(b"controlled Intel archive; not native execution proof")

        def run(arguments, deadline, environment):
            metadata = json.loads(Path(arguments[-1]).read_text())
            self.assertEqual(metadata, {expected_key: expected})
            self.assertEqual(
                arguments[:7],
                [
                    "/native/uv",
                    "python",
                    "install",
                    "cpython-3.11.16-macos-x86_64-none",
                    "--offline",
                    "--no-config",
                    "--python-downloads-json-url",
                ],
            )
            self.assertEqual(deadline, self.deadline)
            self.assertEqual(environment["UV_PYTHON_DOWNLOADS"], "manual")
            self.assertTrue(Path(environment["UV_PYTHON_CACHE_DIR"]).is_dir())
            captures.append(environment["UV_PYTHON_CACHE_DIR"])
            return b""

        with (
            patch.object(BOOTSTRAP, "download", side_effect=download) as downloader,
            patch.object(BOOTSTRAP, "_run_uv", side_effect=run),
        ):
            BOOTSTRAP.install_python(
                "/native/uv", "cpython-3.11-macos-x86_64-none", self.deadline, 1
            )
        self.assertEqual(downloader.call_count, 1)
        self.assertEqual(len(captures), 1)
        self.assertFalse(Path(captures[0]).exists())

    def test_unknown_or_duplicate_catalogue_architectures_refuse_before_network_or_uv(self):
        original = json.loads(BOOTSTRAP.PYTHON_RELEASE.read_text())
        arm_key = "cpython-3.11.16-darwin-aarch64-none"
        intel_key = "cpython-3.11.16-darwin-x86_64-none"
        variants = []
        unknown = json.loads(json.dumps(original))
        unknown["downloads"][intel_key]["arch"]["family"] = "x86_64_v3"
        variants.append(unknown)
        duplicate = json.loads(json.dumps(original))
        duplicate["downloads"][intel_key] = duplicate["downloads"][arm_key]
        variants.append(duplicate)
        missing = json.loads(json.dumps(original))
        del missing["downloads"][intel_key]
        variants.append(missing)
        extra = json.loads(json.dumps(original))
        extra["downloads"]["unknown"] = extra["downloads"][intel_key]
        variants.append(extra)
        for variant in variants:
            catalogue = Path(self.directory.name) / "catalogue.json"
            catalogue.write_text(json.dumps(variant))
            with (
                self.subTest(downloads=list(variant["downloads"])),
                patch.object(BOOTSTRAP, "PYTHON_RELEASE", catalogue),
                patch.object(BOOTSTRAP, "download", side_effect=AssertionError("network acquired")),
                patch.object(BOOTSTRAP, "_run_uv", side_effect=AssertionError("uv acquired")),
            ):
                with self.assertRaisesRegex(BOOTSTRAP.BootstrapFailure, "integrity"):
                    BOOTSTRAP.install_python(
                        "/native/uv", "cpython-3.11-macos-aarch64-none", self.deadline, 1
                    )

    def test_malformed_selected_native_identity_refuses_before_any_input_staging(self):
        original = json.loads(BOOTSTRAP.PYTHON_RELEASE.read_text())
        key = "cpython-3.11.16-darwin-x86_64-none"
        variants = [
            ("url", "https://unqualified.invalid/other"),
            ("sha256", "D" * 64),
            ("patch", True),
            ("variant", "freethreaded"),
            ("unknown", 1),
        ]
        for name, value in variants:
            invalid = json.loads(json.dumps(original))
            invalid["downloads"][key][name] = value
            catalogue = Path(self.directory.name) / "catalogue.json"
            catalogue.write_text(json.dumps(invalid))
            with (
                self.subTest(field=name),
                patch.object(BOOTSTRAP, "PYTHON_RELEASE", catalogue),
                patch.object(BOOTSTRAP, "download", side_effect=AssertionError("network acquired")),
                patch.object(BOOTSTRAP, "_run_uv", side_effect=AssertionError("uv acquired")),
            ):
                with self.assertRaisesRegex(BOOTSTRAP.BootstrapFailure, "integrity"):
                    BOOTSTRAP.install_python(
                        "/native/uv", "cpython-3.11-macos-x86_64-none", self.deadline, 1
                    )


class NativeSpoolShellTests(unittest.TestCase):
    # Replay only the native tool availability/output boundary in this child
    # shell. Every other test/file/process predicate remains the Bash builtin.
    # This seam works for both original direct scutil and shared getter callers.
    scutil_receiver = r"""
function [() {
    if builtin test "$#" -eq 3 && builtin test "$1" = -x && builtin test "$2" = /usr/sbin/scutil; then
        return 0
    fi
    builtin [ "$@"
}
function /usr/sbin/scutil() {
    if [ -n "${SNAPSHOT_TRACE:-}" ]; then printf 'read\n' >> "$SNAPSHOT_TRACE"; fi
    cat "$SNAPSHOT"
}
"""

    def test_private_json_preserves_independent_control_and_unicode_vectors(self):
        script = ROOT / "static/ergopti_plus/macos/modules/llm/network-retry.sh"
        for value in ("plain", 'quote"back\\slash', "line\nreturn\rtab\t", "\x01\x1f", "é日本🙂"):
            with self.subTest(value=repr(value)):
                result = subprocess.run(
                    [
                        bash_executable(),
                        "-c",
                        'set -u; source "$1"; managed_bootstrap_json_string "$2"',
                        "receiving",
                        str(script),
                        value,
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(json.loads(result.stdout), value)

    def test_no_python_spool_replaces_exact_owner_and_keeps_full_url_off_argv(self):
        # This is a shell join receiver. Native identity/PAC/filesystem proofs
        # remain the genuine Swift fixtures; the admission seam is explicit here.
        with tempfile.TemporaryDirectory(prefix="ergopti-spool-shell-") as root:
            directory = Path(root)
            receipt = directory / "receipt.json"
            peer = directory / "peer"
            peer.write_text(
                "#!" + os.sys.executable + "\nimport json,os,sys\n"
                "r=json.load(sys.stdin);r['argv']=sys.argv[1:];r['pid']=os.getpid()\n"
                "with open(os.environ['RECEIPT'],'x') as f:json.dump(r,f)\n",
                encoding="utf-8",
            )
            peer.chmod(0o700)
            environment = dict(
                os.environ,
                ERGOPTI_LAUNCHER_EXECUTABLE=str(peer),
                ERGOPTI_BOOTSTRAP_PYTHON="",
                RECEIPT=str(receipt),
            )
            for name in ("https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"):
                environment.pop(name, None)
            script = ROOT / "static/ergopti_plus/macos/modules/llm/network-retry.sh"
            command = 'set -u; source "$1"; managed_bootstrap_launcher_available() { return 0; }; '
            command += 'managed_bootstrap_download "$2" "$3" "$4" 5 resumable --replace-owner'
            owner = subprocess.Popen(
                [
                    bash_executable(),
                    "-c",
                    command,
                    "receiving",
                    str(script),
                    "https://pin.invalid/full/path?request=one",
                    str(directory / 'quote"é'),
                    "1" * 64,
                ],
                env=environment,
            )
            self.assertEqual(owner.wait(timeout=5), 0)
            captured = json.loads(receipt.read_text())
            self.assertEqual(captured["pid"], owner.pid)
            self.assertEqual(captured["argv"], ["--managed-bootstrap-download", "600000"])
            self.assertEqual(captured["url"], "https://pin.invalid/full/path?request=one")
            self.assertEqual(captured["output"], str(directory / 'quote"é'))
            self.assertEqual(captured["sha256"], "1" * 64)
            self.assertEqual(captured["timeout_ms"], 600000)
            self.assertEqual(captured["size"], 5)

    def test_explicit_all_proxy_aliases_survive_native_static_settings_without_lookup(self):
        script = ROOT / "static/ergopti_plus/macos/modules/llm/network-retry.sh"
        cases = [
            (
                {"ALL_PROXY": "http://upper.invalid:3111"},
                ["", "http://upper.invalid:3111", "http://upper.invalid:3111"],
            ),
            (
                {"all_proxy": "http://lower.invalid:3222"},
                ["http://lower.invalid:3222", "", "http://lower.invalid:3222"],
            ),
            (
                {
                    "all_proxy": "http://lower.invalid:3222",
                    "ALL_PROXY": "http://upper.invalid:3111",
                },
                [
                    "http://lower.invalid:3222",
                    "http://upper.invalid:3111",
                    "http://lower.invalid:3222",
                ],
            ),
        ]
        with tempfile.TemporaryDirectory(prefix="ergopti-system-network-") as folder:
            trace = Path(folder) / "native-getter"
            snapshot = Path(folder) / "snapshot"
            snapshot.write_text(
                "<dictionary> {\n  HTTPSEnable : 1\n  HTTPSProxy : static.invalid\n  HTTPSPort : 3333\n}\n"
            )
            for selected, expected in cases:
                environment = dict(
                    os.environ, SNAPSHOT_TRACE=str(trace), NO_PROXY=".bypass.invalid", no_proxy=""
                )
                for key in (
                    "https_proxy",
                    "HTTPS_PROXY",
                    "http_proxy",
                    "HTTP_PROXY",
                    "all_proxy",
                    "ALL_PROXY",
                ):
                    environment.pop(key, None)
                environment.update(selected)
                command = r"""
set -u
source "$1"
log_info() { printf '%s\n' "$*"; }
log_error() { printf '%s\n' "$*"; }
apply_system_network
printf '%s\n' "${all_proxy:-}" "${ALL_PROXY:-}" "$OPAQUE_NETWORK_INHERITED_HTTPS_ROUTE" "${https_proxy:-}" "${HTTPS_PROXY:-}" "$NO_PROXY" "$UV_SYSTEM_CERTS"
"""
                with self.subTest(selectors=selected):
                    replay = command.replace(
                        "apply_system_network\n",
                        self.scutil_receiver + "\napply_system_network\n",
                        1,
                    )
                    result = subprocess.run(
                        [bash_executable(), "-c", replay, "receiving", str(script)],
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(
                        result.stdout.splitlines(),
                        expected + ["", "", ".bypass.invalid,localhost,127.0.0.1,::1", "1"],
                    )
                    self.assertFalse(
                        trace.exists(),
                        "Explicit ALL routes prevent even the native settings lookup",
                    )
                    self.assertEqual(result.stderr, "")

    def test_automatic_configuration_logs_only_fixed_actual_helper_availability(self):
        script = ROOT / "static/ergopti_plus/macos/modules/llm/network-retry.sh"
        with tempfile.TemporaryDirectory(prefix="ergopti-system-pac-log-") as folder:
            snapshot = Path(folder) / "snapshot"
            snapshot.write_text(
                "<dictionary> {\n  ProxyAutoConfigEnable : 1\n  ProxyAutoConfigURLString : https://reserved:credential@pac.invalid/private?token=reserved\n}\n"
            )
            for available, expected in [
                (0, "Automatic network settings will be evaluated by the native download helper."),
                (
                    1,
                    "Automatic network settings require the native download helper or an explicit relay.",
                ),
            ]:
                environment = dict(os.environ)
                for key in (
                    "https_proxy",
                    "HTTPS_PROXY",
                    "http_proxy",
                    "HTTP_PROXY",
                    "all_proxy",
                    "ALL_PROXY",
                ):
                    environment.pop(key, None)
                command = r"""
set -u
source "$1"
log_info() { printf '%s\n' "$*"; }
log_error() { printf '%s\n' "$*"; }
managed_bootstrap_launcher_available() { return "$AVAILABLE"; }
apply_system_network
"""
                # Metadata/getter and positive native availability are explicit
                # callee seams, not proof of real macOS configuration or signing.
                command = command.replace(
                    "apply_system_network\n", self.scutil_receiver + "\napply_system_network\n", 1
                )
                environment.update(SNAPSHOT=str(snapshot), AVAILABLE=str(available))
                with self.subTest(available=available):
                    result = subprocess.run(
                        [bash_executable(), "-c", command, "receiving", str(script)],
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, expected + "\n")
                    self.assertEqual(result.stderr, "")
                    for private in (
                        "credential",
                        "pac.invalid",
                        "private",
                        "token=reserved",
                        "https://",
                    ):
                        self.assertNotIn(private, result.stdout + result.stderr)

    def test_missing_native_helper_refuses_before_curl_or_successor_without_private_pac_logs(self):
        script = ROOT / "static/ergopti_plus/macos/modules/llm/network-retry.sh"
        with tempfile.TemporaryDirectory(prefix="ergopti-system-pac-refusal-") as folder:
            directory = Path(folder)
            snapshot = directory / "snapshot"
            snapshot.write_text(
                "<dictionary> {\n  ProxyAutoConfigEnable : 1\n  ProxyAutoConfigURLString : https://pac.invalid/private?token=reserved\n}\n"
            )
            environment = dict(
                os.environ,
                SNAPSHOT=str(snapshot),
                ERGOPTI_BOOTSTRAP_PYTHON="",
                ERGOPTI_LAUNCHER_EXECUTABLE=str(
                    directory / "missing.app/Contents/MacOS/ErgoptiPlus"
                ),
                OUTPUT=str(directory / "asset"),
            )
            for key in (
                "https_proxy",
                "HTTPS_PROXY",
                "http_proxy",
                "HTTP_PROXY",
                "all_proxy",
                "ALL_PROXY",
            ):
                environment.pop(key, None)
            command = r"""
set -u
source "$1"
log_info() { printf '%s\n' "$*"; }
log_error() { printf '%s\n' "$*"; }
curl_resumable() { printf 'CURL_STARTED\n'; return 0; }
curl_resilient() { printf 'CURL_STARTED\n'; return 0; }
apply_system_network
if managed_bootstrap_download https://origin.invalid/path "$OUTPUT" "$DIGEST" 7 resumable; then
    printf 'SUCCESSOR_STARTED\n'
else
    exit $?
fi
"""
            environment["DIGEST"] = "1" * 64
            command = command.replace(
                "apply_system_network\n", self.scutil_receiver + "\napply_system_network\n", 1
            )
            result = subprocess.run(
                [bash_executable(), "-c", command, "receiving", str(script)],
                env=environment,
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertEqual(result.returncode, 78, result.stderr)
            self.assertEqual(
                result.stdout,
                "Automatic network settings require the native download helper or an explicit relay.\n"
                "The native download input owner is unavailable. No download was started.\n",
            )
            self.assertEqual(result.stderr, "")
            self.assertFalse(Path(environment["OUTPUT"]).exists())
            for private_or_success in (
                "pac.invalid",
                "private",
                "token=reserved",
                "CURL_STARTED",
                "SUCCESSOR_STARTED",
            ):
                self.assertNotIn(private_or_success, result.stdout + result.stderr)


class BootstrapFailureObservationTests(unittest.TestCase):
    """Actual transport/error producer with recording process/descriptor ports."""

    def engine(self):
        source = ROOT / "static/ergopti_plus/macos/platform/network/native_http.py"
        spec = importlib.util.spec_from_file_location("bootstrap_recording_engine", source)
        engine = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(engine)
        return engine

    def report(self, failure):
        # Execute the actual CLI catch/exit body, never a test copy of its policy.
        entry = ast.parse(SOURCE.read_text(encoding="utf-8")).body[-1]
        self.assertIsInstance(entry, ast.If)

        def main():
            raise failure

        output = io.StringIO()

        def exit(code):
            raise SystemExit(code)

        reporter = getattr(BOOTSTRAP, "_report_failure", None)
        with contextlib.redirect_stderr(output):
            with self.assertRaises(SystemExit) as refused:
                exec(
                    compile(ast.Module(body=[entry], type_ignores=[]), str(SOURCE), "exec"),
                    {
                        "__name__": "__main__",
                        "main": main,
                        "_report_failure": reporter,
                        "sys": SimpleNamespace(stderr=output, exit=exit),
                    },
                )
        self.assertEqual(refused.exception.code, 74)
        lines = output.getvalue().splitlines()
        self.assertEqual(lines[-1], "Managed bootstrap request failed: unavailable.")
        self.assertTrue(lines[0].startswith("# managed_bootstrap_failure "))
        for secret in ("private", "token", "https://", "Password"):
            self.assertNotIn(secret, output.getvalue())
        return json.loads(lines[0].removeprefix("# managed_bootstrap_failure "))

    def testRegisteredInitialFailurePreservesPrimaryAndRecordsRefusedPhysicalClosure(self):
        for registered in (False, True):
            with self.subTest(registered=registered):
                engine = self.engine()
                response = engine.NativeHTTPResponse.__new__(engine.NativeHTTPResponse)
                primary = RuntimeError("private cancellation")
                cleanup = OSError("private physical close refusal")
                retained = []

                def close():
                    retained.append((response, cleanup))
                    raise cleanup

                def progress():
                    raise primary

                with patch.object(response, "close", side_effect=close) as retire:
                    with self.assertRaises(BaseException) as raised:
                        response._open_wire(
                            b"{}",
                            ["--managed-http-worker", "2", "5"],
                            5,
                            2,
                            register=(lambda _: True) if registered else None,
                            progress=progress,
                        )
                self.assertIs(raised.exception, primary if registered else cleanup)
                retire.assert_called_once_with()
                self.assertEqual(retained, [(response, cleanup)])
                self.assertFalse(response._closed)
                self.assertIsNone(response._process)
                self.assertIsNone(response._selector)
                self.assertEqual(cleanup.native_diagnostic["stage"], "native_cleanup")
                self.assertEqual(cleanup.native_diagnostic["cleanup"], "unconfirmed")
                if registered:
                    self.assertEqual(primary.native_diagnostic["cleanup"], "unconfirmed")
                    self.assertIsNone(primary.native_diagnostic["native_child_status"])
                    self.assertIsNone(primary.native_diagnostic["native_receipt_reason"])

    def testRealIdentityAndSpawnRefusalsReportDifferentClosedStages(self):
        for phase, expected in (("identity", "NativeHTTPError"), ("spawn", "OSError")):
            with self.subTest(phase=phase):
                engine = self.engine()
                selector = SimpleNamespace(close=lambda: None)
                resolver = (
                    patch.object(
                        engine, "_resolve_worker", side_effect=engine.NativeHTTPError("unavailable")
                    )
                    if phase == "identity"
                    else patch.object(engine, "_resolve_worker", return_value="/owned/worker")
                )
                with patch.object(engine.selectors, "DefaultSelector", return_value=selector):
                    with (
                        resolver,
                        patch.object(
                            engine.subprocess,
                            "Popen",
                            side_effect=OSError("private token https://secret"),
                        ) as acquire,
                    ):
                        with self.assertRaises(engine.NativeHTTPError) as refused:
                            engine.open_request(
                                "https://source.invalid/path", timeout=5, idle_timeout=2
                            )
                self.assertEqual(acquire.call_count, int(phase == "spawn"))
                self.assertTrue(
                    hasattr(refused.exception, "native_diagnostic"),
                    "Actual unavailable failure must retain source provenance",
                )
                fact = self.report(refused.exception)
                self.assertEqual(fact["stage"], "native_" + phase)
                self.assertEqual(fact["exception_class"], expected)
                self.assertEqual(fact["cleanup"], "confirmed")
                self.assertIsNone(fact["native_child_status"])
                self.assertIsNone(fact["native_receipt_reason"])

    def testRealTerminalFailureReportsStatusOnlyAfterExactClosure(self):
        class Stream(io.BytesIO):
            def fileno(self):
                return 91

            def close(self):
                if getattr(self, "refuse_close", False) and not self.closed:
                    raise OSError("inert stream close refusal")
                return super().close()

        for refusal in ("none", "wait", "stream"):
            refuse_wait = refusal == "wait"
            failed_cleanup = refusal != "none"
            with self.subTest(refusal=refusal):
                engine = self.engine()
                child = SimpleNamespace(
                    pid=4711, returncode=None, stdin=Stream(), stdout=Stream(), poll=lambda: 78
                )

                child.stdout.refuse_close = refusal == "stream"
                self.addCleanup(io.BytesIO.close, child.stdin)
                self.addCleanup(io.BytesIO.close, child.stdout)

                def wait(*args, **kwargs):
                    if refuse_wait:
                        raise OSError("private wait refusal")
                    child.returncode = 78
                    return 78

                child.wait = wait
                selector = SimpleNamespace(
                    close=lambda: None,
                    register=lambda *args: None,
                    unregister=lambda *args: None,
                    select=lambda *args: [True],
                )
                payload = json.dumps(
                    {"version": 1, "success": False, "reason": "unavailable"}
                ).encode()
                with (
                    patch.object(engine.selectors, "DefaultSelector", return_value=selector),
                    patch.object(engine, "_resolve_worker", return_value="/owned/worker"),
                    patch.object(engine.subprocess, "Popen", return_value=child),
                    patch.object(engine.os, "set_blocking"),
                    patch.object(
                        engine.os, "write", side_effect=lambda descriptor, data: len(data)
                    ),
                    patch.object(engine.NativeHTTPResponse, "_frame", return_value=(b"C", payload)),
                    patch.object(engine.NativeHTTPResponse, "_read_exact", return_value=b""),
                ):
                    with self.assertRaises((engine.NativeHTTPError, OSError)) as refused:
                        engine.open_request(
                            "https://source.invalid/path", timeout=5, idle_timeout=2
                        )
                self.assertTrue(
                    hasattr(refused.exception, "native_diagnostic"),
                    "Exact error must retain its native owner outcome",
                )
                fact = self.report(refused.exception)
                self.assertTrue(child.stdin.closed)
                self.assertEqual(child.stdout.closed, refusal != "stream")
                self.assertEqual(fact["cleanup"], "unconfirmed" if failed_cleanup else "confirmed")
                self.assertEqual(
                    fact["stage"], "native_cleanup" if failed_cleanup else "native_terminal"
                )
                self.assertEqual(fact["native_child_pid"], None if failed_cleanup else 4711)
                self.assertEqual(fact["native_child_status"], None if failed_cleanup else 78)
                self.assertEqual(
                    fact["native_receipt_reason"], None if failed_cleanup else "unavailable"
                )
                io.BytesIO.close(child.stdout)

    def testActualImportAndMalformedFactsKeepFailurePrivateAndNonzero(self):
        with (
            patch.dict(sys.modules),
            patch.object(BOOTSTRAP.importlib.util, "spec_from_file_location", return_value=None),
        ):
            sys.modules.pop("_ergopti_native_http", None)
            with self.assertRaises(BOOTSTRAP.BootstrapFailure) as refused:
                BOOTSTRAP._native_request("https://source.invalid/path")
        self.assertTrue(
            hasattr(refused.exception, "bootstrap_stage"),
            "Actual native import refusal must preserve its stage",
        )
        fact = self.report(refused.exception)
        self.assertEqual(
            (fact["stage"], fact["exception_class"]), ("native_import", "BootstrapFailure")
        )
        failure = ValueError("private Password token")
        failure.bootstrap_stage = ["private"]
        failure.native_diagnostic = {
            "stage": ["private"],
            "exception_class": "private",
            "native_child_pid": 1,
            "native_child_status": 0,
            "native_receipt_reason": "complete",
            "cleanup": "confirmed",
        }
        fact = self.report(failure)
        self.assertEqual(
            (fact["stage"], fact["exception_class"], fact["cleanup"]),
            ("bootstrap", "ValueError", "unconfirmed"),
        )
        self.assertIsNone(fact["native_child_status"])
        self.assertIsNone(fact["native_receipt_reason"])


if __name__ == "__main__":
    unittest.main()
