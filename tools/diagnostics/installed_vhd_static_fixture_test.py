# tools/diagnostics/installed_vhd_static_fixture_test.py
"""Portable raw collector controls; native pkgutil/curl/process endpoints are modeled."""

import ast
import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest import mock

import installed_vhd_static_fixture as subject

MODEL_ARTIFACTS = {
    "8.4.0": b"portable pinned fixture 8.4",
    "8.5.0": b"portable pinned fixture 8.5",
    "8.6.0": b"portable pinned fixture 8.6",
}
# These independent fixed digests were frozen before collector implementation.
MODEL_PINS = {
    "8.4.0": (27, "2d747de8d1efa1a4ca8bc140ced5e88ca5f9b66631071853740a2f07d04cedc7"),
    "8.5.0": (27, "52d4899e014849075b768eadbf286283dc128bbd7402028895db4e0a1c9e4340"),
    "8.6.0": (27, "8610df5b435228c76f010e441f61ae49f3c4d039372ea1c639c7c780c803efab"),
}


class RawAcquisitionControls(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve(strict=True)
        self.inputs = self.root / "inputs"
        self.inputs.mkdir(mode=0o700)
        for name in (
            "installed_vhd_static_fixture.py",
            "installed_vhd_acl_ci.py",
            "macos_owned_process.py",
        ):
            copied = self.inputs / name
            shutil.copyfile(subject.ROOT / name, copied)
            copied.chmod(0o600)
        self.artifacts = self.root / "provided"
        self.artifacts.mkdir(mode=0o700)
        for version, body in MODEL_ARTIFACTS.items():
            path = self.artifacts / subject.package_name(version)
            path.write_bytes(body)
            path.chmod(0o600)
        self.clock = [100.0]
        self.groups = []
        self.calls = []
        self.effect = lambda _phase, _group, _arguments: None
        self.closed = True
        self.status = 0
        self.output = b"UNCLASSIFIED NATIVE-ENDPOINT MODEL\n"
        self.actual_load = subject.load_policy
        self.policy = None

    def acquired(self, arguments, _native, register, **options):
        process = types.SimpleNamespace(pid=700 + len(self.groups), returncode=None)
        group = types.SimpleNamespace(process=process, reaped=False, reservation_lost=False)
        self.groups.append(group)
        self.calls.append(arguments)

        def wait(timeout):
            self.assertLessEqual(timeout, 25)
            self.assertLessEqual(timeout, 35)
            self.effect("wait", group, arguments)
            if "--output" in arguments:
                destination = Path(arguments[arguments.index("--output") + 1])
                version = next(
                    version for version in MODEL_ARTIFACTS if version in destination.name
                )
                destination.write_bytes(MODEL_ARTIFACTS[version])
            options["stdout"].write(self.output)
            options["stdout"].flush()

        def settle(timeout=1):
            self.assertEqual(timeout, 3)
            self.effect("settle", group, arguments)
            if self.closed:
                group.reaped = True
                process.returncode = self.status
            return self.closed

        group.wait_for_exit, group.settle = wait, settle
        register(group)
        self.effect("registered", group, arguments)
        return group

    def loaded_policy(self, deadline):
        policy = self.actual_load(deadline)
        actual_load = policy.load_captured
        actual_read = policy.read_input

        def read(path, maximum, *, source=True):
            body, information = actual_read(path, maximum, source=source)
            # This cloud rootfs maps system-image UID to65534. Darwin system
            # image UID0 is a declared modeled native metadata leaf only.
            if Path(path) == Path("/usr/bin/true").resolve(strict=True):
                information = information[:3] + (0,) + information[4:]
            return body, information

        policy.read_input = read

        def load(name, body, path, until):
            module = actual_load(name, body, path, until)
            if path.name == "macos_owned_process.py":
                module.NativeProcessGroups = lambda: object()
                module.acquire_owned = self.acquired
            return module

        policy.load_captured = load
        self.policy = policy
        return policy

    def execute(self, download=False):
        with (
            mock.patch.object(subject, "ROOT", self.inputs),
            mock.patch.object(subject, "PACKAGES", MODEL_PINS),
            mock.patch.object(
                subject, "TOOLS", {"curl": Path("/usr/bin/true"), "pkgutil": Path("/usr/bin/true")}
            ),
            mock.patch.object(subject.sys, "platform", "darwin"),
            mock.patch.object(subject.time, "monotonic", side_effect=lambda: self.clock[0]),
            mock.patch.object(subject, "load_policy", side_effect=self.loaded_policy),
        ):
            return subject.observe(self.root, None if download else self.artifacts)

    def test_healthy_source_bound_collection_never_admits_trust(self):
        root, packet = self.execute()
        self.assertEqual(len(packet["children"]), 4)
        self.assertEqual(len(self.calls), 4)
        self.assertEqual(self.calls[0][1:], ["--help"])
        self.assertTrue(all("--check-signature" in arguments for arguments in self.calls[1:]))
        self.assertEqual(packet["trust"], "unknown")
        self.assertIs(packet["authority"], False)
        self.assertIs(packet["reference_qualified"], False)
        self.assertEqual(packet["native_commands_failed"], 0)
        self.assertEqual(json.loads((root / "raw-observations.json").read_text()), packet)
        self.assertTrue(all(group.reaped for group in self.groups))
        self.assertEqual(root.stat().st_mode & 0o777, 0o700)

    def test_official_pins_keep_fixed85_and_real_alternatives(self):
        self.assertEqual(
            subject.PACKAGES,
            {
                "8.4.0": (
                    2090417,
                    "8e6c433f4e3aaa0403f6f3c72849cfcd054d52d83b53d7408771ade54f1d49a1",
                ),
                "8.5.0": (
                    2089117,
                    "d73d6d9428f0f80b87b8a8ba8a1031f2cbc3bc1fa6b74842d1f1b764b2916fc9",
                ),
                "8.6.0": (
                    2089875,
                    "ff8c7fdc5e25387c7805fc7509a0fa9cf98f69ba582704f717fddcae47424387",
                ),
            },
        )

    def test_frozen_model_pins_match_independent_before_code_bytes(self):
        self.assertEqual(
            MODEL_PINS,
            {
                version: (len(body), hashlib.sha256(body).hexdigest())
                for version, body in MODEL_ARTIFACTS.items()
            },
        )

    def test_unfamiliar_signed_or_trusted_text_is_still_unknown(self):
        self.output = b"trusted signed signature valid Developer ID Installer: MODEL\n"
        _, packet = self.execute()
        self.assertEqual(packet["trust"], "unknown")
        self.assertIs(packet["authority"], False)

    def test_nonzero_native_command_status_is_preserved_as_failed_raw_observation(self):
        self.status = 7
        _, packet = self.execute()
        self.assertEqual(packet["native_commands_failed"], 4)
        self.assertEqual([child["exit_status"] for child in packet["children"]], [7] * 4)
        self.assertEqual(packet["trust"], "unknown")

    def test_empty_raw_stream_is_observed_not_assumed_missing(self):
        self.output = b""
        _, packet = self.execute()
        self.assertTrue(
            all(stream["bytes"] == 0 for child in packet["children"] for stream in child["streams"])
        )

    def test_download_uses_fixed_https_and_default_certificate_verification(self):
        _, packet = self.execute(download=True)
        self.assertEqual(len(packet["children"]), 7)
        for arguments in self.calls[:3]:
            self.assertEqual(arguments[arguments.index("--proto") + 1], "=https")
            self.assertEqual(arguments[arguments.index("--proto-redir") + 1], "=https")
            self.assertNotIn("--insecure", arguments)
            self.assertNotIn("-k", arguments)
            self.assertLessEqual(float(arguments[arguments.index("--max-time") + 1]), 25)
            self.assertTrue(arguments[-1].startswith("https://github.com/pqrs-org/"))

    def test_download_nonzero_cannot_be_redeemed_by_matching_bytes(self):
        self.status = 7
        with self.assertRaises(ValueError):
            self.execute(download=True)
        self.assertEqual(len(self.groups), 1)
        self.assertTrue(self.groups[0].reaped)
        self.assertFalse(any(self.root.rglob("raw-observations.json")))

    def test_wrong_provided_artifact_refuses_before_pkgutil(self):
        path = self.artifacts / subject.package_name("8.5.0")
        path.write_bytes(b"wrong")
        with self.assertRaises(ValueError):
            self.execute()
        self.assertEqual(self.calls, [])

    def test_policy_change_after_bootstrap_refuses_before_native_acquisition(self):
        previous = self.loaded_policy

        def changed_after_bootstrap(deadline):
            policy = previous(deadline)
            with (self.inputs / "installed_vhd_acl_ci.py").open("ab") as output:
                output.write(b"\n# policy changed after its execution\n")
            return policy

        self.loaded_policy = changed_after_bootstrap
        with self.assertRaises(ValueError):
            self.execute()
        self.assertEqual(self.calls, [])
        self.assertFalse(any(self.root.rglob("raw-observations.json")))

    def test_source_hardlink_refuses_before_native_acquisition(self):
        os.link(self.inputs / "installed_vhd_static_fixture.py", self.root / "hardlink")
        with self.assertRaises(ValueError):
            self.execute()
        self.assertEqual(self.calls, [])

    def test_group_writable_policy_refuses_before_native_acquisition(self):
        (self.inputs / "installed_vhd_acl_ci.py").chmod(0o660)
        with self.assertRaises(ValueError):
            self.execute()
        self.assertEqual(self.calls, [])

    def test_provided_artifact_alias_refuses_before_native_acquisition(self):
        path = self.artifacts / subject.package_name("8.5.0")
        moved = path.with_suffix(".original")
        path.rename(moved)
        path.symlink_to(moved)
        with self.assertRaises((ValueError, OSError)):
            self.execute()
        self.assertEqual(self.calls, [])

    def test_registration_exception_still_retires_actual_acquired_owner(self):
        original = RuntimeError("private foreign exception")
        self.effect = lambda phase, _group, _arguments: (
            (_ for _ in ()).throw(original) if phase == "registered" else None
        )
        with self.assertRaises(RuntimeError) as caught:
            self.execute()
        self.assertIs(caught.exception, original)
        self.assertTrue(self.groups[0].reaped)

    def test_retirement_debt_never_publishes_complete_packet(self):
        self.closed = False
        with self.assertRaises(ValueError):
            self.execute()
        self.assertFalse(self.groups[0].reaped)
        self.assertFalse(any(self.root.rglob("raw-observations.json")))

    def test_lost_reservation_is_not_retirement(self):
        self.effect = lambda phase, group, _arguments: (
            setattr(group, "reservation_lost", True) if phase == "settle" else None
        )
        with self.assertRaises(ValueError):
            self.execute()
        self.assertFalse(any(self.root.rglob("raw-observations.json")))

    def test_wait_deadline_does_not_reset_for_later_commands(self):
        self.effect = lambda phase, _group, _arguments: (
            self.clock.__setitem__(0, 126.0) if phase == "wait" else None
        )
        with self.assertRaises(ValueError):
            self.execute()
        self.assertEqual(len(self.groups), 1)
        self.assertTrue(self.groups[0].reaped)

    def test_source_change_during_owned_wait_refuses_after_retirement(self):
        def effect(phase, _group, _arguments):
            if phase == "wait":
                with (self.inputs / "installed_vhd_static_fixture.py").open("ab") as stream:
                    stream.write(b"\n# changed source\n")

        self.effect = effect
        with self.assertRaises(ValueError):
            self.execute()
        self.assertTrue(self.groups[0].reaped)
        self.assertFalse(any(self.root.rglob("raw-observations.json")))

    def test_provided_package_change_during_owned_wait_refuses(self):
        self.effect = lambda phase, _group, _arguments: (
            (self.artifacts / subject.package_name("8.5.0")).write_bytes(b"changed")
            if phase == "wait"
            else None
        )
        with self.assertRaises(ValueError):
            self.execute()
        self.assertTrue(self.groups[0].reaped)

    def test_completed_stream_change_refuses_before_later_command(self):
        def effect(phase, _group, _arguments):
            if phase == "registered" and len(self.calls) == 2:
                path = next(self.root.rglob("pkgutil-help.stdout"))
                path.write_bytes(b"changed")

        self.effect = effect
        with self.assertRaises(ValueError):
            self.execute()
        self.assertTrue(self.groups[-1].reaped)

    def test_oversized_raw_output_refuses_without_complete_packet(self):
        self.output = b"x" * (subject.RAW_BYTES + 1)
        with self.assertRaises(ValueError):
            self.execute()
        self.assertTrue(self.groups[0].reaped)
        self.assertFalse(any(self.root.rglob("raw-observations.json")))

    def test_no_expansion_installer_or_protected_operations_are_invoked(self):
        _, packet = self.execute(download=True)
        text = json.dumps(self.calls)
        for denied in (
            "--expand",
            "installer",
            "launchctl",
            "systemextensionsctl",
            "/Library/",
            "codesign",
            "sudo",
        ):
            self.assertNotIn(denied, text)
        self.assertIs(packet["reference_qualified"], False)

    def test_unsupported_host_acquires_neither_evidence_nor_process(self):
        with mock.patch.object(subject.sys, "platform", "linux"):
            with self.assertRaises(ValueError):
                subject.observe(self.root / "absent")
        self.assertFalse((self.root / "absent").exists())
        self.assertEqual(self.calls, [])

    def test_root_invocation_is_not_ordinary_readonly_collection(self):
        with (
            mock.patch.object(subject.sys, "platform", "darwin"),
            mock.patch.object(subject.os, "geteuid", return_value=0),
        ):
            with self.assertRaises(ValueError):
                subject.observe(self.root / "absent")
        self.assertFalse((self.root / "absent").exists())

    def test_closed_cli_timeout_preserves_no_private_exception_payload(self):
        main = ast.parse(Path(subject.__file__).read_bytes()).body[-1]
        self.assertIsInstance(main, ast.If)
        namespace = dict(subject.__dict__)
        namespace.update(
            __name__="__main__",
            observe=mock.Mock(
                side_effect=subprocess.TimeoutExpired("PRIVATE_EXCEPTION_PAYLOAD", 25)
            ),
        )
        output = io.StringIO()
        with (
            mock.patch.object(subject.sys, "argv", [subject.__file__, "/owned"]),
            contextlib.redirect_stderr(output),
        ):
            with self.assertRaises(SystemExit) as caught:
                exec(
                    compile(ast.Module(body=[main], type_ignores=[]), subject.__file__, "exec"),
                    namespace,
                )
        self.assertEqual(caught.exception.code, 1)
        self.assertEqual(
            output.getvalue(), "Raw VHD package acquisition refused; evidence retained\n"
        )

    def test_ordinary_directory_descriptors_live_through_wait_and_close_once(self):
        opened, closed = [], []
        actual_open, actual_close = subject.os.open, subject.os.close

        def opened_directory(path, flags, *arguments):
            descriptor = actual_open(path, flags, *arguments)
            if flags & os.O_DIRECTORY:
                opened.append(descriptor)
            return descriptor

        def close(descriptor):
            if descriptor in opened:
                closed.append(descriptor)
            return actual_close(descriptor)

        def effect(phase, _group, _arguments):
            if phase == "wait":
                self.assertEqual(len(opened), 3)
                self.assertEqual(closed, [])
                self.assertTrue(
                    all(os.fstat(descriptor).st_mode & 0o40000 for descriptor in opened)
                )

        self.effect = effect
        with (
            mock.patch.object(subject.os, "open", side_effect=opened_directory),
            mock.patch.object(subject.os, "close", side_effect=close),
        ):
            self.execute()
        self.assertEqual(closed, list(reversed(opened)))
        for descriptor in opened:
            with self.assertRaises(OSError):
                os.fstat(descriptor)

    def test_directory_close_failure_refuses_return_and_attempts_other_owned_closes(self):
        opened, closed = [], []
        actual_open, actual_close = subject.os.open, subject.os.close

        def opened_directory(path, flags, *arguments):
            descriptor = actual_open(path, flags, *arguments)
            if flags & os.O_DIRECTORY:
                opened.append(descriptor)
            return descriptor

        def close(descriptor):
            actual_close(descriptor)
            if descriptor in opened:
                closed.append(descriptor)
                if len(closed) == 1:
                    raise OSError("modeled exact close refusal")

        with (
            mock.patch.object(subject.os, "open", side_effect=opened_directory),
            mock.patch.object(subject.os, "close", side_effect=close),
        ):
            with self.assertRaises(OSError):
                self.execute()
        self.assertEqual(closed, list(reversed(opened)))
        self.assertTrue(all(group.reaped for group in self.groups))

    def test_directory_registration_refusal_closes_just_acquired_descriptor(self):
        opened, closed = [], []
        actual_open, actual_close = subject.os.open, subject.os.close

        def opened_directory(path, flags, *arguments):
            descriptor = actual_open(path, flags, *arguments)
            if flags & os.O_DIRECTORY:
                opened.append(descriptor)
            return descriptor

        def close(descriptor):
            if descriptor in opened:
                closed.append(descriptor)
            return actual_close(descriptor)

        with (
            mock.patch.object(subject.os, "open", side_effect=opened_directory),
            mock.patch.object(subject.os, "close", side_effect=close),
            mock.patch.object(
                subject.contextlib.ExitStack,
                "callback",
                side_effect=RuntimeError("modeled registration refusal"),
            ),
        ):
            with self.assertRaises(RuntimeError):
                self.execute()
        self.assertEqual(len(opened), 1)
        self.assertEqual(closed, opened)
        self.assertEqual(self.calls, [])

    def test_summary_persistence_consumes_original_whole_deadline(self):
        actual_fsync = subject.os.fsync

        def fsync(descriptor):
            actual_fsync(descriptor)
            if len(self.calls) == 4:
                self.clock[0] = 126.0

        with mock.patch.object(subject.os, "fsync", side_effect=fsync):
            with self.assertRaises(ValueError):
                self.execute()
        self.assertTrue(all(group.reaped for group in self.groups))
        self.assertEqual(len(self.calls), 4)

    def test_late_package_inventory_addition_refuses_complete_return(self):
        def effect(phase, _group, _arguments):
            if phase == "wait" and len(self.calls) == 4:
                root = next(self.root.glob("vhd-raw-*"))
                (root / "packages" / "unadmitted.pkg").write_bytes(b"unadmitted")

        self.effect = effect
        with self.assertRaises(ValueError):
            self.execute()
        self.assertTrue(self.groups[-1].reaped)
        self.assertFalse(any(self.root.rglob("raw-observations.json")))

    def execute_public(self, *, download=True, status=0, errors=b"\x00\xffstderr\r\n"):
        acquired = self.acquired

        def public_acquired(arguments, native, register, **options):
            downloading = "--output" in arguments
            self.status = 0 if downloading else status
            group = acquired(arguments, native, register, **options)
            waited = group.wait_for_exit

            def wait(timeout):
                waited(timeout)
                if downloading:
                    options["stdout"].seek(0)
                    options["stdout"].truncate()
                    options["stdout"].write(b"PRIVATE_DOWNLOAD_STDOUT_SENTINEL")
                    options["stderr"].write(b"PRIVATE_DOWNLOAD_STDERR_SENTINEL")
                else:
                    options["stderr"].write(errors)
                options["stdout"].flush()
                options["stderr"].flush()

            group.wait_for_exit = wait
            return group

        with (
            mock.patch.object(subject, "ROOT", self.inputs),
            mock.patch.object(subject, "PACKAGES", MODEL_PINS),
            mock.patch.object(
                subject, "TOOLS", {"curl": Path("/usr/bin/true"), "pkgutil": Path("/usr/bin/true")}
            ),
            mock.patch.object(subject.sys, "platform", "darwin"),
            mock.patch.object(subject.time, "monotonic", side_effect=lambda: self.clock[0]),
            mock.patch.object(subject, "load_policy", side_effect=self.loaded_policy),
            mock.patch.object(self, "acquired", side_effect=public_acquired),
        ):
            return subject.observe(
                self.root, None if download else self.artifacts, log_public_pkgutil=True
            )

    def run_public_cli(self, *, packet=None, error=None, opted=True):
        main = ast.parse(Path(subject.__file__).read_bytes()).body[-1]
        namespace = dict(subject.__dict__)
        observer = (
            mock.Mock(side_effect=error) if error else mock.Mock(return_value=(self.root, packet))
        )
        namespace.update(__name__="__main__", observe=observer)
        output, errors = io.StringIO(), io.StringIO()
        arguments = [subject.__file__, "/owned"]
        if opted:
            arguments.append("--log-public-pkgutil")
        with (
            mock.patch.object(subject.sys, "argv", arguments),
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(errors),
        ):
            try:
                exec(
                    compile(ast.Module(body=[main], type_ignores=[]), subject.__file__, "exec"),
                    namespace,
                )
            except SystemExit as caught:
                return caught.code, output.getvalue(), errors.getvalue(), observer
        return 0, output.getvalue(), errors.getvalue(), observer

    def test_public_default_cli_and_api_preserve_original_summary(self):
        _, packet = self.execute()
        self.assertNotIn("public_pkgutil_streams", packet)
        status, output, errors, observer = self.run_public_cli(packet=packet, opted=False)
        self.assertEqual(status, 0)
        self.assertEqual(errors, "")
        self.assertEqual(
            output,
            json.dumps(
                {
                    "trust": "unknown",
                    "authority": False,
                    "diagnostic_root": str(self.root),
                    "native_commands_failed": 0,
                },
                sort_keys=True,
            )
            + "\n",
        )
        observer.assert_called_once_with(Path("/owned"), None)

    def test_public_exact_binary_eight_streams_and_no_download_or_private_paths(self):
        binary = b"\x00\xff\r\n::error::NATIVE_ENDPOINT_MODEL\x80"
        self.output = binary
        root, packet = self.execute_public()
        envelope = packet["public_pkgutil_streams"]
        self.assertEqual(len(self.calls), 7)
        self.assertEqual(envelope["trust"], "unknown")
        self.assertIs(envelope["authority"], False)
        self.assertIs(envelope["reference_qualified"], False)
        self.assertEqual(envelope["source_hashes"], packet["source_hashes"])
        self.assertEqual(envelope["image_hashes"], packet["image_hashes"])
        self.assertEqual(envelope["packages"], packet["packages"])
        self.assertEqual(
            [entry["operation"] for entry in envelope["operations"]],
            [
                "pkgutil-help",
                "pkgutil-signature-8.4.0",
                "pkgutil-signature-8.5.0",
                "pkgutil-signature-8.6.0",
            ],
        )
        for entry in envelope["operations"]:
            self.assertEqual(entry["exit_status"], 0)
            self.assertEqual(
                [stream["channel"] for stream in entry["streams"]], ["stdout", "stderr"]
            )
            for stream, expected in zip(entry["streams"], [binary, b"\x00\xffstderr\r\n"]):
                decoded = base64.b64decode(stream["base64"], validate=True)
                self.assertEqual(decoded, expected)
                self.assertEqual(stream["bytes"], len(expected))
                self.assertEqual(stream["sha256"], hashlib.sha256(expected).hexdigest())
                self.assertNotIn(b"PRIVATE_DOWNLOAD", decoded)
        self.assertNotIn(str(root), json.dumps(envelope))
        self.assertNotIn("diagnostic_root", envelope)
        self.assertEqual(json.loads((root / "raw-observations.json").read_text()), packet)
        self.assertTrue(all(group.reaped for group in self.groups))

    def test_public_framed_cli_multiline_exact_reconstruction_and_complete_bound(self):
        self.output = b"\x00\xff::error::MODEL\r\n" * 400
        _, packet = self.execute_public()
        status, output, errors, observer = self.run_public_cli(packet=packet)
        self.assertEqual(status, 0)
        self.assertEqual(errors, "")
        observer.assert_called_once_with(Path("/owned"), None, log_public_pkgutil=True)
        lines = output.splitlines()
        self.assertEqual(json.loads(lines[0])["authority"], False)
        self.assertLessEqual(len(output.encode()), 131072)
        frames = [json.loads(line) for line in lines[1:]]
        self.assertGreater(len(frames), 1)
        self.assertEqual([frame["index"] for frame in frames], list(range(1, len(frames) + 1)))
        for frame in frames:
            self.assertEqual(frame["kind"], "installed_vhd_public_pkgutil_chunk")
            self.assertEqual(frame["schema"], 1)
            self.assertEqual(frame["count"], len(frames))
            self.assertLessEqual(len(frame["base64"]), 4096)
        self.assertTrue(all(len(line) < 4500 for line in lines[1:]))
        decoded = b"".join(base64.b64decode(frame["base64"], validate=True) for frame in frames)
        self.assertTrue(all(frame["bytes"] == len(decoded) for frame in frames))
        self.assertTrue(
            all(frame["sha256"] == hashlib.sha256(decoded).hexdigest() for frame in frames)
        )
        self.assertEqual(json.loads(decoded), packet["public_pkgutil_streams"])
        self.assertNotIn("::error::", output)
        self.assertNotIn("PRIVATE_DOWNLOAD", output)

    def test_public_nonzero_status_and_empty_stderr_remain_unknown_observations(self):
        _, packet = self.execute_public(status=7, errors=b"")
        self.assertEqual(packet["native_commands_failed"], 4)
        for entry in packet["public_pkgutil_streams"]["operations"]:
            self.assertEqual(entry["exit_status"], 7)
            stream = entry["streams"][1]
            self.assertEqual(stream["channel"], "stderr")
            self.assertEqual(stream["bytes"], 0)
            self.assertEqual(stream["base64"], "")
            self.assertEqual(
                stream["sha256"], "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            )
        self.assertIs(packet["reference_qualified"], False)
        self.assertIs(packet["authority"], False)
        self.assertEqual(packet["trust"], "unknown")

    def test_public_provided_package_argument_refuses_before_native_acquisition(self):
        with self.assertRaises(ValueError):
            self.execute_public(download=False)
        self.assertEqual(self.calls, [])
        self.assertFalse(any(self.root.glob("vhd-raw-*")))

    def test_public_record_overbudget_refuses_after_retirement_without_summary(self):
        self.output = b"x" * 60000
        with self.assertRaises(ValueError):
            self.execute_public()
        self.assertEqual(len(self.calls), 7)
        self.assertTrue(all(group.reaped for group in self.groups))
        self.assertFalse(any(self.root.rglob("raw-observations.json")))
        self.assertEqual(subject.RAW_BYTES, 131072)
        self.assertEqual(subject.MAX_PACKET, 131072)

    def test_public_framed_budget_includes_encoding_and_never_truncates(self):
        within = {"public_pkgutil_streams": {"sample": "x" * 64000}}
        raw_log = subject.public_pkgutil_log(within)
        self.assertLessEqual(len(raw_log.encode()), 131072)
        frames = [json.loads(line) for line in raw_log.splitlines()]
        decoded = b"".join(base64.b64decode(frame["base64"], validate=True) for frame in frames)
        self.assertEqual(json.loads(decoded), within["public_pkgutil_streams"])
        # This raw JSON fits MAX_PACKET, but its exact framed representation does not.
        oversized = {"public_pkgutil_streams": {"sample": "x" * 98000}}
        self.assertLess(len(json.dumps(oversized["public_pkgutil_streams"]).encode()), 131072)
        with self.assertRaises(ValueError):
            subject.public_pkgutil_log(oversized)
        status, output, errors, _ = self.run_public_cli(packet=oversized)
        self.assertEqual(status, 1)
        self.assertEqual(output, "")
        self.assertEqual(errors, "Raw VHD package acquisition refused; evidence retained\n")

    def test_public_private_cli_exception_retains_exact_closed_refusal(self):
        status, output, errors, _ = self.run_public_cli(
            error=subprocess.TimeoutExpired("PRIVATE_EXCEPTION_PAYLOAD", 25)
        )
        self.assertEqual(status, 1)
        self.assertEqual(output, "")
        self.assertEqual(errors, "Raw VHD package acquisition refused; evidence retained\n")

    def test_public_cli_budget_includes_original_summary_before_any_emission(self):
        # Frozen framing arithmetic: 93213 envelope bytes in 31 chunks produce
        # 130289 log bytes. This opaque framing fixture models no native grammar.
        packet = {
            "native_commands_failed": 0,
            "public_pkgutil_streams": {"sample": "x" * 93200},
        }
        self.assertEqual(len(subject.public_pkgutil_log(packet).encode()), 130289)
        self.root = Path("/owned" + "/p" * 450)
        status, output, errors, _ = self.run_public_cli(packet=packet)
        self.assertEqual(status, 1)
        self.assertEqual(output, "")
        self.assertEqual(errors, "Raw VHD package acquisition refused; evidence retained\n")

    def test_public_source_currentness_and_retirement_refusals_never_return_envelope(self):
        for scenario in ("source", "stream", "deadline", "reservation", "debt", "close"):
            with self.subTest(scenario=scenario):
                fixture = RawAcquisitionControls()
                fixture.setUp()
                actual_close = subject.os.close
                try:

                    def effect(phase, group, _arguments):
                        if scenario == "source" and phase == "wait":
                            with (fixture.inputs / "installed_vhd_static_fixture.py").open(
                                "ab"
                            ) as stream:
                                stream.write(b"\n# changed public source\n")
                        if (
                            scenario == "stream"
                            and phase == "registered"
                            and len(fixture.calls) == 5
                        ):
                            next(fixture.root.rglob("pkgutil-help.stdout")).write_bytes(b"changed")
                        if scenario == "deadline" and phase == "wait":
                            fixture.clock[0] = 126.0
                        if scenario == "reservation" and phase == "settle":
                            group.reservation_lost = True

                    fixture.effect = effect
                    fixture.closed = scenario != "debt"

                    def close(descriptor):
                        directory = bool(os.fstat(descriptor).st_mode & 0o40000)
                        actual_close(descriptor)
                        if scenario == "close" and directory:
                            raise OSError("PRIVATE_DIRECTORY_CLOSE_ERROR")

                    output = io.StringIO()
                    with (
                        mock.patch.object(subject.os, "close", side_effect=close),
                        contextlib.redirect_stdout(output),
                    ):
                        with self.assertRaises((ValueError, OSError)):
                            fixture.execute_public()
                    self.assertEqual(output.getvalue(), "")
                    if scenario != "debt":
                        self.assertTrue(all(group.reaped for group in fixture.groups))
                    else:
                        self.assertFalse(fixture.groups[0].reaped)
                finally:
                    fixture.doCleanups()


if __name__ == "__main__":
    unittest.main()
