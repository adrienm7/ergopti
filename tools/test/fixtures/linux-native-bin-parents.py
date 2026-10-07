# tools/test/fixtures/linux-native-bin-parents.py

# controls/test_native_bin_parents.py
"""Actual filesystem/production guard controls, not full installer/native proof."""

from pathlib import Path
import hashlib
import os
import stat
import re
import subprocess
import sys
import tempfile

canonical_bash = Path(sys.argv[2])
expected_bash_sha256 = sys.argv[3]
assert canonical_bash.is_absolute() and not canonical_bash.is_symlink()
assert stat.S_ISREG(canonical_bash.lstat().st_mode) and os.access(canonical_bash, os.X_OK)
bash_bytes = canonical_bash.read_bytes()
assert (
    bash_bytes[:4] == b"\x7fELF" and hashlib.sha256(bash_bytes).hexdigest() == expected_bash_sha256
)
source = Path(sys.argv[1]).read_text()
functions = []
for name in ("_native_output_ordinary_directory", "_native_output_bin_parents"):
    observed = re.search(r"^" + name + r"\(\) \{[\s\S]*?^\}", source, re.M)
    assert observed, "Actual guard function required: " + name
    functions.append(observed.group())
assert source.index("_native_output_bin_parents || exit 1") < source.index('NATIVE_OUTPUT_STAGE=""')
copy = source.index('tar -C "$SRC_DRIVER"')
write = source.index('install -m 755 "$NATIVE_OUTPUT_SOURCE"')
assert "_native_output_bin_parents || exit 1" in source[copy:write]
checks = 0


def quote(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


with tempfile.TemporaryDirectory(prefix="native-bin-parent-") as directory:
    root = Path(directory)
    outside = root / "outside"
    outside.mkdir()
    (outside / "libergopti_archive_publication.so").write_bytes(
        b"ordinary outside marker; not an ELF"
    )
    sentinel = outside / "unchanged"
    sentinel.write_bytes(b"preserve")
    for label, shape in (
        ("checkout source bin symlink", "checkout"),
        ("release payload bin symlink", "payload"),
        ("installed bin symlink", "installed"),
        ("ordinary recovery", "ordinary"),
    ):
        case = root / shape
        src = case / "source"
        lib = case / "destination"
        src.mkdir(parents=True)
        (lib / "linux").mkdir(parents=True)
        if shape in ("checkout", "payload"):
            (src / "bin").symlink_to(outside, target_is_directory=True)
        else:
            (src / "bin").mkdir()
        if shape == "installed":
            (lib / "linux/bin").symlink_to(outside, target_is_directory=True)
        else:
            (lib / "linux/bin").mkdir()
        script = (
            "set -eu\n"
            + "\n".join(functions)
            + "\nSRC_DRIVER="
            + quote(src)
            + "\nLIB_DIR="
            + quote(lib)
            + "\n_native_output_bin_parents\n"
        )
        result = subprocess.run(
            [str(canonical_bash), "-s"], input=script, text=True, capture_output=True, timeout=5
        )
        assert result.returncode == (0 if shape == "ordinary" else 1), (
            label,
            result.returncode,
            result.stderr,
        )
        assert sentinel.read_bytes() == b"preserve"
        assert (
            outside / "libergopti_archive_publication.so"
        ).read_bytes() == b"ordinary outside marker; not an ELF"
        checks += 1
        print("PASS " + label)
assert hashlib.sha256(canonical_bash.read_bytes()).hexdigest() == expected_bash_sha256
assert checks == 4
print("4 PASS, 0 FAIL, 0 SKIP; filesystem guard only")
