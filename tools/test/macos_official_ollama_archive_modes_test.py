"""Receive official installer extraction modes under the real private umask."""

import io
import ctypes
import ctypes.util
import base64
import hashlib
import zlib
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools.lib.git_bash import bash_executable  # noqa: E402

SOURCE = ROOT / "static/ergopti_plus/macos/modules/llm/ensure-ollama-deps.sh"


def literal_appledouble_payload():
    """Return the independently frozen official AppleDouble member bytes."""
    return zlib.decompress(
        base64.b64decode(
            "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"
        )
    )


@unittest.skipUnless(os.name == "posix" and os.geteuid() != 0, "requires an ordinary POSIX user")
class OfficialArchiveModes(unittest.TestCase):
    def receive(self, mask):
        # Independent member literals exercise executable, directory, data and
        # symlink semantics; expectations never come from the extraction code.
        with tempfile.TemporaryDirectory(prefix="ergopti-official-modes-") as directory:
            root = Path(directory)
            archive = root / "official-fixture.tgz"
            with tarfile.open(archive, "w:gz") as output:
                for name, mode, payload in [
                    ("ollama", 0o755, b"pinned cli"),
                    ("libmlx.dylib", 0o755, b"pinned native library"),
                    ("native/LICENSE", 0o644, b"pinned licence"),
                ]:
                    if name.startswith("native/"):
                        member = tarfile.TarInfo("native")
                        member.type, member.mode = tarfile.DIRTYPE, 0o755
                        output.addfile(member)
                    member = tarfile.TarInfo(name)
                    member.mode, member.size = mode, len(payload)
                    output.addfile(member, io.BytesIO(payload))
                member = tarfile.TarInfo("libmlx.link")
                member.type, member.linkname = tarfile.SYMTYPE, "libmlx.dylib"
                output.addfile(member)
            stage = root / "owned-stage"
            stage.mkdir(mode=0o700)
            matches = re.findall(
                r"^if ! ((?:(?:COPYFILE_DISABLE=1|TAR_READER_OPTIONS='tar:!mac-ext') )*tar [^\n]+)\s*; then$",
                SOURCE.read_text(),
                re.M,
            )
            self.assertEqual(len(matches), 1)
            environment = dict(os.environ, archive_path=str(archive), INSTALL_STAGE=str(stage))
            result = subprocess.run(
                [
                    bash_executable(),
                    "--noprofile",
                    "--norc",
                    "-c",
                    "umask " + mask + "; " + matches[0],
                ],
                env=environment,
                capture_output=True,
                timeout=20,
            )
            self.assertEqual(result.returncode, 0, "actual extraction command must complete")
            for name, mode in [
                ("ollama", 0o755),
                ("libmlx.dylib", 0o755),
                ("native", 0o755),
                ("native/LICENSE", 0o644),
            ]:
                self.assertEqual(stat.S_IMODE((stage / name).stat().st_mode), mode, name)
            self.assertEqual((stage / "libmlx.dylib").read_bytes(), b"pinned native library")
            self.assertEqual(os.readlink(stage / "libmlx.link"), "libmlx.dylib")
            self.assertEqual(
                stat.S_IMODE(stage.stat().st_mode),
                0o700,
                "the uniquely owned extraction root remains private",
            )

    def test_native_private_process_umask_preserves_pinned_archive_modes(self):
        self.receive("0077")

    def test_inherited_restrictive_umask_preserves_pinned_archive_modes(self):
        self.receive("0027")

    def test_literal_appledouble_bytes_require_child_scoped_reader_options(self):
        # Frozen bytes from pinned Ollama 0.24.0's official Darwin archive,
        # independently hashed before the installer correction. BSD tar must
        # keep this member literally rather than interpret Apple metadata.
        payload = literal_appledouble_payload()
        self.assertEqual(len(payload), 9663)
        self.assertEqual(
            hashlib.sha256(payload).hexdigest(),
            "39f032126bc209cf7f87c209d8459257589d5488272bb19eba9ae1016e053740",
        )
        commands = re.findall(
            r"^if ! ((?:(?:COPYFILE_DISABLE=1|TAR_READER_OPTIONS='tar:!mac-ext') )*tar [^\n]+)\s*; then$",
            SOURCE.read_text(),
            re.M,
        )
        self.assertEqual(len(commands), 1)
        self.assertEqual(
            commands[0],
            "COPYFILE_DISABLE=1 TAR_READER_OPTIONS='tar:!mac-ext' "
            'tar -xzpf "$archive_path" -C "$INSTALL_STAGE"',
        )
        with tempfile.TemporaryDirectory(prefix="ergopti-official-appledouble-") as directory:
            root = Path(directory)
            archive = root / "literal-appledouble.tgz"
            with tarfile.open(archive, "w:gz") as output:
                member = tarfile.TarInfo("._mlx.metallib")
                member.mode, member.size = 0o644, len(payload)
                output.addfile(member, io.BytesIO(payload))
            stage = root / "owned-stage"
            stage.mkdir(mode=0o700)
            environment = dict(
                os.environ,
                archive_path=str(archive),
                INSTALL_STAGE=str(stage),
                COPYFILE_DISABLE="inherited-sentinel",
                TAR_READER_OPTIONS="tar:mac-ext",
            )
            result = subprocess.run(
                [
                    bash_executable(),
                    "--noprofile",
                    "--norc",
                    "-c",
                    "umask 0077; "
                    + commands[0]
                    + '; test "$COPYFILE_DISABLE" = inherited-sentinel'
                    + '; test "$TAR_READER_OPTIONS" = tar:mac-ext',
                ],
                env=environment,
                capture_output=True,
                timeout=20,
            )
            self.assertEqual(result.returncode, 0, "child extraction preserves caller environment")
            self.assertEqual((stage / "._mlx.metallib").read_bytes(), payload)
            self.assertEqual(stat.S_IMODE((stage / "._mlx.metallib").stat().st_mode), 0o644)
            self.assertEqual(stat.S_IMODE(stage.stat().st_mode), 0o700)

    def test_genuine_tar_reader_preserves_literal_members_and_closes(self):
        library = ctypes.util.find_library("archive")
        self.assertIsNotNone(library, "genuine libarchive is required for reader receiving")
        native = ctypes.CDLL(library)
        native.archive_read_new.restype = ctypes.c_void_p
        for name, arguments, result in [
            ("archive_read_support_filter_gzip", [ctypes.c_void_p], ctypes.c_int),
            ("archive_read_support_format_tar", [ctypes.c_void_p], ctypes.c_int),
            ("archive_read_set_options", [ctypes.c_void_p, ctypes.c_char_p], ctypes.c_int),
            (
                "archive_read_open_memory",
                [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t],
                ctypes.c_int,
            ),
            (
                "archive_read_next_header",
                [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)],
                ctypes.c_int,
            ),
            ("archive_entry_pathname", [ctypes.c_void_p], ctypes.c_char_p),
            ("archive_entry_perm", [ctypes.c_void_p], ctypes.c_uint),
            (
                "archive_read_data",
                [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t],
                ctypes.c_ssize_t,
            ),
            ("archive_read_close", [ctypes.c_void_p], ctypes.c_int),
            ("archive_read_free", [ctypes.c_void_p], ctypes.c_int),
        ]:
            function = getattr(native, name)
            function.argtypes, function.restype = arguments, result
        payload = literal_appledouble_payload()
        self.assertEqual(len(payload), 9663)
        self.assertEqual(
            hashlib.sha256(payload).hexdigest(),
            "39f032126bc209cf7f87c209d8459257589d5488272bb19eba9ae1016e053740",
        )
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as output:
            for name, data in [
                ("._mlx.metallib", payload),
                ("mlx.metallib", b"independent native data"),
            ]:
                member = tarfile.TarInfo(name)
                member.mode, member.size = 0o644, len(data)
                output.addfile(member, io.BytesIO(data))

        def read(disable_extensions):
            archive = native.archive_read_new()
            self.assertTrue(archive)
            contents = []
            try:
                self.assertEqual(native.archive_read_support_filter_gzip(archive), 0)
                self.assertEqual(native.archive_read_support_format_tar(archive), 0)
                # Set the genuine reader to Darwin's enabled default explicitly,
                # so the old control is meaningful on other POSIX hosts too.
                self.assertEqual(native.archive_read_set_options(archive, b"tar:mac-ext"), 0)
                if disable_extensions:
                    self.assertEqual(native.archive_read_set_options(archive, b"tar:!mac-ext"), 0)
                buffer = ctypes.create_string_buffer(stream.getvalue())
                self.assertEqual(
                    native.archive_read_open_memory(archive, buffer, len(stream.getvalue())), 0
                )
                while True:
                    entry = ctypes.c_void_p()
                    status = native.archive_read_next_header(archive, ctypes.byref(entry))
                    if status == 1:
                        break
                    self.assertEqual(status, 0)
                    self.assertLess(len(contents), 2, "the exact literal archive has two members")
                    data = bytearray()
                    chunk = ctypes.create_string_buffer(4096)
                    while True:
                        count = native.archive_read_data(archive, chunk, len(chunk))
                        self.assertGreaterEqual(count, 0)
                        if count == 0:
                            break
                        data.extend(chunk.raw[:count])
                        self.assertLessEqual(len(data), 9663)
                    contents.append(
                        (
                            native.archive_entry_pathname(entry).decode("ascii"),
                            native.archive_entry_perm(entry),
                            bytes(data),
                        )
                    )
                self.assertEqual(native.archive_read_close(archive), 0)
            finally:
                self.assertEqual(native.archive_read_free(archive), 0)
            return contents

        self.assertEqual(read(False), [("mlx.metallib", 0o644, b"independent native data")])
        self.assertEqual(
            read(True),
            [
                ("._mlx.metallib", 0o644, payload),
                ("mlx.metallib", 0o644, b"independent native data"),
            ],
        )


if __name__ == "__main__":
    unittest.main()
