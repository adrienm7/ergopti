"""Receive pinned bootstrap inputs without claiming native PAC qualification."""

import hashlib
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


if __name__ == "__main__":
    unittest.main()
