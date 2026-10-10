# tools/diagnostics/macos_brew_archive_acceptance_test.py
"""Portable refusal/lifecycle controls; these never claim native Brew execution."""

from contextlib import contextmanager
import ast
import inspect
import io
import json
import hashlib
from types import SimpleNamespace
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tempfile
import textwrap
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


class OwnedCaptureLinkModel:
    """Bind the single modeled Windows link to two retained real file streams."""

    def __init__(self, path, target, value, capture_stream, target_stream):
        if type(capture_stream) is not io.FileIO or type(target_stream) is not io.FileIO:
            raise AssertionError("Capture link model requires actual unbuffered file owners")
        self.path, self.target, self.value = path, target, value
        self.capture_stream, self.target_stream = capture_stream, target_stream
        self.native_lstat, self.native_fstat = Path.lstat, os.fstat
        self.identities = {
            path: self.identity(self.native_fstat(capture_stream.fileno())),
            target: self.identity(self.native_fstat(target_stream.fileno())),
        }
        self.validate(path)

    @staticmethod
    def identity(metadata):
        return metadata.st_dev, metadata.st_ino

    def validate(self, observed):
        if observed != self.path:
            raise AssertionError("Foreign capture link projection refused")
        for path, stream in ((self.path, self.capture_stream), (self.target, self.target_stream)):
            if stream.closed or Path(stream.name) != path:
                raise AssertionError("Closed or foreign capture stream refused")
            retained = self.native_fstat(stream.fileno())
            current = self.native_lstat(path)
            if (
                not stat.S_ISREG(retained.st_mode)
                or not stat.S_ISREG(current.st_mode)
                or retained.st_nlink != 1
                or current.st_nlink != 1
                or self.identity(retained) != self.identities[path]
                or self.identity(current) != self.identities[path]
            ):
                raise AssertionError("Capture link file identity or regular kind changed")
            stream.seek(0)
            if retained.st_size != len(self.value) or stream.read(129) != self.value:
                raise AssertionError("Retained capture link bytes changed")

    def project(self, observed):
        self.validate(observed)
        metadata = self.native_lstat(observed)
        modeled = list(metadata)
        modeled[0] = stat.S_IFLNK | stat.S_IMODE(metadata.st_mode)
        return os.stat_result(modeled)


@contextmanager
def owned_capture_file_link(path, target):
    """Use real POSIX links; Windows projects only the exact retained file's type."""
    path, target = Path(path), Path(target)
    parent = path.parent.resolve(strict=True)
    if path.parent != parent or target.parent != parent or path.exists():
        raise AssertionError("Capture link must have one acquired physical parent and absent name")
    target_info = target.lstat()
    if not stat.S_ISREG(target_info.st_mode) or target_info.st_nlink != 1:
        raise AssertionError("Capture link target must be the exact single-link regular fixture")
    if os.name != "nt":
        path.symlink_to(target)
        yield None
        return
    with target.open("rb", buffering=0) as target_stream:
        value = target_stream.read(129)
        if not 0 < len(value) <= 128:
            raise AssertionError("Capture link bytes exceed the existing parser bound")
        with path.open("xb") as writer:
            writer.write(value)
        with path.open("rb", buffering=0) as capture_stream:
            model = OwnedCaptureLinkModel(path, target, value, capture_stream, target_stream)
            original_lstat = Path.lstat

            def lstat(observed, *arguments, **options):
                if observed != path:
                    return original_lstat(observed, *arguments, **options)
                if arguments or options:
                    raise AssertionError("Unexpected capture-link metadata protocol")
                return model.project(observed)

            with patch.object(Path, "lstat", autospec=True, side_effect=lstat):
                yield model


def reject_changed_capture_link_inputs(case, model):
    """Exercise the real model against foreign metadata, changed bytes and closed owners."""
    foreign = model.path.parent / "foreign-link-model.stderr"
    with foreign.open("xb") as writer:
        writer.write(model.value)
    try:
        foreign_metadata = model.native_lstat(foreign)
        original_lstat = model.native_lstat
        with patch.object(
            model,
            "native_lstat",
            side_effect=lambda path: (
                foreign_metadata if path == model.path else original_lstat(path)
            ),
        ):
            with case.assertRaisesRegex(AssertionError, "file identity"):
                model.project(model.path)
        wrong_kind = list(foreign_metadata)
        wrong_kind[0] = stat.S_IFDIR | stat.S_IMODE(foreign_metadata.st_mode)
        with patch.object(
            model,
            "native_lstat",
            side_effect=lambda path: (
                os.stat_result(wrong_kind) if path == model.path else original_lstat(path)
            ),
        ):
            with case.assertRaisesRegex(AssertionError, "regular kind"):
                model.project(model.path)
        with case.assertRaisesRegex(AssertionError, "Foreign capture link"):
            model.project(foreign)
        with model.path.open("wb") as writer:
            writer.write(b"changed owned bytes\n")
        try:
            with case.assertRaisesRegex(AssertionError, "bytes changed"):
                model.project(model.path)
        finally:
            with model.path.open("wb") as writer:
                writer.write(model.value)
        case.assertTrue(stat.S_ISLNK(model.project(model.path).st_mode))
        model.capture_stream.close()
        with case.assertRaisesRegex(AssertionError, "Closed or foreign"):
            model.project(model.path)
    finally:
        foreign.unlink()


@contextmanager
def owned_registration_capture_ports(root, path):
    """Record POSIX directory/no-follow metadata only on the exact Windows capture.

    Real regular-file open/read/fstat/close preserve bytes, device/inode and nlink.
    These ports exercise the unchanged parser; they do not qualify native POSIX APIs.
    """
    if os.name != "nt":
        yield None
        return
    if root != root.resolve(strict=True) or path.parent != root:
        raise AssertionError("Registration ports require one acquired physical capture parent")
    native_open, native_fstat, native_read, native_close = os.open, os.fstat, os.read, os.close
    metadata = root.lstat()
    if not stat.S_ISDIR(metadata.st_mode):
        raise AssertionError("Registration port parent must remain an actual directory")
    # Nonzero protocol sentinels are recording-only and never reach native Windows open.
    model_directory, model_nofollow, model_nonblock = 1 << 24, 1 << 25, 1 << 26
    modeled_bits = model_directory | model_nofollow | model_nonblock
    directory_flags = os.O_RDONLY | model_directory | model_nofollow
    file_flags = os.O_RDONLY | model_nofollow | model_nonblock
    directory_metadata = list(metadata)
    directory_metadata[0] = stat.S_IFDIR | 0o700
    directory_token = object()
    live_directory = False
    directory_acquired = False
    file_attempted = False
    files = set()
    witness = {"link_refusals": 0, "file_stats": 0, "reads": 0, "file_closes": 0, "flags": []}

    def opening(value, flags, mode=0o777, *, dir_fd=None):
        nonlocal live_directory, directory_acquired, file_attempted
        if dir_fd is None and Path(value) == root and not directory_acquired:
            if type(flags) is not int or flags != directory_flags:
                raise OSError("Recorded directory capture flags refused")
            witness["flags"].append(flags)
            live_directory = True
            directory_acquired = True
            return directory_token
        if (
            dir_fd is not directory_token
            or not live_directory
            or value != path.name
            or file_attempted
        ):
            raise AssertionError("Foreign, closed or duplicate capture opening refused")
        if type(flags) is not int or flags != file_flags:
            raise OSError("Recorded file capture flags refused")
        witness["flags"].append(flags)
        file_attempted = True
        if path.is_symlink():
            witness["link_refusals"] += 1
            raise OSError("Controlled no-follow capture link refusal")
        descriptor = native_open(path, flags & ~modeled_bits)
        files.add(descriptor)
        return descriptor

    def fstat(descriptor):
        if descriptor is directory_token and live_directory:
            return os.stat_result(directory_metadata)
        if descriptor not in files:
            raise AssertionError("Foreign or closed capture observation refused")
        witness["file_stats"] += 1
        result = native_fstat(descriptor)
        current = path.stat()
        if (result.st_dev, result.st_ino) != (current.st_dev, current.st_ino):
            raise AssertionError("The actual capture descriptor must retain its file identity")
        return result

    def reading(descriptor, limit):
        if descriptor not in files or limit != 129:
            raise AssertionError("Capture read must retain its exact descriptor and byte bound")
        witness["reads"] += 1
        return native_read(descriptor, limit)

    def closing(descriptor):
        nonlocal live_directory
        if descriptor is directory_token and live_directory:
            live_directory = False
            return
        if descriptor not in files:
            raise AssertionError("Foreign or duplicate capture close refused")
        native_close(descriptor)
        files.remove(descriptor)
        witness["file_closes"] += 1

    with (
        patch.object(probe.os, "O_DIRECTORY", model_directory, create=True),
        patch.object(probe.os, "O_NOFOLLOW", model_nofollow, create=True),
        patch.object(probe.os, "O_NONBLOCK", model_nonblock, create=True),
        patch.object(probe.os, "getuid", return_value=metadata.st_uid, create=True),
        patch.object(probe.os, "open", side_effect=opening),
        patch.object(probe.os, "fstat", side_effect=fstat),
        patch.object(probe.os, "read", side_effect=reading),
        patch.object(probe.os, "close", side_effect=closing),
    ):
        try:
            yield witness
        finally:
            if files or live_directory:
                raise AssertionError("Exact registration capture retirement remains unacknowledged")


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
                "tools/diagnostics/native_appleevent_permission.c",
                "tools/diagnostics/native_appleevent_consent.m",
                "tools/diagnostics/native_appleevent_registration_test.m",
                "tools/diagnostics/native_appleevent_probe_protocol.h",
                "tools/diagnostics/native_appleevent_probe_pair.m",
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
                "tools/diagnostics/native_appleevent_permission.c",
                "tools/diagnostics/native_appleevent_consent.m",
                "tools/diagnostics/native_appleevent_registration_test.m",
                "tools/diagnostics/native_appleevent_probe_protocol.h",
                "tools/diagnostics/native_appleevent_probe_pair.m",
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
            outer = Path(directory).resolve(strict=True)
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
            root = Path(directory).resolve(strict=True)
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
        # The real owner creates its fixture below an already resolved parent.
        root = Path(root).resolve(strict=True)
        judge = self

        class Boundary:
            def __init__(self):
                self.root = root
                self.active = []
                self.groups = {}
                self.sender_calls = []
                self.deliveries = 0

            def start(self, arguments):
                if getattr(self, "allow_automation_consent", False) is True:
                    judge.assertEqual(
                        arguments[0],
                        str(root / "OwnedAppleEvent-receiver.app/Contents/MacOS/receiver"),
                    )
                    judge.assertEqual(len(arguments), 4)
                    ready_index = 1
                else:
                    judge.assertEqual(
                        arguments[:2],
                        [str(root / "OwnedAppleEvent.app/Contents/MacOS/owned-probe"), "receiver"],
                    )
                    judge.assertEqual(len(arguments), 5)
                    ready_index = 2
                child = Mock(pid=73136)
                self.active.append(child)
                self.groups[child] = Mock(reaped=False)
                self.groups[child].observe_exit.return_value = None
                Path(arguments[ready_index]).write_bytes(
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
                            "native_appkit_registration_controls=6\n"
                            "native_private_appleevent_controls=1\n"
                            "native_sender_registration_controls=6\n"
                            "native_sender_identity_controls=7\n"
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
            "native_appkit_registration_controls=6\n",
            "native_appkit_registration_controls=6\nnative_private_appleevent_controls=0\n",
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

    def test_dead_receiver_retains_exact_nonreaping_status_and_checkpoint(self):
        checkpoints = (
            "readiness",
            "before-unconfined-positive",
            "before-deny-removal-positive",
            "before-full-policy-denial",
            "after-full-policy-denial",
        )
        # Independent portable native observations; these do not qualify Darwin.
        for index, checkpoint in enumerate(checkpoints):
            for code, kind, status in (
                (21, "CLD_EXITED", 68),
                (22, "CLD_KILLED", 6),
                (23, "CLD_DUMPED", 6),
            ):
                with (
                    self.subTest(checkpoint=checkpoint, kind=kind),
                    TemporaryDirectory() as directory,
                ):
                    root = Path(directory)
                    (root / "sandbox.sb").write_text(self.policy)
                    children = self.model(root)
                    acquire = children.start

                    def start(arguments):
                        child = acquire(arguments)
                        children.groups[child].observe_exit.side_effect = [None] * index + [
                            Mock(si_pid=73136, si_code=code, si_status=status)
                        ]
                        return child

                    children.start = start
                    with (
                        patch.object(probe.uuid, "uuid4", return_value=self.nonce),
                        patch.object(
                            probe, "native_compiler", return_value=["modeled-native-clang"]
                        ),
                        patch.multiple(
                            probe.os, CLD_EXITED=21, CLD_KILLED=22, CLD_DUMPED=23, create=True
                        ),
                    ):
                        with self.assertRaises(probe.AppleEventBoundaryError) as refused:
                            probe.admit_appleevent_boundary(children, root)
                    expected = (
                        "Native AppleEvent boundary unavailable: "
                        "The exact owned AppleEvent receiver is no longer live: "
                        f"checkpoint={checkpoint}, receiver_pid=73136, "
                        f"waitid_kind={kind}, waitid_code={code}, waitid_status={status}"
                    )
                    self.assertEqual(str(refused.exception), expected)
                    self.assertNotIn(directory, str(refused.exception))
                    self.assertNotIn(self.nonce, str(refused.exception))
                    self.assertEqual(len(children.sender_calls), max(0, index - 1))
                    self.assertEqual(len(children.active), 1)
                    child = children.active[0]
                    self.assertEqual(children.groups[child].observe_exit.call_count, index + 1)
                    self.assertFalse(children.groups[child].reaped)
                    child.poll.assert_not_called()
                    child.wait.assert_not_called()
                    self.assertEqual((root / "sandbox.sb").read_text(), self.policy)


class RegistrationFactControls(unittest.TestCase):
    """Real bounded capture admission; native registration remains unqualified."""

    def capture(self, root, value):
        root = Path(root).resolve(strict=True)
        root.chmod(0o700)
        receiver = Mock(pid=73136)
        path = root / "child-1.stderr"
        path.write_bytes(value)
        children = Mock(root=root, captures={receiver: (root / "child-1.stdout", path)})
        return children, receiver, path

    def line(self, phase, status):
        return (
            "Owned AppleEvent recipient registration failed: phase="
            + phase
            + ", osstatus="
            + str(status)
            + "\n"
        ).encode("ascii")

    def test_only_two_closed_phases_and_canonical_nonzero_int32_are_projected(self):
        for phase in ("get-current-process", "transform-process-type"):
            for status in (-2147483648, -600, -50, 1, 2147483647):
                with self.subTest(phase=phase, status=status), TemporaryDirectory() as directory:
                    children, receiver, _path = self.capture(
                        Path(directory), self.line(phase, status)
                    )
                    expected = {"phase": phase, "osstatus": status}
                    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
                        expected = {}
                    self.assertEqual(
                        probe.appleevent_registration_fact(children, receiver), expected
                    )
                    receiver.poll.assert_not_called()
                    receiver.wait.assert_not_called()

    def test_unknown_nul_noise_overflow_and_noncanonical_statuses_omit_facts(self):
        valid = self.line("get-current-process", -50)
        invalid = (
            self.line("unowned-stage", -50),
            self.line("get-current-process", 0),
            self.line("get-current-process", -2147483649),
            self.line("get-current-process", 2147483648),
            valid.replace(b"-50", b"+50"),
            valid.replace(b"-50", b"-050"),
            valid.replace(b"-50", b"-0"),
            valid.replace(b"-50", b"-50\0"),
            valid + b"noise\n",
            valid + valid,
            valid[:-1],
            b"x" * 129,
            b"",
        )
        for value in invalid:
            with self.subTest(value=value), TemporaryDirectory() as directory:
                children, receiver, _path = self.capture(Path(directory), value)
                self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})

    def test_foreign_symlink_nonregular_and_unclosed_captures_omit_facts(self):
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            children, receiver, capture = self.capture(
                root, self.line("transform-process-type", -50)
            )
            capture.unlink()
            self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
            foreign = root / "foreign"
            foreign.mkdir()
            other = foreign / "child-1.stderr"
            other.write_bytes(self.line("transform-process-type", -50))
            children.captures[receiver] = (root / "child-1.stdout", other)
            self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
            children.captures[receiver] = (root / "child-1.stdout", capture)
            if hasattr(os, "O_NOFOLLOW") and hasattr(os, "O_DIRECTORY"):
                capture.symlink_to(other)
                self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
                capture.unlink()
                capture.mkdir()
                self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
                capture.rmdir()
                if hasattr(os, "mkfifo"):
                    os.mkfifo(capture)
                    self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
                    capture.unlink()
                capture.write_bytes(self.line("get-current-process", -600))
                with patch.object(probe.os, "read", return_value=b"partial"):
                    self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
                with patch.object(probe.os, "read", return_value=b"x" * 129):
                    self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})

    def test_exit65_projects_only_typed_facts_and_never_changes_failure_ownership(self):
        boundary = AppleEventBoundaryControls()
        for code, status, value in (
            (21, 65, self.line("transform-process-type", -50)),
            (21, 65, b"unknown private bytes\0\n"),
            (21, 68, self.line("transform-process-type", -50)),
            (22, 65, self.line("transform-process-type", -50)),
        ):
            with self.subTest(code=code, status=status), TemporaryDirectory() as directory:
                root = Path(directory).resolve(strict=True)
                root.chmod(0o700)
                (root / "sandbox.sb").write_text(boundary.policy)
                children = boundary.model(root)
                children.captures = {}
                acquire = children.start

                def start(arguments):
                    child = acquire(arguments)
                    capture = root / "child-1.stderr"
                    capture.write_bytes(value)
                    children.captures[child] = (root / "child-1.stdout", capture)
                    children.groups[child].observe_exit.return_value = Mock(
                        si_pid=73136, si_code=code, si_status=status
                    )
                    return child

                children.start = start
                with (
                    patch.object(probe.uuid, "uuid4", return_value=boundary.nonce),
                    patch.object(probe, "native_compiler", return_value=["modeled-native-clang"]),
                    patch.multiple(
                        probe.os, CLD_EXITED=21, CLD_KILLED=22, CLD_DUMPED=23, create=True
                    ),
                ):
                    with self.assertRaises(probe.AppleEventBoundaryError) as failure:
                        probe.admit_appleevent_boundary(children, root)
                detail = str(failure.exception)
                admitted = (
                    code == 21
                    and status == 65
                    and value == self.line("transform-process-type", -50)
                    and hasattr(os, "O_NOFOLLOW")
                    and hasattr(os, "O_DIRECTORY")
                )
                if admitted:
                    self.assertTrue(
                        detail.endswith(
                            ", registration_phase=transform-process-type, registration_osstatus=-50"
                        )
                    )
                else:
                    self.assertNotIn("registration_phase=", detail)
                self.assertIn("checkpoint=readiness", detail)
                self.assertIn("waitid_status=" + str(status), detail)
                self.assertNotIn(directory, detail)
                self.assertNotIn(boundary.nonce, detail)
                self.assertNotIn("unknown private bytes", detail)
                self.assertEqual(children.sender_calls, [])
                self.assertEqual(len(children.active), 1)
                child = children.active[0]
                self.assertEqual(children.groups[child].observe_exit.call_count, 1)
                self.assertFalse(children.groups[child].reaped)
                child.poll.assert_not_called()
                child.wait.assert_not_called()


class SenderFactControls(unittest.TestCase):
    """Independent closed outcome records; native reply routing remains unqualified."""

    def line(
        self,
        phase="reply-read",
        send=0,
        read=-1701,
        size="unobserved",
        match="unobserved",
        error_read=0,
        error_size=4,
        error=-1743,
    ):
        return (
            f"Owned AppleEvent outcome admission failed: phase={phase}, send={send}, "
            f"read={read}, length={size}, match={match}, error_read={error_read}, "
            f"error_length={error_size}, error_value={error}\n"
        )

    def test_target_error_is_observed_only_from_successful_exact_sint32_read(self):
        for error in (-2147483648, -1743, 0, 2147483647):
            with self.subTest(error=error):
                self.assertEqual(
                    probe.appleevent_sender_fact(self.line(error=error)),
                    {
                        "phase": "reply-read",
                        "send_osstatus": 0,
                        "reply_read_osstatus": -1701,
                        "reply_length": None,
                        "reply_match": None,
                        "error_read_osstatus": 0,
                        "error_length": 4,
                        "error_number": error,
                    },
                )
        unavailable = probe.appleevent_sender_fact(
            self.line(error_read=-1701, error_size="unobserved", error="unobserved")
        )
        self.assertIsNone(unavailable["error_number"])
        self.assertIsNone(unavailable["error_length"])
        self.assertEqual(unavailable["error_read_osstatus"], -1701)
        wrong_length = probe.appleevent_sender_fact(self.line(error_size=3, error="unobserved"))
        self.assertIsNone(wrong_length["error_number"])
        self.assertEqual(wrong_length["error_length"], 3)

    def test_closed_failure_phases_preserve_transport_read_length_and_match_distinctions(self):
        for size in (0, 37, 4096, "outside-bound"):
            with self.subTest(size=size):
                facts = probe.appleevent_sender_fact(
                    self.line(phase="reply-length", read=0, size=size)
                )
                self.assertEqual(facts["reply_length"], size)
                self.assertIsNone(facts["reply_match"])
        facts = probe.appleevent_sender_fact(
            self.line(phase="reply-match", read=0, size=36, match=0)
        )
        self.assertIs(facts["reply_match"], False)
        for phase, send in (("send", -1712), ("denied-status", -1744)):
            with self.subTest(phase=phase):
                facts = probe.appleevent_sender_fact(
                    self.line(
                        phase=phase,
                        send=send,
                        read="unobserved",
                        error_read="unobserved",
                        error_size="unobserved",
                        error="unobserved",
                    )
                )
                self.assertEqual(facts["send_osstatus"], send)
                self.assertIsNone(facts["reply_read_osstatus"])
                self.assertIsNone(facts["error_number"])

    def test_unknown_oversized_noisy_or_contradictory_native_records_are_omitted(self):
        valid = self.line()
        invalid = (
            valid + "extra\n",
            valid[:-1],
            valid + "\0",
            "x" * 257,
            valid.replace("reply-read", "foreign-phase"),
            valid.replace("send=0", "send=+0"),
            valid.replace("read=-1701", "read=-01701"),
            valid.replace("read=-1701", "read=-2147483649", 1),
            valid.replace("error_value=-1743", "error_value=2147483648"),
            valid.replace("error_value=-1743", "error_value=-1743\0"),
            valid.replace("error_value=-1743", "error_value=unobserved"),
            valid.replace("error_length=4", "error_length=5"),
            valid.replace("error_length=4", "error_length=unobserved"),
            self.line(read=0),
            self.line(size=0),
            self.line(match=0),
            self.line(phase="reply-match", read=0, size=36, match=1),
            self.line(phase="reply-length", read=0, size=36),
            self.line(phase="reply-length", read=0, size=4097),
            self.line(
                phase="denied-status",
                send=-1743,
                read="unobserved",
                error_read="unobserved",
                error_size="unobserved",
                error="unobserved",
            ),
            self.line(error_read=-1701),
            None,
            b"unowned bytes",
            "é" * 40,
        )
        for value in invalid:
            with self.subTest(value=value):
                self.assertEqual(probe.appleevent_sender_fact(value), {})

    def test_nonzero_outcome_stays_refused_without_exporting_unadmitted_capture_bytes(self):
        for status, value in (
            (66, self.line()),
            (66, "private nonce/raw path\0"),
            (65, self.line()),
        ):
            with self.subTest(status=status, value=value):
                children = Mock()
                children.run.return_value = subprocess.CompletedProcess(
                    ["private-path", "private-nonce"], status, "", value
                )
                with self.assertRaises(probe.AdmissionError) as failed:
                    probe.run_appleevent_sender(
                        children, ["private-path", "private-nonce"], "deny-removal-positive"
                    )
                detail = str(failed.exception)
                self.assertIn("control=deny-removal-positive", detail)
                self.assertIn("exit=" + str(status), detail)
                self.assertEqual("sender_fact=" in detail, status == 66 and value == self.line())
                self.assertNotIn("private nonce/raw path", detail)
                self.assertNotIn("private-path", detail)
                self.assertNotIn("private-nonce", detail)
                children.run.assert_called_once_with(
                    ["private-path", "private-nonce"], check=False, confined=False
                )
                children.settle.assert_not_called()

    def test_zero_exit_alone_cannot_bypass_exact_stdout_stderr_or_denial_oracles(self):
        for control, expected in (
            ("unconfined-positive", "native_appleevent_status=0\n"),
            ("deny-removal-positive", "native_appleevent_status=0\n"),
            ("full-policy-denial", "native_appleevent_status=-1743\n"),
        ):
            with self.subTest(control=control):
                children = Mock()
                children.run.return_value = subprocess.CompletedProcess([], 0, expected, "")
                accepted = probe.run_appleevent_sender(children, [], control, confined=True)
                self.assertEqual(accepted.stdout, expected)
                children.run.assert_called_with([], check=False, confined=True)
                for stdout, stderr in (
                    ("", ""),
                    (expected, "private noise"),
                    ("native_appleevent_status=-1744\n", ""),
                ):
                    children.run.return_value = subprocess.CompletedProcess([], 0, stdout, stderr)
                    with self.assertRaises(probe.AdmissionError):
                        probe.run_appleevent_sender(children, [], control)
                children.settle.assert_not_called()

    def test_deny_removal_failure_stops_before_third_send_and_retains_receiver_owner(self):
        boundary = AppleEventBoundaryControls()
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "sandbox.sb").write_text(boundary.policy)
            children = boundary.model(root, failure=2)
            execute = children.run

            def run(arguments, **options):
                completed = execute(arguments, **options)
                if completed.returncode == 65:
                    return subprocess.CompletedProcess(arguments, 66, "", self.line())
                return completed

            children.run = run
            with (
                patch.object(probe.uuid, "uuid4", return_value=boundary.nonce),
                patch.object(probe, "native_compiler", return_value=["modeled-native-clang"]),
            ):
                with self.assertRaises(probe.AppleEventBoundaryError) as failed:
                    probe.admit_appleevent_boundary(children, root)
            detail = str(failed.exception)
            self.assertIn("control=deny-removal-positive", detail)
            self.assertIn('"error_number": -1743', detail)
            self.assertNotIn(directory, detail)
            self.assertNotIn(boundary.nonce, detail)
            self.assertEqual(len(children.sender_calls), 2)
            self.assertEqual(len(children.active), 1)
            receiver = children.active[0]
            self.assertFalse(children.groups[receiver].reaped)
            self.assertEqual(children.groups[receiver].observe_exit.call_count, 3)
            self.assertTrue((root / "appleevent-delivered.1").exists())
            self.assertFalse((root / "appleevent-delivered.2").exists())
            self.assertFalse((root / "appleevent-delivered.3").exists())
            self.assertEqual((root / "sandbox.sb").read_text(), boundary.policy)


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


class SenderOwnedMarkerSnapshotControls(unittest.TestCase):
    FAILURE = (
        "Owned AppleEvent outcome admission failed: phase=reply-read, send=0, read=-1701, "
        "length=unobserved, match=unobserved, error_read=0, error_length=4, error_value=-10004"
    )

    def test_existing_closed_sender_facts_remain_byte_equivalent_without_marker(self):
        value = self.FAILURE + "\n"
        self.assertEqual(
            probe.appleevent_sender_marker_fact(value), probe.appleevent_sender_fact(value)
        )

    def test_four_snapshot_enums_preserve_all_independent_original_native_facts(self):
        expected = {
            "phase": "reply-read",
            "send_osstatus": 0,
            "reply_read_osstatus": -1701,
            "reply_length": None,
            "reply_match": None,
            "error_read_osstatus": 0,
            "error_length": 4,
            "error_number": -10004,
        }
        for snapshot in ("absent", "conforming", "invalid", "unavailable"):
            with self.subTest(snapshot=snapshot):
                self.assertEqual(
                    probe.appleevent_sender_marker_fact(
                        self.FAILURE + ", marker2=" + snapshot + "\n"
                    ),
                    {**expected, "marker2_snapshot": snapshot},
                )

    def test_snapshot_noise_or_incompatible_causal_phase_never_exports_private_bytes(self):
        for value in [
            self.FAILURE + ", marker2=private-path-nonce\n",
            self.FAILURE + ", marker2=absent, marker2=conforming\n",
            self.FAILURE + ", marker2=absent\nnoise",
            self.FAILURE + ", marker2=absent\0\n",
            self.FAILURE + ", marker2=absent\n" + "x" * 256,
            "Owned AppleEvent outcome admission failed: phase=send, send=-1743, read=unobserved, "
            "length=unobserved, match=unobserved, error_read=unobserved, error_length=unobserved, "
            "error_value=unobserved, marker2=conforming\n",
        ]:
            with self.subTest(value=value):
                self.assertEqual(probe.appleevent_sender_marker_fact(value), {})

    def test_conforming_snapshot_cannot_change_existing_sender_failure_or_acceptance(self):
        owner = Mock()
        owner.run.return_value = subprocess.CompletedProcess(
            [], 66, "", self.FAILURE + ", marker2=conforming\n"
        )
        with self.assertRaises(probe.AdmissionError) as failure:
            probe.run_appleevent_sender(owner, ["owned-sender"], "deny-removal-positive")
        owner.run.assert_called_once_with(["owned-sender"], check=False, confined=False)
        self.assertIn("exit=66", str(failure.exception))
        self.assertIn('"error_number": -10004', str(failure.exception))
        self.assertIn('"marker2_snapshot": "conforming"', str(failure.exception))
        owner.run.return_value = subprocess.CompletedProcess(
            [], 0, "native_appleevent_status=0\n", self.FAILURE + ", marker2=conforming\n"
        )
        with self.assertRaises(probe.AdmissionError):
            probe.run_appleevent_sender(owner, ["owned-sender"], "deny-removal-positive")


class FailedSenderReceiverObservationControls(unittest.TestCase):
    """Semantic one-observation controls; these do not qualify Darwin AppleEvents."""

    def world(self):
        receiver = Mock(pid=73136, returncode=None)
        group = Mock(process=receiver, reaped=False, reservation_lost=False)
        group.observe_exit.return_value = None
        owner = SimpleNamespace(groups={receiver: group}, active=[receiver], debt=[])
        return owner, receiver, group

    def invoke(self, owner, receiver, group, control="unconfined-positive"):
        return probe.run_appleevent_sender_observed(
            owner, ["owned-sender"], control, receiver=receiver, group=group, confined=True
        )

    def test_success_returns_original_receipt_without_observation_or_optional_output(self):
        owner, receiver, group = self.world()
        result = subprocess.CompletedProcess([], 0, "native_appleevent_status=0\n", "")
        with patch.object(probe, "run_appleevent_sender", return_value=result) as sender:
            with patch("builtins.print") as output:
                self.assertIs(self.invoke(owner, receiver, group), result)
        sender.assert_called_once_with(
            owner, ["owned-sender"], "unconfined-positive", confined=True
        )
        group.observe_exit.assert_not_called()
        output.assert_not_called()

    def test_failed_send_observes_target_once_and_preserves_identical_primary_and_owner(self):
        for control in ("unconfined-positive", "deny-removal-positive", "full-policy-denial"):
            with self.subTest(control=control):
                owner, receiver, group = self.world()
                primary = probe.AdmissionError("independent original sender refusal")
                with patch.object(probe, "run_appleevent_sender", side_effect=primary):
                    with patch("builtins.print") as output:
                        with self.assertRaises(probe.AdmissionError) as raised:
                            self.invoke(owner, receiver, group, control)
                self.assertIs(raised.exception, primary)
                group.observe_exit.assert_called_once_with()
                expected = {"schema": 1, "control": control, "state": "no-terminal-observation"}
                self.assertEqual(
                    output.call_args.args[0],
                    "Owned AppleEvent receiver after failed sender: "
                    + json.dumps(expected, sort_keys=True),
                )
                self.assertEqual(owner.active, [receiver])
                self.assertEqual(owner.debt, [])
                self.assertFalse(group.reaped)
                receiver.poll.assert_not_called()
                receiver.wait.assert_not_called()
                group.settle.assert_not_called()

    def test_terminal_projection_reuses_same_single_observation_and_keeps_native_status(self):
        with patch.multiple(probe.os, CLD_EXITED=1, CLD_KILLED=2, CLD_DUMPED=3, create=True):
            for code, status in ((1, 68), (2, 15), (3, 6)):
                with self.subTest(code=code):
                    owner, receiver, group = self.world()
                    observation = SimpleNamespace(si_pid=73136, si_code=code, si_status=status)
                    group.observe_exit.return_value = observation
                    primary = probe.AdmissionError("independent sender refused")
                    with patch.object(probe, "run_appleevent_sender", side_effect=primary):
                        with patch.object(
                            probe,
                            "_appleevent_capture",
                            return_value=(b"", b"Owned AppleEvent receipt failed: -600\n"),
                        ):
                            with patch.object(
                                probe,
                                "_appleevent_terminal_packet",
                                wraps=probe._appleevent_terminal_packet,
                            ) as project:
                                with patch("builtins.print") as output:
                                    with self.assertRaises(probe.AdmissionError) as raised:
                                        self.invoke(owner, receiver, group)
                    self.assertIs(raised.exception, primary)
                    group.observe_exit.assert_called_once_with()
                    project.assert_called_once_with(owner, receiver, group, observation)
                    expected = {
                        "schema": 1,
                        "control": "unconfined-positive",
                        "state": "terminal",
                        "si_code": code,
                        "si_status": status,
                        "stderr_phase": "receipt",
                        "stderr_osstatus": -600,
                    }
                    self.assertEqual(
                        output.call_args.args[0],
                        "Owned AppleEvent receiver after failed sender: "
                        + json.dumps(expected, sort_keys=True),
                    )
                    self.assertFalse(group.reaped)
                    receiver.wait.assert_not_called()
                    receiver.poll.assert_not_called()
                    group.settle.assert_not_called()

    def test_native_observation_refusal_preserves_reservation_loss_debt_and_primary(self):
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted):
                owner, receiver, group = self.world()
                primary = probe.AdmissionError("sender original")
                debt = {"kind": "process-group", "pid": 73136}

                def refused_observation():
                    owner.debt.append(debt)
                    group.reservation_lost = not interrupted
                    if interrupted:
                        raise probe.OwnedProcessInterrupted("private observation cancelled")
                    raise RuntimeError("private capture/path must never export")

                group.observe_exit.side_effect = refused_observation
                with patch.object(probe, "run_appleevent_sender", side_effect=primary):
                    with patch("builtins.print") as output:
                        with self.assertRaises(probe.AdmissionError) as raised:
                            self.invoke(owner, receiver, group)
                self.assertIs(raised.exception, primary)
                self.assertEqual(owner.debt, [debt])
                self.assertEqual(group.reservation_lost, not interrupted)
                group.observe_exit.assert_called_once_with()
                self.assertIn('"state": "unavailable"', output.call_args.args[0])
                self.assertNotIn("private", output.call_args.args[0])
                self.assertFalse(group.reaped)

    def test_foreign_receiver_or_terminal_projection_failure_is_never_reported_live(self):
        for foreign in (False, True):
            with self.subTest(foreign=foreign):
                owner, receiver, group = self.world()
                if foreign:
                    owner.groups[receiver] = Mock()
                else:
                    group.observe_exit.return_value = SimpleNamespace(
                        si_pid=99999, si_code=1, si_status=68
                    )
                primary = probe.AdmissionError("same sender original")
                with patch.object(probe, "run_appleevent_sender", side_effect=primary):
                    with patch("builtins.print") as output:
                        with self.assertRaises(probe.AdmissionError) as raised:
                            self.invoke(owner, receiver, group)
                self.assertIs(raised.exception, primary)
                self.assertIn('"state": "unavailable"', output.call_args.args[0])
                self.assertNotIn('"state": "terminal"', output.call_args.args[0])
                self.assertNotIn('"state": "no-terminal-observation"', output.call_args.args[0])
                self.assertEqual(group.observe_exit.call_count, 0 if foreign else 1)
                receiver.poll.assert_not_called()
                receiver.wait.assert_not_called()

    def test_optional_publication_failure_cannot_replace_original_sender_exception(self):
        owner, receiver, group = self.world()
        primary = probe.AdmissionError("original sender failure")
        with patch.object(probe, "run_appleevent_sender", side_effect=primary):
            with patch("builtins.print", side_effect=OSError("unavailable optional stream")):
                with self.assertRaises(probe.AdmissionError) as raised:
                    self.invoke(owner, receiver, group)
        self.assertIs(raised.exception, primary)
        group.observe_exit.assert_called_once_with()
        self.assertEqual(owner.active, [receiver])
        self.assertFalse(group.reaped)
        group.settle.assert_not_called()


class AppKitRegistrationFactControls(unittest.TestCase):
    """Closed native enum facts; actual AppKit capability remains unqualified."""

    def capture(self, root, value):
        return RegistrationFactControls.capture(self, root, value)

    def line(self, reason):
        return (
            "Owned AppleEvent recipient AppKit admission refused (reason " + str(reason) + ").\n"
        ).encode("ascii")

    def test_three_actual_enum_values_project_names_without_osstatus(self):
        for number, reason in (
            (1, "application-missing"),
            (2, "policy-refused"),
            (3, "policy-unconfirmed"),
        ):
            with self.subTest(number=number), TemporaryDirectory() as directory:
                children, receiver, _path = self.capture(Path(directory), self.line(number))
                expected = {"phase": "appkit-admission", "appkit_reason": reason}
                if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
                    expected = {}
                fact = probe.appleevent_registration_fact(children, receiver)
                self.assertEqual(fact, expected)
                self.assertNotIn("osstatus", fact)
                receiver.poll.assert_not_called()
                receiver.wait.assert_not_called()

    def test_unknown_admitted_noncanonical_noise_and_partial_frames_omit_reason(self):
        valid = self.line(2)
        for value in (
            self.line(0),
            self.line(4),
            self.line(-1),
            self.line("+2"),
            self.line("02"),
            valid.replace(b"reason 2", b"reason 2\0"),
            valid + b"noise\n",
            valid + valid,
            valid[:-1],
            b" " + valid,
            valid.replace(b"refused", b"accepted"),
            b"x" * 129,
        ):
            with self.subTest(value=value), TemporaryDirectory() as directory:
                children, receiver, _path = self.capture(Path(directory), value)
                self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})

    def test_symlink_hardlink_root_and_partial_read_refusals_do_not_publish_reason(self):
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            children, receiver, path = self.capture(root, self.line(2))
            original = root / "original.stderr"
            with owned_registration_capture_ports(root, path) as witness:
                self.assertTrue(
                    probe.appleevent_registration_fact(children, receiver),
                    "The real owned capture must reach the unchanged parser",
                )
                if witness is not None:
                    self.assertEqual(
                        (witness["file_stats"], witness["reads"], witness["file_closes"]), (1, 1, 1)
                    )
                    self.assertEqual(
                        witness["flags"],
                        [
                            probe.os.O_RDONLY | probe.os.O_DIRECTORY | probe.os.O_NOFOLLOW,
                            probe.os.O_RDONLY | probe.os.O_NOFOLLOW | probe.os.O_NONBLOCK,
                        ],
                    )
                    with self.assertRaisesRegex(AssertionError, "Foreign or closed"):
                        probe.os.fstat(object())
                    with self.assertRaisesRegex(AssertionError, "Foreign, closed or duplicate"):
                        probe.os.open(root, probe.os.O_RDONLY)
                    with self.assertRaisesRegex(AssertionError, "Foreign, closed or duplicate"):
                        probe.os.open("foreign.stderr", probe.os.O_RDONLY, dir_fd=object())
            path.rename(original)
            with owned_capture_file_link(path, original) as link_model:
                with owned_registration_capture_ports(root, path) as witness:
                    self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
                    self.assertTrue(path.is_symlink(), "The exact link-kind witness is required")
                    if witness is not None:
                        self.assertEqual(witness["link_refusals"], 1)
                        self.assertEqual(
                            (witness["file_stats"], witness["reads"], witness["file_closes"]),
                            (0, 0, 0),
                        )
                if link_model is not None:
                    reject_changed_capture_link_inputs(self, link_model)
            path.unlink()
            os.link(original, path)
            with path.open("rb") as capture:
                self.assertEqual(os.fstat(capture.fileno()).st_nlink, 2)
            with owned_registration_capture_ports(root, path) as witness:
                self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
                if witness is not None:
                    self.assertEqual(
                        (witness["file_stats"], witness["reads"], witness["file_closes"]), (1, 0, 1)
                    )
            path.unlink()
            original.rename(path)
            root.chmod(0o755)
            self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
            root.chmod(0o700)
            with patch.object(probe.os, "read", return_value=self.line(2)[:-1]):
                self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
            receiver.poll.assert_not_called()
            receiver.wait.assert_not_called()

    def test_only_existing_exit65_observation_publishes_reason_and_remains_refused(self):
        boundary = AppleEventBoundaryControls()
        for code, status, number, reason in (
            (21, 65, 1, "application-missing"),
            (21, 65, 2, "policy-refused"),
            (21, 65, 3, "policy-unconfirmed"),
            (21, 65, 0, None),
            (21, 68, 2, None),
            (22, 65, 2, None),
        ):
            with (
                self.subTest(code=code, status=status, number=number),
                TemporaryDirectory() as directory,
            ):
                root = Path(directory).resolve(strict=True)
                root.chmod(0o700)
                (root / "sandbox.sb").write_text(boundary.policy)
                children = boundary.model(root)
                children.captures = {}
                acquire = children.start
                value = self.line(number)

                def start(arguments):
                    child = acquire(arguments)
                    capture = root / "child-1.stderr"
                    capture.write_bytes(value)
                    children.captures[child] = (root / "child-1.stdout", capture)
                    children.groups[child].observe_exit.return_value = Mock(
                        si_pid=73136, si_code=code, si_status=status
                    )
                    return child

                children.start = start
                with (
                    patch.object(probe.uuid, "uuid4", return_value=boundary.nonce),
                    patch.object(probe, "native_compiler", return_value=["modeled-native-clang"]),
                    patch.multiple(
                        probe.os, CLD_EXITED=21, CLD_KILLED=22, CLD_DUMPED=23, create=True
                    ),
                ):
                    with self.assertRaises(probe.AppleEventBoundaryError) as failed:
                        probe.admit_appleevent_boundary(children, root)
                detail = str(failed.exception)
                if reason is not None and hasattr(os, "O_NOFOLLOW") and hasattr(os, "O_DIRECTORY"):
                    self.assertTrue(
                        detail.endswith(
                            ", registration_phase=appkit-admission, registration_appkit_reason="
                            + reason
                        )
                    )
                else:
                    self.assertNotIn("registration_appkit_reason=", detail)
                self.assertNotIn("registration_osstatus=", detail)
                self.assertIn("checkpoint=readiness", detail)
                self.assertIn("waitid_status=" + str(status), detail)
                self.assertNotIn(directory, detail)
                self.assertNotIn(boundary.nonce, detail)
                self.assertEqual(children.sender_calls, [])
                self.assertEqual(len(children.active), 1)
                child = children.active[0]
                self.assertEqual(children.groups[child].observe_exit.call_count, 1)
                children.groups[child].settle.assert_not_called()


class AppKitPolicyStateControls(unittest.TestCase):
    """Fixed policy snapshots do not authorize registration or diagnose its cause."""

    def capture(self, root, value):
        return RegistrationFactControls.capture(self, root, value)

    def frame(self, initial, after, reason=2):
        return (
            "Owned AppleEvent recipient AppKit admission refused (reason "
            + str(reason)
            + ").\nAPPKIT_POLICY/1 initial="
            + initial
            + " after="
            + after
            + "\n"
        ).encode("ascii")

    def test_fixed_initial_and_after_no_labels_project_only_observed_states(self):
        labels = ("regular", "accessory", "prohibited", "unrecognized")
        for initial in labels:
            for after in labels:
                with self.subTest(initial=initial, after=after), TemporaryDirectory() as directory:
                    value = self.frame(initial, after)
                    self.assertLessEqual(len(value), 128)
                    children, receiver, _path = self.capture(Path(directory), value)
                    expected = {
                        "phase": "appkit-admission",
                        "appkit_reason": "policy-refused",
                        "appkit_initial_policy": initial,
                        "appkit_after_no_policy": after,
                    }
                    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
                        expected = {}
                    self.assertEqual(
                        probe.appleevent_registration_fact(children, receiver), expected
                    )
                    receiver.poll.assert_not_called()
                    receiver.wait.assert_not_called()

    def test_unknown_noisy_or_wrong_admission_frames_do_not_project_policy(self):
        valid = self.frame("accessory", "accessory")
        for value in (
            self.frame("accessory", "accessory", reason=1),
            self.frame("accessory", "accessory", reason=3),
            self.frame("unavailable", "accessory"),
            self.frame("0", "1"),
            valid.replace(
                b"initial=accessory after=accessory", b"after=accessory initial=accessory"
            ),
            valid.replace(b"APPKIT_POLICY/1", b"APPKIT_POLICY/2"),
            valid.replace(b"after=accessory", b"after=accessory\0"),
            valid + b"noise\n",
            valid + valid,
            valid[:-1],
            valid.split(b"\n", 1)[1],
            b"x" * 129,
        ):
            with self.subTest(value=value), TemporaryDirectory() as directory:
                children, receiver, _path = self.capture(Path(directory), value)
                self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})

    def test_policy_projection_preserves_capture_refusals_and_no_process_observation(self):
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            value = self.frame("regular", "prohibited")
            children, receiver, path = self.capture(root, value)
            original = root / "original.stderr"
            with owned_registration_capture_ports(root, path) as witness:
                self.assertTrue(
                    probe.appleevent_registration_fact(children, receiver),
                    "The real owned capture must reach the unchanged parser",
                )
                if witness is not None:
                    self.assertEqual(
                        (witness["file_stats"], witness["reads"], witness["file_closes"]), (1, 1, 1)
                    )
                    self.assertEqual(
                        witness["flags"],
                        [
                            probe.os.O_RDONLY | probe.os.O_DIRECTORY | probe.os.O_NOFOLLOW,
                            probe.os.O_RDONLY | probe.os.O_NOFOLLOW | probe.os.O_NONBLOCK,
                        ],
                    )
                    with self.assertRaisesRegex(AssertionError, "Foreign or closed"):
                        probe.os.fstat(object())
                    with self.assertRaisesRegex(AssertionError, "Foreign, closed or duplicate"):
                        probe.os.open(root, probe.os.O_RDONLY)
                    with self.assertRaisesRegex(AssertionError, "Foreign, closed or duplicate"):
                        probe.os.open("foreign.stderr", probe.os.O_RDONLY, dir_fd=object())
            path.rename(original)
            with owned_capture_file_link(path, original) as link_model:
                with owned_registration_capture_ports(root, path) as witness:
                    self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
                    self.assertTrue(path.is_symlink(), "The exact link-kind witness is required")
                    if witness is not None:
                        self.assertEqual(witness["link_refusals"], 1)
                        self.assertEqual(
                            (witness["file_stats"], witness["reads"], witness["file_closes"]),
                            (0, 0, 0),
                        )
                if link_model is not None:
                    reject_changed_capture_link_inputs(self, link_model)
            path.unlink()
            os.link(original, path)
            with path.open("rb") as capture:
                self.assertEqual(os.fstat(capture.fileno()).st_nlink, 2)
            with owned_registration_capture_ports(root, path) as witness:
                self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
                if witness is not None:
                    self.assertEqual(
                        (witness["file_stats"], witness["reads"], witness["file_closes"]), (1, 0, 1)
                    )
            path.unlink()
            original.rename(path)
            root.chmod(0o755)
            self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
            root.chmod(0o700)
            with patch.object(probe.os, "read", return_value=value[:-1]):
                self.assertEqual(probe.appleevent_registration_fact(children, receiver), {})
            receiver.poll.assert_not_called()
            receiver.wait.assert_not_called()

    def test_policy_snapshot_uses_same_exit65_and_keeps_readiness_refused(self):
        boundary = AppleEventBoundaryControls()
        for code, status, reason in ((21, 65, 2), (21, 68, 2), (22, 65, 2), (21, 65, 3)):
            with (
                self.subTest(code=code, status=status, reason=reason),
                TemporaryDirectory() as directory,
            ):
                root = Path(directory).resolve(strict=True)
                root.chmod(0o700)
                (root / "sandbox.sb").write_text(boundary.policy)
                children = boundary.model(root)
                children.captures = {}
                acquire = children.start

                def start(arguments):
                    child = acquire(arguments)
                    capture = root / "child-1.stderr"
                    capture.write_bytes(self.frame("accessory", "accessory", reason))
                    children.captures[child] = (root / "child-1.stdout", capture)
                    children.groups[child].observe_exit.return_value = Mock(
                        si_pid=73136, si_code=code, si_status=status
                    )
                    return child

                children.start = start
                with (
                    patch.object(probe.uuid, "uuid4", return_value=boundary.nonce),
                    patch.object(probe, "native_compiler", return_value=["modeled-native-clang"]),
                    patch.multiple(
                        probe.os, CLD_EXITED=21, CLD_KILLED=22, CLD_DUMPED=23, create=True
                    ),
                ):
                    with self.assertRaises(probe.AppleEventBoundaryError) as failed:
                        probe.admit_appleevent_boundary(children, root)
                detail = str(failed.exception)
                if (
                    code == 21
                    and status == 65
                    and reason == 2
                    and hasattr(os, "O_NOFOLLOW")
                    and hasattr(os, "O_DIRECTORY")
                ):
                    self.assertIn("registration_appkit_initial_policy=accessory", detail)
                    self.assertIn("registration_appkit_after_no_policy=accessory", detail)
                else:
                    self.assertNotIn("registration_appkit_initial_policy=", detail)
                    self.assertNotIn("registration_appkit_after_no_policy=", detail)
                self.assertIn("checkpoint=readiness", detail)
                self.assertNotIn(directory, detail)
                self.assertNotIn(boundary.nonce, detail)
                self.assertEqual(children.sender_calls, [])
                self.assertEqual(len(children.active), 1)
                child = children.active[0]
                self.assertEqual(children.groups[child].observe_exit.call_count, 1)
                children.groups[child].settle.assert_not_called()


class SenderNonpromptPermissionControls(unittest.TestCase):
    """Constructed capture controls; actual Darwin permission behavior remains unqualified."""

    FAILURE = (
        "Owned AppleEvent outcome admission failed: phase=reply-read, send=0, read=-1701, "
        "length=unobserved, match=unobserved, error_read=0, error_length=4, "
        "error_value=-10004, marker2=absent\n"
    )

    def test_fixed_signed_statuses_are_projected_without_permission_cause_labels(self):
        for status in (0, -1742, -1743, -1744, -10004, -(2**31), 2**31 - 1):
            with self.subTest(status=status):
                self.assertEqual(
                    probe.appleevent_permission_query_fact(
                        "OWNED_APPLEEVENT_PERMISSION/1 osstatus=" + str(status) + "\n"
                    ),
                    {"osstatus": status},
                )

    def test_noise_noncanonical_and_out_of_range_statuses_cannot_publish_capture(self):
        for value in (
            None,
            "",
            "OWNED_APPLEEVENT_PERMISSION/1 osstatus=0",
            "OWNED_APPLEEVENT_PERMISSION/1 osstatus=00\n",
            "OWNED_APPLEEVENT_PERMISSION/1 osstatus=-0\n",
            "OWNED_APPLEEVENT_PERMISSION/1 osstatus=+0\n",
            "OWNED_APPLEEVENT_PERMISSION/1 osstatus=0.0\n",
            "OWNED_APPLEEVENT_PERMISSION/1 osstatus=2147483648\n",
            "OWNED_APPLEEVENT_PERMISSION/1 osstatus=-2147483649\n",
            "OWNED_APPLEEVENT_PERMISSION/1 osstatus=0\nnoise\n",
            "OWNED_APPLEEVENT_PERMISSION/1 osstatus=0\n" * 2,
            "OWNED_APPLEEVENT_PERMISSION/1 osstatus=private-path-or-nonce\n",
            "OWNED_APPLEEVENT_PERMISSION/1 osstatus=0\x00\n",
            "x" * 97,
        ):
            with self.subTest(value=value):
                self.assertEqual(probe.appleevent_permission_query_fact(value), {})

    def test_permission_zero_never_exonerates_original_sender_error_or_changes_owner(self):
        for status in (0, -1743, -1744):
            with self.subTest(status=status):
                owner = Mock()
                owner.run.return_value = subprocess.CompletedProcess(
                    [],
                    66,
                    "OWNED_APPLEEVENT_PERMISSION/1 osstatus=" + str(status) + "\n",
                    self.FAILURE,
                )
                with self.assertRaises(probe.AdmissionError) as failure:
                    probe.run_appleevent_sender(
                        owner, ["owned-sender"], "deny-removal-positive", confined=True
                    )
                detail = str(failure.exception)
                self.assertIn("control=deny-removal-positive, exit=66", detail)
                self.assertIn('"error_number": -10004', detail)
                self.assertIn('"marker2_snapshot": "absent"', detail)
                self.assertIn('permission_query_fact={"osstatus": ' + str(status) + "}", detail)
                owner.run.assert_called_once_with(["owned-sender"], check=False, confined=True)
                self.assertEqual(len(owner.mock_calls), 1)
                owner.settle.assert_not_called()

    def test_other_exit_or_full_denial_cannot_borrow_a_positive_permission_frame(self):
        for status, control in ((65, "deny-removal-positive"), (66, "full-policy-denial")):
            with self.subTest(status=status, control=control):
                owner = Mock()
                owner.run.return_value = subprocess.CompletedProcess(
                    [], status, "OWNED_APPLEEVENT_PERMISSION/1 osstatus=0\n", self.FAILURE
                )
                with self.assertRaises(probe.AdmissionError) as failure:
                    probe.run_appleevent_sender(owner, [], control)
                self.assertIn("exit=" + str(status), str(failure.exception))
                self.assertNotIn("permission_query_fact=", str(failure.exception))

    def test_optional_frame_never_replaces_success_or_primary_failure_evidence(self):
        owner = Mock()
        for capture in ("", "noise-private-input\n"):
            owner.run.return_value = subprocess.CompletedProcess([], 66, capture, self.FAILURE)
            with self.assertRaises(probe.AdmissionError) as failure:
                probe.run_appleevent_sender(owner, [], "unconfined-positive")
            self.assertIn('"error_number": -10004', str(failure.exception))
            self.assertNotIn("permission_query_fact=", str(failure.exception))
        owner.run.return_value = subprocess.CompletedProcess(
            [], 0, "OWNED_APPLEEVENT_PERMISSION/1 osstatus=0\n", ""
        )
        with self.assertRaises(probe.AdmissionError):
            probe.run_appleevent_sender(owner, [], "unconfined-positive")


class AutomationPrerequisiteControls(unittest.TestCase):
    """Model normal consent receipt admission, without claiming a native OS grant."""

    def invoke(self, root, statuses, *, allow=True, mutate=None, error=None, raw=None, ui=False):
        sender = root / "OwnedAppleEvent-sender.app/Contents/MacOS/sender"
        sender.parent.mkdir(parents=True)
        sender.write_bytes(b"Independent final signed executable identity\n")
        policy = root / "sandbox-appleevent-positive.sb"
        policy.write_text("(version 1)\n(deny file-write*)\n(deny network-outbound)\n")
        owner = Mock(allow_automation_consent=allow)
        owner.allow_owned_consent_ui = ui
        owner.automation_sender_name = "Owned sender identity"
        owner.automation_receiver_name = "Owned receiver identity"
        observed = []
        queue = iter(statuses)

        def run(arguments, **options):
            self.assertEqual(arguments[:3], ["/usr/bin/sandbox-exec", "-f", str(policy)])
            self.assertEqual(arguments[3:6], [str(sender), "73136", "owned-nonce"])
            mode = arguments[-1].removeprefix("permission-")
            callback = options.pop("after_start", None)
            self.assertEqual(options, {"check": False, "timeout": 30})
            if ui and mode == "request":
                self.assertTrue(callable(callback))
                callback("exact-owned-requester", 30)
            else:
                self.assertIsNone(callback)
            if error is not None:
                raise error
            status = next(queue)
            if mutate is not None:
                (sender if mutate == "sender" else policy).write_bytes(b"Replaced identity\n")
            if raw is not None:
                stdout, stderr, code = raw
            else:
                stdout = f"OWNED_APPLEEVENT_PREFLIGHT/1 mode={mode} osstatus={status}\n"
                stderr, code = "", 0 if status == 0 else 67
            return subprocess.CompletedProcess(arguments, code, stdout, stderr)

        owner.run.side_effect = run
        receipt = probe.admit_appleevent_permission_prerequisite(
            owner, [str(sender), "73136", "owned-nonce"], policy, observed.append
        )
        return owner, observed, receipt

    def test_missing_explicit_boolean_opt_in_never_starts_a_native_request(self):
        for value in (False, None, 1, "true"):
            with self.subTest(value=value), TemporaryDirectory() as directory:
                with self.assertRaisesRegex(probe.AdmissionError, "not explicitly authorized"):
                    self.invoke(Path(directory).resolve(strict=True), (), allow=value)

    def test_existing_permission_requires_two_fresh_exact_context_queries(self):
        with TemporaryDirectory() as directory:
            owner, observed, receipt = self.invoke(Path(directory).resolve(strict=True), (0, 0))
            self.assertEqual(owner.run.call_count, 2)
            self.assertEqual(
                observed,
                [
                    "before-automation-query",
                    "after-automation-query",
                    "before-automation-query",
                    "after-automation-query",
                ],
            )
            self.assertEqual(receipt["statuses"], [{"mode": "query", "osstatus": 0}] * 2)

    def test_ui_opt_in_only_observes_the_exact_owned_request_mode(self):
        with (
            TemporaryDirectory() as directory,
            patch.object(
                probe, "approve_owned_automation_prompt", return_value="pressed"
            ) as approval,
        ):
            owner, observed, receipt = self.invoke(
                Path(directory).resolve(strict=True), (-1744, 0, 0), ui=True
            )
        approval.assert_called_once_with(
            owner, "exact-owned-requester", 30, "Owned sender identity", "Owned receiver identity"
        )
        self.assertEqual(
            receipt["statuses"][1],
            {
                "mode": "request",
                "osstatus": 0,
                "native_ui": "pressed",
            },
        )
        self.assertEqual(receipt["statuses"][2], {"mode": "query", "osstatus": 0})

    def test_consent_required_request_and_fresh_query_keep_original_sender_and_policy(self):
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            owner, observed, receipt = self.invoke(root, (-1744, 0, 0))
            self.assertEqual(owner.run.call_count, 3)
            self.assertEqual(
                [call.args[0][-1] for call in owner.run.call_args_list],
                [
                    "permission-query",
                    "permission-request",
                    "permission-query",
                ],
            )
            self.assertEqual(len(observed), 6)
            self.assertEqual(
                receipt["statuses"],
                [
                    {"mode": "query", "osstatus": -1744},
                    {"mode": "request", "osstatus": 0},
                    {"mode": "query", "osstatus": 0},
                ],
            )
            self.assertEqual(
                receipt["sender_sha256"],
                probe.digest(root / "OwnedAppleEvent-sender.app/Contents/MacOS/sender"),
            )

    def test_refused_permission_or_unavailable_target_never_becomes_a_grant(self):
        for statuses in ((-1743,), (-600,), (-1744, -1743), (-1744, -600), (-1744, -1744)):
            with self.subTest(statuses=statuses), TemporaryDirectory() as directory:
                with self.assertRaisesRegex(probe.AdmissionError, "was not granted"):
                    self.invoke(Path(directory).resolve(strict=True), statuses)

    def test_initial_or_requested_grant_requires_fresh_nonprompt_confirmation(self):
        for statuses in ((0, -1744), (-1744, 0, -1743)):
            with self.subTest(statuses=statuses), TemporaryDirectory() as directory:
                with self.assertRaisesRegex(probe.AdmissionError, "Fresh nonprompt"):
                    self.invoke(Path(directory).resolve(strict=True), statuses)

    def test_prompt_timeout_preserves_the_native_owner_failure(self):
        failure = probe.AdmissionError("Owned native command exceeded deadline")
        with TemporaryDirectory() as directory:
            with self.assertRaises(probe.AdmissionError) as caught:
                self.invoke(Path(directory).resolve(strict=True), (), error=failure)
            self.assertIs(caught.exception, failure)

    def test_changed_executable_or_policy_cannot_borrow_permission_receipt(self):
        for target in ("sender", "policy"):
            with self.subTest(target=target), TemporaryDirectory() as directory:
                with self.assertRaisesRegex(probe.AdmissionError, "identity changed"):
                    self.invoke(Path(directory).resolve(strict=True), (0,), mutate=target)

    def test_dirty_mismatched_or_noncanonical_receipts_cannot_grant_permission(self):
        for raw in (
            ("OWNED_APPLEEVENT_PREFLIGHT/1 mode=query osstatus=0\n", "dirty", 0),
            ("OWNED_APPLEEVENT_PREFLIGHT/1 mode=request osstatus=0\n", "", 0),
            ("OWNED_APPLEEVENT_PREFLIGHT/1 mode=query osstatus=00\n", "", 0),
            ("OWNED_APPLEEVENT_PREFLIGHT/1 mode=query osstatus=-0\n", "", 0),
            ("OWNED_APPLEEVENT_PREFLIGHT/1 mode=query osstatus=2147483648\n", "", 67),
            ("OWNED_APPLEEVENT_PREFLIGHT/1 mode=query osstatus=0\n", "", 67),
            ("OWNED_APPLEEVENT_PREFLIGHT/1 mode=query osstatus=-1744\n", "", 0),
            ("OWNED_APPLEEVENT_PREFLIGHT/1 mode=query osstatus=0\n" * 2, "", 0),
        ):
            with self.subTest(raw=raw), TemporaryDirectory() as directory:
                with self.assertRaises(probe.AdmissionError):
                    self.invoke(Path(directory).resolve(strict=True), (0,), raw=raw)

    def test_consented_prerequisite_never_replaces_original_positive_or_denial_receipts(self):
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            (root / "sandbox.sb").write_text(AppleEventBoundaryControls.policy)
            judge = AppleEventBoundaryControls()
            owner = judge.model(root)
            owner.allow_automation_consent = True
            permission = {"sender_sha256": "a" * 64, "statuses": [{"mode": "query", "osstatus": 0}]}
            with (
                patch.object(probe.uuid, "uuid4", return_value=judge.nonce),
                patch.object(probe, "native_compiler", return_value=["modeled-native-clang"]),
                patch.object(
                    probe, "admit_appleevent_permission_prerequisite", return_value=permission
                ) as request,
            ):
                receipt = probe.admit_appleevent_boundary(owner, root)
            self.assertEqual(len(owner.sender_calls), 3)
            self.assertEqual(owner.deliveries, 2)
            self.assertEqual(receipt["unconfined_status"], 0)
            self.assertEqual(receipt["deny_removal_status"], 0)
            self.assertEqual(receipt["denied_status"], -1743)
            self.assertEqual(receipt["permission_prerequisite"], permission)
            self.assertTrue(receipt["receiver_retired"])
            request.assert_called_once()
            arguments = request.call_args.args
            self.assertIs(arguments[0], owner)
            self.assertEqual(arguments[1][1:], ["73136", judge.nonce])
            self.assertEqual(arguments[2], root / "sandbox-appleevent-positive.sb")


class OwnedConsentUIControls(unittest.TestCase):
    """Bounded exact-requester controls; actual secure OS UI is native-only."""

    def owner(self, packets, *, terminal=None, reaped=False):
        process = Mock(pid=73136)
        group = Mock(process=process, reaped=reaped)
        group.observe_exit.return_value = terminal
        owner = Mock(root=Path("/owned-private-root"), groups={process: group})
        owner.run.side_effect = [
            subprocess.CompletedProcess([], code, out, err) for code, out, err in packets
        ]
        return owner, process, group

    def test_absent_then_unique_pressed_prompt_stays_inside_request_deadline(self):
        owner, process, group = self.owner(
            [
                (0, "OWNED_AUTOMATION_UI/1 state=absent\n", ""),
                (0, "OWNED_AUTOMATION_UI/1 state=pressed\n", ""),
            ]
        )
        with (
            patch.object(probe.time, "monotonic", return_value=20),
            patch.object(probe.time, "sleep") as sleep,
        ):
            probe.approve_owned_automation_prompt(owner, process, 22, "sender", "receiver")
        self.assertEqual(owner.run.call_count, 2)
        self.assertEqual(group.observe_exit.call_count, 2)
        sleep.assert_called_once_with(0.05)
        for call in owner.run.call_args_list:
            self.assertEqual(
                call.args[0],
                [str(owner.root / "native-appleevent-consent"), "sender", "receiver", "73136"],
            )
            self.assertEqual(call.kwargs, {"check": False, "timeout": 2})

    def test_terminal_requester_never_acquires_or_presses_a_consent_window(self):
        owner, process, group = self.owner([], terminal=object())
        probe.approve_owned_automation_prompt(owner, process, 0, "sender", "receiver")
        owner.run.assert_not_called()

    def test_lost_or_replaced_requester_reservation_never_acquires_ui(self):
        for fault in ("reaped", "replaced", "missing"):
            owner, process, group = self.owner([], reaped=fault == "reaped")
            if fault == "replaced":
                group.process = Mock()
            if fault == "missing":
                owner.groups = {}
            with (
                self.subTest(fault=fault),
                self.assertRaisesRegex(probe.AdmissionError, "reservation changed"),
            ):
                probe.approve_owned_automation_prompt(owner, process, 100, "sender", "receiver")
            owner.run.assert_not_called()

    def test_missing_permission_identity_or_unqualified_native_ui_never_grants(self):
        for state in (
            "accessibility-unavailable",
            "identity-unqualified",
            "observation-refused",
            "approval-refused",
            "requester-unavailable",
        ):
            owner, process, group = self.owner(
                [(67, "OWNED_AUTOMATION_UI/1 state=" + state + "\n", "")]
            )
            with self.subTest(state=state), patch.object(probe.time, "monotonic", return_value=0):
                with self.assertRaisesRegex(probe.AdmissionError, state):
                    probe.approve_owned_automation_prompt(owner, process, 30, "sender", "receiver")
            self.assertEqual(owner.run.call_count, 1)

    def test_dirty_or_ambiguous_frame_never_exposes_private_capture(self):
        for packet in (
            (0, "OWNED_AUTOMATION_UI/1 state=pressed\n", "private-capture"),
            (67, "private-path-or-nonce\n", ""),
            (67, "OWNED_AUTOMATION_UI/1 state=pressed\n", ""),
            (0, "OWNED_AUTOMATION_UI/1 state=pressed\n" * 2, ""),
        ):
            owner, process, group = self.owner([packet])
            with patch.object(probe.time, "monotonic", return_value=0):
                with self.assertRaises(probe.AdmissionError) as caught:
                    probe.approve_owned_automation_prompt(owner, process, 30, "sender", "receiver")
            self.assertNotIn("private-", str(caught.exception))

    def test_expired_outer_deadline_never_acquires_native_ui(self):
        owner, process, group = self.owner([])
        with patch.object(probe.time, "monotonic", return_value=30):
            with self.assertRaisesRegex(probe.AdmissionError, "deadline"):
                probe.approve_owned_automation_prompt(owner, process, 30, "sender", "receiver")
        owner.run.assert_not_called()

    def test_after_start_exception_physically_settles_same_native_requester(self):
        with (
            TemporaryDirectory() as directory,
            patch.object(probe, "NativeProcessGroups"),
            patch.object(probe.os, "getuid", return_value=501, create=True),
        ):
            owner = probe.Children(Path(directory))
            child = Mock(pid=73136, returncode=None)
            refusal = probe.AdmissionError("Normal UI refused owned prompt")
            callback = Mock(side_effect=refusal)
            with (
                patch.object(probe.subprocess, "Popen", return_value=child),
                patch.object(owner, "settle") as settle,
                patch.object(OwnedProcessGroup, "wait_for_exit") as wait,
            ):
                with self.assertRaises(probe.AdmissionError) as caught:
                    owner.run(["owned-requester"], timeout=30, after_start=callback)
                self.assertIs(caught.exception, refusal)
                callback.assert_called_once()
                self.assertIs(callback.call_args.args[0], child)
                wait.assert_not_called()
                settle.assert_called_once_with(child)
            self.assertEqual(owner.active, [])

    def test_ui_callback_does_not_restart_original_native_request_deadline(self):
        with (
            TemporaryDirectory() as directory,
            patch.object(probe, "NativeProcessGroups"),
            patch.object(probe.os, "getuid", return_value=501, create=True),
        ):
            owner = probe.Children(Path(directory))
            child = Mock(pid=73136, returncode=0)
            callback = Mock()
            with (
                patch.object(probe.subprocess, "Popen", return_value=child),
                patch.object(owner, "settle") as settle,
                patch.object(OwnedProcessGroup, "wait_for_exit") as wait,
                patch.object(probe.time, "monotonic", side_effect=(20, 45)),
            ):
                result = owner.run(["owned-requester"], timeout=30, after_start=callback)
                self.assertEqual(result.returncode, 0)
                callback.assert_called_once_with(child, 50)
                wait.assert_called_once_with(5)
                settle.assert_called_once_with(child)
            self.assertEqual(owner.active, [])

    def test_pending_native_ipc_then_pressed_reuses_requester_and_original_budget(self):
        owner, process, group = self.owner(
            [
                (0, "OWNED_AUTOMATION_UI/1 state=observation-pending\n", ""),
                (0, "OWNED_AUTOMATION_UI/1 state=pressed\n", ""),
            ]
        )
        with (
            patch.object(probe.time, "monotonic", side_effect=(20, 20, 21)),
            patch.object(probe.time, "sleep") as sleep,
        ):
            self.assertEqual(
                probe.approve_owned_automation_prompt(owner, process, 22, "sender", "receiver"),
                "pressed",
            )
        self.assertEqual(group.observe_exit.call_count, 2)
        self.assertEqual([c.kwargs["timeout"] for c in owner.run.call_args_list], [2, 1])
        self.assertTrue(all(c.args[0][-1] == "73136" for c in owner.run.call_args_list))
        sleep.assert_called_once_with(0.05)

    def test_persistent_pending_native_ipc_is_refused_at_original_deadline(self):
        owner, process, group = self.owner(
            [
                (0, "OWNED_AUTOMATION_UI/1 state=observation-pending\n", ""),
                (0, "OWNED_AUTOMATION_UI/1 state=observation-pending\n", ""),
            ]
        )
        with (
            patch.object(probe.time, "monotonic", side_effect=(0, 0, 1, 1, 2)),
            patch.object(probe.time, "sleep"),
        ):
            with self.assertRaisesRegex(probe.AdmissionError, "deadline"):
                probe.approve_owned_automation_prompt(owner, process, 2, "sender", "receiver")
        self.assertEqual(owner.run.call_count, 2)
        self.assertEqual(group.observe_exit.call_count, 3)
        self.assertEqual([c.kwargs["timeout"] for c in owner.run.call_args_list], [2, 1])

    def test_terminal_requester_after_pending_never_acquires_another_ui(self):
        owner, process, group = self.owner(
            [
                (0, "OWNED_AUTOMATION_UI/1 state=observation-pending\n", ""),
            ]
        )
        group.observe_exit.side_effect = (None, 0)
        with (
            patch.object(probe.time, "monotonic", return_value=0),
            patch.object(probe.time, "sleep"),
        ):
            self.assertEqual(
                probe.approve_owned_automation_prompt(owner, process, 2, "sender", "receiver"),
                "request-ended",
            )
        self.assertEqual(owner.run.call_count, 1)

    def test_pending_native_frame_requires_zero_exit_and_complete_clean_capture(self):
        for packet in (
            (67, "OWNED_AUTOMATION_UI/1 state=observation-pending\n", ""),
            (0, "OWNED_AUTOMATION_UI/1 state=observation-pending\n", "private"),
            (0, "OWNED_AUTOMATION_UI/1 state=observation-pending\n" * 2, ""),
        ):
            with self.subTest(packet=packet):
                owner, process, group = self.owner([packet])
                with patch.object(probe.time, "monotonic", return_value=0):
                    with self.assertRaises(probe.AdmissionError):
                        probe.approve_owned_automation_prompt(
                            owner, process, 2, "sender", "receiver"
                        )
                self.assertEqual(owner.run.call_count, 1)


class OwnedAutomationUIFactControls(unittest.TestCase):
    """Private enum evidence controls do not claim macOS AX observation."""

    @staticmethod
    def packet():
        return {
            "schema": 1,
            "ax_trusted": True,
            "requester_qualified": True,
            "scanned_agents": 2,
            "windows": 1,
            "nodes": 7,
            "candidates": 0,
            "matches": 0,
            "first_agent": 1,
            "first_attribute": "windows",
            "first_type": "absent",
            "first_error": -25205,
        }

    def test_literal_ax_error_and_agent_enum_remain_closed_without_ui_text(self):
        packet = self.packet()
        self.assertEqual(probe._validate_owned_automation_ui_fact(packet), packet)
        for key, value in (
            ("schema", True),
            ("ax_trusted", 1),
            ("scanned_agents", True),
            ("nodes", 1048577),
            ("first_agent", 4),
            ("first_error", 2**31),
            ("first_attribute", "private-window-title"),
            ("first_type", "private-text"),
        ):
            invalid = dict(packet)
            invalid[key] = value
            with self.subTest(key=key), self.assertRaises(probe.AdmissionError):
                probe._validate_owned_automation_ui_fact(invalid)
        packet["private_text"] = "not-admitted"
        with self.assertRaises(probe.AdmissionError):
            probe._validate_owned_automation_ui_fact(packet)

    def test_private_capture_preserves_primary_native_refusal_and_exports_only_enum_facts(self):
        with TemporaryDirectory() as directory, patch.object(probe, "NativeProcessGroups"):
            root = Path(directory)
            evidence_dir = root / "evidence"
            evidence_dir.mkdir(mode=0o700)
            evidence = probe.PhaseEvidence(evidence_dir)
            owner = probe.Children(root, evidence=evidence)
            packet = self.packet()
            primary = subprocess.CompletedProcess(
                [], 67, "OWNED_AUTOMATION_UI/1 state=observation-refused\n", ""
            )

            def producer(arguments, **kwargs):
                self.assertEqual(arguments[:-1], ["/owned/helper", "sender", "receiver", "73"])
                self.assertEqual(kwargs, {"check": False, "timeout": 2})
                path = Path(arguments[-1])
                self.assertEqual(path.parent, root)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                path.write_text(json.dumps(packet))
                return primary

            owner.run = Mock(side_effect=producer)
            try:
                result = probe._owned_automation_ui_run(
                    owner, ["/owned/helper", "sender", "receiver", "73"], 2
                )
                self.assertIs(result, primary)
                exported = json.loads((evidence_dir / "checkpoint.json").read_text())
                self.assertEqual(exported["native_ui"], packet)
                self.assertEqual(exported["phase"], "automation.ui-observation")
                self.assertEqual(exported["status"], "refused")
                self.assertFalse(exported["ownership_closed"])
                self.assertEqual(list(root.glob("automation-ui-fact-*")), [])
            finally:
                evidence.close()

    def test_replaced_diagnostic_path_is_neither_read_as_fact_nor_unlinked(self):
        with TemporaryDirectory() as directory, patch.object(probe, "NativeProcessGroups"):
            root = Path(directory)
            owner = probe.Children(root)
            captured = []

            def producer(arguments, **kwargs):
                path = Path(arguments[-1])
                path.unlink()
                path.write_text("foreign-replacement")
                captured.append(path)
                return subprocess.CompletedProcess(
                    [], 67, "OWNED_AUTOMATION_UI/1 state=observation-refused\n", ""
                )

            owner.run = Mock(side_effect=producer)
            with self.assertRaisesRegex(probe.AdmissionError, "identity or bound"):
                probe._owned_automation_ui_run(
                    owner, ["/owned/helper", "sender", "receiver", "73"], 2
                )
            self.assertEqual(captured[0].read_text(), "foreign-replacement")

    def test_observation_packet_cannot_claim_acceptance_or_physical_closure(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            for status, closed in (("accepted", False), ("pending", True)):
                evidence = probe.PhaseEvidence(root)
                try:
                    self.assertFalse(
                        evidence.record(
                            "automation.ui-observation",
                            status=status,
                            closed=closed,
                            native_ui=self.packet(),
                        )
                    )
                    self.assertTrue(evidence.failed)
                    self.assertFalse((root / "checkpoint.json").exists())
                finally:
                    evidence.close()


class ComposedNativeDiagnosticControls(unittest.TestCase):
    """Independent joint grammar and real adapter controls, not macOS admission."""

    def combined(self):
        root = AppleEventSenderDiagnosticControls().marker()
        phase = "Owned AppleEvent outcome admission failed: phase=reply-read, send=0, read=-1701, length=unobserved, match=unobserved, error_read=0, error_length=4, error_value=-1708, marker2=absent\n"
        return root + phase

    def test_joint_sender_preserves_both_closed_projections_without_success(self):
        value = self.combined()
        self.assertEqual(
            probe._appleevent_sender_diagnostic(value),
            AppleEventSenderDiagnosticControls().packet(),
        )
        self.assertEqual(probe.appleevent_sender_marker_fact(value)["marker2_snapshot"], "absent")
        owner = SimpleNamespace(
            run=Mock(
                return_value=subprocess.CompletedProcess(
                    [], 66, "OWNED_APPLEEVENT_PERMISSION/1 osstatus=0\n", value
                )
            )
        )
        with self.assertRaises(probe.AdmissionError) as caught:
            probe.run_appleevent_sender(owner, [], "unconfined-positive")
        self.assertIn('"error_number": -1708', str(caught.exception))
        self.assertIn('"osstatus": 0', str(caught.exception))
        self.assertNotIn("native_appleevent_status=0", str(caught.exception))

    def test_joint_sender_unknown_duplicate_mismatch_and_noise_are_refused(self):
        value = self.combined()
        mutations = (
            value + "PRIVATE\n",
            value.replace("send=0,", "send=-36,"),
            value.replace("error_value=-1708", "error_value=-10004"),
            value.replace("read=-1701,", "read=-1700,"),
            value.replace('"schema":1', '"schema":1,"schema":1'),
            value.replace("marker2=absent", "marker2=PRIVATE"),
            value.replace("phase=reply-read", "phase=PRIVATE"),
            value.replace("marker2=absent", "marker2=absent, marker2=absent"),
            value.replace("marker2=absent", "marker2=\ud800"),
        )
        for changed in mutations:
            with self.subTest(value=repr(changed[-80:])):
                with self.assertRaises((probe.AdmissionError, UnicodeError)):
                    probe._appleevent_sender_diagnostic(changed)
                self.assertEqual(probe.appleevent_sender_marker_fact(changed), {})

    def test_independently_valid_sender_statuses_must_still_agree(self):
        packet = {
            "schema": 1,
            "mode": 2,
            "send_status": 0,
            "nonce_read_available": False,
            "nonce_read_status": None,
            "nonce_size": None,
            "nonce_match": None,
            "reply_type": 0,
            "error_read_available": False,
            "error_read_status": None,
            "error_type": None,
            "error_size": None,
            "error_available": False,
            "error_number": None,
        }
        root = (
            "Owned AppleEvent outcome admission failed: 0\nOwned AppleEvent sender diagnostic: "
            + json.dumps(packet, separators=(",", ":"))
            + "\n"
        )
        phase = "Owned AppleEvent outcome admission failed: phase=denied-status, send=-600, read=unobserved, length=unobserved, match=unobserved, error_read=unobserved, error_length=unobserved, error_value=unobserved\n"
        self.assertEqual(probe._appleevent_sender_diagnostic(root), packet)
        self.assertEqual(probe.appleevent_sender_marker_fact(phase)["send_osstatus"], -600)
        with self.assertRaises(probe.AdmissionError):
            probe._appleevent_sender_diagnostic(root + phase)
        self.assertEqual(probe.appleevent_sender_marker_fact(root + phase), {})

    def test_joint_registration_scalar_and_label_facts_agree(self):
        value = (
            b"Owned AppleEvent recipient AppKit admission refused (reason 2; before 1/2; after 1/2).\n"
            b"APPKIT_POLICY/1 initial=prohibited after=prohibited\n"
        )
        self.assertGreater(len(value), 128)
        expected = {
            "phase": "appkit-admission",
            "appkit_reason": "policy-refused",
            "appkit_initial_policy": "prohibited",
            "appkit_after_no_policy": "prohibited",
        }
        self.assertEqual(probe._appkit_joint_registration_fact(value), expected)
        with TemporaryDirectory() as directory:
            owner, receiver, _ = RegistrationFactControls.capture(self, Path(directory), value)
            self.assertEqual(probe.appleevent_registration_fact(owner, receiver), expected)
        for changed in (
            value + b"PRIVATE\n",
            value.replace(b"initial=prohibited", b"initial=regular"),
            value.replace(b"reason 2", b"reason 1"),
            value.replace(b"before 1/2", b"before 0/2"),
            value.replace(b"after 1/2", b"after 1/3"),
            value.replace(b"after=prohibited", b"after=PRIVATE"),
        ):
            self.assertEqual(probe._appkit_joint_registration_fact(changed), {})

    def test_joint_terminal_reuses_root_capture_hashes_and_policy(self):
        with patch.multiple(probe.os, CLD_EXITED=1, CLD_KILLED=2, CLD_DUMPED=3, create=True):
            receiver = Mock(pid=73136, returncode=None)
            group = Mock(process=receiver, reaped=False)
            owner = SimpleNamespace(groups={receiver: group})
            value = (
                b"Owned AppleEvent recipient AppKit admission refused (reason 2; before 1/2; after 1/2).\n"
                b"APPKIT_POLICY/1 initial=prohibited after=prohibited\n"
            )
            observed = SimpleNamespace(si_pid=73136, si_code=1, si_status=65)
            with patch.object(probe, "_appleevent_capture", return_value=(b"", value)):
                packet = probe._appleevent_terminal_packet(owner, receiver, group, observed)
            self.assertEqual(packet["stderr_phase"], "appkit-policy")
            self.assertEqual(packet["appkit_policy"]["before_policy"], 2)
            self.assertEqual(packet["stderr_sha256"], hashlib.sha256(value).hexdigest())
            self.assertEqual(packet["stderr_bytes"], len(value))
            group.observe_exit.assert_not_called()

    def test_native_adapter_reuses_one_observation_for_both_receivers(self):
        control = AppleEventSenderDiagnosticControls()
        owner, receiver, group = control.world()
        owner.run = Mock(return_value=subprocess.CompletedProcess([], 66, "", self.combined()))
        with patch("builtins.print") as output:
            with self.assertRaises(probe.AdmissionError) as caught:
                probe._run_appleevent_sender(owner, receiver, group, "deny-removal-positive", [])
        self.assertIn("control=deny-removal-positive", str(caught.exception))
        self.assertIn('"marker2_snapshot": "absent"', str(caught.exception))
        group.observe_exit.assert_called_once_with()
        self.assertEqual(
            owner.evidence.record.call_args.kwargs["sender_failure"]["sender"], control.packet()
        )
        self.assertIn('"state": "no-terminal-observation"', output.call_args.args[0])
        group.settle.assert_not_called()
        receiver.poll.assert_not_called()
        receiver.wait.assert_not_called()

    def test_optional_receiver_publication_cannot_replace_primary_or_swallow_cancellation(self):
        control = AppleEventSenderDiagnosticControls()
        owner, receiver, group = control.world()
        original = probe.AdmissionError("original native refusal")
        with patch("builtins.print", side_effect=OSError("PRIVATE")):
            probe._observe_sender_failure(
                owner, receiver, group, "unconfined-positive", None, original
            )
        self.assertEqual(str(original), "original native refusal")
        self.assertNotIn("PRIVATE", "".join(original.__notes__))
        cancellation = probe.OwnedProcessInterrupted("cancelled")
        with patch("builtins.print", side_effect=cancellation):
            with self.assertRaises(probe.OwnedProcessInterrupted) as caught:
                probe._observe_sender_failure(
                    owner, receiver, group, "unconfined-positive", None, original
                )
        self.assertIs(caught.exception, cancellation)

    def test_dev_current_process_failure_uses_exact_root_terminal_lifetime(self):
        with patch.multiple(probe.os, CLD_EXITED=1, CLD_KILLED=2, CLD_DUMPED=3, create=True):
            receiver = Mock(pid=73136, returncode=None)
            group = Mock(process=receiver, reaped=False)
            owner = SimpleNamespace(groups={receiver: group})
            observed = SimpleNamespace(si_pid=73136, si_code=1, si_status=65)
            value = b"Owned AppleEvent recipient registration failed: phase=get-current-process, osstatus=-50\n"
            with patch.object(probe, "_appleevent_capture", return_value=(b"", value)):
                packet = probe._appleevent_terminal_packet(owner, receiver, group, observed)
            self.assertEqual(packet["stderr_phase"], "registration-current-process")
            self.assertEqual(packet["stderr_osstatus"], -50)
            group.observe_exit.assert_not_called()


class SharedImageAppleEventRecipeControls(unittest.TestCase):
    """Real recipe/filesystem over an explicit compiler port, never native delivery."""

    def test_two_roles_share_one_compiled_signed_image_without_privacy_changes(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            calls = []
            children = SimpleNamespace(run=lambda args, **options: calls.append((args, options)))
            nonce = "54bc7a36-e2f0-43f8-917e-ce3d286d7520"
            roles = probe._build_appleevent_pair(children, root, root, ["owned-clang"], nonce)
            self.assertEqual(set(roles), {"receiver", "sender"})
            self.assertEqual(roles["receiver"][0], roles["sender"][0])
            self.assertEqual(roles["receiver"][1], "receiver")
            self.assertEqual(roles["sender"][1], "sender")
            self.assertEqual(len(calls), 3)
            self.assertEqual(calls[0][0][0], "owned-clang")
            self.assertIn(
                str(root / "tools/diagnostics/native_appleevent_probe_pair.m"), calls[0][0]
            )
            self.assertEqual(calls[0][0][-1], roles["receiver"][0])
            app = root / "OwnedAppleEvent.app"
            self.assertEqual(calls[1][0], ["/usr/bin/codesign", "--force", "--sign", "-", str(app)])
            self.assertEqual(
                calls[2][0], ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)]
            )
            self.assertTrue(all(options == {"confined": True} for _, options in calls))
            info = probe.plistlib.loads((app / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleIdentifier"], "com.ergopti.private.appleevent." + nonce)
            self.assertEqual(info["CFBundleExecutable"], "owned-probe")
            self.assertNotIn("NSAppleScriptEnabled", info)
            self.assertNotIn("--entitlements", str(calls))

    def test_compiler_refusal_cannot_sign_or_supply_role_routes(self):
        with TemporaryDirectory() as directory:
            run = Mock(side_effect=probe.AdmissionError("actual compiler refusal"))
            with self.assertRaisesRegex(probe.AdmissionError, "actual compiler refusal"):
                probe._build_appleevent_pair(
                    SimpleNamespace(run=run),
                    Path(directory),
                    Path(directory),
                    ["owned-clang"],
                    "54bc7a36-e2f0-43f8-917e-ce3d286d7520",
                )
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.kwargs, {"confined": True})

    def test_an_existing_bundle_is_never_replaced_or_signed(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            existing = root / "OwnedAppleEvent.app/Contents/MacOS"
            existing.mkdir(parents=True)
            sentinel = existing / "foreign"
            sentinel.write_bytes(b"independent foreign bytes")
            run = Mock()
            with self.assertRaises(FileExistsError):
                probe._build_appleevent_pair(
                    SimpleNamespace(run=run),
                    root,
                    root,
                    ["owned-clang"],
                    "54bc7a36-e2f0-43f8-917e-ce3d286d7520",
                )
            run.assert_not_called()
            self.assertEqual(sentinel.read_bytes(), b"independent foreign bytes")


class SenderRegistrationIdentityControls(unittest.TestCase):
    """Closed scalar transport controls; actual AppKit/Security APIs require macOS."""

    FAILURE = (
        "Owned AppleEvent outcome admission failed: phase=reply-read, send=0, "
        "read=-1701, length=unobserved, match=unobserved, error_read=0, "
        "error_length=4, error_value=-1744, marker2=absent\n"
    )
    FRAME = (
        "OWNED_APPLEEVENT_IDENTITY/1 before=1 after=1 self=1 target=1 "
        "self_team=0 target_team=0 team=-1 identifier=1 hash=1\n"
    )

    def test_closed_identity_preserves_original_nonce_and_permission_failure(self):
        original, facts = probe.appleevent_sender_identity_frame(self.FAILURE + self.FRAME)
        self.assertEqual(original, self.FAILURE)
        self.assertEqual(
            facts,
            {
                "appkit_before": 1,
                "appkit_after": 1,
                "self_available": True,
                "target_available": True,
                "self_team": False,
                "target_team": False,
                "team_equal": None,
                "identifier_equal": True,
                "hash_equal": True,
            },
        )
        self.assertEqual(probe.appleevent_sender_marker_fact(original)["error_number"], -1744)
        result = subprocess.CompletedProcess(
            [], 66, "OWNED_APPLEEVENT_PERMISSION/1 osstatus=-1744\n", self.FAILURE + self.FRAME
        )
        with self.assertRaises(probe.AdmissionError) as failed:
            probe.run_appleevent_sender(
                SimpleNamespace(run=Mock(return_value=result)), [], "unconfined-positive"
            )
        self.assertIn("sender_identity_fact=", str(failed.exception))
        self.assertIn('"error_number": -1744', str(failed.exception))
        self.assertIn('"osstatus": -1744', str(failed.exception))
        self.assertNotIn("OWNED_APPLEEVENT_IDENTITY/", str(failed.exception))

    def test_unavailable_code_identity_remains_unknown_not_equal(self):
        frame = self.FRAME.replace(
            "self=1 target=1 self_team=0 target_team=0 team=-1 identifier=1 hash=1",
            "self=0 target=0 self_team=-1 target_team=-1 team=-1 identifier=-1 hash=-1",
        )
        original, facts = probe.appleevent_sender_identity_frame(self.FAILURE + frame)
        self.assertEqual(original, self.FAILURE)
        self.assertIs(facts["self_available"], False)
        for field in ("self_team", "target_team", "team_equal", "identifier_equal", "hash_equal"):
            self.assertIsNone(facts[field])

    def test_wrong_or_private_fields_cannot_be_exported(self):
        for frame in (
            self.FRAME.replace("self=1", "self=0"),
            self.FRAME.replace("team=-1", "team=1"),
            self.FRAME.replace("hash=1", "hash=private-digest"),
            self.FRAME.replace("before=1", "before=01"),
            self.FRAME + self.FRAME,
            self.FRAME.rstrip("\n"),
            self.FRAME + "private-path\n",
            self.FRAME.replace("target=1", "target=2"),
        ):
            with self.subTest(frame=frame):
                value = self.FAILURE + frame
                self.assertEqual(probe.appleevent_sender_identity_frame(value), (value, {}))

    def test_sender_precondition_refusal_remains_failed_before_nonce_send(self):
        failure = "Owned AppleEvent sender AppKit admission refused: 2\n"
        frame = self.FRAME.replace(
            "self=1 target=1 self_team=0 target_team=0 team=-1 identifier=1 hash=1",
            "self=0 target=0 self_team=-1 target_team=-1 team=-1 identifier=-1 hash=-1",
        )
        original, facts = probe.appleevent_sender_identity_frame(failure + frame)
        self.assertEqual(original, failure)
        self.assertIs(facts["target_available"], False)
        result = subprocess.CompletedProcess([], 65, "", failure + frame)
        with self.assertRaisesRegex(probe.AdmissionError, "exit=65"):
            probe.run_appleevent_sender(
                SimpleNamespace(run=Mock(return_value=result)), [], "unconfined-positive"
            )

    def test_success_cannot_adopt_identity_output_instead_of_exact_nonce_receipt(self):
        result = subprocess.CompletedProcess([], 0, "native_appleevent_status=0\n", self.FRAME)
        with self.assertRaises(probe.AdmissionError):
            probe.run_appleevent_sender(
                SimpleNamespace(run=Mock(return_value=result)), [], "unconfined-positive"
            )

    def test_security_recipe_and_each_native_control_marker_are_mandatory(self):
        with TemporaryDirectory() as directory:
            calls = []
            root = Path(directory)
            probe._build_appleevent_pair(
                SimpleNamespace(run=lambda args, **options: calls.append(args)),
                root,
                root,
                ["owned-clang"],
                "54bc7a36-e2f0-43f8-917e-ce3d286d7520",
            )
            self.assertIn("Security", calls[0])
        for absent in (
            "native_sender_registration_controls=6\n",
            "native_sender_identity_controls=7\n",
        ):
            with self.subTest(absent=absent), TemporaryDirectory() as directory:
                original = (
                    "native_appkit_registration_controls=6\n"
                    "native_private_appleevent_controls=1\n"
                    "native_sender_registration_controls=6\n"
                    "native_sender_identity_controls=7\n"
                )
                with self.assertRaisesRegex(probe.AppleEventBoundaryError, "registration refusals"):
                    AppleEventBoundaryControls().invoke(
                        directory, registration_output=original.replace(absent, "")
                    )


class ConsentPairMergeJoinControls(unittest.TestCase):
    def test_explicit_consent_keeps_two_named_roles_and_default_shared_image(self):
        import plistlib

        nonce = "54bc7a36-e2f0-43f8-917e-ce3d286d7520"
        with TemporaryDirectory() as directory:
            root = Path(directory)
            calls = []
            owner = SimpleNamespace(
                run=lambda args, **options: calls.append((args, options)),
                allow_automation_consent=True,
                allow_owned_consent_ui=True,
            )
            roles = probe._build_appleevent_consent_pair(owner, root, root, ["owned-clang"], nonce)
            self.assertEqual(set(roles), {"sender", "receiver"})
            self.assertNotEqual(roles["sender"][0], roles["receiver"][0])
            for role in ("sender", "receiver"):
                app = root / ("OwnedAppleEvent-" + role + ".app")
                properties = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                self.assertEqual(
                    properties["CFBundleIdentifier"],
                    "com.ergopti.private.appleevent." + role + "." + nonce,
                )
                self.assertEqual(
                    properties["CFBundleName"], "Owned AppleEvent " + role + " " + nonce
                )
                self.assertEqual(roles[role], [str(app / "Contents/MacOS" / role)])
                self.assertTrue(properties["LSUIElement"])
                self.assertFalse(any("Entitlement" in key for key in properties))
            self.assertEqual(owner.automation_sender_name, "Owned AppleEvent sender " + nonce)
            self.assertEqual(owner.automation_receiver_name, "Owned AppleEvent receiver " + nonce)
            compilations = [args for args, _ in calls if args[0] == "owned-clang"]
            self.assertEqual(len(compilations), 3)
            sender = [
                args
                for args in compilations
                if str(root / "tools/diagnostics/native_appleevent_probe_sender.c") in args
            ]
            receiver = [
                args
                for args in compilations
                if str(root / "tools/diagnostics/native_appleevent_probe_receiver.c") in args
            ]
            self.assertEqual(len(sender), 1)
            self.assertEqual(len(receiver), 1)
            for recipe in (sender[0], receiver[0]):
                self.assertIn("-fobjc-arc", recipe)
                self.assertEqual(recipe[recipe.index("-x") + 1], "objective-c")
                for framework in ("ApplicationServices", "Carbon", "AppKit", "Security"):
                    self.assertIn(framework, recipe)
            self.assertIn(str(root / "tools/diagnostics/native_appleevent_permission.c"), sender[0])
            self.assertNotIn(
                str(root / "tools/diagnostics/native_appleevent_permission.c"), receiver[0]
            )
            self.assertTrue(all(options == {"confined": True} for _, options in calls))
        with TemporaryDirectory() as directory:
            root = Path(directory)
            calls = []
            owner = SimpleNamespace(run=lambda args, **options: calls.append(args))
            roles = probe._build_appleevent_pair(owner, root, root, ["owned-clang"], nonce)
            image = str(root / "OwnedAppleEvent.app/Contents/MacOS/owned-probe")
            self.assertEqual(roles["sender"], [image, "sender"])
            self.assertEqual(roles["receiver"], [image, "receiver"])
            shared_compile = [args for args in calls if args[0] == "owned-clang"]
            self.assertEqual(len(shared_compile), 1)
            self.assertIn(
                str(root / "tools/diagnostics/native_appleevent_permission.c"), shared_compile[0]
            )
            self.assertFalse(hasattr(owner, "automation_sender_name"))
            self.assertFalse(hasattr(owner, "automation_receiver_name"))


class ComposedSenderIdentityControls(unittest.TestCase):
    """Both old closed frames remain independent and share no native authority."""

    FRAME = SenderRegistrationIdentityControls.FRAME

    def value(self):
        return ComposedNativeDiagnosticControls().combined() + self.FRAME

    def test_exact_joint_frame_retains_both_old_scalar_protocols(self):
        value = self.value()
        original, identity = probe.appleevent_sender_identity_frame(value)
        self.assertEqual(original, ComposedNativeDiagnosticControls().combined())
        self.assertTrue(identity["self_available"])
        self.assertTrue(identity["target_available"])
        self.assertTrue(identity["identifier_equal"])
        self.assertEqual(
            probe.appleevent_sender_marker_fact(original)["marker2_snapshot"], "absent"
        )
        self.assertEqual(
            probe._appleevent_sender_diagnostic(original),
            AppleEventSenderDiagnosticControls().packet(),
        )

    def test_primary_refusal_projects_identity_with_one_receiver_observation(self):
        control = AppleEventSenderDiagnosticControls()
        owner, receiver, group = control.world()
        owner.run = Mock(return_value=subprocess.CompletedProcess([], 66, "", self.value()))
        with patch("builtins.print"):
            with self.assertRaises(probe.AdmissionError) as caught:
                probe._run_appleevent_sender(owner, receiver, group, "deny-removal-positive", [])
        self.assertIn("sender_identity_fact=", str(caught.exception))
        self.assertIn('"marker2_snapshot": "absent"', str(caught.exception))
        group.observe_exit.assert_called_once_with()
        self.assertEqual(
            owner.evidence.record.call_args.kwargs["sender_failure"]["sender"], control.packet()
        )
        group.settle.assert_not_called()
        receiver.poll.assert_not_called()
        receiver.wait.assert_not_called()

    def test_noncanonical_joint_frames_cannot_project_partial_identity(self):
        value = self.value()
        for changed in (
            value + "PRIVATE\n",
            value + self.FRAME,
            self.FRAME + value,
            value.replace("identifier=1", "identifier=2"),
            value.replace("send=0", "send=-600"),
            value.replace("error_value=-1708", "error_value=-1709"),
            value.replace("before=1", "before=3"),
            value.replace("self=1 target=1", "self=0 target=1"),
            value.replace("\nOWNED_APPLEEVENT_IDENTITY", "\r\nOWNED_APPLEEVENT_IDENTITY"),
            " " * 1537 + value,
        ):
            with self.subTest(changed=changed):
                self.assertEqual(probe.appleevent_sender_identity_frame(changed), (changed, {}))

    def test_identity_metadata_never_replaces_exact_success_or_denial(self):
        for control, status in (("unconfined-positive", 0), ("full-policy-denial", -1742)):
            owner = SimpleNamespace(
                run=Mock(
                    return_value=subprocess.CompletedProcess(
                        [], 0, f"native_appleevent_status={status}\n", self.value()
                    )
                )
            )
            with self.assertRaises(probe.AdmissionError):
                probe.run_appleevent_sender(owner, [], control)


class PhysicalFixtureRootControls(unittest.TestCase):
    """Reproduce aliased temporary roots without weakening physical confinement."""

    def test_owned_temp_alias_replays_all_original_path_sensitive_controls(self):
        with TemporaryDirectory() as directory:
            outer = Path(directory).resolve(strict=True)
            physical = outer / "physical" / "temp"
            physical.mkdir(parents=True)
            aliases = outer / "aliases"
            aliases.mkdir()
            alias = aliases / "temp"
            with owned_directory_link(outer, alias, physical):
                self.assertNotEqual(alias, alias.resolve(strict=True))
                self.assertEqual(alias.resolve(strict=True), physical)
                with patch.object(tempfile, "tempdir", str(alias)):
                    suite = unittest.TestLoader().loadTestsFromTestCase(AppleEventBoundaryControls)
                    self.assertEqual(suite.countTestCases(), 7)
                    for name in (
                        "test_observed_symlink_cannot_admit_a_host_cache_or_tap",
                        "test_missing_declared_format_fails_before_cask_install",
                    ):
                        suite.addTest(ArchiveAcceptanceControls(name))
                    suite.addTest(
                        SenderFactControls(
                            "test_deny_removal_failure_stops_before_third_send_and_retains_receiver_owner"
                        )
                    )
                    result = unittest.TestResult()
                    suite.run(result)
                self.assertEqual(result.testsRun, 10)
                self.assertEqual(result.skipped, [])
                self.assertEqual(result.failures, [])
                self.assertEqual(result.errors, [])
            self.assertFalse(alias.exists())
            self.assertTrue(physical.is_dir())

    def test_registration_fixture_roots_match_exact_boundary_and_capture_parents(self):
        classes = (
            RegistrationFactControls,
            AppKitRegistrationFactControls,
            AppKitPolicyStateControls,
        )
        with TemporaryDirectory() as directory:
            outer = Path(directory).resolve(strict=True)
            physical = outer / "physical" / "temp"
            physical.mkdir(parents=True)
            aliases = outer / "aliases"
            aliases.mkdir()
            alias = aliases / "temp"
            with owned_directory_link(outer, alias, physical):
                self.assertNotEqual(alias, alias.resolve(strict=True))
                boundary = AppleEventBoundaryControls().model(alias)
                for cls in classes:
                    with self.subTest(capture_owner=cls.__name__):
                        capture_owner, receiver, capture = cls().capture(
                            alias, b"fixed fixture bytes\n"
                        )
                        self.assertEqual(capture_owner.root, boundary.root)
                        self.assertEqual(capture.parent, boundary.root)
                        self.assertEqual(probe.owned_path(boundary.root, capture), capture)
                        self.assertEqual(capture.read_bytes(), b"fixed fixture bytes\n")
                        receiver.poll.assert_not_called()
                        receiver.wait.assert_not_called()
        # Scan every root acquisition in the three capture-owning classes, not
        # only the three current failure sites; negative capture controls need
        # their physical parent too, or they can refuse for the wrong reason.
        acquisitions = 0
        for cls in classes:
            tree = ast.parse(textwrap.dedent(inspect.getsource(cls)))
            for node in ast.walk(tree):
                if not isinstance(node, ast.Assign) or len(node.targets) != 1:
                    continue
                if not isinstance(node.targets[0], ast.Name) or node.targets[0].id != "root":
                    continue
                value = node.value
                if (
                    isinstance(value, ast.Call)
                    and isinstance(value.func, ast.Attribute)
                    and value.func.attr == "resolve"
                    and isinstance(value.func.value, ast.Call)
                    and isinstance(value.func.value.func, ast.Name)
                    and value.func.value.func.id == "Path"
                    and len(value.func.value.args) == 1
                    and isinstance(value.func.value.args[0], ast.Name)
                    and value.func.value.args[0].id == "directory"
                ):
                    self.assertEqual(
                        [(kw.arg, ast.dump(kw.value)) for kw in value.keywords],
                        [("strict", "Constant(value=True)")],
                    )
                    acquisitions += 1
                elif (
                    isinstance(value, ast.Call)
                    and isinstance(value.func, ast.Name)
                    and value.func.id == "Path"
                    and len(value.args) == 1
                    and isinstance(value.args[0], ast.Name)
                    and value.args[0].id == "directory"
                ):
                    self.fail("A capture-owner root acquisition still keeps a lexical alias")
        self.assertEqual(acquisitions, 6, "all six real root acquisitions must be present")


class FirstPositiveAutomationPrerequisiteControls(unittest.TestCase):
    """Model the first-send prerequisite order, without claiming native TCC consent."""

    def invoke(self, root, statuses, *, allow=True):
        judge = AppleEventBoundaryControls()
        (root / "sandbox.sb").write_text(judge.policy)
        owner = judge.model(root)
        owner.allow_automation_consent = allow
        owner.allow_owned_consent_ui = False
        original_run = owner.run
        observations = []
        queue = iter(statuses)
        confirmed = False

        def run(arguments, **options):
            nonlocal confirmed
            if "-o" in arguments:
                executable = Path(arguments[arguments.index("-o") + 1])
                executable.write_bytes(
                    b"Independent modeled signed input " + executable.name.encode()
                )
            mode = arguments[-1]
            if mode.startswith("permission-"):
                self.assertTrue(allow)
                self.assertEqual(
                    arguments[:3],
                    ["/usr/bin/sandbox-exec", "-f", str(root / "sandbox-appleevent-positive.sb")],
                )
                self.assertEqual(
                    arguments[3:6],
                    [
                        str(root / "OwnedAppleEvent-sender.app/Contents/MacOS/sender"),
                        "73136",
                        judge.nonce,
                    ],
                )
                self.assertEqual(options, {"check": False, "timeout": 30})
                self.assertEqual((root / "sandbox.sb").read_text(), judge.policy)
                self.assertEqual(
                    Path(arguments[2]).read_text(),
                    judge.policy.replace("(deny appleevent-send)\n", ""),
                )
                status = next(queue)
                observations.append((mode, status))
                confirmed = status == 0 and mode == "permission-query" and len(observations) >= 2
                return subprocess.CompletedProcess(
                    arguments,
                    0 if status == 0 else 67,
                    f"OWNED_APPLEEVENT_PREFLIGHT/1 mode={mode.removeprefix('permission-')} osstatus={status}\n",
                    "",
                )
            if mode in ("success", "denied"):
                self.assertTrue(
                    not allow or confirmed,
                    "first mandatory send preceded normal consent prerequisite",
                )
                observations.append((mode, None))
            return original_run(arguments, **options)

        owner.run = run
        self.last_owner = owner
        self.last_observations = observations
        with (
            patch.object(probe.uuid, "uuid4", return_value=judge.nonce),
            patch.object(probe, "native_compiler", return_value=["modeled-native-clang"]),
        ):
            receipt = probe.admit_appleevent_boundary(owner, root)
        return owner, observations, receipt

    def test_fresh_owned_permission_precedes_first_positive_and_keeps_all_three_routes(self):
        with TemporaryDirectory() as directory:
            owner, observations, receipt = self.invoke(
                Path(directory).resolve(strict=True), (-1744, 0, 0)
            )
            self.assertEqual(
                observations,
                [
                    ("permission-query", -1744),
                    ("permission-request", 0),
                    ("permission-query", 0),
                    ("success", None),
                    ("success", None),
                    ("denied", None),
                ],
            )
            self.assertEqual(len(owner.sender_calls), 3)
            self.assertEqual(owner.deliveries, 2)
            self.assertTrue(receipt["receiver_retired"])
            self.assertEqual(receipt["denied_status"], -1743)
            self.assertEqual(
                receipt["permission_prerequisite"]["statuses"],
                [
                    {"mode": "query", "osstatus": -1744},
                    {"mode": "request", "osstatus": 0},
                    {"mode": "query", "osstatus": 0},
                ],
            )

    def test_refused_or_unconfirmed_permission_never_acquires_first_positive(self):
        for statuses in ((-1743,), (-1744, -1743), (-1744, -1744), (0, -1744)):
            with self.subTest(statuses=statuses), TemporaryDirectory() as directory:
                with self.assertRaises(probe.AppleEventBoundaryError) as refusal:
                    self.invoke(Path(directory).resolve(strict=True), statuses)
                self.assertIsInstance(refusal.exception.__cause__, probe.AdmissionError)
                self.assertEqual(self.last_owner.sender_calls, [])
                self.assertEqual(self.last_owner.deliveries, 0)
                self.assertEqual(len(self.last_owner.active), 1)
                self.assertFalse(self.last_owner.groups[self.last_owner.active[0]].reaped)

    def test_default_shared_image_never_requests_consent_and_keeps_original_routes(self):
        with TemporaryDirectory() as directory:
            owner, observations, receipt = self.invoke(
                Path(directory).resolve(strict=True), (), allow=False
            )
            self.assertEqual(observations, [("success", None), ("success", None), ("denied", None)])
            self.assertEqual(len(owner.sender_calls), 3)
            self.assertTrue(receipt["receiver_retired"])
            self.assertNotIn("permission_prerequisite", receipt)


class RefusedButtonSubroleFactControls(unittest.TestCase):
    """Receive fixed diagnostic enums on real private files, never native AX/TCC credit."""

    def packet(self, subrole="close", kind="string", error=0):
        packet = OwnedAutomationUIFactControls.packet()
        packet.update(first_attribute="button-title", first_error=-25205)
        packet["first_button"] = {"schema": 1, "subrole": subrole, "type": kind, "error": error}
        return packet

    def test_closed_subrole_evidence_preserves_original_unsupported_title_refusal(self):
        for subrole, kind, error in (
            ("close", "string", 0),
            ("minimize", "string", 0),
            ("zoom", "string", 0),
            ("unknown", "string", 0),
            ("absent", "absent", -25205),
            ("wrong-type", "number", 0),
        ):
            with self.subTest(subrole=subrole):
                packet = self.packet(subrole, kind, error)
                self.assertEqual(probe._validate_owned_automation_ui_fact(packet), packet)
                self.assertEqual(packet["first_attribute"], "button-title")
                self.assertEqual(packet["first_error"], -25205)

    def test_foreign_private_malformed_or_unbound_button_facts_are_refused(self):
        for replacement in (
            None,
            {"schema": True, "subrole": "close", "type": "string", "error": 0},
            {"schema": 1, "subrole": "private-description", "type": "string", "error": 0},
            {"schema": 1, "subrole": "close", "type": "string", "error": -25205},
            {"schema": 1, "subrole": "close", "type": "absent", "error": 0},
            {"schema": 1, "subrole": "close", "type": "string", "error": True},
            {"schema": 1, "subrole": "close", "type": "string", "error": 2**31},
            {"schema": 1, "subrole": "unknown", "type": "other", "error": 0},
            {"schema": 1, "subrole": "close", "type": "string", "error": 0, "accepted": True},
        ):
            with self.subTest(replacement=replacement), self.assertRaises(probe.AdmissionError):
                packet = self.packet()
                packet["first_button"] = replacement
                probe._validate_owned_automation_ui_fact(packet)
        for attribute in ("none", "windows", "button-enabled"):
            with self.subTest(attribute=attribute), self.assertRaises(probe.AdmissionError):
                packet = self.packet()
                packet["first_attribute"] = attribute
                probe._validate_owned_automation_ui_fact(packet)

    def test_real_owned_capture_exports_subrole_without_grant_or_retirement_credit(self):
        with TemporaryDirectory() as directory, patch.object(probe, "NativeProcessGroups"):
            root = Path(directory)
            evidence_dir = root / "evidence"
            evidence_dir.mkdir(mode=0o700)
            evidence = probe.PhaseEvidence(evidence_dir)
            owner = probe.Children(root, evidence=evidence)
            packet = self.packet()
            primary = subprocess.CompletedProcess(
                [], 67, "OWNED_AUTOMATION_UI/1 state=observation-refused\n", ""
            )

            def producer(arguments, **options):
                self.assertEqual(arguments[:-1], ["/owned/helper", "sender", "receiver", "73"])
                self.assertEqual(options, {"check": False, "timeout": 2})
                path = Path(arguments[-1])
                self.assertEqual(path.parent, root)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                path.write_text(json.dumps(packet))
                return primary

            owner.run = Mock(side_effect=producer)
            try:
                result = probe._owned_automation_ui_run(
                    owner, ["/owned/helper", "sender", "receiver", "73"], 2
                )
                self.assertIs(result, primary)
                self.assertEqual(result.returncode, 67)
                self.assertEqual(result.stdout, "OWNED_AUTOMATION_UI/1 state=observation-refused\n")
                receipt = json.loads((evidence_dir / "checkpoint.json").read_text())
                self.assertEqual(receipt["native_ui"], packet)
                self.assertEqual(receipt["status"], "refused")
                self.assertFalse(receipt["ownership_closed"])
                self.assertEqual(list(root.glob("automation-ui-fact-*")), [])
            finally:
                evidence.close()


class RefusedButtonWindowControlFactControls(unittest.TestCase):
    """Fixed same-window identity receipts are observations, never native AX consent."""

    def packet(self):
        packet = RefusedButtonSubroleFactControls().packet("absent", "absent", -25205)
        packet["first_button"]["window"] = {
            "schema": 1,
            "role": "window",
            "type": "string",
            "error": 0,
            "controls": {
                "close": {"type": "ax-element", "error": 0, "relation": "same"},
                "minimize": {"type": "ax-element", "error": 0, "relation": "different"},
                "zoom": {"type": "absent", "error": -25205, "relation": "unobserved"},
            },
        }
        return packet

    def test_closed_window_reference_facts_preserve_absent_subrole_and_primary_refusal(self):
        packet = self.packet()
        self.assertEqual(probe._validate_owned_automation_ui_fact(packet), packet)
        self.assertEqual(packet["first_error"], -25205)
        self.assertEqual(packet["first_button"]["subrole"], "absent")
        self.assertEqual(packet["candidates"], 0)
        self.assertEqual(packet["matches"], 0)
        for role, kind, error in (
            ("sheet", "string", 0),
            ("other", "string", 0),
            ("absent", "absent", -25205),
            ("wrong-type", "number", 0),
        ):
            with self.subTest(role=role):
                packet = self.packet()
                packet["first_button"]["window"].update(role=role, type=kind, error=error)
                self.assertEqual(probe._validate_owned_automation_ui_fact(packet), packet)

    def test_unobserved_or_foreign_reference_cannot_claim_same_native_button(self):
        for control in (
            {"type": "absent", "error": -25205, "relation": "same"},
            {"type": "string", "error": 0, "relation": "same"},
            {"type": "ax-element", "error": -25204, "relation": "same"},
            {"type": "ax-element", "error": 0, "relation": "unobserved"},
            {"type": "ax-element", "error": True, "relation": "same"},
            {"type": "ax-element", "error": 0, "relation": "private-title"},
            {"type": "ax-element", "error": 0, "relation": "same", "accepted": True},
        ):
            with self.subTest(control=control), self.assertRaises(probe.AdmissionError):
                packet = self.packet()
                packet["first_button"]["window"]["controls"]["close"] = control
                probe._validate_owned_automation_ui_fact(packet)
        for change in (
            "missing-control",
            "foreign-control",
            "wrong-role",
            "private-role",
            "boolean-status",
        ):
            with self.subTest(change=change), self.assertRaises(probe.AdmissionError):
                packet = self.packet()
                window = packet["first_button"]["window"]
                if change == "missing-control":
                    del window["controls"]["zoom"]
                elif change == "foreign-control":
                    window["controls"]["other"] = window["controls"]["close"]
                elif change == "wrong-role":
                    window["role"] = "wrong-type"
                elif change == "private-role":
                    window["role"] = "private-window-role"
                else:
                    window["error"] = True
                probe._validate_owned_automation_ui_fact(packet)

    def test_real_private_window_receipt_cannot_authorize_action_or_closure(self):
        with TemporaryDirectory() as directory, patch.object(probe, "NativeProcessGroups"):
            root = Path(directory)
            evidence_dir = root / "evidence"
            evidence_dir.mkdir(mode=0o700)
            evidence = probe.PhaseEvidence(evidence_dir)
            owner = probe.Children(root, evidence=evidence)
            packet = self.packet()
            primary = subprocess.CompletedProcess(
                [], 67, "OWNED_AUTOMATION_UI/1 state=observation-refused\n", ""
            )

            def producer(arguments, **options):
                self.assertEqual(arguments[:-1], ["/owned/helper", "sender", "receiver", "73"])
                self.assertEqual(options, {"check": False, "timeout": 2})
                path = Path(arguments[-1])
                self.assertEqual(path.parent, root)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                path.write_text(json.dumps(packet))
                return primary

            owner.run = Mock(side_effect=producer)
            try:
                result = probe._owned_automation_ui_run(
                    owner, ["/owned/helper", "sender", "receiver", "73"], 2
                )
                self.assertIs(result, primary)
                self.assertEqual(result.returncode, 67)
                receipt = json.loads((evidence_dir / "checkpoint.json").read_text())
                self.assertEqual(receipt["native_ui"], packet)
                self.assertEqual(receipt["status"], "refused")
                self.assertFalse(receipt["ownership_closed"])
                self.assertEqual(list(root.glob("automation-ui-fact-*")), [])
            finally:
                evidence.close()


class RefusedButtonLabelFactControls(unittest.TestCase):
    """Closed labels are observations; no localized string or consent authority crosses the frame."""

    def packet(self):
        packet = RefusedButtonWindowControlFactControls().packet()
        packet["first_button"]["labels"] = {
            "description": {"type": "string", "error": 0, "family": "close"},
            "value": {"type": "absent", "error": -25205, "family": "absent"},
        }
        return packet

    def test_closed_label_families_retain_original_title_refusal(self):
        for family in ("allow", "deny", "close", "minimize", "zoom", "other"):
            with self.subTest(family=family):
                packet = self.packet()
                packet["first_button"]["labels"]["description"]["family"] = family
                self.assertEqual(probe._validate_owned_automation_ui_fact(packet), packet)
                self.assertEqual(packet["first_attribute"], "button-title")
                self.assertEqual(packet["first_error"], -25205)
                self.assertEqual(packet["candidates"], 0)
                self.assertEqual(packet["matches"], 0)
        packet = self.packet()
        packet["first_button"]["labels"]["value"] = {
            "type": "number",
            "error": 0,
            "family": "wrong-type",
        }
        self.assertEqual(probe._validate_owned_automation_ui_fact(packet), packet)

    def test_failed_private_or_malformed_labels_cannot_claim_observation(self):
        for replacement in (
            {"type": "absent", "error": -25205, "family": "allow"},
            {"type": "string", "error": -25204, "family": "close"},
            {"type": "number", "error": 0, "family": "close"},
            {"type": "string", "error": True, "family": "close"},
            {"type": "string", "error": 2**31, "family": "close"},
            {"type": "string", "error": 0, "family": "private-description"},
            {"type": "string", "error": 0, "family": "close", "accepted": True},
        ):
            with self.subTest(replacement=replacement), self.assertRaises(probe.AdmissionError):
                packet = self.packet()
                packet["first_button"]["labels"]["description"] = replacement
                probe._validate_owned_automation_ui_fact(packet)
        for labels in (
            None,
            {},
            {"description": {"type": "string", "error": 0, "family": "close"}},
            {"description": {}, "value": {}, "title": {}},
        ):
            with self.subTest(labels=labels), self.assertRaises(probe.AdmissionError):
                packet = self.packet()
                packet["first_button"]["labels"] = labels
                probe._validate_owned_automation_ui_fact(packet)

    def test_real_private_label_receipt_never_admits_consent_or_closure(self):
        with TemporaryDirectory() as directory, patch.object(probe, "NativeProcessGroups"):
            root = Path(directory)
            evidence_dir = root / "evidence"
            evidence_dir.mkdir(mode=0o700)
            evidence = probe.PhaseEvidence(evidence_dir)
            owner = probe.Children(root, evidence=evidence)
            packet = self.packet()
            primary = subprocess.CompletedProcess(
                [], 67, "OWNED_AUTOMATION_UI/1 state=observation-refused\n", ""
            )

            def producer(arguments, **options):
                self.assertEqual(arguments[:-1], ["/owned/helper", "sender", "receiver", "73"])
                self.assertEqual(options, {"check": False, "timeout": 2})
                path = Path(arguments[-1])
                self.assertEqual(path.parent, root)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                path.write_text(json.dumps(packet))
                return primary

            owner.run = Mock(side_effect=producer)
            try:
                result = probe._owned_automation_ui_run(
                    owner, ["/owned/helper", "sender", "receiver", "73"], 2
                )
                self.assertIs(result, primary)
                self.assertEqual(result.returncode, 67)
                receipt = json.loads((evidence_dir / "checkpoint.json").read_text())
                self.assertEqual(receipt["native_ui"], packet)
                self.assertEqual(receipt["status"], "refused")
                self.assertFalse(receipt["ownership_closed"])
                self.assertEqual(list(root.glob("automation-ui-fact-*")), [])
            finally:
                evidence.close()


class ForegroundRequestRefusalControls(unittest.TestCase):
    """A normal activation refusal is not a permission status or a grant."""

    def invoke(self, root, frame, *, code=65, stdout="", mode="request"):
        executable = root / "owned-sender"
        executable.write_bytes(b"independent acquired image")
        policy = root / "owned-policy.sb"
        policy.write_text("(version 1)\n(deny default)\n")
        owner = SimpleNamespace(allow_automation_consent=True, allow_owned_consent_ui=False)
        calls = []

        def run(arguments, **options):
            self.assertEqual(options, {"check": False, "timeout": 30})
            calls.append(arguments[-1])
            if mode == "request" and len(calls) == 1:
                return subprocess.CompletedProcess(
                    arguments, 67, "OWNED_APPLEEVENT_PREFLIGHT/1 mode=query osstatus=-1744\n", ""
                )
            return subprocess.CompletedProcess(arguments, code, stdout, frame)

        owner.run = run
        try:
            probe.admit_appleevent_permission_prerequisite(
                owner, [str(executable), "73136", "independent-nonce"], policy, lambda phase: None
            )
        finally:
            self.calls = calls

    def test_exact_owned_request_foreground_refusal_never_reaches_fresh_grant_query(self):
        for state in ("unavailable", "inactive"):
            with self.subTest(state=state), TemporaryDirectory() as directory:
                with self.assertRaisesRegex(
                    probe.AdmissionError, "foreground precondition refused: " + state
                ):
                    self.invoke(
                        Path(directory), "OWNED_APPLEEVENT_FOREGROUND/1 state=" + state + "\n"
                    )
                self.assertEqual(self.calls, ["permission-query", "permission-request"])

    def test_foreign_mode_exit_or_dirty_frame_has_no_foreground_or_permission_credit(self):
        for mode, code, stdout, frame in (
            ("query", 65, "", "OWNED_APPLEEVENT_FOREGROUND/1 state=inactive\n"),
            ("request", 0, "", "OWNED_APPLEEVENT_FOREGROUND/1 state=inactive\n"),
            ("request", 65, "PRIVATE", "OWNED_APPLEEVENT_FOREGROUND/1 state=inactive\n"),
            ("request", 65, "", "OWNED_APPLEEVENT_FOREGROUND/1 state=private-label\n"),
            ("request", 65, "", "OWNED_APPLEEVENT_FOREGROUND/1 state=inactive\nPRIVATE\n"),
        ):
            with self.subTest(mode=mode, code=code, frame=frame), TemporaryDirectory() as directory:
                with self.assertRaisesRegex(
                    probe.AdmissionError, "Malformed owned Automation receipt"
                ):
                    self.invoke(Path(directory), frame, mode=mode, code=code, stdout=stdout)
                self.assertEqual(len(self.calls), 1 if mode == "query" else 2)


class CanonicalPermissionFixtureRootControls(unittest.TestCase):
    """Keep modeled permission expectations on the same physical fixture root."""

    def test_all_permission_fixture_root_acquisitions_are_physical(self):
        acquisitions = 0
        for cls in (AutomationPrerequisiteControls, FirstPositiveAutomationPrerequisiteControls):
            tree = ast.parse(textwrap.dedent(inspect.getsource(cls)))
            parents = {
                child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)
            }
            for node in ast.walk(tree):
                if not (
                    isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Name)
                    and node.func.id == "Path"
                    and len(node.args) == 1
                    and isinstance(node.args[0], ast.Name)
                    and node.args[0].id == "directory"
                ):
                    continue
                resolver = parents.get(node)
                self.assertIsInstance(resolver, ast.Attribute)
                self.assertEqual(resolver.attr, "resolve")
                call = parents.get(resolver)
                self.assertIsInstance(call, ast.Call)
                self.assertEqual(call.args, [])
                self.assertEqual(
                    [(kw.arg, ast.dump(kw.value)) for kw in call.keywords],
                    [("strict", "Constant(value=True)")],
                )
                acquisitions += 1
        self.assertEqual(
            acquisitions, 13, "every original permission fixture acquisition must remain"
        )


class ForegroundOriginalDeadlineControls(unittest.TestCase):
    """Portable exact owner calls; the child port is explicit, not macOS credit."""

    def owner(self, root):
        with (
            patch.object(probe, "NativeProcessGroups"),
            patch.object(probe.os, "getuid", return_value=501, create=True),
        ):
            return probe.Children(root)

    def physical_port(self, owner, *, acquired=None):
        observed = {}

        def acquire(arguments, native, register, **options):
            observed["arguments"] = tuple(arguments)
            observed["environment"] = options["env"]
            process = subprocess.Popen(
                [probe.sys.executable, "-I", "-B", "-c", "import time; time.sleep(0.05)"],
                **options,
            )
            observed["process"] = process
            group = SimpleNamespace(process=process, reaped=False)

            def wait(timeout):
                observed["wait"] = timeout
                process.wait(timeout=timeout)

            def settle():
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)
                group.reaped = True
                return True

            group.wait_for_exit, group.settle = wait, settle
            observed["group"] = group
            register(group)
            if acquired is not None:
                acquired()
            return group

        return observed, acquire

    def test_expired_request_refuses_before_native_child_or_capture_allocation(self):
        with TemporaryDirectory() as directory:
            owner = self.owner(Path(directory))
            with patch.object(probe.time, "monotonic_ns", return_value=1_000_000_000):
                command = probe.OwnedAutomationRequest(["owned", "permission-request"], 30)
            with (
                patch.object(probe.time, "monotonic_ns", return_value=31_000_000_000),
                patch.object(owner, "start") as start,
            ):
                with self.assertRaisesRegex(probe.AdmissionError, "exceeded deadline"):
                    owner.run(command, timeout=30)
                start.assert_not_called()
            self.assertEqual(owner.sequence, 0)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_mutated_argv_or_changed_budget_never_acquires_a_child(self):
        with TemporaryDirectory() as directory:
            owner = self.owner(Path(directory))
            for fault in ("argv", "budget"):
                with (
                    self.subTest(fault=fault),
                    patch.object(probe.time, "monotonic_ns", return_value=1_000_000_000),
                ):
                    command = probe.OwnedAutomationRequest(["owned", "permission-request"], 30)
                    if fault == "argv":
                        command.append("foreign")
                    with patch.object(owner, "start") as start:
                        with self.assertRaises(probe.AdmissionError):
                            owner.run(command, timeout=31 if fault == "budget" else 30)
                        start.assert_not_called()

    def test_expired_ui_callback_physically_retires_actual_child_without_late_permission_credit(
        self,
    ):
        with TemporaryDirectory() as directory:
            owner = self.owner(Path(directory))
            clock = [1_000_000_000]
            with patch.object(probe.time, "monotonic_ns", side_effect=lambda: clock[0]):
                command = probe.OwnedAutomationRequest(["owned", "permission-request"], 30)
                with self.assertRaises(AttributeError):
                    command.deadline_ns = 61_000_000_000
                with self.assertRaises(AttributeError):
                    command.timeout = 60
                observed, acquire = self.physical_port(owner)

                def callback(process, deadline):
                    self.assertIs(process, observed["process"])
                    self.assertEqual(deadline, 31)
                    process.wait(timeout=5)
                    clock[0] = 31_000_000_000

                with patch.object(probe, "acquire_owned", side_effect=acquire):
                    with self.assertRaisesRegex(probe.AdmissionError, "exceeded deadline"):
                        owner.run(command, timeout=30, after_start=callback)
            self.assertNotIn("wait", observed)
            self.assertTrue(observed["group"].reaped)
            self.assertIsNotNone(observed["process"].returncode)
            self.assertEqual(owner.active, [])
            self.assertEqual(owner.debt, [])

    def test_clock_invalidity_or_regression_refuses_before_child(self):
        for invalid in (True, -1, "clock", None):
            with (
                self.subTest(invalid=invalid),
                patch.object(probe.time, "monotonic_ns", return_value=invalid),
            ):
                with self.assertRaisesRegex(probe.AdmissionError, "clock unavailable"):
                    probe.OwnedAutomationRequest(["owned", "permission-request"], 30)
        with patch.object(probe.time, "monotonic_ns", side_effect=(2, 1)):
            command = probe.OwnedAutomationRequest(["owned", "permission-request"], 30)
            with self.assertRaisesRegex(probe.AdmissionError, "clock unavailable"):
                command.remaining()

    def test_actual_child_environment_is_private_and_start_ui_wait_share_original_deadline(self):
        with TemporaryDirectory() as directory:
            owner = self.owner(Path(directory))
            original = owner.environment.copy()
            clock = [1_000_000_000]
            with patch.object(probe.time, "monotonic_ns", side_effect=lambda: clock[0]):
                command = probe.OwnedAutomationRequest(["owned", "permission-request"], 30)
                clock[0] = 6_000_000_000
                observed, acquire = self.physical_port(
                    owner, acquired=lambda: clock.__setitem__(0, 21_000_000_000)
                )

                def callback(process, deadline):
                    self.assertIs(process, observed["process"])
                    self.assertEqual(deadline, 31)
                    clock[0] = 26_000_000_000

                with patch.object(probe, "acquire_owned", side_effect=acquire):
                    result = owner.run(command, timeout=30, after_start=callback)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(observed["wait"], 5)
            self.assertEqual(observed["arguments"], ("owned", "permission-request"))
            self.assertEqual(
                observed["environment"],
                {**original, "ERGOPTI_OWNED_AUTOMATION_DEADLINE_NS": "31000000000"},
            )
            self.assertEqual(owner.environment, original)
            self.assertEqual(owner.active, [])
            self.assertTrue(observed["group"].reaped)
            self.assertEqual(observed["process"].returncode, 0)

    def test_clock_failure_after_actual_acquisition_keeps_primary_and_retires_same_child(self):
        with TemporaryDirectory() as directory:
            owner = self.owner(Path(directory))
            failure = RuntimeError("independent clock refused after real acquire")
            acquired = [False]

            def clock():
                if acquired[0]:
                    raise failure
                return 1_000_000_000

            with patch.object(probe.time, "monotonic_ns", side_effect=clock):
                command = probe.OwnedAutomationRequest(["owned", "permission-request"], 30)
                observed, acquire = self.physical_port(
                    owner, acquired=lambda: acquired.__setitem__(0, True)
                )
                callback = Mock()
                with patch.object(probe, "acquire_owned", side_effect=acquire):
                    with self.assertRaises(RuntimeError) as caught:
                        owner.run(command, timeout=30, after_start=callback)
            self.assertIs(caught.exception, failure)
            callback.assert_not_called()
            self.assertNotIn("wait", observed)
            self.assertTrue(observed["group"].reaped)
            self.assertIsNotNone(observed["process"].returncode)
            self.assertEqual(owner.active, [])
            self.assertEqual(owner.debt, [])

    def test_request_deadline_is_captured_before_checkpoint_without_changing_original_argv_options(
        self,
    ):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            sender, policy = root / "sender", root / "policy"
            sender.write_bytes(b"source-bound original sender")
            policy.write_bytes(b"source-bound original policy")
            owner = SimpleNamespace(allow_automation_consent=True, allow_owned_consent_ui=False)
            clock = [1_000_000_000]
            calls = []

            def checkpoint(phase):
                if phase == "before-automation-request":
                    clock[0] = 6_000_000_000

            def run(arguments, **options):
                self.assertEqual(options, {"check": False, "timeout": 30})
                mode = arguments[-1]
                self.assertEqual(
                    arguments[:6],
                    ["/usr/bin/sandbox-exec", "-f", str(policy), str(sender), "73136", "nonce"],
                )
                calls.append(mode)
                if mode == "permission-request":
                    self.assertIs(type(arguments), probe.OwnedAutomationRequest)
                    self.assertEqual(arguments.deadline_ns, 31_000_000_000)
                    self.assertEqual(arguments.remaining(), 25)
                else:
                    self.assertIs(type(arguments), list)
                status = -1744 if len(calls) == 1 else 0
                label = mode.removeprefix("permission-")
                return subprocess.CompletedProcess(
                    arguments,
                    67 if status else 0,
                    f"OWNED_APPLEEVENT_PREFLIGHT/1 mode={label} osstatus={status}\n",
                    "",
                )

            owner.run = run
            with patch.object(probe.time, "monotonic_ns", side_effect=lambda: clock[0]):
                receipt = probe.admit_appleevent_permission_prerequisite(
                    owner, [str(sender), "73136", "nonce"], policy, checkpoint
                )
            self.assertEqual(calls, ["permission-query", "permission-request", "permission-query"])
            self.assertEqual([entry["osstatus"] for entry in receipt["statuses"]], [-1744, 0, 0])

    def test_native_request_pump_uses_original_public_deadline_and_same_app_only(self):
        source = Path(probe.__file__).with_name("native_appleevent_probe_sender.c").read_text()
        start = source.index("static int admit_sender_foreground_request(")
        body = source[start : source.index("/* A separate closed metadata frame", start)]
        self.assertIn("foreground_deadline_ns(&deadline)", body)
        self.assertIn("now < previous || now >= deadline", body)
        self.assertIn("now >= previous && now < deadline ? 0 : 2", body)
        self.assertIn("[application finishLaunching]", body)
        self.assertIn("NSApplicationActivationPolicyAccessory", body)
        self.assertIn("remaining < 0.05 ? remaining : 0.05", body)
        self.assertIn("nextEventMatchingMask:NSEventMaskAny", body)
        self.assertIn("inMode:NSDefaultRunLoopMode dequeue:YES", body)
        self.assertIn("if (event != nil) [application sendEvent:event]", body)
        self.assertNotIn("owned_appleevent_permission", body)
        self.assertNotIn("NSApplicationActivationPolicyRegular", body)
        self.assertNotIn("sleep(", body)


class PassiveWindowIdentityControls(unittest.TestCase):
    """Closed portable facts; these controls never claim native AX traversal."""

    @staticmethod
    def packet():
        packet = RefusedButtonLabelFactControls().packet()
        packet["identity"] = {
            "schema": 1,
            "sender": True,
            "receiver": False,
            "complete": True,
            "nodes": 8,
            "refusal": "none",
            "error": 0,
        }
        return packet

    def test_complete_and_partial_scalar_observations_preserve_original_refusal(self):
        for sender, receiver in ((False, False), (True, False), (False, True), (True, True)):
            packet = self.packet()
            packet["identity"].update(sender=sender, receiver=receiver)
            self.assertEqual(probe._validate_owned_automation_ui_fact(packet), packet)
            self.assertEqual(packet["candidates"], 0)
            self.assertEqual(packet["matches"], 0)
            self.assertEqual(packet["first_error"], -25205)
        for refusal in (
            "deadline",
            "timeout",
            "node-limit",
            "node-type",
            "role",
            "value",
            "children",
        ):
            packet = self.packet()
            packet["identity"].update(complete=False, refusal=refusal, error=-25212)
            self.assertEqual(probe._validate_owned_automation_ui_fact(packet), packet)

    def test_unadmitted_text_and_wrong_scalar_or_completion_cannot_enter_evidence(self):
        for key, value in (
            ("schema", True),
            ("sender", 1),
            ("receiver", "private receiver"),
            ("complete", 1),
            ("nodes", True),
            ("nodes", 257),
            ("nodes", -1),
            ("error", True),
            ("error", 2**31),
            ("refusal", "private UI title"),
            ("refusal", "deadline"),
            ("complete", False),
            ("nodes", 0),
        ):
            packet = self.packet()
            packet["identity"][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(probe.AdmissionError):
                probe._validate_owned_automation_ui_fact(packet)
        for change in ("extra", "missing", "different-primary", "missing-button"):
            packet = self.packet()
            if change == "extra":
                packet["identity"]["title"] = "private"
            elif change == "missing":
                del packet["identity"]["sender"]
            elif change == "different-primary":
                packet["first_error"] = -25212
            else:
                del packet["first_button"]
            with self.subTest(change=change), self.assertRaises(probe.AdmissionError):
                probe._validate_owned_automation_ui_fact(packet)

    def test_real_private_capture_keeps_primary_refusal_even_when_both_names_observed(self):
        with TemporaryDirectory() as directory, patch.object(probe, "NativeProcessGroups"):
            root = Path(directory)
            evidence_dir = root / "evidence"
            evidence_dir.mkdir(mode=0o700)
            evidence = probe.PhaseEvidence(evidence_dir)
            owner = probe.Children(root, evidence=evidence)
            packet = self.packet()
            packet["identity"]["receiver"] = True
            primary = subprocess.CompletedProcess(
                [], 67, "OWNED_AUTOMATION_UI/1 state=observation-refused\n", ""
            )

            def producer(arguments, **options):
                self.assertEqual(options, {"check": False, "timeout": 2})
                Path(arguments[-1]).write_text(json.dumps(packet, separators=(",", ":")))
                return primary

            owner.run = Mock(side_effect=producer)
            try:
                self.assertIs(
                    probe._owned_automation_ui_run(
                        owner, ["helper", "sender", "receiver", "73"], 2
                    ),
                    primary,
                )
                receipt = json.loads((evidence_dir / "checkpoint.json").read_text())
                self.assertEqual(receipt["native_ui"], packet)
                self.assertEqual(receipt["status"], "refused")
                self.assertFalse(receipt["ownership_closed"])
                self.assertEqual(list(root.glob("automation-ui-fact-*")), [])
            finally:
                evidence.close()

    def test_legacy_projection_without_optional_identity_remains_exact(self):
        packet = self.packet()
        del packet["identity"]
        self.assertEqual(probe._validate_owned_automation_ui_fact(packet), packet)
        self.assertLess(len(json.dumps(self.packet(), separators=(",", ":")).encode()), 1024)


class AutomationStartupReadinessControls(unittest.TestCase):
    """Private filesystem/explicit child-port controls; none grant macOS signed identity."""

    NONCE = "11111111-2222-3333-4444-555555555555"

    @contextmanager
    def fixture(self):
        with TemporaryDirectory() as directory, patch.object(probe, "NativeProcessGroups"):
            owner = probe.Children(Path(directory))
            clock = [1_000_000_000]
            with patch.object(probe.time, "monotonic_ns", side_effect=lambda: clock[0]):
                request = probe.OwnedAutomationRequest(["owned", "permission-request"], 30)
                request.readiness_nonce = self.NONCE
                ready = probe.OwnedAutomationReadiness(owner, request)
                process = Mock(pid=73136, returncode=None)
                group = SimpleNamespace(
                    process=process, reaped=False, observe_exit=Mock(return_value=None)
                )
                owner.groups[process] = group
                try:
                    yield owner, request, ready, process, group, clock
                finally:
                    ready.close()

    def bytes(self, process):
        return (
            b"OWNED_APPLEEVENT_READY/1 pid="
            + str(process.pid).encode()
            + b" nonce=11111111-2222-3333-4444-555555555555\n"
        )

    def test_observer_cannot_run_during_launcher_or_partial_sender_acknowledgement(self):
        with self.fixture() as (owner, request, ready, process, group, clock):
            observations = []

            def advance(seconds):
                observations.append(ready.accepted)
                self.assertLessEqual(seconds, 0.02)
                ready.path.write_bytes(
                    self.bytes(process)[:17] if len(observations) == 1 else self.bytes(process)
                )
                clock[0] += 10_000_000

            with patch.object(probe.time, "sleep", side_effect=advance):
                self.assertTrue(ready.wait(process))
            self.assertEqual(observations, [False, False])
            self.assertTrue(ready.accepted)
            self.assertEqual(request.deadline_ns, 31_000_000_000)
            self.assertEqual(request.remaining(), 29.98)
            self.assertFalse(group.reaped)

    def test_forged_pid_nonce_or_extra_bytes_never_admit_startup(self):
        for payload in (
            b"OWNED_APPLEEVENT_READY/1 pid=73 nonce=11111111-2222-3333-4444-555555555555\n",
            b"OWNED_APPLEEVENT_READY/1 pid=73136 nonce=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n",
            b"OWNED_APPLEEVENT_READY/1 pid=73136 nonce=11111111-2222-3333-4444-555555555555\nextra",
            b"private arbitrary bytes",
        ):
            with self.subTest(payload=payload), self.fixture() as (_, _, ready, process, _, _):
                ready.path.write_bytes(payload)
                with self.assertRaises(probe.AdmissionError):
                    ready.wait(process)
                self.assertFalse(ready.accepted)

    def test_truncated_acknowledgement_exhausts_only_original_deadline(self):
        with self.fixture() as (_, request, ready, process, _, clock):
            ready.path.write_bytes(self.bytes(process)[:-1])

            def expire(seconds):
                clock[0] = request.deadline_ns

            with patch.object(probe.time, "sleep", side_effect=expire):
                with self.assertRaisesRegex(probe.AdmissionError, "exceeded deadline"):
                    ready.wait(process)
            self.assertEqual(request.deadline_ns, 31_000_000_000)
            self.assertFalse(ready.accepted)

    def test_replaced_or_symlinked_name_refuses_and_preserves_foreign_inode(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink), self.fixture() as (owner, _, ready, process, _, _):
                replacement = owner.root / "independent-replacement"
                replacement.write_bytes(self.bytes(process))
                replacement.chmod(0o600)
                ready.path.unlink()
                if symlink:
                    ready.path.symlink_to(replacement)
                else:
                    replacement.rename(ready.path)
                foreign = ready.path.lstat()
                with self.assertRaisesRegex(probe.AdmissionError, "identity or bound"):
                    ready.wait(process)
                ready.close()
                self.assertEqual(ready.path.lstat().st_ino, foreign.st_ino)
                self.assertEqual(
                    owner.debt, [{"kind": "automation-readiness", "path": str(ready.path)}]
                )

    def test_hardlink_or_changed_permissions_never_admit_or_retire_ambiguous_input(self):
        for fault in ("hardlink", "mode"):
            with self.subTest(fault=fault), self.fixture() as (owner, _, ready, process, _, _):
                ready.path.write_bytes(self.bytes(process))
                if fault == "hardlink":
                    os.link(ready.path, owner.root / "independent-link")
                else:
                    ready.path.chmod(0o644)
                with self.assertRaisesRegex(probe.AdmissionError, "identity or bound"):
                    ready.wait(process)
                ready.close()
                self.assertTrue(ready.path.exists())
                self.assertEqual(len(owner.debt), 1)

    def test_terminal_requester_before_ack_never_arms_ui_or_borrows_readiness(self):
        with self.fixture() as (_, _, ready, process, group, _):
            group.observe_exit.return_value = SimpleNamespace(si_status=65)
            self.assertFalse(ready.wait(process))
            self.assertFalse(ready.accepted)

    def test_complete_ack_and_terminal_requester_admit_no_ui_action(self):
        with self.fixture() as (_, _, ready, process, group, _):
            ready.path.write_bytes(self.bytes(process))
            group.observe_exit.return_value = SimpleNamespace(si_status=0)
            self.assertFalse(ready.wait(process))
            self.assertTrue(ready.accepted)

    def test_lost_reservation_or_expired_original_clock_never_reads_ready_credit(self):
        for fault in ("reservation", "reaped", "expired", "regressed"):
            with (
                self.subTest(fault=fault),
                self.fixture() as (owner, request, ready, process, group, clock),
            ):
                ready.path.write_bytes(self.bytes(process))
                if fault == "reservation":
                    owner.groups = {}
                elif fault == "reaped":
                    group.reaped = True
                else:
                    clock[0] = request.deadline_ns if fault == "expired" else 0
                with self.assertRaises(probe.AdmissionError):
                    ready.wait(process)
                self.assertFalse(ready.accepted)

    def test_unlink_refusal_and_live_child_keep_owned_cleanup_debt(self):
        for fault in ("unlink", "live"):
            with self.subTest(fault=fault), self.fixture() as (owner, _, ready, _, _, _):
                if fault == "unlink":
                    with patch.object(probe.os, "unlink", side_effect=OSError("private refusal")):
                        ready.close()
                else:
                    ready.close(retire=False)
                self.assertTrue(ready.path.exists())
                self.assertEqual(
                    owner.debt, [{"kind": "automation-readiness", "path": str(ready.path)}]
                )

    def run_port(self, root, *, code=0, acknowledge=True, callback=None):
        """Model the reserved process port while exercising the real parent owner and files."""
        owner = probe.Children(root)
        request = probe.OwnedAutomationRequest(["owned", "permission-request"], 30)
        request.readiness_nonce = self.NONCE
        observations = {}

        def acquire(arguments, native, register, **options):
            process = Mock(pid=73136, returncode=None)
            group = SimpleNamespace(
                process=process, reaped=False, observe_exit=Mock(return_value=None)
            )
            observations.update(process=process, group=group, environment=options["env"])

            def wait(timeout):
                process.returncode = code

            def settle():
                process.returncode = code
                group.reaped = True
                return True

            group.wait_for_exit, group.settle = wait, settle
            register(group)
            os.write(
                options["stdout"].fileno(),
                b"OWNED_APPLEEVENT_PREFLIGHT/1 mode=request osstatus=0\n" if code == 0 else b"",
            )
            os.write(
                options["stderr"].fileno(),
                b"" if code == 0 else b"OWNED_APPLEEVENT_FOREGROUND/1 state=inactive\n",
            )
            if acknowledge:
                request.readiness.path.write_bytes(self.bytes(process))
            else:
                group.observe_exit.return_value = SimpleNamespace(si_status=code)
            return group

        after_start = Mock() if callback is None else callback
        observations["callback"] = after_start
        with patch.object(probe, "acquire_owned", side_effect=acquire):
            result = owner.run(request, timeout=30, check=False, after_start=after_start)
        return owner, result, observations

    def test_real_parent_awaits_ack_without_changing_native_receipts_or_budget(self):
        with TemporaryDirectory() as directory, patch.object(probe, "NativeProcessGroups"):
            root = Path(directory)
            owner, result, observed = self.run_port(root)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(
                result.stdout, "OWNED_APPLEEVENT_PREFLIGHT/1 mode=request osstatus=0\n"
            )
            self.assertEqual(result.stderr, "")
            observed["callback"].assert_called_once()
            self.assertIs(observed["callback"].call_args.args[0], observed["process"])
            self.assertTrue(observed["group"].reaped)
            self.assertEqual(owner.active, [])
            self.assertEqual(owner.debt, [])
            self.assertEqual(list(root.glob("automation-ready-*")), [])
            self.assertNotIn("ERGOPTI_OWNED_AUTOMATION_READY_NAME", owner.environment)
            self.assertEqual(
                set(observed["environment"]) - set(owner.environment),
                {
                    "ERGOPTI_OWNED_AUTOMATION_DEADLINE_NS",
                    "ERGOPTI_OWNED_AUTOMATION_READY_NAME",
                    "ERGOPTI_OWNED_AUTOMATION_READY_DEV",
                    "ERGOPTI_OWNED_AUTOMATION_READY_INO",
                },
            )

    def test_pre_ready_native_refusal_retains_original_foreground_capture(self):
        with TemporaryDirectory() as directory, patch.object(probe, "NativeProcessGroups"):
            owner, result, observed = self.run_port(Path(directory), code=65, acknowledge=False)
            self.assertEqual(result.returncode, 65)
            self.assertEqual(result.stdout, "")
            self.assertEqual(result.stderr, "OWNED_APPLEEVENT_FOREGROUND/1 state=inactive\n")
            observed["callback"].assert_not_called()
            self.assertTrue(observed["group"].reaped)
            self.assertEqual(owner.debt, [])

    def test_zero_exit_without_acknowledgement_cannot_pass_original_owner(self):
        with TemporaryDirectory() as directory, patch.object(probe, "NativeProcessGroups"):
            with self.assertRaisesRegex(probe.AdmissionError, "without readiness acknowledgement"):
                self.run_port(Path(directory), acknowledge=False)
            self.assertEqual(list(Path(directory).glob("automation-ready-*")), [])

    def test_callback_failure_physically_settles_request_before_private_input_retirement(self):
        with TemporaryDirectory() as directory, patch.object(probe, "NativeProcessGroups"):
            root = Path(directory)
            refusal = probe.AdmissionError("independent original identity refusal")

            def callback(process, deadline):
                self.assertEqual(len(list(root.glob("automation-ready-*"))), 1)
                raise refusal

            with self.assertRaises(probe.AdmissionError) as caught:
                self.run_port(root, callback=callback)
            self.assertIs(caught.exception, refusal)
            self.assertEqual(list(root.glob("automation-ready-*")), [])

    def test_native_ack_is_after_foreground_before_permission_without_receipt_changes(self):
        source = Path(probe.__file__).with_name("native_appleevent_probe_sender.c").read_text()
        start = source.index(
            'if (strcmp(argv[3], "permission-request") == 0) {', source.index("int main(")
        )
        caller = source[
            start : source.index("const int outcome = owned_appleevent_permission", start)
        ]
        self.assertLess(
            caller.index("admit_sender_foreground_request(application)"),
            caller.index("acknowledge_sender_readiness(argv[2])"),
        )
        body_start = source.index("static int acknowledge_sender_readiness(")
        body = source[body_start : source.index("\nstatic ", body_start + 10)]
        self.assertNotIn("printf(", body.replace("snprintf(", "packing("))
        self.assertNotIn("fprintf(", body)
        self.assertIn("O_NOFOLLOW", body)
        self.assertIn("before.st_nlink != 1", body)
        self.assertIn("before.st_size != 0", body)
        self.assertIn("(uintmax_t)before.st_dev != device", body)
        self.assertIn("(uintmax_t)before.st_ino != inode", body)
        self.assertIn("fsync(descriptor)", body)

    def test_close_refusal_before_syscall_retains_live_fd_and_path_without_retry(self):
        with self.fixture() as (owner, _, ready, _, _, _):
            close = os.close
            try:
                with patch.object(
                    probe.os, "close", side_effect=OSError("independent pre-close refusal")
                ) as attempted:
                    ready.close()
                    ready.close()
                attempted.assert_called_once_with(ready.descriptor)
                self.assertFalse(ready.closed)
                self.assertTrue(ready.close_attempted)
                self.assertTrue(ready.close_uncertain)
                self.assertEqual(os.fstat(ready.descriptor).st_ino, ready.identity.st_ino)
                self.assertTrue(ready.path.exists())
                self.assertEqual(
                    owner.debt,
                    [
                        {
                            "kind": "automation-readiness",
                            "path": str(ready.path),
                            "descriptor": ready.descriptor,
                            "descriptor_close": "unacknowledged",
                        }
                    ],
                )
            finally:
                # The explicit test port proves this FD never reached close().
                close(ready.descriptor)

    def test_constructor_fstat_and_close_refusal_keep_exact_acquisition_debt(self):
        with TemporaryDirectory() as directory, patch.object(probe, "NativeProcessGroups"):
            owner = probe.Children(Path(directory))
            request = probe.OwnedAutomationRequest(["owned", "permission-request"], 30)
            request.readiness_nonce = self.NONCE
            acquired = []
            open_file, close = os.open, os.close

            def allocate(*args, **options):
                descriptor = open_file(*args, **options)
                acquired.append(descriptor)
                return descriptor

            try:
                with (
                    patch.object(probe.os, "open", side_effect=allocate),
                    patch.object(
                        probe.os, "fstat", side_effect=OSError("independent identity refusal")
                    ),
                    patch.object(
                        probe.os, "close", side_effect=OSError("independent close refusal")
                    ) as attempted,
                ):
                    with self.assertRaisesRegex(OSError, "identity refusal"):
                        probe.OwnedAutomationReadiness(owner, request)
                self.assertEqual(len(acquired), 1)
                attempted.assert_called_once_with(acquired[0])
                self.assertEqual(len(owner.debt), 1)
                debt = owner.debt[0]
                self.assertEqual(debt["descriptor"], acquired[0])
                self.assertEqual(debt["descriptor_close"], "unacknowledged")
                self.assertEqual(os.fstat(acquired[0]).st_ino, Path(debt["path"]).stat().st_ino)
            finally:
                for descriptor in acquired:
                    close(descriptor)

    def test_close_error_after_syscall_never_closes_reused_foreign_fd_or_unlinks_input(self):
        with self.fixture() as (owner, _, ready, _, _, _):
            close = os.close

            def released_then_refused(descriptor):
                close(descriptor)
                raise OSError("independent post-close refusal")

            with patch.object(probe.os, "close", side_effect=released_then_refused) as attempted:
                ready.close()
            attempted.assert_called_once_with(ready.descriptor)
            foreign_path = owner.root / "independently-acquired-foreign-fd"
            foreign = os.open(foreign_path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                self.assertEqual(foreign, ready.descriptor)
                with patch.object(probe.os, "close", wraps=close) as retry:
                    ready.close()
                retry.assert_not_called()
                self.assertEqual(os.fstat(foreign).st_ino, foreign_path.stat().st_ino)
                self.assertTrue(ready.path.exists())
                self.assertFalse(ready.closed)
                self.assertTrue(ready.close_uncertain)
                self.assertEqual(owner.debt[0]["descriptor_close"], "unacknowledged")
            finally:
                close(foreign)

    def test_post_ack_native_clock_and_activity_are_fresh_in_compiled_explicit_port(self):
        source = Path(probe.__file__).with_name("native_appleevent_probe_sender.c").read_text()
        start = source.index("static bool sender_foreground_after_readiness(")
        body = source[start : source.index("\n/* A separate closed metadata", start)]
        body = body.replace("NSApplication *", "struct Application *").replace("nil", "NULL")
        body = body.replace("[application isActive]", "model_is_active(application)")
        port = r"""
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
struct Application { bool active; int reads; };
static uint64_t clocks[2];
static bool available[2];
static int cursor;
static bool foreground_now_ns(uint64_t *value) {
    if (cursor >= 2) return false;
    *value = clocks[cursor];
    return available[cursor++];
}
static bool model_is_active(struct Application *app) { app->reads++; return app->active; }
"""
        cases = r"""
int main(void) {
    // Independent receiving values: acknowledgement I/O may cross the clock
    // boundary, focus may be lost, and even the fresh getter may consume time.
    const struct { uint64_t first, second; bool first_ok, second_ok, active, missing, expected; int reads; } cases[] = {
        {110,111,true,true,true,false,true,1},
        {200,201,true,true,true,false,false,0},
        {210,211,true,true,true,false,false,0},
        {99,110,true,true,true,false,false,0},
        {110,111,true,true,false,false,false,1},
        {110,200,true,true,true,false,false,1},
        {110,109,true,true,true,false,false,1},
        {110,111,false,true,true,false,false,0},
        {110,111,true,false,true,false,false,1},
        {110,111,true,true,true,true,false,0},
        {199,199,true,true,true,false,true,1}
    };
    for (size_t index=0; index<sizeof(cases)/sizeof(cases[0]); index++) {
        struct Application app={cases[index].active,0};
        clocks[0]=cases[index].first; clocks[1]=cases[index].second;
        available[0]=cases[index].first_ok; available[1]=cases[index].second_ok;
        cursor=0;
        bool result=sender_foreground_after_readiness(cases[index].missing ? NULL : &app,200,100);
        if (result!=cases[index].expected || app.reads!=cases[index].reads) return 3;
    }
    puts("foreground_after_readiness_controls=11");
    return 0;
}
"""
        compiler = probe.shutil.which("cc")
        self.assertIsNotNone(compiler, "An actual C compiler is required for the explicit port")
        with TemporaryDirectory() as directory:
            model, binary = Path(directory) / "model.c", Path(directory) / "model"
            model.write_text(port + body + cases)
            built = subprocess.run(
                [compiler, "-std=c11", "-Wall", "-Werror", str(model), "-o", str(binary)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "foreground_after_readiness_controls=11\n")
            self.assertEqual(result.stderr, "")

    def test_native_permission_call_is_guarded_after_ack_io_without_new_activation(self):
        source = Path(probe.__file__).with_name("native_appleevent_probe_sender.c").read_text()
        start = source.index(
            'if (strcmp(argv[3], "permission-request") == 0) {', source.index("int main(")
        )
        caller = source[
            start : source.index("const int outcome = owned_appleevent_permission", start)
        ]
        self.assertLess(
            caller.index("foreground_deadline_ns(&readiness_deadline)"),
            caller.index("acknowledge_sender_readiness(argv[2])"),
        )
        self.assertLess(
            caller.index("acknowledge_sender_readiness(argv[2])"),
            caller.index(
                "sender_foreground_after_readiness(application, readiness_deadline, readiness_before)"
            ),
        )
        final_guard = caller[caller.index("if (!sender_foreground_after_readiness(") :]
        self.assertIn("AEDisposeDesc(&address)", final_guard)
        self.assertIn("return 65", final_guard)
        body = source[
            source.index("static bool sender_foreground_after_readiness(") : source.index(
                "\n/* A separate closed metadata"
            )
        ]
        self.assertNotIn("activateIgnoringOtherApps", body)
        self.assertNotIn("admit_sender_foreground_request", body)


class IndependentWindowDiscoveryScopeControls(unittest.TestCase):
    """Compiled CF/AX interface port; these controls grant no native UI or consent credit."""

    def test_actual_scope_core_and_original_dispatch_keep_unknown_and_owned_refusals(self):
        source = Path(probe.__file__).with_name("native_appleevent_consent.m").read_text()
        begin = source.index("enum OwnedWindowScope {")
        end = source.index("// Passive traversal of only the retained refused window.", begin)
        body = source[begin:end]
        clock_begin = body.index("static bool scope_before_deadline(void) {")
        clock_end = body.index("static AXError scope_copy_attribute(", clock_begin)
        body = body[:clock_begin] + body[clock_end:]
        self.assertNotIn("AXUIElementSetMessagingTimeout", body)
        self.assertNotIn("AXUIElementPerformAction", body)
        self.assertNotIn("factIdentity", body)
        anchor = "                if (!inspect_window(window, sender, receiver, buttons, &targetSeen, &senderSeen, &denySeen, agentIndex)) {"
        original_begin = source.index(anchor)
        original_end = source.index("                if (!targetSeen) continue;", original_begin)
        legacy = source[original_begin:original_end]
        scope_begin = source.rindex(
            "                enum OwnedWindowScope scope =", 0, original_begin
        )
        scoped = source[scope_begin:original_end]
        scoped = scoped.replace("(__bridge CFStringRef)", "").replace(
            "application.processIdentifier", "31337"
        )
        port = r"""#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
typedef long CFIndex;
typedef int AXError;
struct Object;
typedef struct Object *CFTypeRef;
typedef struct Object *AXUIElementRef;
typedef struct Object *CFStringRef;
typedef struct Object *CFArrayRef;
struct Object {
    int kind;
    const char *text;
    CFIndex length;
    pid_t pid;
    AXError pid_error, role_error, value_error, children_error;
    struct Object *role, *value, *children;
    struct Object **items;
    CFIndex count;
};
struct CFRange { CFIndex location, length; };
enum { TYPE_AX=1, TYPE_STRING=2, TYPE_ARRAY=3, TYPE_OTHER=4 };
enum { kAXErrorSuccess=0, kAXErrorCannotComplete=-25204,
       kAXErrorAttributeUnsupported=-25205, kAXErrorNoValue=-25212,
       kAXErrorInvalidUIElement=-25202 };
static const CFIndex kCFNotFound=-1;
static struct Object role_key={.kind=TYPE_STRING,.text="AXRole"};
static struct Object value_key={.kind=TYPE_STRING,.text="AXValue"};
static struct Object children_key={.kind=TYPE_STRING,.text="AXChildren"};
static struct Object static_role={.kind=TYPE_STRING,.text="AXStaticText"};
#define kAXRoleAttribute (&role_key)
#define kAXValueAttribute (&value_key)
#define kAXChildrenAttribute (&children_key)
#define kAXStaticTextRole (&static_role)
static struct Object scope_window_role={.kind=TYPE_STRING,.text="AXWindow"};
#define kAXWindowRole (&scope_window_role)
static int references=0, deadline_calls=0, expire_after=-1;
static double remaining=1;
static bool scope_before_deadline(void) {
    deadline_calls++;
    return remaining>0 && remaining<=3 && (expire_after<0 || deadline_calls<=expire_after);
}
static int CFGetTypeID(CFTypeRef value) { return value->kind; }
static int AXUIElementGetTypeID(void) { return TYPE_AX; }
static int CFStringGetTypeID(void) { return TYPE_STRING; }
static int CFArrayGetTypeID(void) { return TYPE_ARRAY; }
static CFTypeRef CFRetain(CFTypeRef value) { references++; return value; }
static void CFRelease(CFTypeRef value) { if (value==NULL) abort(); references--; }
static CFIndex CFStringGetLength(CFStringRef value) { return value->length ? value->length : (CFIndex)strlen(value->text); }
static bool CFEqual(CFTypeRef first, CFTypeRef second) {
    return first->kind==TYPE_STRING && second->kind==TYPE_STRING && strcmp(first->text,second->text)==0;
}
static struct CFRange CFStringFind(CFStringRef value, CFStringRef needle, unsigned flags) {
    (void)flags;
    const char *found=strstr(value->text,needle->text);
    return (struct CFRange){found ? (CFIndex)(found-value->text) : kCFNotFound, 0};
}
static CFIndex CFArrayGetCount(CFArrayRef value) { return value->count; }
static CFTypeRef CFArrayGetValueAtIndex(CFArrayRef value, CFIndex index) { return value->items[index]; }
static AXError AXUIElementGetPid(AXUIElementRef value,pid_t *pid) {
    *pid=value->pid;
    return value->pid_error;
}
static AXError AXUIElementCopyAttributeValue(AXUIElementRef value,CFStringRef key,CFTypeRef *result) {
    AXError status;
    if (key==kAXRoleAttribute) { *result=value->role; status=value->role_error; }
    else if (key==kAXValueAttribute) { *result=value->value; status=value->value_error; }
    else if (key==kAXChildrenAttribute) { *result=value->children; status=value->children_error; }
    else abort();
    if (*result!=NULL) CFRetain(*result);
    return status;
}
"""
        cases = r"""static struct Object sender_name={.kind=TYPE_STRING,.text="Owned AppleEvent sender 11111111-2222-3333-4444-555555555555"};
static struct Object receiver_name={.kind=TYPE_STRING,.text="Owned AppleEvent receiver 11111111-2222-3333-4444-555555555555"};
static struct Object window_role={.kind=TYPE_STRING,.text="AXWindow"};
static struct Object button_role={.kind=TYPE_STRING,.text="AXButton"};
static struct Object other={.kind=TYPE_OTHER};
static int run_case(int which) {
    struct Object root={.kind=TYPE_AX,.pid=31337,.role=&window_role};
    struct Object sender={.kind=TYPE_AX,.pid=31337,.role=&static_role,.value=&sender_name};
    struct Object receiver={.kind=TYPE_AX,.pid=31337,.role=&static_role,.value=&receiver_name};
    struct Object button={.kind=TYPE_AX,.pid=31337,.role=&button_role};
    struct Object extra[6];
    for (int index=0;index<6;index++) extra[index]=(struct Object){.kind=TYPE_AX,.pid=31337,.role=&button_role};
    struct Object *items[257]={&sender,&receiver};
    struct Object array={.kind=TYPE_ARRAY,.items=items,.count=2};
    struct Object bad_text={.kind=TYPE_STRING,.text="unrelated",.length=4097};
    root.children=&array;
    remaining=1;expire_after=-1;deadline_calls=0;references=0;
    int expected=OwnedWindowScopeRefused;
    switch(which) {
        case 0: /* Complete unrelated seven-node graph, including an untitled button. */
            for(int index=0;index<6;index++)items[index]=&extra[index];
            array.count=6;expected=OwnedWindowScopeUnrelated;break;
        case 1: expected=OwnedWindowScopeCandidate;break;
        case 2: array.count=1;break;
        case 3: items[0]=&receiver;array.count=1;break;
        case 4: root.role_error=kAXErrorCannotComplete;break;
        case 5: root.role=&other;break;
        case 6: root.role=&bad_text;break;
        case 7: sender.value=NULL;sender.value_error=kAXErrorNoValue;break;
        case 8: sender.value=&other;break;
        case 9: sender.value=&bad_text;break;
        case 10: root.children=NULL;root.children_error=kAXErrorNoValue;expected=OwnedWindowScopeUnrelated;break;
        case 11: root.children=NULL;root.children_error=kAXErrorAttributeUnsupported;expected=OwnedWindowScopeUnrelated;break;
        case 12: root.children=NULL;root.children_error=kAXErrorCannotComplete;break;
        case 13: root.children=NULL;root.children_error=kAXErrorInvalidUIElement;break;
        case 14: root.children=&other;break;
        case 15: items[0]=&other;break;
        case 16: sender.pid=31338;break;
        case 17: root.pid_error=kAXErrorInvalidUIElement;break;
        case 18: array.count=257;break;
        case 19: {
            struct Object *nested_items[2]={&sender,&receiver};
            struct Object nested={.kind=TYPE_ARRAY,.items=nested_items,.count=2};
            button.children=&nested;
            for(int index=0;index<256;index++)items[index]=&button;
            array.count=256;
            int got=discover_window_scope(&root,&sender_name,&receiver_name,31337);
            return got==expected && references==0 ? 0 : 3;
        }
        case 20: items[0]=&root;array.count=1;break;
        case 21: remaining=0;break;
        case 22: remaining=4;break;
        case 23: expire_after=3;break;
        case 24: items[0]=&other;items[1]=&sender;items[2]=&receiver;array.count=3;break;
        case 25: root.children=NULL;root.role=&button_role;break;
        case 26: sender.children=NULL;sender.children_error=kAXErrorNoValue;expected=OwnedWindowScopeCandidate;break;
        case 27: sender.children=NULL;sender.children_error=kAXErrorAttributeUnsupported;expected=OwnedWindowScopeCandidate;break;
        case 28: root.children=NULL;expire_after=7;break; /* Final clock check. */
        case 29: root.children=NULL;expire_after=4;break; /* Read completes after deadline. */
        case 30: root.pid=31338;break;
        case 31: items[0]=NULL;break;
        case 32: root.children_error=kAXErrorNoValue;break; /* Nonnull/error is ambiguous. */
        case 33: root.role_error=kAXErrorAttributeUnsupported;break;
        case 34: sender.value_error=kAXErrorCannotComplete;break;
        default: return 2;
    }
    int got=discover_window_scope(&root,&sender_name,&receiver_name,31337);
    return got==expected && references==0 ? 0 : 3;
}
"""
        selector = r"""
static int inspector_calls=0;
static bool inspector_answer=false;
#define YES true
static bool inspect_window(AXUIElementRef window, CFStringRef sender, CFStringRef receiver,
    void *buttons, bool *targetSeen, bool *senderSeen, bool *denySeen, int agentIndex) {
    (void)window;(void)sender;(void)receiver;(void)buttons;
    (void)targetSeen;(void)senderSeen;(void)denySeen;(void)agentIndex;
    inspector_calls++;
    return inspector_answer;
}
static int legacy_dispatch(AXUIElementRef window) {
    CFStringRef sender=&sender_name,receiver=&receiver_name;
    void *buttons=NULL;
    bool targetSeen=false,senderSeen=false,denySeen=false,observationRefused=false;
    int agentIndex=0;
    do {
LEGACY_FRAGMENT
    } while(false);
    return observationRefused ? 1 : 0;
}
static int scoped_dispatch(AXUIElementRef window) {
    CFStringRef sender=&sender_name,receiver=&receiver_name;
    void *buttons=NULL;
    bool targetSeen=false,senderSeen=false,denySeen=false,observationRefused=false;
    int agentIndex=0;
    do {
SCOPED_FRAGMENT
    } while(false);
    return observationRefused ? 1 : 0;
}
static int selector_case(int which) {
    struct Object root={.kind=TYPE_AX,.pid=31337,.role=&window_role};
    struct Object sender={.kind=TYPE_AX,.pid=31337,.role=&static_role,.value=&sender_name};
    struct Object receiver={.kind=TYPE_AX,.pid=31337,.role=&static_role,.value=&receiver_name};
    struct Object *items[2]={&sender,&receiver};
    struct Object array={.kind=TYPE_ARRAY,.items=items,.count=2};
    remaining=1;expire_after=-1;deadline_calls=0;references=0;
    inspector_calls=0;inspector_answer=false;
    int expected=1,calls=0,got;
    switch(which) {
        case 0: /* Actual old call order cannot exclude a malformed unrelated window. */
            got=legacy_dispatch(&root);calls=1;break;
        case 1: /* Independent complete zero-identity census can exclude only this scope. */
            got=scoped_dispatch(&root);expected=0;break;
        case 2: /* Both private names still require the unchanged failing inspector. */
            root.children=&array;got=scoped_dispatch(&root);calls=1;break;
        case 3: /* Partial private identity remains refusal. */
            root.children=&array;array.count=1;got=scoped_dispatch(&root);break;
        case 4: /* Unknown traversal remains refusal, with no inspector/action credit. */
            root.children_error=kAXErrorCannotComplete;got=scoped_dispatch(&root);break;
        case 5: /* A candidate can progress only through the existing inspector. */
            root.children=&array;inspector_answer=true;
            got=scoped_dispatch(&root);expected=0;calls=1;break;
        default:return 2;
    }
    return got==expected && inspector_calls==calls && references==0 ? 0 : 4;
}
int main(void) {
    for(int index=0;index<35;index++)if(run_case(index)!=0) {
        fprintf(stderr,"scope_case=%d\n",index);return 3;
    }
    for(int index=0;index<6;index++)if(selector_case(index)!=0) {
        fprintf(stderr,"selector_case=%d\n",index);return 4;
    }
    puts("window_scope_controls=35; selector_controls=6");
    return 0;
}
"""
        selector = selector.replace("LEGACY_FRAGMENT", legacy).replace("SCOPED_FRAGMENT", scoped)
        compiler = probe.shutil.which("cc")
        self.assertIsNotNone(
            compiler, "An actual C compiler is required for the explicit CF/AX interface port"
        )
        with TemporaryDirectory() as directory:
            model, binary = Path(directory) / "model.c", Path(directory) / "model"
            model.write_text(port + body + cases + selector)
            built = subprocess.run(
                [compiler, "-std=c11", "-Wall", "-Werror", str(model), "-o", str(binary)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "window_scope_controls=35; selector_controls=6\n")
            self.assertEqual(result.stderr, "")


class TimeoutEvidenceUnavailableFixture:
    """Closed test sentinel: actual capability refusal, never positive publication credit."""

    __slots__ = ()

    @staticmethod
    def packet():
        return {
            "schema": 1,
            "scope": "timeout-evidence-fixture",
            "capability": "O_NOFOLLOW",
            "status": "capability-refused",
            "positive_publication": "UNEXECUTED",
            "child_acquisitions": 0,
            "evidence_files_created": 0,
        }


def timeout_evidence_unavailable_fixture(case, world):
    """A declared negative receipt cannot silently substitute for a positive port."""
    if type(world) is not TimeoutEvidenceUnavailableFixture:
        return False
    packet = world.packet()
    case.assertEqual(
        packet,
        {
            "schema": 1,
            "scope": "timeout-evidence-fixture",
            "capability": "O_NOFOLLOW",
            "status": "capability-refused",
            "positive_publication": "UNEXECUTED",
            "child_acquisitions": 0,
            "evidence_files_created": 0,
        },
    )
    for key in ("schema", "child_acquisitions", "evidence_files_created"):
        case.assertIs(type(packet[key]), int)
    for key in ("scope", "capability", "status", "positive_publication"):
        case.assertIs(type(packet[key]), str)
    case.assertFalse(hasattr(probe.os, "O_NOFOLLOW"))
    print(
        "UNEXECUTED positive-publication: O_NOFOLLOW unavailable; native capability refusal verified"
    )
    return True


class FirstCommandTimeoutControls(unittest.TestCase):
    """Actual private publication plus modeled reservation port; no native timeout credit."""

    @staticmethod
    def fact():
        return {
            "schema": 1,
            "command": "consent-observer",
            "stage": "exit-wait",
            "budget_seconds": 0.12345678901234568,
            "request_deadline_ns": 40_000_000_000,
            "started_ns": 11_000_000_000,
            "expired_ns": 14_000_000_000,
            "spent_ns": 3_000_000_000,
        }

    @contextmanager
    def world(self):
        with (
            TemporaryDirectory() as directory,
            patch.object(probe, "NativeProcessGroups") as native_groups,
        ):
            root = Path(directory)
            evidence_root = root / "evidence"
            evidence_root.mkdir(mode=0o700)
            writer = PhaseEvidenceControls().evidence(evidence_root)
            if writer is None:
                self.assertFalse(hasattr(probe.os, "O_NOFOLLOW"))
                self.assertEqual(list(evidence_root.iterdir()), [])
                native_groups.assert_not_called()
                yield TimeoutEvidenceUnavailableFixture()
                return
            owner = probe.Children(root, evidence=writer)
            clock = [10_000_000_000]
            acquired, retired, waits = [], [], []
            failure = [None]

            def acquire(arguments, native, register, **options):
                process = Mock(pid=73136 + len(acquired), returncode=None)
                group = SimpleNamespace(
                    process=process, reaped=False, observe_exit=Mock(return_value=None)
                )

                def wait(timeout):
                    waits.append((process, timeout))
                    clock[0] = 14_000_000_000
                    if failure[0] is not None:
                        raise failure[0]
                    raise subprocess.TimeoutExpired("PRIVATE_COMMAND_NOT_FOR_EXPORT", timeout)

                def settle():
                    retired.append(process)
                    process.returncode = -15
                    group.reaped = True
                    return True

                group.wait_for_exit, group.settle = wait, settle
                register(group)
                acquired.append(process)
                return group

            try:
                with (
                    patch.object(probe, "acquire_owned", side_effect=acquire),
                    patch.object(probe.time, "monotonic_ns", side_effect=lambda: clock[0]),
                ):
                    yield owner, writer, evidence_root, clock, acquired, retired, waits, failure
            finally:
                writer.close()

    def test_strict_typed_schema_refuses_private_forged_and_nonfinite_facts(self):
        independent = self.fact()
        admitted = probe._validate_command_timeout(independent)
        self.assertEqual(admitted, independent)
        self.assertIsNot(admitted, independent)
        self.assertEqual(
            json.loads(json.dumps(admitted))["budget_seconds"], independent["budget_seconds"]
        )
        faults = [
            ("schema", True),
            ("schema", 2),
            ("command", "PRIVATE_COMMAND"),
            ("command", 1),
            ("stage", "PRIVATE_STAGE"),
            ("stage", True),
            ("budget_seconds", True),
            ("budget_seconds", 0),
            ("budget_seconds", -1),
            ("budget_seconds", 181),
            ("budget_seconds", float("nan")),
            ("budget_seconds", float("inf")),
            ("budget_seconds", "PRIVATE_BUDGET"),
            ("request_deadline_ns", True),
            ("request_deadline_ns", 0),
            ("request_deadline_ns", -1),
            ("request_deadline_ns", 2**64),
            ("request_deadline_ns", float("nan")),
            ("started_ns", True),
            ("started_ns", -1),
            ("started_ns", 2**64),
            ("expired_ns", 10_000_000_000),
            ("expired_ns", None),
            ("expired_ns", 2**64),
            ("spent_ns", 2_999_999_999),
            ("spent_ns", True),
            ("spent_ns", -1),
            ("spent_ns", 2**64),
        ]
        for key, value in faults:
            packet = self.fact()
            packet[key] = value
            with self.subTest(key=key, value=repr(value)), self.assertRaises(probe.AdmissionError):
                probe._validate_command_timeout(packet)
        for change in ("extra", "missing", "subclass", "request-without-deadline"):
            packet = self.fact()
            if change == "extra":
                packet["argv"] = ["PRIVATE_ARGV"]
            elif change == "missing":
                del packet["stage"]
            elif change == "subclass":
                packet = type("ForeignTimeoutDict", (dict,), {})(packet)
            else:
                packet.update(command="permission-request", request_deadline_ns=None)
            with self.subTest(change=change), self.assertRaises(probe.AdmissionError):
                probe._validate_command_timeout(packet)
        packet = self.fact()
        packet["request_deadline_ns"] = None
        self.assertIsNone(probe._validate_command_timeout(packet)["request_deadline_ns"])

    def test_first_fact_survives_omitted_history_later_timeout_and_final_closure(self):
        with self.world() as timeout_world:
            if timeout_evidence_unavailable_fixture(self, timeout_world):
                return
            (_, writer, evidence_root, _, _, _, _, _) = timeout_world
            for index in range(258):
                self.assertTrue(writer.record("initial-" + str(index)))
            first = self.fact()
            self.assertTrue(writer.retain_timeout(first))
            first["command"] = "other"  # Caller mutation cannot rewrite the retained snapshot.
            second = self.fact()
            second.update(command="permission-request", stage="ui-observer", budget_seconds=30)
            self.assertTrue(writer.retain_timeout(second))
            self.assertTrue(writer.retain_timeout(second))
            for phase, status, closed in (
                ("command.end", "refused", False),
                ("cleanup.begin", "pending", False),
                ("cleanup.closed", "accepted", True),
                ("candidate.failed", "refused", True),
            ):
                self.assertTrue(writer.record(phase, status=status, closed=closed))
                latest = json.loads((evidence_root / "checkpoint.json").read_bytes())
                self.assertEqual(latest["first_timeout"], self.fact())
                self.assertEqual(latest["ownership_closed"], closed)
                self.assertEqual(latest["cases"], {})
                self.assertGreater(latest["history_omitted"], 0)
                self.assertLessEqual(len(json.dumps(latest).encode()), 4096)
            self.assertEqual(len(list(evidence_root.glob("phase-*.json"))), 256)
            self.assertTrue(
                all(
                    "first_timeout" not in json.loads(p.read_bytes())
                    for p in evidence_root.glob("phase-*.json")
                )
            )

    def test_forged_replacement_cannot_overwrite_first_or_publish_a_private_payload(self):
        with self.world() as timeout_world:
            if timeout_evidence_unavailable_fixture(self, timeout_world):
                return
            (_, writer, evidence_root, _, _, _, _, _) = timeout_world
            self.assertTrue(writer.retain_timeout(self.fact()))
            before = (evidence_root / "checkpoint.json").read_bytes()
            forged = self.fact()
            forged["private_path"] = "PRIVATE_PATH"
            self.assertFalse(writer.retain_timeout(forged))
            self.assertTrue(writer.failed)
            self.assertEqual((evidence_root / "checkpoint.json").read_bytes(), before)
            self.assertEqual(writer.first_timeout, self.fact())
            writer.first_timeout["spent_ns"] = -1
            self.assertFalse(writer.record("cleanup.closed", status="accepted", closed=True))
            self.assertEqual((evidence_root / "checkpoint.json").read_bytes(), before)
            self.assertNotIn(b"PRIVATE", before)

    def test_writer_missing_new_member_preserves_legacy_projection_before_first_fact(self):
        with self.world() as timeout_world:
            if timeout_evidence_unavailable_fixture(self, timeout_world):
                return
            (_, writer, evidence_root, _, _, _, _, _) = timeout_world
            del writer.first_timeout
            self.assertTrue(writer.record("candidate.begin"))
            packet = json.loads((evidence_root / "checkpoint.json").read_bytes())
            self.assertNotIn("first_timeout", packet)
            self.assertTrue(writer.retain_timeout(self.fact()))
            self.assertEqual(
                json.loads((evidence_root / "checkpoint.json").read_bytes())["first_timeout"],
                self.fact(),
            )

    def test_generic_exit_wait_keeps_supplied_float_budget_and_opaque_deadline_null(self):
        with self.world() as timeout_world:
            # Receiving case: old591 reaches its real timeout + final checkpoint,
            # then fails an observation assertion, without calling any new API.
            if timeout_evidence_unavailable_fixture(self, timeout_world):
                return
            (owner, writer, evidence_root, _, acquired, retired, waits, _) = timeout_world
            for index in range(258):
                self.assertTrue(writer.record("pre-timeout-" + str(index)))
            foreign = owner.root / "foreign" / "native-appleevent-consent"
            with self.assertRaisesRegex(
                probe.AdmissionError, "^Owned native command exceeded deadline$"
            ):
                owner.run([str(foreign), "PRIVATE_ARGUMENT"], timeout=0.12345678901234568)
            self.assertEqual(waits, [(acquired[0], 0.12345678901234568)])
            self.assertEqual(retired, acquired)
            self.assertTrue(owner.groups[acquired[0]].reaped)
            self.assertEqual(owner.active, [])
            self.assertEqual(owner.debt, [])
            self.assertTrue(writer.record("candidate.failed", status="refused", closed=True))
            final = json.loads((evidence_root / "checkpoint.json").read_bytes())
            self.assertEqual(final["phase"], "candidate.failed")
            self.assertTrue(final["ownership_closed"])
            self.assertGreater(final["history_omitted"], 0)
            self.assertEqual(len(list(evidence_root.glob("phase-*.json"))), 256)
            self.assertEqual(final["cases"], {})
            expected = {
                "schema": 1,
                "command": "other",
                "stage": "exit-wait",
                "budget_seconds": 0.12345678901234568,
                "request_deadline_ns": None,
                "started_ns": 10_000_000_000,
                "expired_ns": 14_000_000_000,
                "spent_ns": 4_000_000_000,
            }
            self.assertEqual(final.get("first_timeout"), expected)
            self.assertNotIn("PRIVATE", (evidence_root / "checkpoint.json").read_text())

    def test_nested_consent_observer_timeout_keeps_first_identity_parent_deadline_and_exact_cleanup(
        self,
    ):
        with self.world() as timeout_world:
            if timeout_evidence_unavailable_fixture(self, timeout_world):
                return
            (owner, writer, evidence_root, clock, acquired, retired, waits, _) = timeout_world
            request = probe.OwnedAutomationRequest(["owned", "permission-request"], 30)
            original = []

            def callback(process, deadline):
                self.assertIs(process, acquired[0])
                self.assertEqual(deadline, 40)
                clock[0] = 11_000_000_000
                try:
                    owner.run(
                        [str(owner.root / "native-appleevent-consent"), "PRIVATE_UI_NAMES"],
                        timeout=3,
                        check=False,
                    )
                except probe.AdmissionError as primary:
                    original.append(primary)
                    raise

            with self.assertRaises(probe.AdmissionError) as caught:
                owner.run(request, timeout=30, after_start=callback)
            self.assertIs(caught.exception, original[0])
            self.assertEqual(str(caught.exception), "Owned native command exceeded deadline")
            self.assertEqual(waits, [(acquired[1], 3)])
            self.assertEqual(retired, [acquired[1], acquired[0]])
            self.assertTrue(all(owner.groups[p].reaped for p in acquired))
            self.assertEqual(owner.active, [])
            self.assertEqual(owner.debt, [])
            self.assertIsNone(owner._timeout_request_deadline_ns)
            expected = self.fact()
            expected["budget_seconds"] = 3
            self.assertEqual(writer.first_timeout, expected)
            self.assertTrue(writer.record("candidate.failed", status="refused", closed=True))
            self.assertEqual(
                json.loads((evidence_root / "checkpoint.json").read_bytes())["first_timeout"],
                expected,
            )
            self.assertNotIn("PRIVATE", (evidence_root / "checkpoint.json").read_text())

    def test_request_readiness_timeout_preserves_original_deadline_and_retires_its_private_file(
        self,
    ):
        with self.world() as timeout_world:
            if timeout_evidence_unavailable_fixture(self, timeout_world):
                return
            (owner, writer, _, _, acquired, retired, waits, _) = timeout_world
            request = probe.OwnedAutomationRequest(["owned", "permission-request"], 30)
            request.readiness_nonce = "11111111-2222-3333-4444-555555555555"
            callback = Mock()
            with patch.object(
                probe.OwnedAutomationReadiness,
                "wait",
                side_effect=subprocess.TimeoutExpired("PRIVATE_READINESS", 30),
            ):
                with self.assertRaisesRegex(
                    probe.AdmissionError, "^Owned native command exceeded deadline$"
                ):
                    owner.run(request, timeout=30, after_start=callback)
            callback.assert_not_called()
            self.assertEqual(waits, [])
            self.assertEqual(retired, acquired)
            self.assertEqual(owner.active, [])
            self.assertEqual(owner.debt, [])
            self.assertIsNone(request.readiness)
            self.assertEqual(list(owner.root.glob("automation-ready-*")), [])
            self.assertEqual(writer.first_timeout["command"], "permission-request")
            self.assertEqual(writer.first_timeout["stage"], "readiness")
            self.assertEqual(writer.first_timeout["request_deadline_ns"], 40_000_000_000)
            self.assertEqual(request.deadline_ns, 40_000_000_000)
            self.assertEqual(writer.first_timeout["budget_seconds"], 30)

    def test_raw_ui_callback_timeout_labels_actual_stage_without_claiming_permission_entry(self):
        with self.world() as timeout_world:
            if timeout_evidence_unavailable_fixture(self, timeout_world):
                return
            (owner, writer, _, _, acquired, retired, waits, _) = timeout_world
            request = probe.OwnedAutomationRequest(["owned", "permission-request"], 30)
            callback = Mock(side_effect=subprocess.TimeoutExpired("PRIVATE_CALLBACK", 30))
            with self.assertRaisesRegex(
                probe.AdmissionError, "^Owned native command exceeded deadline$"
            ):
                owner.run(request, timeout=30, after_start=callback)
            callback.assert_called_once_with(acquired[0], 40)
            self.assertEqual(waits, [])
            self.assertEqual(retired, acquired)
            self.assertEqual(owner.active, [])
            self.assertEqual(owner.debt, [])
            self.assertEqual(writer.first_timeout["command"], "permission-request")
            self.assertEqual(writer.first_timeout["stage"], "ui-observer")
            self.assertEqual(writer.first_timeout["request_deadline_ns"], 40_000_000_000)
            self.assertEqual(writer.first_timeout["spent_ns"], 0)
            self.assertIsNone(owner._timeout_request_deadline_ns)

    def test_optional_publication_fault_or_signal_cannot_replace_timeout_primary_or_skip_retirement(
        self,
    ):
        for secondary in (
            OSError("PRIVATE_PUBLICATION"),
            process_owner.OwnedProcessInterrupted("PRIVATE_DIAGNOSTIC_SIGNAL"),
        ):
            with (
                self.subTest(secondary=type(secondary).__name__),
                self.world() as timeout_world,
            ):
                if timeout_evidence_unavailable_fixture(self, timeout_world):
                    return
                (owner, writer, _, _, acquired, retired, _, _) = timeout_world
                with patch.object(writer, "retain_timeout", side_effect=secondary):
                    with self.assertRaisesRegex(
                        probe.AdmissionError, "^Owned native command exceeded deadline$"
                    ):
                        owner.run(["owned"], timeout=3)
                self.assertEqual(retired, acquired)
                self.assertEqual(owner.active, [])
                self.assertEqual(owner.debt, [])
                self.assertIsNone(writer.first_timeout)

    def test_original_cancellation_remains_same_primary_and_never_claims_a_timeout(self):
        with self.world() as timeout_world:
            if timeout_evidence_unavailable_fixture(self, timeout_world):
                return
            (owner, writer, _, _, acquired, retired, _, failure) = timeout_world
            original = process_owner.OwnedProcessInterrupted("ORIGINAL_CANCELLATION")
            failure[0] = original
            with self.assertRaises(process_owner.OwnedProcessInterrupted) as caught:
                owner.run(["owned"], timeout=3)
            self.assertIs(caught.exception, original)
            self.assertEqual(retired, acquired)
            self.assertEqual(owner.active, [])
            self.assertEqual(owner.debt, [])
            self.assertIsNone(writer.first_timeout)


class GenericCallbackTimeoutStageControls(unittest.TestCase):
    """Keep the literal existing deadline/callback/wait sequence and its stage facts."""

    world = FirstCommandTimeoutControls.world

    def test_generic_callback_failure_preserves_callback_arguments_and_ui_stage(self):
        with self.world() as timeout_world:
            if timeout_evidence_unavailable_fixture(self, timeout_world):
                return
            (owner, writer, _, _, acquired, retired, waits, _) = timeout_world
            callback = Mock(side_effect=subprocess.TimeoutExpired("PRIVATE_CALLBACK", 3))
            with patch.object(probe.time, "monotonic", return_value=20):
                with self.assertRaisesRegex(
                    probe.AdmissionError, "^Owned native command exceeded deadline$"
                ):
                    owner.run(["owned"], timeout=3, after_start=callback)
            callback.assert_called_once_with(acquired[0], 23)
            self.assertEqual(waits, [])
            self.assertEqual(retired, acquired)
            self.assertEqual(owner.active, [])
            self.assertEqual(owner.debt, [])
            self.assertEqual(writer.first_timeout["command"], "other")
            self.assertEqual(writer.first_timeout["stage"], "ui-observer")
            self.assertEqual(writer.first_timeout["budget_seconds"], 3)
            self.assertIsNone(writer.first_timeout["request_deadline_ns"])
            self.assertEqual(writer.first_timeout["spent_ns"], 0)


class TimeoutEvidenceMissingCapabilityControls(unittest.TestCase):
    """Forced real constructor refusal; positive publication remains explicitly unexecuted."""

    world = FirstCommandTimeoutControls.world

    def test_actual_missing_nofollow_refuses_before_child_acquisition_and_emits_closed_unexecuted_receipt(
        self,
    ):
        present = hasattr(probe.os, "O_NOFOLLOW")
        original = getattr(probe.os, "O_NOFOLLOW", None)
        native_constructor = probe.PhaseEvidence
        try:
            if present:
                del probe.os.O_NOFOLLOW
            with (
                patch.object(probe, "PhaseEvidence", wraps=native_constructor) as constructors,
                patch.object(probe, "Children", wraps=probe.Children) as children,
                patch.object(probe, "acquire_owned") as acquire,
                patch.object(probe.sys, "stdout", new_callable=io.StringIO) as output,
            ):
                with self.world() as unavailable:
                    self.assertIs(type(unavailable), TimeoutEvidenceUnavailableFixture)
                    self.assertTrue(timeout_evidence_unavailable_fixture(self, unavailable))
                    self.assertEqual(unavailable.packet()["positive_publication"], "UNEXECUTED")
                    constructors.assert_called_once()
                    self.assertEqual(list(Path(constructors.call_args.args[0]).iterdir()), [])
                    children.assert_not_called()
                    acquire.assert_not_called()
                self.assertEqual(
                    output.getvalue(),
                    "UNEXECUTED positive-publication: O_NOFOLLOW unavailable; native capability refusal verified\n",
                )
        finally:
            if present:
                probe.os.O_NOFOLLOW = original
        self.assertEqual(hasattr(probe.os, "O_NOFOLLOW"), present)


if __name__ == "__main__":
    unittest.main()
