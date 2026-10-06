# tools/ci/ubuntu_apt_test.py
"""Constructed archive and argv controls; native APT remains a CI obligation."""

from pathlib import Path
import subprocess
import stat
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import ubuntu_apt as owner


VALID = b"Types: deb\nURIs: http://azure.archive.ubuntu.com/ubuntu/\nSuites: noble noble-updates\nComponents: main universe\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n"


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
        healthy = SimpleNamespace(st_mode=stat.S_IFREG | 0o644, st_uid=0)
        source = SimpleNamespace(lstat=lambda: healthy, read_bytes=lambda: VALID)
        keyring = SimpleNamespace(lstat=lambda: healthy)
        with (
            patch.object(owner.sys, "platform", "linux"),
            patch.object(owner.os, "geteuid", return_value=0, create=True),
            patch.object(owner, "SOURCE", source),
            patch.object(owner, "KEYRING", keyring),
            patch.object(owner, "acquire") as acquire,
        ):
            owner.main(["luajit"])
            acquire.assert_called_once_with(VALID, ["luajit"])
            for authority in (source, keyring):
                for metadata in (
                    SimpleNamespace(st_mode=stat.S_IFREG | 0o644, st_uid=1000),
                    SimpleNamespace(st_mode=stat.S_IFREG | 0o664, st_uid=0),
                    SimpleNamespace(st_mode=stat.S_IFREG | 0o646, st_uid=0),
                    SimpleNamespace(st_mode=stat.S_IFLNK | 0o777, st_uid=0),
                ):
                    with (
                        self.subTest(authority=authority is source, metadata=metadata),
                        patch.object(authority, "lstat", return_value=metadata),
                    ):
                        acquire.reset_mock()
                        with self.assertRaises(RuntimeError):
                            owner.main(["luajit"])
                        acquire.assert_not_called()

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
            self.assertEqual(Path(source).read_bytes(), VALID)
            self.assertTrue((root / "lists").is_dir())
            self.assertTrue((root / "cache").is_dir())
            roots.append(root)
            calls.append(argv)

        owner.acquire(VALID, ["-y", "--no-install-recommends", "luajit", "./owned.deb"], execute)
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
            owner.acquire(VALID, ["luajit"], execute)
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
            owner.acquire(VALID, ["luajit"], execute)
        self.assertIs(observed.exception, failure)
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
