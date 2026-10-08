"""Receive official installer extraction modes under the real private umask."""

import io
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
            matches = re.findall(r"^if ! (tar [^\n]+)\s*; then$", SOURCE.read_text(), re.M)
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


if __name__ == "__main__":
    unittest.main()
