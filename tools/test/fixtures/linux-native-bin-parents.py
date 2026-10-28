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
PAYLOAD_START = 'NATIVE_LUV_RETAINED_DIGEST=""'
BIN_MKDIR = 'install -d "${LIB_DIR}/linux/bin"'
BIN_INSTALL = 'install -m 755 "$NATIVE_OUTPUT_SOURCE"'
GUARD = re.compile(r"^_native_output_bin_parents \|\| exit 1[ \t]*$", re.M)


def payload_guards(text):
    for marker in (PAYLOAD_START, BIN_MKDIR, BIN_INSTALL):
        assert text.count(marker) == 1, "Actual payload boundary must be unique: " + marker
    start = text.index(PAYLOAD_START)
    mkdir = text.index(BIN_MKDIR)
    write = text.index(BIN_INSTALL)
    assert start < mkdir < write, "Native publication boundaries must retain their order"
    guards = list(GUARD.finditer(text, start))
    assert guards, "Actual post-payload guard required"
    first = guards[0]
    assert start + len(PAYLOAD_START) < first.start() < mkdir, (
        "The payload must retire before a guard admits native bin creation"
    )
    second = [guard for guard in guards if mkdir < guard.start() < write]
    assert second, "A second guard must re-admit the created bin before native publication"
    return start, first, second[0]


def payload_copied(text):
    start, first, _ = payload_guards(text)
    with tempfile.TemporaryDirectory(prefix="native-bin-copy-") as directory:
        root = Path(directory)
        src = root / "source"
        lib = root / "destination"
        (src / "bin").mkdir(parents=True)
        (lib / "linux").mkdir(parents=True)
        original = b"actual payload bytes\n\0tail"
        (src / "payload").write_bytes(original)
        (src / "bin/libergopti_archive_publication.so").write_bytes(b"ignored, never executed")
        script = (
            "set -euo pipefail\n"
            + "\n".join(functions)
            + "\nSRC_DRIVER="
            + quote(src)
            + "\nLIB_DIR="
            + quote(lib)
            + '\nNATIVE_LUV_STAGE=""\n'
            + text[start : first.start()]
        )
        observed = subprocess.run(
            [str(canonical_bash), "-s"], input=script, text=True, capture_output=True, timeout=5
        )
        assert observed.returncode >= 0, "A signalled copy probe is not a refusal witness"
        assert (src / "payload").read_bytes() == original
        copied = lib / "linux/payload"
        return (
            observed.returncode == 0
            and copied.is_file()
            and copied.read_bytes() == original
            and not (lib / "linux/bin/libergopti_archive_publication.so").exists()
        )


def validate_payload(text):
    payload_guards(text)
    assert payload_copied(text), "The exact bounded owner must actually copy the admitted payload"


def rejects_payload(text):
    try:
        validate_payload(text)
    except AssertionError:
        return True
    return False


checks = 0


def quote(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


validate_payload(source)
start, first_guard, second_guard = payload_guards(source)
for guard in (first_guard, second_guard):
    removed = source[: guard.start()] + source[guard.end() :]
    assert rejects_payload(removed), "Removing either publication guard must refuse"
    insertion = removed.index(PAYLOAD_START) + len(PAYLOAD_START) + 1
    moved = removed[:insertion] + guard.group() + "\n" + removed[insertion:]
    assert rejects_payload(moved), "A guard before the copy cannot acknowledge payload retirement"
# A comment alone owns no filesystem authority, wherever it is placed.
comment = "# Inert owner-position witness.\n"
for position in (source.index(PAYLOAD_START), source.index(BIN_MKDIR)):
    commented = source[:position] + comment + source[position:]
    validate_payload(commented)
for marker in (PAYLOAD_START, BIN_MKDIR, BIN_INSTALL):
    assert rejects_payload(source.replace(marker, "", 1)), "An absent owner boundary must refuse"
    assert rejects_payload(source.replace(marker, marker + "\n" + marker, 1)), (
        "A duplicate owner boundary must refuse"
    )


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
