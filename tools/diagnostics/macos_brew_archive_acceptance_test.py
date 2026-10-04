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
            children = Mock(debt=[{"kind": "process-group", "pid": 73136}])
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
        self.assertIn('(remote ip "127.0.0.1:*")', profile)
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
        with patch.object(probe.uuid, "uuid4", return_value=self.nonce):
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


if __name__ == "__main__":
    unittest.main()
