# tools/diagnostics/macos_brew_archive_acceptance_test.py
"""Portable refusal/lifecycle controls; these never claim native Brew execution."""

from contextlib import contextmanager
import json
import hashlib
from types import SimpleNamespace
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

import macos_brew_archive_acceptance as probe
from macos_owned_process import OwnedProcessGroup
import macos_owned_process as process_owner


@contextmanager
def owned_directory_link(outer, link, target):
    """Keep POSIX symlinks; Windows uses a physical, confined directory junction."""
    outer = outer.resolve(strict=True)
    target = target.resolve(strict=True)
    if outer not in target.parents or outer not in link.parent.resolve(strict=True).parents:
        raise AssertionError("Link fixture must stay below its acquired private root")
    if link.exists() or link.is_symlink():
        raise AssertionError("Link fixture destination must be absent")
    if os.name == "nt":
        environment = os.environ.copy()
        environment["ERGOPTI_LINK_FIXTURE_TARGET"] = str(target)
        environment["ERGOPTI_LINK_FIXTURE_LINK"] = str(link)
        subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "$ErrorActionPreference='Stop'; "
                "New-Item -ItemType Junction -Path $env:ERGOPTI_LINK_FIXTURE_LINK "
                "-Target $env:ERGOPTI_LINK_FIXTURE_TARGET | Out-Null",
            ],
            env=environment,
            check=True,
            capture_output=True,
            timeout=10,
        )
    else:
        link.symlink_to(target, target_is_directory=True)
    try:
        if os.name == "nt" and link.lstat().st_reparse_tag != stat.IO_REPARSE_TAG_MOUNT_POINT:
            raise AssertionError("Directory fixture must be an actual junction")
        if link.resolve(strict=True) != target:
            raise AssertionError("Directory link must resolve to the exact owned foreign fixture")
        yield
    finally:
        # Remove only the acquired link, never recursively walk its target.
        if os.name == "nt":
            link.rmdir()
        else:
            link.unlink()


class ReceiptLinkModel:
    """Schema 1: closed virtual file links; real regular files remain real I/O.

    The ordinary Windows token cannot create file symlinks. Only rglob/lstat/readlink supply
    virtual entries; the unchanged tree_receipt hashes real bytes and modes.
    This model never qualifies native Windows file-symlink creation or Brew.
    """

    schema = 1

    @staticmethod
    def closed_name(value):
        return (
            isinstance(value, str)
            and value not in ("", ".", "..")
            and not any(character in value for character in "/\\\0")
        )

    def __init__(self, root, links):
        self.root = root.resolve(strict=True)
        self.links = dict(links)
        self.observed = []
        for name, target in self.links.items():
            if not self.closed_name(name) or not self.closed_name(target):
                raise AssertionError("Model links must have closed single-component names")
            if (self.root / name).exists() or (self.root / name).is_symlink():
                raise AssertionError("Virtual link must not replace a physical entry")

    @contextmanager
    def installed(self):
        original_rglob, original_lstat = Path.rglob, Path.lstat

        def rglob(path, pattern, **options):
            if path != self.root:
                return original_rglob(path, pattern, **options)
            if pattern != "*" or options:
                raise AssertionError("Unexpected tree-receipt enumeration protocol")
            if not all(
                self.closed_name(name) and self.closed_name(target)
                for name, target in self.links.items()
            ):
                raise AssertionError("Invalid modeled link descriptor")
            physical = list(original_rglob(path, pattern))
            if any(path.name in self.links for path in physical):
                raise AssertionError("Physical entry collided with a modeled link")
            return iter(physical + [self.root / name for name in self.links])

        def lstat(path, *arguments, **options):
            if path.parent == self.root and path.name in self.links:
                if arguments or options:
                    raise AssertionError("Unexpected link metadata protocol")
                self.observed.append(("lstat", path.name))
                return os.stat_result((stat.S_IFLNK | 0o777, 0, 0, 1, 0, 0, 0, 0, 0, 0))
            return original_lstat(path, *arguments, **options)

        def readlink(path, *arguments, **options):
            path = Path(path)
            if path.parent == self.root and path.name in self.links:
                if arguments or options:
                    raise AssertionError("Unexpected link target protocol")
                self.observed.append(("readlink", path.name))
                return self.links[path.name]
            raise AssertionError("Unexpected readlink outside the closed fixture model")

        with (
            patch.object(Path, "rglob", autospec=True, side_effect=rglob),
            patch.object(Path, "lstat", autospec=True, side_effect=lstat),
            patch.object(probe.os, "readlink", side_effect=readlink),
        ):
            yield self


@contextmanager
def receipt_file_link(root):
    """Choose the explicit model only on Windows, never replace the POSIX tier."""
    if os.name == "nt":
        with ReceiptLinkModel(root, {"link": "resource"}).installed() as model:
            yield model
    else:
        (root / "link").symlink_to("resource")
        yield None


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
                "tools/diagnostics/native_appleevent_registration_test.m",
                "tools/diagnostics/native_appleevent_probe_protocol.h",
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
                "tools/diagnostics/native_appleevent_registration_test.m",
                "tools/diagnostics/native_appleevent_probe_protocol.h",
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
            sentinel = foreign / "sentinel"
            sentinel.write_bytes(b"Independent foreign directory bytes\n")
            with owned_directory_link(outer, root / "tap", foreign):
                with self.assertRaisesRegex(probe.AdmissionError, "escapes"):
                    probe.owned_path(root, root / "tap")
                self.assertEqual(probe.owned_path(root, root), root)
            self.assertFalse((root / "tap").exists())
            self.assertEqual(list(foreign.iterdir()), [sentinel])
            self.assertEqual(sentinel.read_bytes(), b"Independent foreign directory bytes\n")

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
            root = Path(directory).resolve(strict=True)
            (root / "resource").write_bytes(b"Independent expected bytes\n")
            (root / "resource").chmod(0o751)
            with receipt_file_link(root) as model:
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
                (root / "resource").chmod(0o444)
                self.assertNotEqual(probe.tree_receipt(root), expected)
                (root / "resource").chmod(0o751)
                self.assertEqual(probe.tree_receipt(root), expected)
                (root / "resource").write_bytes(b"Corrupted signed resource\n")
                self.assertNotEqual(probe.tree_receipt(root), expected)
                (root / "resource").unlink()
                self.assertNotEqual(probe.tree_receipt(root), expected)
                if model is not None:
                    self.assertEqual(model.schema, 1)
                    self.assertIn(("lstat", "link"), model.observed)
                    self.assertIn(("readlink", "link"), model.observed)

    def test_tree_receipt_closed_link_model_conforms_to_real_regular_entries(self):
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            (root / "resource").write_bytes(b"Independent expected bytes\n")
            (root / "directory").mkdir()
            (root / "directory/nested").write_bytes(b"Independent nested bytes\n")
            physical = probe.tree_receipt(root)
            model = ReceiptLinkModel(root, {"link": "resource"})
            with model.installed():
                actual = probe.tree_receipt(root)
                self.assertEqual(actual.pop("link"), {"link": "resource"})
                self.assertEqual(actual, physical)
                self.assertEqual(model.observed, [("lstat", "link"), ("readlink", "link")])
                model.links["link"] = "missing"
                self.assertEqual(probe.tree_receipt(root)["link"], {"link": "missing"})
                del model.links["link"]
                self.assertEqual(probe.tree_receipt(root), physical)
            self.assertEqual(probe.tree_receipt(root), physical)
            if os.name != "nt":
                # Conformance against an actual POSIX file link stays mandatory.
                (root / "link").symlink_to("resource")
                real_link_receipt = probe.tree_receipt(root)
                (root / "link").unlink()
                with ReceiptLinkModel(root, {"link": "resource"}).installed():
                    self.assertEqual(probe.tree_receipt(root), real_link_receipt)

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
        self,
        root,
        *,
        outcome=-1743,
        failure=None,
        unexpected_delivery=False,
        partial_ready=False,
        registration_output=None,
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
                if arguments == [str(root / "native-appleevent-registration-test")]:
                    judge.assertTrue(options["confined"])
                    return subprocess.CompletedProcess(
                        arguments,
                        0,
                        (
                            "native_appkit_registration_controls=5\n"
                            "native_private_appleevent_controls=1\n"
                        )
                        if registration_output is None
                        else registration_output,
                        "",
                    )
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

    def test_sdk_private_event_control_is_required_before_any_native_delivery(self):
        for output in (
            "native_appkit_registration_controls=5\n",
            "native_appkit_registration_controls=5\nnative_private_appleevent_controls=0\n",
        ):
            with self.subTest(output=output), TemporaryDirectory() as directory:
                with self.assertRaisesRegex(probe.AppleEventBoundaryError, "registration refusals"):
                    self.invoke(directory, registration_output=output)
                self.assertFalse((Path(directory) / "appleevent-ready").exists())
                self.assertFalse((Path(directory) / "appleevent-delivered.1").exists())

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


class AppleEventTerminalControls(unittest.TestCase):
    """Constructed WNOWAIT facts test diagnostics, never native process retirement."""

    def setUp(self):
        constants = patch.multiple(probe.os, CLD_EXITED=1, CLD_KILLED=2, CLD_DUMPED=3, create=True)
        constants.start()
        self.addCleanup(constants.stop)

    def world(self, *, status=65):
        receiver = SimpleNamespace(pid=73136, returncode=None)
        group = SimpleNamespace(process=receiver, reaped=False)
        # Real Popen objects are hashable; preserve that contract in this recording object.
        receiver = Mock(pid=73136, returncode=None)
        group.process = receiver
        children = SimpleNamespace(groups={receiver: group})
        observed = SimpleNamespace(si_pid=73136, si_code=probe.os.CLD_EXITED, si_status=status)
        return children, receiver, group, observed

    def test_closed_appkit_policy_observation_preserves_refusal_and_availability(self):
        for before, after, expected in (("1/1", "1/1", True), ("0/3", "0/3", False)):
            with self.subTest(before=before):
                children, receiver, group, observed = self.world()
                errors = f"Owned AppleEvent recipient AppKit admission refused (reason 2; before {before}; after {after}).\n".encode()
                with patch.object(probe, "_appleevent_capture", return_value=(b"", errors)):
                    packet = probe._appleevent_terminal_packet(children, receiver, group, observed)
                self.assertEqual(packet["si_status"], 65)
                self.assertIsNone(receiver.returncode)
                self.assertFalse(group.reaped)
                self.assertEqual(packet["stderr_phase"], "appkit-policy")
                self.assertIsNone(packet["stderr_osstatus"])
                self.assertEqual(
                    packet["appkit_policy"],
                    {
                        "reason": 2,
                        "before_available": expected,
                        "before_policy": 1 if expected else 3,
                        "after_available": expected,
                        "after_policy": 1 if expected else 3,
                    },
                )
                self.assertEqual(packet["stderr_sha256"], hashlib.sha256(errors).hexdigest())
        children, receiver, group, observed = self.world()
        for malformed in (
            b"Owned AppleEvent recipient AppKit admission refused (reason 2; before 1/3; after 0/3).\n",
            b"Owned AppleEvent recipient AppKit admission refused (reason 2; before 0/1; after 0/3).\n",
        ):
            with patch.object(probe, "_appleevent_capture", return_value=(b"", malformed)):
                with self.assertRaises(probe.AdmissionError):
                    probe._appleevent_terminal_packet(children, receiver, group, observed)
        for private in (
            b"Owned AppleEvent recipient AppKit admission refused (reason 2; before 1/1; after 1/1).\nPRIVATE\n",
            b"Owned AppleEvent recipient AppKit admission refused (reason 2; before 1/1; after 1/1)!\n",
        ):
            with patch.object(probe, "_appleevent_capture", return_value=(b"", private)):
                packet = probe._appleevent_terminal_packet(children, receiver, group, observed)
            self.assertEqual(packet["stderr_phase"], "unclassified")
            self.assertNotIn("appkit_policy", packet)

    def test_current_process_and_transform_registration_refusals_remain_distinct(self):
        for stage, phase in (
            ("current-process", "registration-current-process"),
            ("transform", "registration-transform"),
        ):
            with self.subTest(stage=stage):
                children, receiver, group, observed = self.world()
                errors = (
                    "Owned AppleEvent recipient " + stage + " registration failed: -50\n"
                ).encode("ascii")
                with patch.object(probe, "_appleevent_capture", return_value=(b"", errors)):
                    packet = probe._appleevent_terminal_packet(children, receiver, group, observed)
                self.assertEqual(packet["si_pid"], 73136)
                self.assertEqual(packet["si_code"], 1)
                self.assertEqual(packet["si_status"], 65)
                self.assertEqual(packet["stderr_phase"], phase)
                self.assertEqual(packet["stderr_osstatus"], -50)
                self.assertEqual(packet["stderr_bytes"], len(errors))
                self.assertEqual(packet["stderr_sha256"], hashlib.sha256(errors).hexdigest())
                self.assertEqual(packet["stdout_sha256"], hashlib.sha256(b"").hexdigest())
                self.assertFalse(group.reaped)
                self.assertIsNone(receiver.returncode)

    def test_exact_terminal_status_and_fixed_osstatus_are_retained_without_raw_streams(self):
        children, receiver, group, observed = self.world()
        errors = b"Owned AppleEvent recipient registration failed: -50\n"
        with patch.object(probe, "_appleevent_capture", return_value=(b"", errors)):
            packet = probe._appleevent_terminal_packet(children, receiver, group, observed)
        self.assertEqual(packet["si_pid"], 73136)
        self.assertEqual(packet["si_code"], 1)
        self.assertEqual(packet["si_status"], 65)
        self.assertEqual(packet["stderr_phase"], "registration")
        self.assertEqual(packet["stderr_osstatus"], -50)
        self.assertEqual(packet["stderr_bytes"], len(errors))
        self.assertEqual(packet["stderr_sha256"], hashlib.sha256(errors).hexdigest())
        self.assertEqual(packet["stdout_sha256"], hashlib.sha256(b"").hexdigest())
        self.assertFalse(group.reaped)
        self.assertIsNone(receiver.returncode)
        for unknown in (
            b"private fixture path and credentials\n",
            b"Owned AppleEvent receipt failed: 2147483648\n",
        ):
            with patch.object(probe, "_appleevent_capture", return_value=(b"", unknown)):
                redacted = probe._appleevent_terminal_packet(children, receiver, group, observed)
            self.assertEqual(redacted["stderr_phase"], "unclassified")
            self.assertIsNone(redacted["stderr_osstatus"])
            self.assertNotIn(unknown.decode(), json.dumps(redacted))

    def test_foreign_terminal_or_unbounded_capture_cannot_export_a_native_fact(self):
        children, receiver, group, observed = self.world()
        for field, value in (
            ("si_pid", 73137),
            ("si_code", 4),
            ("si_status", 256),
            ("si_status", True),
        ):
            with self.subTest(field=field, value=value):
                invalid = SimpleNamespace(**vars(observed))
                setattr(invalid, field, value)
                with patch.object(probe, "_appleevent_capture") as read:
                    with self.assertRaisesRegex(probe.AdmissionError, "exact unreaped receiver"):
                        probe._appleevent_terminal_packet(children, receiver, group, invalid)
                read.assert_not_called()
        with patch.object(probe, "_appleevent_capture") as read:
            with self.assertRaisesRegex(probe.AdmissionError, "exact unreaped receiver"):
                probe._appleevent_terminal_packet(
                    children, receiver, SimpleNamespace(process=receiver, reaped=False), observed
                )
        read.assert_not_called()
        with patch.object(probe, "_appleevent_capture", return_value=(b"a" * 4097, b"")):
            unavailable = probe._appleevent_terminal_packet(children, receiver, group, observed)
        self.assertEqual(unavailable["capture_status"], "unavailable")
        self.assertEqual(unavailable["si_status"], 65)
        self.assertIsNone(unavailable["stdout_bytes"])

    def test_terminal_schema_rejects_unknown_facts_and_never_claims_group_closure(self):
        children, receiver, group, observed = self.world()
        with patch.object(probe, "_appleevent_capture", return_value=(b"", b"")):
            packet = probe._appleevent_terminal_packet(children, receiver, group, observed)
        for changes in (
            {"private_path": "not exportable"},
            {"stderr_bytes": 4097},
            {"stderr_phase": "private"},
            {"stderr_osstatus": 1},
        ):
            invalid = {**packet, **changes}
            with self.assertRaises(probe.AdmissionError):
                probe._validate_appleevent_terminal(invalid)
        with TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            writer = PhaseEvidenceControls().evidence(root)
            if writer is None:
                return  # Existing portable no-follow refusal remains explicit.
            try:
                self.assertTrue(
                    writer.record(
                        "appleevent.receiver-exit",
                        status="refused",
                        groups=[group],
                        native_terminal=packet,
                    )
                )
                expected = (root / "checkpoint.json").read_bytes()
                actual = json.loads(expected)
                self.assertEqual(actual["native_terminal"], packet)
                self.assertFalse(actual["ownership_closed"])
                self.assertEqual(actual["groups"], [{"pid": 73136, "closed": False}])
                self.assertFalse(
                    writer.record(
                        "appleevent.receiver-exit",
                        status="accepted",
                        closed=True,
                        groups=[group],
                        native_terminal=packet,
                    )
                )
                self.assertEqual((root / "checkpoint.json").read_bytes(), expected)
                self.assertTrue(writer.failed)
            finally:
                writer.close()

    def test_dead_receiver_diagnostic_precedes_original_refusal_and_cleanup(self):
        judge = AppleEventBoundaryControls()
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "sandbox.sb").write_text(judge.policy)
            children = judge.model(root)
            children.evidence = Mock()
            original_start = children.start

            def dead_start(arguments):
                receiver = original_start(arguments)
                receiver.returncode = None
                group = children.groups[receiver]
                group.process = receiver
                group.observe_exit.return_value = SimpleNamespace(
                    si_pid=73136, si_code=1, si_status=66
                )
                return receiver

            def observe_export(phase, **facts):
                self.assertEqual(phase, "appleevent.receiver-exit")
                self.assertFalse(facts["groups"][0].reaped)
                self.assertEqual(facts["native_terminal"]["si_status"], 66)
                self.assertEqual(children.sender_calls, [])
                return True

            children.start = dead_start
            children.evidence.record.side_effect = observe_export
            with (
                patch.object(probe.uuid, "uuid4", return_value=judge.nonce),
                patch.object(
                    probe, "native_compiler", return_value=[str(root / "modeled-native-clang")]
                ),
                patch.object(
                    probe,
                    "_appleevent_capture",
                    return_value=(b"", b"Owned AppleEvent handler admission failed: -50\n"),
                ),
            ):
                with self.assertRaisesRegex(
                    probe.AppleEventBoundaryError,
                    "exact owned AppleEvent receiver is no longer live",
                ):
                    probe.admit_appleevent_boundary(children, root)
            children.evidence.record.assert_called_once()
            self.assertEqual(len(children.active), 1)
            self.assertFalse(children.groups[children.active[0]].reaped)
            self.assertEqual(children.sender_calls, [])

    def test_capture_failure_preserves_exact_exit_without_exporting_exception_path(self):
        children, receiver, group, observed = self.world(status=68)
        with patch.object(
            probe, "_appleevent_capture", side_effect=OSError("private path and secret")
        ):
            packet = probe._appleevent_terminal_packet(children, receiver, group, observed)
        self.assertEqual(packet["si_pid"], 73136)
        self.assertEqual(packet["si_code"], 1)
        self.assertEqual(packet["si_status"], 68)
        self.assertEqual(packet["capture_status"], "unavailable")
        self.assertEqual(packet["stderr_phase"], "unavailable")
        self.assertIsNone(packet["stderr_osstatus"])
        self.assertIsNone(packet["stdout_bytes"])
        self.assertIsNone(packet["stderr_sha256"])
        self.assertNotIn("private path", json.dumps(packet))
        self.assertFalse(group.reaped)
        with patch.object(
            probe,
            "_appleevent_capture",
            side_effect=process_owner.OwnedProcessInterrupted("original cancellation"),
        ):
            with self.assertRaisesRegex(
                process_owner.OwnedProcessInterrupted, "original cancellation"
            ):
                probe._appleevent_terminal_packet(children, receiver, group, observed)

    def test_actual_capture_preserves_primary_interruption_when_close_also_fails(self):
        children, receiver, group, observed = self.world()
        root = Path("/recorded-private-capture-root")
        children.root = root
        children.captures = {receiver: (root / "owned.stdout", root / "owned.stderr")}
        children.capture_identities = {receiver: ((11, 22), (11, 23))}
        entry = SimpleNamespace(
            st_mode=stat.S_IFREG | 0o600, st_uid=42, st_dev=11, st_ino=22, st_size=0
        )
        interruption = process_owner.OwnedProcessInterrupted("original capture cancellation")
        with (
            patch.object(probe, "owned_path", side_effect=lambda _root, value: value),
            patch.object(probe.os, "O_NOFOLLOW", 0x100, create=True),
            patch.object(probe.os, "getuid", return_value=42, create=True),
            patch.object(probe.os, "open", return_value=61) as opening,
            patch.object(probe.os, "fstat", return_value=entry),
            patch.object(probe.os, "read", side_effect=interruption) as reading,
            patch.object(
                probe.os, "close", side_effect=OSError("secondary capture close refusal")
            ) as closing,
        ):
            with self.assertRaises(process_owner.OwnedProcessInterrupted) as captured:
                # Exercise the actual capture and outer packet functions, not a mocked capture helper.
                probe._appleevent_terminal_packet(children, receiver, group, observed)
        self.assertIs(captured.exception, interruption)
        opening.assert_called_once()
        reading.assert_called_once_with(61, 4097)
        closing.assert_called_once_with(61)
        self.assertFalse(group.reaped)
        self.assertIsNone(receiver.returncode)


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


class AppleEventSenderDiagnosticControls(unittest.TestCase):
    """Recording reply/owner observations are distinct from unexecuted macOS delivery."""

    def setUp(self):
        constants = patch.multiple(probe.os, CLD_EXITED=1, CLD_KILLED=2, CLD_DUMPED=3, create=True)
        constants.start()
        self.addCleanup(constants.stop)

    def packet(self):
        return {
            "schema": 1,
            "mode": 1,
            "send_status": 0,
            "nonce_read_available": True,
            "nonce_read_status": -1701,
            "nonce_size": 0,
            "nonce_match": False,
            "reply_type": 0x61657674,
            "error_read_available": True,
            "error_read_status": 0,
            "error_type": 0x6C6F6E67,
            "error_size": 4,
            "error_available": True,
            "error_number": -1708,
        }

    def marker(self, packet=None):
        packet = self.packet() if packet is None else packet
        return (
            "Owned AppleEvent outcome admission failed: "
            + str(packet["send_status"])
            + "\n"
            + "Owned AppleEvent sender diagnostic: "
            + json.dumps(packet, separators=(",", ":"))
            + "\n"
        )

    def world(self, observation=None):
        receiver = Mock(pid=73136, returncode=None)
        group = Mock(process=receiver, reaped=False)
        group.observe_exit.return_value = observation
        evidence = Mock()
        evidence.record.return_value = True
        children = SimpleNamespace(groups={receiver: group}, evidence=evidence)
        return children, receiver, group

    def test_actual_parser_preserves_numeric_reply_error_without_private_bytes(self):
        packet = probe._appleevent_sender_diagnostic(self.marker())
        self.assertEqual(packet, self.packet())
        self.assertEqual(packet["nonce_read_status"], -1701)
        self.assertEqual(packet["error_number"], -1708)
        self.assertNotIn("nonce", packet)
        self.assertNotIn("raw", json.dumps(packet))
        for key, value in (("nonce_size", 35), ("nonce_size", 37), ("nonce_read_status", -1700)):
            changed = self.packet()
            changed[key] = value
            self.assertEqual(probe._appleevent_sender_diagnostic(self.marker(changed))[key], value)

    def test_unknown_extra_duplicate_and_unavailable_fields_refuse(self):
        for key, value in (
            ("raw", "PRIVATE_NONCE"),
            ("schema", True),
            ("nonce_size", 4097),
            ("error_available", False),
            ("error_number", True),
            ("reply_type", 2**32),
        ):
            with self.subTest(key=key):
                changed = self.packet()
                changed[key] = value
                with self.assertRaises(probe.AdmissionError):
                    probe._appleevent_sender_diagnostic(self.marker(changed))
        duplicate = self.marker().replace('"schema":1', '"schema":1,"schema":1')
        for text in (duplicate, self.marker() + "PRIVATE\n", self.marker() * 10):
            with self.assertRaises(probe.AdmissionError):
                probe._appleevent_sender_diagnostic(text)
        changed = self.packet()
        changed.update(
            error_read_status=-1701,
            error_type=0x6E756C6C,
            error_size=0,
            error_available=False,
            error_number=None,
        )
        self.assertIsNone(probe._appleevent_sender_diagnostic(self.marker(changed))["error_number"])
        changed["error_number"] = -1708
        with self.assertRaises(probe.AdmissionError):
            probe._appleevent_sender_diagnostic(self.marker(changed))

    def test_exact_held_receiver_terminal_is_observed_before_any_retirement(self):
        observed = SimpleNamespace(si_pid=73136, si_code=1, si_status=68)
        children, receiver, group = self.world(observed)
        original = probe.AdmissionError("ORIGINAL_REFUSAL")
        with patch.object(
            probe,
            "_appleevent_capture",
            return_value=(b"", b"Owned AppleEvent dispatch failed: -36\n"),
        ):
            result = probe._observe_sender_failure(
                children, receiver, group, "unconfined-positive", self.marker(), original
            )
        self.assertEqual(result["receiver_state"], "terminal")
        self.assertEqual(result["native_terminal"]["si_status"], 68)
        self.assertEqual(result["native_terminal"]["stderr_osstatus"], -36)
        self.assertFalse(group.reaped)
        self.assertIsNone(receiver.returncode)
        group.settle.assert_not_called()
        children.evidence.record.assert_called_once()
        self.assertEqual(children.evidence.record.call_args.kwargs["sender_failure"], result)

    def test_pending_and_failed_observations_do_not_invent_exit_or_mask_original(self):
        children, receiver, group = self.world()
        original = probe.AdmissionError("ORIGINAL_REFUSAL")
        result = probe._observe_sender_failure(
            children, receiver, group, "unconfined-positive", self.marker(), original
        )
        self.assertEqual(result["receiver_state"], "pending")
        self.assertIsNone(result["native_terminal"])
        group.observe_exit.side_effect = OSError("PRIVATE_PATH")
        result = probe._observe_sender_failure(
            children, receiver, group, "unconfined-positive", "PRIVATE_NONCE", original
        )
        self.assertEqual(result["receiver_state"], "unavailable")
        self.assertEqual(result["sender_observation"], "unclassified")
        self.assertNotIn("PRIVATE", json.dumps(result))
        children.evidence.record.return_value = False
        probe._observe_sender_failure(
            children, receiver, group, "unconfined-positive", None, original
        )
        self.assertEqual(str(original), "ORIGINAL_REFUSAL")
        self.assertEqual(
            original.__notes__,
            ["Owned AppleEvent optional sender observation publication was refused."],
        )

    def test_new_owner_cancellation_and_base_exceptions_are_never_metadata(self):
        for interruption in (
            process_owner.OwnedProcessInterrupted("CONTROL_CANCEL"),
            KeyboardInterrupt(),
            SystemExit(71),
        ):
            with self.subTest(kind=type(interruption).__name__):
                children, receiver, group = self.world()
                group.observe_exit.side_effect = interruption
                with self.assertRaises(type(interruption)) as caught:
                    probe._observe_sender_failure(
                        children,
                        receiver,
                        group,
                        "unconfined-positive",
                        None,
                        probe.AdmissionError("ORIGINAL_REFUSAL"),
                    )
                self.assertIs(caught.exception, interruption)
                self.assertFalse(group.reaped)
                children.evidence.record.assert_not_called()
                group.observe_exit.side_effect = OSError("PRIVATE_SECONDARY")
                children.run = Mock(side_effect=interruption)
                with self.assertRaises(type(interruption)) as primary_caught:
                    probe._run_appleevent_sender(
                        children, receiver, group, "unconfined-positive", ["sender", "success"]
                    )
                self.assertIs(primary_caught.exception, interruption)
        interruption = process_owner.OwnedProcessInterrupted("CONTROL_CANCEL")
        with patch.object(probe, "_admit_appleevent_boundary", side_effect=interruption):
            with self.assertRaises(process_owner.OwnedProcessInterrupted) as caught:
                probe.admit_appleevent_boundary(None, None)
            self.assertIs(caught.exception, interruption)

    def test_first_sender_failure_keeps_original_error_and_blocks_later_effects(self):
        children, receiver, group = self.world()
        original = probe.AdmissionError("ORIGINAL_REFUSAL")
        children.run = Mock(side_effect=original)
        with self.assertRaises(probe.AdmissionError) as caught:
            probe._run_appleevent_sender(
                children, receiver, group, "unconfined-positive", ["sender", "success"]
            )
        self.assertIs(caught.exception, original)
        children.run.assert_called_once_with(["sender", "success"], check=False, confined=False)
        self.assertEqual(
            children.evidence.record.call_args.kwargs["sender_failure"]["sender_observation"],
            "unavailable",
        )
        children.run.side_effect = None
        children.run.return_value = subprocess.CompletedProcess(
            ["sender", "success"], 66, "", self.marker()
        )
        with self.assertRaisesRegex(probe.AdmissionError, "Owned sender failed with exit 66"):
            probe._run_appleevent_sender(
                children, receiver, group, "unconfined-positive", ["sender", "success"]
            )
        self.assertEqual(
            children.evidence.record.call_args.kwargs["sender_failure"]["sender"], self.packet()
        )
        self.assertFalse(group.reaped)

    def test_actual_boundary_first_sender_refusal_never_reaches_second_or_third_send(self):
        judge = AppleEventBoundaryControls()
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "sandbox.sb").write_text(judge.policy)
            children = judge.model(root)
            children.evidence = Mock()
            children.evidence.record.return_value = True
            original_start, original_run = children.start, children.run

            def start(arguments):
                receiver = original_start(arguments)
                children.groups[receiver].process = receiver
                receiver.returncode = None
                return receiver

            def run(arguments, **options):
                if arguments[-1] == "success":
                    children.sender_calls.append((arguments, options))
                    return subprocess.CompletedProcess(arguments, 66, "", self.marker())
                return original_run(arguments, **options)

            children.start, children.run = start, run
            with (
                patch.object(probe.uuid, "uuid4", return_value=judge.nonce),
                patch.object(
                    probe, "native_compiler", return_value=[str(root / "modeled-native-clang")]
                ),
            ):
                with self.assertRaisesRegex(
                    probe.AppleEventBoundaryError, "Owned sender failed with exit 66"
                ):
                    probe.admit_appleevent_boundary(children, root)
            self.assertEqual(len(children.sender_calls), 1)
            self.assertEqual(children.sender_calls[0][0][-1], "success")
            self.assertEqual(children.deliveries, 0)
            self.assertFalse((root / "appleevent-delivered.1").exists())
            self.assertFalse((root / "appleevent-delivered.2").exists())
            self.assertFalse((root / "appleevent-delivered.3").exists())
            self.assertEqual(len(children.active), 1)
            self.assertFalse(children.groups[children.active[0]].reaped)
            fact = children.evidence.record.call_args.kwargs["sender_failure"]
            self.assertEqual(fact["role"], "unconfined-positive")
            self.assertEqual(fact["sender"], self.packet())
            self.assertEqual(fact["receiver_state"], "pending")

    def test_sender_phase_writer_refuses_acceptance_and_foreign_group(self):
        children, receiver, group = self.world()
        original = probe.AdmissionError("ORIGINAL_REFUSAL")
        packet = probe._observe_sender_failure(
            children, receiver, group, "unconfined-positive", self.marker(), original
        )
        evidence = object.__new__(probe.PhaseEvidence)
        evidence.descriptor = 19
        evidence.started = probe.time.monotonic()
        evidence.sequence = 0
        evidence.failed = False
        evidence.ownership_closed = False
        evidence.previous = None
        stream = Mock()
        stream.fileno.return_value = 20
        context = Mock()
        context.__enter__ = Mock(return_value=stream)
        context.__exit__ = Mock(return_value=False)
        with (
            patch.object(probe.os, "O_NOFOLLOW", 0, create=True),
            patch.object(probe.os, "open", return_value=20),
            patch.object(probe.os, "fdopen", return_value=context),
            patch.object(probe.os, "fsync"),
            patch.object(probe.os, "link") as link,
            patch.object(probe.os, "replace") as replace,
            patch.object(probe.os, "unlink"),
            patch.object(probe.os, "close") as close,
        ):
            try:
                self.assertTrue(
                    evidence.record(
                        "appleevent.sender-refusal",
                        status="refused",
                        groups=[group],
                        sender_failure=packet,
                    )
                )
                written = json.loads(stream.write.call_args.args[0])
                self.assertEqual(written["sender_failure"], packet)
                self.assertFalse(written["ownership_closed"])
                self.assertNotIn("PRIVATE", json.dumps(written))
                link.assert_called_once()
                replace.assert_called_once()
                self.assertFalse(
                    evidence.record(
                        "appleevent.sender-refusal",
                        status="accepted",
                        groups=[group],
                        sender_failure=packet,
                    )
                )
                self.assertFalse(
                    evidence.record(
                        "appleevent.sender-refusal",
                        status="refused",
                        groups=[Mock(process=Mock(pid=73137), reaped=False)],
                        sender_failure=packet,
                    )
                )
                stream.write.assert_called_once()
            finally:
                evidence.close()
            close.assert_called_once_with(19)


if __name__ == "__main__":
    unittest.main()
