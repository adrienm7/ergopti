# tests/hardware/run_ollama_install_files_native.py

"""Build a tiny independent archive; run Lua under the approved child subreaper."""

import argparse
import hashlib
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("driver", type=Path)
parser.add_argument("--shared-lua", type=Path)
parser.add_argument("--native-driver", type=Path)
parser.add_argument("--native-shared", type=Path)
parser.add_argument("--lua", default="luajit")
args = parser.parse_args()
driver = args.driver.resolve()
shared = (args.shared_lua or driver.parent / "_shared/lua").resolve()
native_driver = (args.native_driver or driver).resolve()
native_shared = (args.native_shared or shared).resolve()
if (
    not driver.is_dir()
    or not shared.is_dir()
    or not native_driver.is_dir()
    or not native_shared.is_dir()
):
    raise FileNotFoundError("actual driver/shared source roots are required")
with tempfile.TemporaryDirectory(prefix="ergopti-archive-native-") as temporary:
    root = Path(temporary)
    plain = root / "independent-fixture.tar"
    with tarfile.open(plain, "w", format=tarfile.GNU_FORMAT) as archive:
        for directory in ("bin", "lib", "lib/ollama"):
            info = tarfile.TarInfo(directory)
            info.type = tarfile.DIRTYPE
            info.mode = 0o700
            info.mtime = 0
            archive.addfile(info)
        content = {
            "bin/ollama": b"#!/bin/sh\nprintf 'independent archive fixture\\n'\n",
            "lib/ollama/native-fixture.txt": b"independent full library tree fixture\n",
        }
        for name, data in content.items():
            info = tarfile.TarInfo(name)
            info.mode = 0o755 if name == "bin/ollama" else 0o600
            info.size = len(data)
            info.mtime = 0
            archive.addfile(info, io.BytesIO(data))
    compressed = root / "independent-fixture.tar.zst"
    subprocess.run(
        ["zstd", "--quiet", "--no-progress", "-o", str(compressed), str(plain)], check=True
    )
    data = compressed.read_bytes()
    command = [
        "python3",
        str(native_driver / "tests/hardware/run_native_subreaper.py"),
        args.lua,
        str(driver / "tests/hardware/run_ollama_install_files_native.lua"),
        str(driver),
        str(shared),
        str(native_driver),
        str(native_shared),
        str(root),
        str(compressed),
        str(len(data)),
        hashlib.sha256(data).hexdigest(),
    ]
    subprocess.run(command, check=True)
