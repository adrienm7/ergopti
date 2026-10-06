# tools/ci/ubuntu_apt_test.py
"""Constructed archive and argv controls; native APT remains a CI obligation."""

from pathlib import Path
from contextlib import contextmanager
import errno
import subprocess
import stat
import hashlib
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import ubuntu_apt as owner


VALID = b"Types: deb\nURIs: http://azure.archive.ubuntu.com/ubuntu/\nSuites: noble noble-updates\nComponents: main universe\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n"

CANONICAL = owner.PINNED_KEYRING.read_bytes()
MIRRORS = b"http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\nhttps://archive.ubuntu.com/ubuntu/\tpriority:2\nhttps://security.ubuntu.com/ubuntu/\tpriority:3\n"


class OriginDescriptorModel:
    """Closed descriptor recording port; POSIX flags here are not native evidence."""

    def __init__(self, source=VALID, mirrors=MIRRORS):
        self.payloads = {"source": source, "mirrors": mirrors}
        self.metadata = {
            role: dict(
                st_mode=stat.S_IFREG | 0o644,
                st_uid=0,
                st_dev=71,
                st_ino=120 + index,
                st_size=len(raw),
                st_mtime_ns=900,
                st_ctime_ns=1000,
            )
            for index, (role, raw) in enumerate(self.payloads.items())
        }
        self.after = {}
        self.fd_rows = {}
        self.opens, self.reads, self.stats, self.closes = [], [], [], []
        self.open_error = None
        self.read_error = None
        self.close_error = None
        self.chunk_bytes = None

    def open(self, path, flags):
        if path == owner.SOURCE:
            role = "source"
        elif path == owner.MIRRORS:
            role = "mirrors"
        else:
            raise AssertionError("Unknown origin path reached native open")
        if flags != (owner.os.O_RDONLY | owner.os.O_NOFOLLOW | owner.os.O_NONBLOCK):
            raise AssertionError("Origin open omitted exact no-follow policy")
        self.opens.append((role, flags))
        if self.open_error is not None:
            raise self.open_error
        descriptor = 300 + len(self.opens)
        self.fd_rows[descriptor] = {"role": role, "offset": 0, "stat_count": 0}
        return descriptor

    def row(self, descriptor):
        if descriptor not in self.fd_rows:
            raise AssertionError("Unknown or closed descriptor reached origin port")
        return self.fd_rows[descriptor]

    def fstat(self, descriptor):
        row = self.row(descriptor)
        self.stats.append(descriptor)
        row["stat_count"] += 1
        facts = dict(self.metadata[row["role"]])
        if row["stat_count"] > 1:
            facts.update(self.after.get(row["role"], {}))
        return SimpleNamespace(**facts)

    def read(self, descriptor, requested):
        row = self.row(descriptor)
        if type(requested) is not int or not 0 < requested <= 65537:
            raise AssertionError("Origin read exceeded independent literal byte bound")
        self.reads.append((descriptor, requested))
        if self.read_error is not None:
            raise self.read_error
        size = requested if self.chunk_bytes is None else min(requested, self.chunk_bytes)
        block = self.payloads[row["role"]][row["offset"] : row["offset"] + size]
        row["offset"] += len(block)
        return block

    def close(self, descriptor):
        self.row(descriptor)
        self.closes.append(descriptor)
        if self.close_error is not None:
            raise self.close_error
        del self.fd_rows[descriptor]


@contextmanager
def origin_ports(model):
    """Only modeled native descriptor operations; no real APT or POSIX opens."""
    with (
        patch.object(owner.os, "O_NOFOLLOW", 0x20000, create=True),
        patch.object(owner.os, "O_NONBLOCK", 0x800, create=True),
        patch.object(owner.os, "open", model.open),
        patch.object(owner.os, "fstat", model.fstat),
        patch.object(owner.os, "read", model.read),
        patch.object(owner.os, "close", model.close),
    ):
        yield model


class UbuntuArchiveControls(unittest.TestCase):
    def test_both_archive_and_security_stanzas_keep_their_original_signed_source_bytes(self):
        raw = VALID.replace(b"noble noble-updates", b"noble noble-updates noble-backports")
        raw += b"\n" + VALID.replace(
            b"http://azure.archive.ubuntu.com", b"http://security.ubuntu.com"
        ).replace(b"noble noble-updates", b"noble-security")
        self.assertEqual(owner.admitted_source(raw), raw)
        for source in (
            raw.replace(b"Types: deb", b"Types: deb deb-src"),
            raw + b"Allow-Insecure: yes\n",
            raw + b"Check-Valid-Until: no\n",
        ):
            with self.subTest(source=source), self.assertRaises(ValueError):
                owner.admitted_source(source)

    def test_actual_entry_refuses_unowned_writable_or_nonregular_authorities_before_acquisition(
        self,
    ):
        model = OriginDescriptorModel()
        with (
            origin_ports(model),
            patch.object(owner.sys, "platform", "linux"),
            patch.object(owner.os, "geteuid", return_value=0, create=True),
            patch.object(owner, "read_pinned_keyring", return_value=CANONICAL),
            patch.object(owner, "acquire") as acquire,
        ):
            owner.main(["luajit"])
            acquire.assert_called_once_with(VALID, ["luajit"], keyring=CANONICAL, mirrors=None)
            for metadata in (
                SimpleNamespace(st_mode=stat.S_IFREG | 0o644, st_uid=1000),
                SimpleNamespace(st_mode=stat.S_IFREG | 0o664, st_uid=0),
                SimpleNamespace(st_mode=stat.S_IFREG | 0o646, st_uid=0),
                SimpleNamespace(st_mode=stat.S_IFLNK | 0o777, st_uid=0),
            ):
                with self.subTest(metadata=metadata):
                    model.metadata["source"].update(
                        st_mode=metadata.st_mode, st_uid=metadata.st_uid
                    )
                    acquire.reset_mock()
                    with self.assertRaises(RuntimeError):
                        owner.main(["luajit"])
                    acquire.assert_not_called()
        self.assertEqual(len(model.opens), len(model.closes))
        self.assertEqual(model.fd_rows, {})

    def test_actual_source_bytes_and_package_selection_survive_both_scoped_operations(self):
        calls, roots = [], []

        def execute(argv, *, check):
            self.assertTrue(check)
            source = next(
                value.split("=", 1)[1]
                for value in argv
                if value.startswith("Dir::Etc::SourceList=")
            )
            root = Path(source).parent
            self.assertEqual(
                Path(source).read_bytes(),
                VALID.replace(
                    owner.KEYRING_NAME.encode("ascii"),
                    str(root / "ubuntu-archive-keyring.gpg").encode("utf-8"),
                ),
            )
            self.assertEqual((root / "ubuntu-archive-keyring.gpg").read_bytes(), CANONICAL)
            self.assertEqual((root / "ubuntu-archive-keyring.gpg").stat().st_mode & 0o222, 0)
            self.assertTrue((root / "lists").is_dir())
            self.assertTrue((root / "cache").is_dir())
            roots.append(root)
            calls.append(argv)

        owner.acquire(
            VALID,
            ["-y", "--no-install-recommends", "luajit", "./owned.deb"],
            execute,
            keyring=CANONICAL,
        )
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][:-1], calls[1][:-5])
        self.assertEqual(calls[0][-1], "update")
        self.assertEqual(
            calls[1][-5:], ["install", "-y", "--no-install-recommends", "luajit", "./owned.deb"]
        )
        self.assertIn("Dir::Etc::SourceParts=-", calls[0])
        self.assertIn("APT::Update::Error-Mode=any", calls[0])
        self.assertIn("APT::Get::AllowUnauthenticated=false", calls[0])
        self.assertIn("Acquire::AllowInsecureRepositories=false", calls[0])
        self.assertIn("Acquire::AllowDowngradeToInsecureRepositories=false", calls[0])
        self.assertEqual(roots[0], roots[1])
        self.assertFalse(roots[0].exists())

    def test_foreign_repository_and_weakened_signature_sources_refuse_before_execution(self):
        for raw in (
            b"",
            VALID + b"Trusted: yes\n",
            VALID.replace(b"azure.archive.ubuntu.com", b"packages.microsoft.com"),
            VALID.replace(b"azure.archive.ubuntu.com", b"archive.ubuntu.com.foreign.invalid"),
            VALID.replace(
                b"Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg",
                b"Signed-By: /foreign.gpg",
            ),
            VALID.replace(b"Types: deb", b"Types: deb\nTypes: deb"),
        ):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                owner.acquire(raw, ["luajit"], lambda *a, **k: self.fail("Refused source executed"))

    def test_package_arguments_cannot_override_scoped_archive_or_signature_policy(self):
        for arguments in (
            [],
            ["-y"],
            ["--allow-unauthenticated", "luajit"],
            ["-o", "Dir::Etc::SourceParts=/foreign"],
            ["luajit\x00"],
        ):
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                owner.acquire(
                    VALID, arguments, lambda *a, **k: self.fail("Refused policy executed")
                )

    def test_update_failure_never_reaches_install_and_keeps_its_original_status(self):
        calls, roots = [], []
        failure = subprocess.CalledProcessError(100, ["apt-get", "update"])

        def execute(argv, *, check):
            calls.append(argv)
            source = next(
                value.split("=", 1)[1]
                for value in argv
                if value.startswith("Dir::Etc::SourceList=")
            )
            roots.append(Path(source).parent)
            raise failure

        with self.assertRaises(subprocess.CalledProcessError) as observed:
            owner.acquire(VALID, ["luajit"], execute, keyring=CANONICAL)
        self.assertIs(observed.exception, failure)
        self.assertEqual(len(calls), 1)
        self.assertFalse(roots[0].exists())

    def test_install_failure_is_not_promoted_to_success(self):
        calls = []
        failure = subprocess.CalledProcessError(101, ["apt-get", "install"])

        def execute(argv, *, check):
            calls.append(argv)
            if "install" in argv:
                raise failure

        with self.assertRaises(subprocess.CalledProcessError) as observed:
            owner.acquire(VALID, ["luajit"], execute, keyring=CANONICAL)
        self.assertIs(observed.exception, failure)
        self.assertEqual(len(calls), 2)


class PinnedUbuntuAuthorityControls(unittest.TestCase):
    def test_canonical_package_key_bytes_are_independent_of_writable_image_material(self):
        self.assertEqual(len(CANONICAL), 3607)
        self.assertEqual(
            hashlib.sha256(CANONICAL).hexdigest(),
            "80a36b0a6de2f69f49d2df75ef473ccde121e9e190b9ea01d20a4f63778d5c31",
        )
        model = OriginDescriptorModel()
        image = SimpleNamespace(
            lstat=lambda: SimpleNamespace(st_mode=stat.S_IFREG | 0o777, st_uid=0),
            read_bytes=lambda: self.fail("Writable image is not a trust anchor"),
        )
        with (
            origin_ports(model),
            patch.object(owner.sys, "platform", "linux"),
            patch.object(owner.os, "geteuid", return_value=0, create=True),
            patch.object(owner, "KEYRING", image),
            patch.object(owner, "read_pinned_keyring", return_value=CANONICAL),
            patch.object(owner, "acquire") as acquire,
        ):
            owner.main(["./owned.deb"])
        acquire.assert_called_once_with(VALID, ["./owned.deb"], keyring=CANONICAL, mirrors=None)
        self.assertEqual(model.fd_rows, {})

    def test_tampered_same_size_key_refuses_before_any_namespace_or_apt(self):
        corrupted = bytes([CANONICAL[0] ^ 1]) + CANONICAL[1:]
        with (
            patch.object(
                owner.tempfile,
                "TemporaryDirectory",
                side_effect=AssertionError("Tampered key reached namespace creation"),
            ) as namespace,
            patch.object(owner.subprocess, "run") as execute,
        ):
            with self.assertRaisesRegex(ValueError, "Pinned Ubuntu keyring bytes refused"):
                owner.acquire(VALID, ["luajit"], execute, keyring=corrupted)
        namespace.assert_not_called()
        execute.assert_not_called()

    def test_original_exact_mirror_bytes_and_priority_are_copied_into_private_source(self):
        raw = VALID.replace(
            b"http://azure.archive.ubuntu.com/ubuntu/", owner.MIRROR_URI.encode("ascii")
        )
        calls, roots = [], []

        def execute(argv, *, check):
            self.assertTrue(check)
            source = next(
                value.split("=", 1)[1]
                for value in argv
                if value.startswith("Dir::Etc::SourceList=")
            )
            root = Path(source).parent
            roots.append(root)
            expected = raw.replace(
                owner.KEYRING_NAME.encode("ascii"),
                str(root / "ubuntu-archive-keyring.gpg").encode("utf-8"),
            )
            expected = expected.replace(
                owner.MIRROR_URI.encode("ascii"),
                ("mirror+file:" + str(root / "apt-mirrors.txt")).encode("utf-8"),
            )
            self.assertEqual(Path(source).read_bytes(), expected)
            self.assertEqual((root / "apt-mirrors.txt").read_bytes(), MIRRORS)
            self.assertEqual((root / "ubuntu-archive-keyring.gpg").read_bytes(), CANONICAL)
            self.assertIn("Dir::Etc::SourceParts=-", argv)
            calls.append(argv)

        owner.acquire(raw, ["-y", "luajit"], execute, keyring=CANONICAL, mirrors=MIRRORS)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][:-1], calls[1][:-3])
        self.assertFalse(roots[0].exists())
        self.assertFalse(roots[1].exists())

    def test_unknown_mirrors_paths_or_options_refuse_before_namespace(self):
        raw = VALID.replace(
            b"http://azure.archive.ubuntu.com/ubuntu/", owner.MIRROR_URI.encode("ascii")
        )
        for mirrors in (
            None,
            b"",
            MIRRORS.replace(b"archive.ubuntu.com", b"packages.microsoft.com"),
            MIRRORS + b"file:/foreign\n",
            MIRRORS + b"https://archive.ubuntu.com/ubuntu/\ttrusted:yes\n",
        ):
            with (
                self.subTest(mirrors=mirrors),
                patch.object(
                    owner.tempfile,
                    "TemporaryDirectory",
                    side_effect=AssertionError("Untrusted mirror reached namespace creation"),
                ) as namespace,
            ):
                with self.assertRaises(ValueError):
                    owner.acquire(
                        raw,
                        ["luajit"],
                        lambda *a, **k: self.fail("Refused mirror executed"),
                        keyring=CANONICAL,
                        mirrors=mirrors,
                    )
                namespace.assert_not_called()
        with self.assertRaises(ValueError):
            owner.admitted_source(raw.replace(b"/etc/apt/apt-mirrors.txt", b"/foreign"), MIRRORS)

    def test_private_authority_refusal_precedes_apt_and_retires_owned_namespace(self):
        for mode in ("after-write", "private-writable"):
            with self.subTest(mode=mode):
                acquired = []
                original = owner.write_private
                original_chmod = Path.chmod

                def refuse(path, raw, role):
                    acquired.append(path.parent)
                    original(path, raw, role)
                    if role == "private-keyring":
                        raise OSError("Constructed private authority refusal")

                def writable(path, permissions):
                    if path.name == "ubuntu-archive-keyring.gpg":
                        acquired.append(path.parent)
                        return original_chmod(path, 0o666)
                    return original_chmod(path, permissions)

                fault = (
                    patch.object(owner, "write_private", side_effect=refuse)
                    if mode == "after-write"
                    else patch.object(Path, "chmod", writable)
                )
                with fault, patch.object(owner.subprocess, "run") as execute:
                    with self.assertRaises(OSError if mode == "after-write" else RuntimeError):
                        owner.acquire(VALID, ["luajit"], execute, keyring=CANONICAL)
                execute.assert_not_called()
                self.assertEqual(len(acquired), 1)
                self.assertFalse(acquired[0].exists())

    def test_origin_refusal_diagnostic_is_typed_and_never_exports_path_or_source(self):
        for role, metadata, expected in (
            (
                "source",
                SimpleNamespace(st_mode=stat.S_IFREG | 0o664, st_uid=0),
                {"role": "source", "kind": "regular", "uid": 0, "mode": "0664"},
            ),
            (
                "mirrors",
                SimpleNamespace(st_mode=stat.S_IFLNK | 0o777, st_uid=1001),
                {"role": "mirrors", "kind": "symlink", "uid": 1001, "mode": "0777"},
            ),
        ):
            with self.subTest(role=role), self.assertRaises(RuntimeError) as caught:
                owner.require_owned(metadata, role)
            text = str(caught.exception)
            self.assertEqual(json.loads(text.split(": ", 1)[1]), expected)
            self.assertNotIn("/etc/", text)
            self.assertNotIn("Signed-By", text)


class OriginDescriptorControls(unittest.TestCase):
    def test_actual_short_reads_use_one_native_identity_and_bounded_requests_then_close(self):
        for role in ("source", "mirrors"):
            with self.subTest(role=role):
                model = OriginDescriptorModel()
                model.chunk_bytes = 7
                origin = owner.SOURCE if role == "source" else owner.MIRRORS
                with origin_ports(model):
                    actual = owner.read_owned_origin(origin, role)
                self.assertEqual(actual, model.payloads[role])
                self.assertEqual(len(model.opens), 1)
                self.assertEqual(len(model.stats), 2)
                self.assertEqual(len(set(model.stats)), 1)
                self.assertTrue(len(model.reads) > 2)
                self.assertTrue(all(fd == model.stats[0] for fd, _ in model.reads))
                self.assertTrue(all(0 < count <= 65537 for _, count in model.reads))
                self.assertEqual(model.closes, [model.stats[0]])
                self.assertEqual(model.fd_rows, {})

    def test_symlink_open_refusal_never_reads_stats_or_closes_an_unacquired_descriptor(self):
        for role in ("source", "mirrors"):
            with self.subTest(role=role):
                model = OriginDescriptorModel()
                refusal = OSError(errno.ELOOP, "Controlled no-follow origin refusal")
                model.open_error = refusal
                origin = owner.SOURCE if role == "source" else owner.MIRRORS
                with origin_ports(model), self.assertRaises(OSError) as caught:
                    owner.read_owned_origin(origin, role)
                self.assertIs(caught.exception, refusal)
                self.assertEqual(len(model.opens), 1)
                self.assertEqual(model.stats, [])
                self.assertEqual(model.reads, [])
                self.assertEqual(model.closes, [])

    def test_descriptor_ownership_and_regular_type_refuse_before_any_origin_bytes(self):
        for role in ("source", "mirrors"):
            for mode, uid in (
                (stat.S_IFREG | 0o644, 1000),
                (stat.S_IFREG | 0o664, 0),
                (stat.S_IFREG | 0o646, 0),
                (stat.S_IFDIR | 0o755, 0),
                (stat.S_IFLNK | 0o777, 0),
                (stat.S_IFIFO | 0o644, 0),
            ):
                with self.subTest(role=role, mode=mode, uid=uid):
                    model = OriginDescriptorModel()
                    model.metadata[role].update(st_mode=mode, st_uid=uid)
                    origin = owner.SOURCE if role == "source" else owner.MIRRORS
                    with origin_ports(model), self.assertRaises(RuntimeError):
                        owner.read_owned_origin(origin, role)
                    self.assertEqual(model.reads, [])
                    self.assertEqual(model.closes, model.stats)
                    self.assertEqual(model.fd_rows, {})

    def test_declared_origin_size_is_bounded_before_read_for_both_roles(self):
        for role in ("source", "mirrors"):
            for size in (0, 65537):
                with self.subTest(role=role, size=size):
                    model = OriginDescriptorModel()
                    model.metadata[role]["st_size"] = size
                    origin = owner.SOURCE if role == "source" else owner.MIRRORS
                    with (
                        origin_ports(model),
                        self.assertRaisesRegex(ValueError, "origin size refused"),
                    ):
                        owner.read_owned_origin(origin, role)
                    self.assertEqual(model.reads, [])
                    self.assertEqual(model.closes, model.stats)
                    self.assertEqual(model.fd_rows, {})

    def test_growing_stream_is_cut_at_independent_maximum_plus_one_before_admission(self):
        for role in ("source", "mirrors"):
            with self.subTest(role=role):
                model = OriginDescriptorModel()
                model.metadata[role]["st_size"] = 65536
                model.payloads[role] = b"x" * 65537
                origin = owner.SOURCE if role == "source" else owner.MIRRORS
                with origin_ports(model), self.assertRaisesRegex(ValueError, "origin size refused"):
                    owner.read_owned_origin(origin, role)
                self.assertEqual([count for _, count in model.reads], [65537])
                self.assertEqual(len(model.closes), 1)
                self.assertEqual(model.fd_rows, {})

    def test_same_descriptor_identity_mode_and_mutation_drift_refuse_after_capture(self):
        for role in ("source", "mirrors"):
            for field in (
                "st_dev",
                "st_ino",
                "st_size",
                "st_mode",
                "st_uid",
                "st_mtime_ns",
                "st_ctime_ns",
            ):
                with self.subTest(role=role, field=field):
                    model = OriginDescriptorModel()
                    model.after[role] = {field: model.metadata[role][field] + 1}
                    origin = owner.SOURCE if role == "source" else owner.MIRRORS
                    with origin_ports(model), self.assertRaises(RuntimeError):
                        owner.read_owned_origin(origin, role)
                    self.assertEqual(len(model.stats), 2)
                    self.assertEqual(len(set(model.stats)), 1)
                    self.assertEqual(model.closes, [model.stats[0]])
                    self.assertEqual(model.fd_rows, {})

    def test_truncated_regular_origin_cannot_admit_its_short_capture(self):
        for role in ("source", "mirrors"):
            with self.subTest(role=role):
                model = OriginDescriptorModel()
                model.metadata[role]["st_size"] += 1
                origin = owner.SOURCE if role == "source" else owner.MIRRORS
                with (
                    origin_ports(model),
                    self.assertRaisesRegex(RuntimeError, "changed during capture"),
                ):
                    owner.read_owned_origin(origin, role)
                self.assertEqual(len(model.closes), 1)
                self.assertEqual(model.fd_rows, {})

    def test_close_refusal_without_primary_never_returns_bytes_or_retries_close(self):
        for role in ("source", "mirrors"):
            with self.subTest(role=role):
                model = OriginDescriptorModel()
                failure = OSError("Controlled exact close refusal")
                model.close_error = failure
                origin = owner.SOURCE if role == "source" else owner.MIRRORS
                with origin_ports(model), self.assertRaises(OSError) as caught:
                    owner.read_owned_origin(origin, role)
                self.assertIs(caught.exception, failure)
                self.assertEqual(len(model.closes), 1)
                self.assertEqual(len(model.fd_rows), 1)

    def test_primary_read_error_and_cancellation_survive_secondary_close_refusal(self):
        for role in ("source", "mirrors"):
            for primary in (
                OSError("Controlled read refusal"),
                KeyboardInterrupt(),
                SystemExit(29),
            ):
                with self.subTest(role=role, kind=type(primary).__name__):
                    model = OriginDescriptorModel()
                    model.read_error = primary
                    model.close_error = OSError("Controlled secondary close refusal")
                    origin = owner.SOURCE if role == "source" else owner.MIRRORS
                    with origin_ports(model), self.assertRaises(type(primary)) as caught:
                        owner.read_owned_origin(origin, role)
                    self.assertIs(caught.exception, primary)
                    self.assertEqual(len(model.closes), 1)
                    self.assertIn(
                        "Ubuntu archive origin descriptor close refused: " + role,
                        caught.exception.__notes__,
                    )

    def test_new_close_cancellation_supersedes_ordinary_primary_without_retry(self):
        for role in ("source", "mirrors"):
            for cancellation in (KeyboardInterrupt(), SystemExit(31)):
                with self.subTest(role=role, kind=type(cancellation).__name__):
                    model = OriginDescriptorModel()
                    model.read_error = OSError("Controlled read refusal")
                    model.close_error = cancellation
                    origin = owner.SOURCE if role == "source" else owner.MIRRORS
                    with origin_ports(model), self.assertRaises(type(cancellation)) as caught:
                        owner.read_owned_origin(origin, role)
                    self.assertIs(caught.exception, cancellation)
                    self.assertEqual(len(model.closes), 1)

    def test_actual_entry_rejects_oversized_mirror_before_key_namespace_or_apt(self):
        raw = VALID.replace(
            b"http://azure.archive.ubuntu.com/ubuntu/", owner.MIRROR_URI.encode("ascii")
        )
        model = OriginDescriptorModel(source=raw)
        model.metadata["mirrors"]["st_size"] = 65537
        with (
            origin_ports(model),
            patch.object(owner.sys, "platform", "linux"),
            patch.object(owner.os, "geteuid", return_value=0, create=True),
            patch.object(
                owner,
                "read_pinned_keyring",
                side_effect=AssertionError("Origin refusal reached key capture"),
            ) as key,
            patch.object(
                owner, "acquire", side_effect=AssertionError("Origin refusal reached namespace")
            ) as acquire,
        ):
            with self.assertRaisesRegex(ValueError, "origin size refused: mirrors"):
                owner.main(["luajit"])
        self.assertEqual([role for role, _ in model.opens], ["source", "mirrors"])
        self.assertEqual(len(model.closes), 2)
        self.assertEqual(model.fd_rows, {})
        key.assert_not_called()
        acquire.assert_not_called()


class ActiveOriginAndCleanupControls(unittest.TestCase):
    def test_comment_only_mirror_uri_keeps_actual_direct_entry_and_private_source(self):
        raw = VALID + b"# diagnostic " + owner.MIRROR_URI.encode("ascii") + b"\n"
        model = OriginDescriptorModel(source=raw)
        with (
            origin_ports(model),
            patch.object(owner.sys, "platform", "linux"),
            patch.object(owner.os, "geteuid", return_value=0, create=True),
            patch.object(owner, "read_pinned_keyring", return_value=CANONICAL),
            patch.object(owner, "acquire") as acquire,
        ):
            owner.main(["luajit"])
        acquire.assert_called_once_with(raw, ["luajit"], keyring=CANONICAL, mirrors=None)
        self.assertEqual([role for role, _ in model.opens], ["source"])
        calls, roots = [], []

        def execute(argv, *, check):
            self.assertTrue(check)
            source = next(
                value.split("=", 1)[1]
                for value in argv
                if value.startswith("Dir::Etc::SourceList=")
            )
            directory = Path(source).parent
            self.assertFalse((directory / "apt-mirrors.txt").exists())
            self.assertEqual(
                Path(source).read_bytes(),
                raw.replace(
                    owner.KEYRING_NAME.encode("ascii"),
                    str(directory / "ubuntu-archive-keyring.gpg").encode("utf-8"),
                ),
            )
            roots.append(directory)
            calls.append(argv)

        owner.acquire(raw, ["luajit"], execute, keyring=CANONICAL)
        self.assertEqual(len(calls), 2)
        self.assertFalse(roots[0].exists())

    def test_mixed_stanzas_select_only_the_active_mirror_and_preserve_full_source(self):
        raw = (
            VALID
            + b"\n"
            + VALID.replace(
                b"http://azure.archive.ubuntu.com/ubuntu/", owner.MIRROR_URI.encode("ascii")
            )
        )
        model = OriginDescriptorModel(source=raw)
        with (
            origin_ports(model),
            patch.object(owner.sys, "platform", "linux"),
            patch.object(owner.os, "geteuid", return_value=0, create=True),
            patch.object(owner, "read_pinned_keyring", return_value=CANONICAL),
            patch.object(owner, "acquire") as acquire,
        ):
            owner.main(["./owned.deb"])
        acquire.assert_called_once_with(raw, ["./owned.deb"], keyring=CANONICAL, mirrors=MIRRORS)
        self.assertEqual([role for role, _ in model.opens], ["source", "mirrors"])
        self.assertEqual(model.fd_rows, {})
        self.assertEqual(owner.admitted_source(raw, MIRRORS), raw)

    def cleanup_report_case(self, report_error):
        roots = []
        original_temporary = owner.tempfile.TemporaryDirectory
        primary = subprocess.CalledProcessError(100, ["apt-get", "update"])

        class RefusedCleanup:
            def __init__(self, *args, **kwargs):
                self.native = original_temporary(*args, **kwargs)
                self.name = self.native.name
                roots.append(Path(self.name))

            def cleanup(self):
                self.native.cleanup()
                raise OSError("Controlled cleanup refusal after exact namespace retirement")

        class RefusedReporter:
            def write(self, text):
                raise report_error

        def execute(argv, *, check):
            self.assertTrue(check)
            raise primary

        with (
            patch.object(owner.tempfile, "TemporaryDirectory", RefusedCleanup),
            patch.object(owner.sys, "stderr", RefusedReporter()),
        ):
            expected = (
                type(report_error)
                if isinstance(report_error, (KeyboardInterrupt, SystemExit))
                else type(primary)
            )
            with self.assertRaises(expected) as caught:
                owner.acquire(VALID, ["luajit"], execute, keyring=CANONICAL)
        self.assertEqual(len(roots), 1)
        self.assertFalse(roots[0].exists())
        return primary, caught.exception

    def test_closed_stderr_cannot_replace_actual_apt_status_or_cleanup_refusal(self):
        primary, observed = self.cleanup_report_case(ValueError("Controlled closed stderr"))
        self.assertIs(observed, primary)
        self.assertEqual(observed.returncode, 100)
        self.assertIn("Ubuntu private authority cleanup refused", observed.__notes__)
        self.assertIn("Ubuntu private authority cleanup reporting unavailable", observed.__notes__)

    def test_new_optional_reporting_cancellation_is_not_swallowed(self):
        for cancellation in (KeyboardInterrupt(), SystemExit(37)):
            with self.subTest(kind=type(cancellation).__name__):
                _, observed = self.cleanup_report_case(cancellation)
                self.assertIs(observed, cancellation)


if __name__ == "__main__":
    unittest.main()
