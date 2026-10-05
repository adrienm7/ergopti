# tools/diagnostics/macos_brew_archive_acceptance_test.py
"""Portable refusal/lifecycle controls; these never claim native Brew execution."""

import json
import os
from pathlib import Path, PurePosixPath
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

import macos_brew_archive_acceptance as probe
from macos_owned_process import OwnedProcessGroup
import macos_owned_process as process_owner


class ArchiveAcceptanceControls(unittest.TestCase):
    def setUp(self):
        self.uid = patch.object(probe.os, "getuid", return_value=501, create=True)
        self.uid.start()
        self.addCleanup(self.uid.stop)
        self.kill_signal = patch.object(probe.signal, "SIGKILL", 9, create=True)
        self.kill_signal.start()
        self.addCleanup(self.kill_signal.stop)
        self.native = Mock()
        self.native.observe_exit.return_value = object()
        self.native.live_members.return_value = []
        self.native_patch = patch.object(probe, "NativeProcessGroups", return_value=self.native)
        self.native_patch.start()
        self.addCleanup(self.native_patch.stop)
        for name, value in (("SIG_BLOCK", 0), ("SIG_SETMASK", 2)):
            option = patch.object(probe.signal, name, value, create=True)
            option.start()
            self.addCleanup(option.stop)
        masking = patch.object(probe.signal, "pthread_sigmask", return_value=set(), create=True)
        masking.start()
        self.addCleanup(masking.stop)

    def test_non_macos_fails_before_fixture_or_child_acquisition(self):
        with (
            patch.object(probe.sys, "platform", "linux"),
            patch.object(probe.tempfile, "mkdtemp") as acquire,
        ):
            with self.assertRaisesRegex(probe.AdmissionError, "requires macOS"):
                probe.observe("unused", "unused")
            acquire.assert_not_called()

    def test_foreign_running_app_or_unknown_pgrep_status_fails_before_brew_mutation(self):
        for code, stdout in [(0, b"501\n"), (2, b""), (1, b"unexpected")]:
            with self.subTest(code=code, stdout=stdout):
                with (
                    patch.object(probe.sys, "platform", "darwin"),
                    patch.object(probe.Path, "is_file", return_value=True),
                    patch.object(probe.os, "access", return_value=True),
                    patch.object(probe.shutil, "which", return_value="/existing/bin/brew"),
                    patch.object(
                        probe.subprocess,
                        "run",
                        return_value=subprocess.CompletedProcess([], code, stdout, b""),
                    ) as child,
                ):
                    with self.assertRaisesRegex(probe.AdmissionError, "Foreign running Ergopti"):
                        probe.native_preconditions()
                    self.assertEqual(child.call_count, 1)

    def test_deadline_settles_exact_child_before_releasing_its_owned_capture_files(self):
        with TemporaryDirectory() as directory:
            owner = probe.Children(Path(directory))

            class Child:
                pid = 73136
                returncode = None

                def wait(self, **_options):
                    raise subprocess.TimeoutExpired("owned", 1)

            child = Child()
            with (
                patch.object(probe.subprocess, "Popen", return_value=child),
                patch.object(owner, "settle") as settle,
                patch.object(
                    OwnedProcessGroup,
                    "wait_for_exit",
                    side_effect=subprocess.TimeoutExpired("owned", 1),
                ),
            ):
                with self.assertRaisesRegex(probe.AdmissionError, "exceeded deadline"):
                    owner.run(["owned-executable"], timeout=1)
            settle.assert_called_once_with(child)
            self.assertEqual(owner.active, [])

    def test_acquired_root_retires_after_initialization_or_signal_acquisition_exception(self):
        with TemporaryDirectory() as directory:
            outer = Path(directory)
            repository = outer / "repository"
            for name in (
                "tools/build/homebrew-cask.cjs",
                "tools/build/macos-release-archives.cjs",
                "tools/diagnostics/macos_brew_archive_acceptance.py",
                "tools/diagnostics/macos_owned_process.py",
                "tools/diagnostics/native_appleevent_probe_receiver.c",
                "tools/diagnostics/native_appleevent_probe_sender.c",
            ):
                file = repository / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(b"Independent source identity bytes\n")
            for boundary in ("children", "signal"):
                with self.subTest(boundary=boundary):
                    output = outer / (boundary + ".json")
                    failure_patch = (
                        patch.object(
                            probe, "Children", side_effect=RuntimeError("construction failure")
                        )
                        if boundary == "children"
                        else patch.object(
                            probe.signal,
                            "signal",
                            side_effect=RuntimeError("signal acquisition failure"),
                        )
                    )
                    with (
                        patch.object(
                            probe, "native_preconditions", return_value=(outer, outer, outer)
                        ),
                        patch.object(probe, "host_receipt", return_value={}),
                        failure_patch,
                    ):
                        with self.assertRaises(probe.AdmissionError):
                            probe.observe(repository, output, fixture_parent=outer)
                    receipt = json.loads(output.read_text())
                    self.assertFalse(receipt["complete"])
                    self.assertFalse(receipt["fixture_retained"])
                    self.assertTrue(receipt["host_unchanged"])
                    self.assertEqual(receipt["cleanup_errors"], [])
                    self.assertEqual(list(outer.glob("ErgoptiBrewAcceptance-*")), [])

    def test_pending_native_cleanup_keeps_ledger_and_fixture_until_exact_closed_acknowledgement(
        self,
    ):
        with TemporaryDirectory() as directory:
            outer = Path(directory)
            repository = outer / "repository"
            for name in (
                "tools/build/homebrew-cask.cjs",
                "tools/build/macos-release-archives.cjs",
                "tools/diagnostics/macos_brew_archive_acceptance.py",
                "tools/diagnostics/macos_owned_process.py",
                "tools/diagnostics/native_appleevent_probe_receiver.c",
                "tools/diagnostics/native_appleevent_probe_sender.c",
            ):
                file = repository / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(b"Independent source identity bytes\n")
            output = outer / "receipt.json"
            children = Mock(debt=[{"kind": "process-group", "pid": 73136}], active=[], groups={})
            attempts = []

            def retire():
                attempts.append(len(attempts) + 1)
                self.assertEqual(len(list(outer.glob("ErgoptiBrewAcceptance-*"))), 1)
                if len(attempts) == 1:
                    self.assertFalse(output.exists())
                    return False
                pending = json.loads(output.read_bytes())
                self.assertEqual(
                    pending["ownership"], {"schema": 1, "helper_pid": os.getpid(), "closed": False}
                )
                self.assertTrue(pending["fixture_retained"])
                self.assertFalse(pending["complete"])
                children.debt = []
                return True

            children.retire.side_effect = retire
            with (
                patch.object(probe, "native_preconditions", return_value=(outer, outer, outer)),
                patch.object(probe, "host_receipt", return_value={}),
                patch.object(probe, "Children", return_value=children),
                patch.object(
                    probe,
                    "admit_sandbox",
                    side_effect=probe.AdmissionError("original operation deadline"),
                ),
                patch.object(probe.time, "sleep") as retry,
            ):
                with self.assertRaisesRegex(probe.AdmissionError, "original operation deadline"):
                    probe.observe(repository, output, fixture_parent=outer)
            self.assertEqual(attempts, [1, 2])
            retry.assert_called_once_with(0.25)
            terminal = json.loads(output.read_bytes())
            self.assertEqual(
                terminal["ownership"], {"schema": 1, "helper_pid": os.getpid(), "closed": True}
            )
            self.assertFalse(terminal["complete"])
            self.assertEqual(list(outer.glob("ErgoptiBrewAcceptance-*")), [])

    def test_process_group_retry_acknowledges_physical_retirement_and_clears_only_its_debt(self):
        with TemporaryDirectory() as directory:
            owner = probe.Children(Path(directory))

            class Child:
                pid = 73136
                returncode = None

                def wait(self, **_options):
                    self.returncode = 0
                    return 0

            child = Child()
            owner.groups[child] = OwnedProcessGroup(child, owner.native_groups)
            owner.active.append(child)
            owner.debt = [{"kind": "process-group", "pid": child.pid}]
            with patch.object(probe.os, "killpg", side_effect=ProcessLookupError, create=True):
                self.assertTrue(owner.retire())
            self.assertEqual(owner.active, [])
            self.assertEqual(owner.debt, [])

    def test_retried_canary_retirement_clears_only_its_exact_debt_without_duplicate_growth(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            children = probe.Children(root)
            canary = root / "owned-canary"
            canary.mkdir()
            children.external_owned.append(canary)
            with patch.object(probe.Path, "rmdir", side_effect=OSError("temporary refusal")):
                self.assertFalse(children.retire())
                self.assertFalse(children.retire())
            self.assertEqual(children.debt, [{"kind": "external-canary", "path": str(canary)}])
            self.assertTrue(canary.exists())
            self.assertTrue(children.retire())
            self.assertEqual(children.debt, [])
            self.assertEqual(children.external_owned, [])
            self.assertFalse(canary.exists())

    def test_tls_server_partial_construction_retires_bound_socket_before_thread_launch(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            owner = probe.Children(root)

            def key_generation(_arguments, **_options):
                (root / "tls.key").write_bytes(b"inert-key-fixture")
                return subprocess.CompletedProcess([], 0, "", "")

            bound = []
            original_close = probe.HTTPServer.server_close

            def close(server):
                bound.append(server)
                original_close(server)

            with (
                patch.object(owner, "run", side_effect=key_generation),
                patch.object(probe.ssl, "SSLContext"),
                patch.object(
                    probe.threading,
                    "Thread",
                    side_effect=RuntimeError("thread construction failure"),
                ),
                patch.object(probe.HTTPServer, "server_close", side_effect=close, autospec=True),
            ):
                with self.assertRaisesRegex(RuntimeError, "thread construction failure"):
                    probe.Assets(root, owner)
            self.assertEqual(len(bound), 1)
            self.assertEqual(bound[0].socket.fileno(), -1)
            self.assertEqual(owner.servers, [])
            self.assertTrue(owner.retire())

    def test_observed_symlink_cannot_admit_a_host_cache_or_tap(self):
        with TemporaryDirectory() as directory:
            outer = Path(directory)
            root = outer / "owned"
            foreign = outer / "foreign"
            root.mkdir()
            foreign.mkdir()
            (root / "tap").symlink_to(foreign, target_is_directory=True)
            with self.assertRaisesRegex(probe.AdmissionError, "escapes"):
                probe.owned_path(root, root / "tap")
            self.assertEqual(probe.owned_path(root, root), root)

    def test_environment_never_inherits_credentials_proxy_ruby_or_brew_injection(self):
        with patch.dict(
            os.environ,
            {
                "GH_TOKEN": "private",
                "HTTPS_PROXY": "private",
                "RUBYOPT": "private",
                "HOMEBREW_FORCE_VENDOR_RUBY": "1",
                "HOMEBREW_ARTIFACT_DOMAIN": "https://foreign.invalid",
            },
        ):
            environment = probe.private_environment(PurePosixPath("/owned-fixture"))
        self.assertNotIn("GH_TOKEN", environment)
        self.assertNotIn("HTTPS_PROXY", environment)
        self.assertNotIn("RUBYOPT", environment)
        self.assertNotIn("HOMEBREW_FORCE_VENDOR_RUBY", environment)
        self.assertNotIn("HOMEBREW_ARTIFACT_DOMAIN", environment)
        self.assertEqual(environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
        self.assertEqual(environment["HOMEBREW_TEMP"], "/owned-fixture/temp")
        self.assertEqual(environment["HOME"], "/owned-fixture/home")
        self.assertEqual(environment["HOMEBREW_DOWNLOAD_CONCURRENCY"], "2")

    def test_tree_receipt_detects_signed_byte_mode_symlink_or_missing_artifact_regression(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "resource").write_bytes(b"Independent expected bytes\n")
            (root / "resource").chmod(0o751)
            (root / "link").symlink_to("resource")
            expected = {
                "resource": {
                    "sha256": "822b2d0a72f6442eb1595796fe43863db2b2a59b4c0ac73012acdf3d44038984",
                    "mode": 0o666 if os.name == "nt" else 0o751,
                },
                "link": {"link": "resource"},
            }
            actual = probe.tree_receipt(root)
            # The hand-authored oracle uses known SHA bytes, independent of the
            # subject helper's digest implementation.
            self.assertEqual(actual, expected)
            (root / "resource").write_bytes(b"Corrupted signed resource\n")
            self.assertNotEqual(probe.tree_receipt(root), expected)
            (root / "resource").unlink()
            self.assertNotEqual(probe.tree_receipt(root), expected)

    def test_missing_declared_format_fails_before_cask_install(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            tap = root / "tap"
            tap.mkdir()
            cask = tap / "cask.rb"
            cask.write_text(
                '  sha256 "' + "a" * 64 + '"\n'
                '  url "https://github.com/adrienm7/ergopti/releases/download/v#{version}/ErgoptiPlus.app.zip"\n'
                '  app "ErgoptiPlus.app"\n'
            )

            class Renderer:
                def __init__(self):
                    self.root = root
                    self.calls = []

                def run(self, arguments, **_options):
                    self.calls.append(arguments)
                    return subprocess.CompletedProcess(arguments, 0, str(cask) + "\n", "")

            child = Renderer()
            with self.assertRaisesRegex(probe.AdmissionError, "origin/artifact/format"):
                probe.render_cask(
                    child, root, tap, "71.36.2", root / "ErgoptiPlus.app.tar.xz", "a" * 64
                )
            self.assertEqual(
                len(child.calls), 1, "No tap mutation follows rejected generator output"
            )
            self.assertEqual(child.calls[0][-2], "ErgoptiPlus.app.tar.xz")

    def test_native_sandbox_policy_contains_write_and_outbound_namespaces(self):
        profile = probe.sandbox_profile(PurePosixPath('/owned "fixture"'))
        self.assertIn("(deny file-write*)", profile)
        self.assertIn("(deny network-outbound)", profile)
        self.assertEqual(profile.count("(deny appleevent-send)"), 1)
        self.assertIn('(remote ip "localhost:*")', profile)
        self.assertEqual(profile.count("(allow network-outbound "), 1)
        self.assertEqual(profile.count("(remote ip "), 1)
        self.assertNotIn('(remote ip "*:*")', profile)
        self.assertIn("(subpath " + json.dumps('/owned "fixture"') + ")", profile)
        self.assertNotIn("(allow network-outbound)", profile)

    def test_process_group_debt_is_retained_when_descendants_survive_both_signals(self):
        with TemporaryDirectory() as directory:
            owner = probe.Children(Path(directory))

            class Child:
                pid = 73136
                returncode = None

                def wait(self, **_options):
                    raise AssertionError("Live group must keep the leader unreaped")

            child = Child()
            owner.groups[child] = OwnedProcessGroup(child, owner.native_groups)
            self.native.live_members.return_value = [87236]
            with (
                patch.object(probe.os, "killpg", create=True) as signal,
                patch.object(process_owner.time, "monotonic", side_effect=[0, 4, 0, 4, 0, 4]),
            ):
                owner.settle(child)
            self.assertEqual(owner.debt, [{"kind": "process-group", "pid": 73136}])
            self.assertFalse(owner.retire())
            self.assertEqual(
                [call.args[1] for call in signal.call_args_list],
                [probe.signal.SIGTERM, probe.signal.SIGKILL],
            )

    def test_retired_process_group_creates_no_cleanup_debt(self):
        with TemporaryDirectory() as directory:
            owner = probe.Children(Path(directory))

            class Child:
                pid = 73136
                returncode = None

                def wait(self, **_options):
                    self.returncode = 0
                    return 0

            child = Child()
            owner.groups[child] = OwnedProcessGroup(child, owner.native_groups)
            with patch.object(
                probe.os, "killpg", side_effect=ProcessLookupError, create=True
            ) as signals:
                owner.settle(child)
            signals.assert_not_called()
            self.assertEqual(owner.debt, [])
            self.assertTrue(owner.retire())


class AppleEventBoundaryControls(unittest.TestCase):
    """Model receipt admission separately from unexecuted native AppleEvent APIs."""

    nonce = "54bc7a36-e2f0-43f8-917e-ce3d286d7520"
    policy = "(version 1)\n(deny file-write*)\n(deny appleevent-send)\n(deny network-outbound)\n"

    def model(
        self, root, *, outcome=-1743, failure=None, unexpected_delivery=False, partial_ready=False
    ):
        judge = self

        class Boundary:
            def __init__(self):
                self.root = root
                self.active = []
                self.groups = {}
                self.sender_calls = []
                self.deliveries = 0

            def start(self, arguments):
                child = Mock(pid=73136)
                self.active.append(child)
                self.groups[child] = Mock(reaped=False)
                self.groups[child].observe_exit.return_value = None
                Path(arguments[1]).write_bytes(
                    b"" if partial_ready else b"73136\n" + judge.nonce.encode() + b"\n"
                )
                return child

            def run(self, arguments, **options):
                if arguments[-1] not in ("success", "denied"):
                    return subprocess.CompletedProcess(arguments, 0, "", "")
                self.sender_calls.append((arguments, options))
                if failure == len(self.sender_calls):
                    return subprocess.CompletedProcess(
                        arguments, 65, "", "independent native prerequisite failure"
                    )
                judge.assertEqual(arguments[-3:-1], ["73136", judge.nonce])
                if arguments[-1] == "success":
                    self.deliveries += 1
                    if self.deliveries == 2:
                        judge.assertEqual(arguments[:2], ["/usr/bin/sandbox-exec", "-f"])
                        judge.assertEqual(
                            Path(arguments[2]).read_text(),
                            "(version 1)\n(deny file-write*)\n(deny network-outbound)\n",
                        )
                    (root / ("appleevent-delivered." + str(self.deliveries))).write_bytes(
                        judge.nonce.encode()
                    )
                    return subprocess.CompletedProcess(
                        arguments, 0, "native_appleevent_status=0\n", ""
                    )
                judge.assertTrue(options["confined"])
                if unexpected_delivery:
                    (root / "appleevent-delivered.3").write_bytes(judge.nonce.encode())
                return subprocess.CompletedProcess(
                    arguments, 0, "native_appleevent_status=" + str(outcome) + "\n", ""
                )

            def settle(self, child):
                self.groups[child].reaped = True

        return Boundary()

    def invoke(self, directory, **options):
        root = Path(directory)
        (root / "sandbox.sb").write_text(self.policy)
        children = self.model(root, **options)
        with (
            patch.object(probe.uuid, "uuid4", return_value=self.nonce),
            patch.object(
                probe, "native_compiler", return_value=[str(root / "modeled-native-clang")]
            ),
        ):
            receipt = probe.admit_appleevent_boundary(children, root)
        return children, receipt

    def test_two_independent_positive_routes_precede_each_documented_refusal(self):
        for status in (-1742, -1743):
            with self.subTest(status=status), TemporaryDirectory() as directory:
                children, receipt = self.invoke(directory, outcome=status)
                self.assertEqual(receipt["unconfined_status"], 0)
                self.assertEqual(receipt["deny_removal_status"], 0)
                self.assertEqual(receipt["denied_status"], status)
                self.assertTrue(receipt["receiver_retired"])
                self.assertEqual(children.active, [])
                self.assertEqual(len(children.sender_calls), 3)
                self.assertEqual((Path(directory) / "sandbox.sb").read_text(), self.policy)

    def test_exclusive_readiness_creation_waits_for_complete_native_acknowledgement(self):
        expected = b"73136\n" + self.nonce.encode() + b"\n"
        with TemporaryDirectory() as directory:
            ready = Path(directory) / "appleevent-ready"
            acknowledgements = iter((b"731", expected))
            previous = iter((b"", b"731"))

            def complete_acknowledgement(_delay):
                self.assertEqual(ready.read_bytes(), next(previous))
                ready.write_bytes(next(acknowledgements))

            with patch.object(probe.time, "sleep", side_effect=complete_acknowledgement) as waiting:
                _children, receipt = self.invoke(directory, partial_ready=True)
            self.assertEqual(waiting.call_count, 2)
            self.assertTrue(receipt["receiver_retired"])
        for invalid in (b"foreign", expected + b"overflow"):
            with self.subTest(invalid=invalid), TemporaryDirectory() as directory:
                ready = Path(directory) / "appleevent-ready"
                with patch.object(
                    probe.time, "sleep", side_effect=lambda _delay: ready.write_bytes(invalid)
                ):
                    with self.assertRaisesRegex(probe.AppleEventBoundaryError, "identity or nonce"):
                        self.invoke(directory, partial_ready=True)
                self.assertFalse((Path(directory) / "appleevent-delivered.1").exists())
        with TemporaryDirectory() as directory:
            with patch.object(probe.time, "monotonic", side_effect=(0, 11)):
                with self.assertRaisesRegex(probe.AppleEventBoundaryError, "acknowledge readiness"):
                    self.invoke(directory, partial_ready=True)
            self.assertFalse((Path(directory) / "appleevent-delivered.1").exists())

    def test_arbitrary_nonzero_native_status_cannot_satisfy_policy_refusal(self):
        for status in (-1744, -600, -609, -1712, 0):
            with self.subTest(status=status), TemporaryDirectory() as directory:
                with self.assertRaisesRegex(
                    probe.AppleEventBoundaryError, "documented AppleEvent refusal"
                ):
                    self.invoke(directory, outcome=status)

    def test_missing_positive_or_deny_removal_prerequisite_cannot_count_as_denial(self):
        for phase in (1, 2):
            with self.subTest(phase=phase), TemporaryDirectory() as directory:
                with self.assertRaises(probe.AppleEventBoundaryError):
                    self.invoke(directory, failure=phase)
                self.assertFalse((Path(directory) / "appleevent-delivered.3").exists())

    def test_delivered_third_event_cannot_pass_even_with_an_admitted_refusal_status(self):
        with TemporaryDirectory() as directory:
            with self.assertRaisesRegex(probe.AppleEventBoundaryError, "delivery state"):
                self.invoke(directory, unexpected_delivery=True)


class PhaseEvidenceControls(unittest.TestCase):
    """Actual bounded filesystem controls; these never substitute native process closure."""

    def evidence(self, root):
        if not hasattr(os, "O_NOFOLLOW"):
            with self.assertRaisesRegex(probe.AdmissionError, "no-follow"):
                probe.PhaseEvidence(root)
            self.assertEqual(list(root.iterdir()), [])
            return None
        return probe.PhaseEvidence(root)

    def test_failed_initial_directory_census_retires_the_acquired_descriptor(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            if not hasattr(os, "O_NOFOLLOW"):
                self.evidence(root)
                return
            original_open, original_fstat = probe.os.open, probe.os.fstat
            acquired = []

            def tracked_open(*arguments, **options):
                descriptor = original_open(*arguments, **options)
                acquired.append(descriptor)
                return descriptor

            with (
                patch.object(probe.os, "open", side_effect=tracked_open),
                patch.object(probe.os, "fstat", side_effect=OSError("original census refusal")),
            ):
                with self.assertRaisesRegex(OSError, "original census refusal"):
                    probe.PhaseEvidence(root)
            self.assertEqual(len(acquired), 1)
            with self.assertRaises(OSError):
                original_fstat(acquired[0])
            self.assertEqual(list(root.iterdir()), [])

    def test_initial_phase_interruption_retires_evidence_without_acquiring_native_fixture(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            writer = self.evidence(root)
            if writer is None:
                return
            descriptor, original_record, original_fstat = writer.descriptor, writer.record, os.fstat

            def interrupted_initial(phase, **facts):
                if phase == "candidate.begin":
                    raise process_owner.OwnedProcessInterrupted("initial cancellation")
                return original_record(phase, **facts)

            with (
                patch.object(probe, "PhaseEvidence", return_value=writer),
                patch.object(writer, "record", side_effect=interrupted_initial),
                patch.object(probe.tempfile, "mkdtemp") as acquire,
            ):
                with self.assertRaisesRegex(
                    process_owner.OwnedProcessInterrupted, "initial cancellation"
                ):
                    probe.observe("unused", "unused", evidence_directory=root)
            acquire.assert_not_called()
            with self.assertRaises(OSError):
                original_fstat(descriptor)
            self.assertFalse(
                json.loads((root / "checkpoint.json").read_bytes())["ownership_closed"]
            )

    def test_phase_is_exported_before_native_prerequisite_refusal(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            writer = self.evidence(root)
            if writer is None:
                return
            writer.close()
            with (
                patch.object(probe.sys, "platform", "linux"),
                patch.object(probe.tempfile, "mkdtemp") as acquire,
            ):
                with self.assertRaisesRegex(probe.AdmissionError, "requires macOS"):
                    probe.observe("unused", "unused", evidence_directory=root)
            acquire.assert_not_called()
            packet = json.loads((root / "checkpoint.json").read_bytes())
            self.assertEqual(packet["phase"], "candidate.failed")
            self.assertEqual(packet["ownership_closed"], False)
            self.assertEqual(packet["owner_pid"], os.getpid())
            self.assertEqual(packet["groups"], [])

    def test_symlink_evidence_directory_cannot_write_foreign_state(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            if not hasattr(os, "O_NOFOLLOW"):
                self.evidence(root)
                return
            foreign = root / "foreign"
            foreign.mkdir()
            link = root / "link"
            link.symlink_to(foreign, target_is_directory=True)
            with self.assertRaises(OSError):
                probe.PhaseEvidence(link)
            self.assertEqual(list(foreign.iterdir()), [])

    def test_unknown_receipt_fact_cannot_export_private_payload_or_claim_closure(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            writer = self.evidence(root)
            if writer is None:
                return
            try:
                self.assertTrue(writer.record("candidate.begin"))
                expected = (root / "checkpoint.json").read_bytes()
                self.assertFalse(
                    writer.record(
                        "cleanup.closed", closed=True, cases={"private-signing-key": False}
                    )
                )
                self.assertTrue(writer.failed)
                self.assertEqual((root / "checkpoint.json").read_bytes(), expected)
                self.assertFalse(json.loads(expected)["ownership_closed"])
                self.assertEqual(
                    set(path.name for path in root.iterdir()), {"checkpoint.json", "phase-000.json"}
                )
            finally:
                writer.close()

    def test_signal_during_phase_publication_preserves_the_primary_cancellation(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            writer = self.evidence(root)
            if writer is None:
                return
            try:
                self.assertTrue(writer.record("candidate.begin"))
                expected = (root / "checkpoint.json").read_bytes()
                with patch.object(
                    probe.os,
                    "fsync",
                    side_effect=process_owner.OwnedProcessInterrupted("original cancellation"),
                ):
                    with self.assertRaisesRegex(
                        process_owner.OwnedProcessInterrupted, "original cancellation"
                    ):
                        writer.record("command.begin")
                self.assertEqual((root / "checkpoint.json").read_bytes(), expected)
                self.assertFalse(any(path.name.startswith(".phase-") for path in root.iterdir()))
            finally:
                writer.close()

    def test_bounded_history_preserves_latest_actual_phase_with_explicit_omission(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            writer = self.evidence(root)
            if writer is None:
                return
            try:
                for index in range(258):
                    self.assertTrue(writer.record("phase-" + str(index)))
                self.assertEqual(len(list(root.glob("phase-*.json"))), 256)
                latest = json.loads((root / "checkpoint.json").read_bytes())
                self.assertEqual(latest["phase"], "phase-257")
                self.assertEqual(latest["history_omitted"], 2)
                self.assertFalse(latest["ownership_closed"])
                self.assertLessEqual(max(path.stat().st_size for path in root.iterdir()), 4096)
            finally:
                writer.close()


class NativeCompilerSelectionControls(unittest.TestCase):
    """Qualify path/cache admission only, never actual macOS compilation."""

    def selected(self, root, developer):
        owner = Mock(root=root)
        owner.run.return_value = subprocess.CompletedProcess([], 0, str(developer) + "\n", "")
        return owner

    def make_layout(self, developer, xcode):
        tools = developer / ("Toolchains/XcodeDefault.xctoolchain/usr/bin" if xcode else "usr/bin")
        sdk = developer / (
            "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" if xcode else "SDKs/MacOSX.sdk"
        )
        tools.mkdir(parents=True)
        sdk.mkdir(parents=True)
        for tool in ("clang", "ld"):
            (tools / tool).write_bytes(b"Independent nonnative tool-path fixture")
            (tools / tool).chmod(0o700)
        return tools, sdk

    def test_selected_xcode_and_clt_paths_have_explicit_sdk_linker_and_private_cache(self):
        for xcode in [True, False]:
            with self.subTest(xcode=xcode), TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                developer = root / "Selected Developer With Spaces"
                tools, sdk = self.make_layout(developer, xcode)
                owner = self.selected(root, developer)
                plan = probe.native_compiler(owner)
                owner.run.assert_called_once_with(
                    ["/usr/bin/xcode-select", "--print-path"], confined=True
                )
                self.assertEqual(
                    plan,
                    [
                        str(tools / "clang"),
                        "-isysroot",
                        str(sdk),
                        "-B",
                        str(tools),
                        "-fmodules-cache-path=" + str(root / "native-compiler-cache"),
                    ],
                )
                self.assertTrue((root / "native-compiler-cache").is_dir())
                self.assertNotIn("/usr/bin/xcrun", plan)
                self.assertNotIn("/usr/bin/clang", plan)

    def test_unknown_or_malformed_selection_refuses_before_any_cache_acquisition(self):
        for value in ["relative\n", "missing\nsecond\n", "", "/missing-native-developer\n"]:
            with self.subTest(value=value), TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                owner = self.selected(root, root)
                owner.run.return_value.stdout = value
                with self.assertRaises((probe.AdmissionError, FileNotFoundError)):
                    probe.native_compiler(owner)
                self.assertFalse((root / "native-compiler-cache").exists())

    def test_foreign_sdk_symlink_and_prior_cache_are_refused(self):
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            developer = root / "Selected Developer"
            tools, sdk = self.make_layout(developer, True)
            sdk.rmdir()
            foreign = root / "Foreign SDK"
            foreign.mkdir()
            # Model the escape independently; native symlink semantics remain a CI gate.
            original = probe.Path.resolve

            def resolve(path, *args, **kwargs):
                if path == sdk:
                    return foreign
                return original(path, *args, **kwargs)

            with (
                patch.object(
                    probe.Path,
                    "is_dir",
                    autospec=True,
                    side_effect=lambda path: path == sdk or path == foreign,
                ),
                patch.object(probe.Path, "resolve", autospec=True, side_effect=resolve),
            ):
                with self.assertRaisesRegex(probe.AdmissionError, "escaped"):
                    probe.native_compiler(self.selected(root, developer))
            self.assertFalse((root / "native-compiler-cache").exists())
            sdk.mkdir()
            (root / "native-compiler-cache").write_bytes(b"Independent preexisting private input")
            with self.assertRaises(FileExistsError):
                probe.native_compiler(self.selected(root, developer))
            self.assertEqual(
                (root / "native-compiler-cache").read_bytes(),
                b"Independent preexisting private input",
            )


if __name__ == "__main__":
    unittest.main()
