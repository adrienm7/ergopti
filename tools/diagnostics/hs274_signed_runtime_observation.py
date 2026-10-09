# tools/diagnostics/hs274_signed_runtime_observation.py
"""Readonly actual signatures and independently specified content preservation.

This does not recreate the original compiler custody or grant shipping authority.
Native calls require Darwin and the caller's existing SDK Guardian.
"""

import hashlib
import importlib.util
import os
import re
from pathlib import Path
import stat
import struct
import subprocess
import sys
import time

# Insert final fixture hash at sealing; execute exact held source, never a pyc.
FIXTURE_SHA256 = "f2a492cd326b0808922e4abe0d8e864f5069b6aff772b9399a95e56855fe9bf8"
_path = Path(__file__).with_name("hs274_native_signing_fixture.py")
_data = _path.read_bytes()
if hashlib.sha256(_data).hexdigest() != FIXTURE_SHA256:
    raise RuntimeError("Signing fixture source changed")
_spec = importlib.util.spec_from_file_location("native_signing_fixture", _path)
F = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = F
exec(compile(_data, str(_path), "exec"), F.__dict__)
FixtureRefusal = F.FixtureRefusal
require = F.require
BUILDER_SHA256 = "c62f4184a4876783044a5a047b8d41f6009162a89897bf697714c75cced8fd6c"
TARGETS = (
    (
        "Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",
        "com.ergoptiplus.remap.core",
    ),
    ("Runtime/ErgoptiPlus-Remap-Core.app", "com.ergoptiplus.remap.core"),
    (
        "Runtime/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console",
        "com.ergoptiplus.remap.console",
    ),
    ("Runtime/ErgoptiPlus-Remap-Console.app", "com.ergoptiplus.remap.console"),
    ("Runtime/bin/ergoptiplus_remap_cli", "com.ergoptiplus.remap.cli"),
)
PRIMARY = (TARGETS[0][0], TARGETS[2][0], TARGETS[4][0])
RESOURCE_ADDITIONS = frozenset(
    (
        TARGETS[1][0] + "/Contents/_CodeSignature/CodeResources",
        TARGETS[3][0] + "/Contents/_CodeSignature/CodeResources",
    )
)


def require_identifier(data, identifier, identity):
    require(type(data) is bytes and len(data) < 65536, "requirement")
    lines = data.decode("utf-8", "strict").splitlines()
    matches = [line for line in lines if line.startswith("designated => ")]
    require(len(matches) == 1, "requirement")
    rendered = re.fullmatch(
        r'designated => identifier "([A-Za-z0-9.]+)" and certificate leaf = H"([A-Fa-f0-9]{40})"',
        matches[0],
    )
    require(
        rendered is not None
        and rendered.group(1) == identifier
        and rendered.group(2).upper() == identity,
        "requirement",
    )


def require_leaf(actual, expected):
    require(actual == expected and bool(expected), "leaf")


def _slices(data):
    require(type(data) is bytes and 48 <= len(data) <= 128 * 1024 * 1024, "macho")
    magic, count = struct.unpack_from(">II", data)
    require(magic == 0xCAFEBABE and count == 2, "macho")
    rows = []
    prior = 48
    for index in range(2):
        cpu, sub, offset, size, align = struct.unpack_from(">IIIII", data, 8 + 20 * index)
        require(
            cpu in (0x1000007, 0x100000C)
            and 0 < align <= 20
            and offset >= prior
            and offset % (1 << align) == 0
            and size >= 32
            and offset + size <= len(data),
            "macho",
        )
        require(not any(data[prior:offset]), "macho_padding")
        rows.append((cpu, sub, align, data[offset : offset + size]))
        prior = offset + size
    require(not any(data[prior:]) and len({r[0] for r in rows}) == 2, "macho")
    return tuple(sorted(rows))


def _thin(data, cpu, sub):
    require(len(data) >= 32, "macho")
    header = struct.unpack_from("<8I", data)
    require(
        header[0] == 0xFEEDFACF
        and header[1:3] == (cpu, sub)
        and header[3] == 2
        and 0 < header[4] <= 128
        and 0 < header[5] <= 32768,
        "macho",
    )
    end = 32 + header[5]
    require(end <= len(data), "macho")
    commands = []
    signature = None
    link = None
    cursor = 32
    sections = []
    for index in range(header[4]):
        require(cursor + 8 <= end, "macho")
        kind, size = struct.unpack_from("<II", data, cursor)
        require(size >= 8 and size % 8 == 0 and cursor + size <= end, "macho")
        raw = data[cursor : cursor + size]
        if kind == 0x1D:
            require(signature is None and size == 16 and index == header[4] - 1, "macho_signature")
            signature = struct.unpack_from("<II", raw, 8)
        elif kind == 0x19:
            require(size >= 72, "macho")
            fields = struct.unpack_from("<II16sQQQQIIII", raw)
            require(size == 72 + 80 * fields[9], "macho")
            name = fields[2].split(b"\0")[0]
            if name == b"__LINKEDIT":
                require(
                    link is None and fields[9] == 0 and fields[5] + fields[6] == len(data),
                    "macho_linkedit",
                )
                link = (fields[5], fields[6], fields[4])
                normal = bytearray(raw)
                normal[32:40] = bytes(8)
                normal[48:56] = bytes(8)
                raw = bytes(normal)
            else:
                require(fields[5] + fields[6] <= len(data), "macho")
                for section in range(fields[9]):
                    row = struct.unpack_from("<16s16sQQIIIIIIII", raw, 72 + 80 * section)
                    # Zero-fill sections have no physical file payload.
                    if row[8] & 0xFF not in (1, 12, 18) and row[3]:
                        require(end <= row[4] and row[4] + row[3] <= len(data), "macho_section")
                        sections.append(row[4])
        commands.append((kind, raw))
        cursor += size
    require(cursor == end and link is not None and sections, "macho")
    first = min(sections)
    require(end <= first and not any(data[end:first]), "macho_padding")
    if signature:
        offset, length = signature
        require(
            link[0] <= offset and length > 0 and offset + length == len(data), "macho_signature"
        )
        require(data[offset : offset + 4] == bytes.fromhex("fade0cc0"), "macho_signature")
    return header, tuple(raw for kind, raw in commands if kind != 0x1D), signature, end, first, link


def layout_unchanged(original, signed):
    left, right = _slices(original), _slices(signed)
    require(tuple(r[:3] for r in left) == tuple(r[:3] for r in right), "macho_architecture")
    for old, new in zip(left, right, strict=True):
        a, b = _thin(old[3], *old[:2]), _thin(new[3], *new[:2])
        require(b[2] is not None, "macho_signature")
        require(a[0][:4] + a[0][6:] == b[0][:4] + b[0][6:] and a[1] == b[1], "macho_commands")
        old_end = a[2][0] if a[2] else len(old[3])
        new_end = b[2][0]
        require(
            old_end <= new_end
            and a[4] == b[4]
            and new[3][max(a[3], b[3]) : old_end] == old[3][max(a[3], b[3]) : old_end],
            "macho_content",
        )
        require(0 <= new_end - old_end <= 15 and not any(new[3][old_end:new_end]), "macho_content")
        page = 4096 if old[0] == 0x1000007 else 16384
        rounded = (b[5][1] + page - 1) // page * page
        require(b[5][2] == rounded or (b[5][2] == a[5][2] and a[5][2] >= b[5][1]), "macho_linkedit")
        # An added signature command may consume only old header padding.
        require(
            a[3] <= b[3] and not any(old[3][a[3] : b[3]]) if not a[2] else a[3] == b[3],
            "macho_commands",
        )
    return ("x86_64", "arm64")


def _inventory(root):
    ancestors = F._ancestors(root)
    result, directories = {}, []
    pending = [root]
    directories_seen = 1
    while pending:
        parent = pending.pop()
        directories.append((parent, F._stamp(parent.lstat())))
        # Consume and qualify one real entry at a time. Never os.walk/list/sort
        # a potentially unbounded native directory before applying its cap.
        with os.scandir(parent) as entries:
            for entry in entries:
                path = parent / entry.name
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode):
                    require(
                        directories_seen < 256 and stat.S_IMODE(info.st_mode) == 0o755, "inventory"
                    )
                    directories_seen += 1
                    pending.append(path)
                    continue
                require(len(result) < 256, "inventory")
                held = F.ordinary(path)
                relative = str(path.relative_to(root))
                mode = held.identity[3]
                require(mode in (0o644, 0o755), "inventory")
                if mode == 0o755 or held.data[:4] in (
                    bytes.fromhex("cafebabe"),
                    bytes.fromhex("cffaedfe"),
                ):
                    require(relative in PRIMARY, "secondary_executable")
                result[relative] = held
    require(set(PRIMARY) <= set(result), "inventory")
    return result, tuple(directories), ancestors


def observe(repository, owner, public_leaf, captures):
    require(sys.platform == "darwin", "platform")
    repository, owner, public_leaf, captures = map(Path, (repository, owner, public_leaf, captures))
    require(captures.parent == owner.parent and captures != owner, "capture_owner")
    capture_ancestors = F._ancestors(captures)
    require(
        not any(captures.iterdir()) and stat.S_IMODE(captures.lstat().st_mode) == 0o700,
        "capture_owner",
    )
    deadline = time.monotonic() + 30
    builder_source = F.ordinary(
        repository / "tools/build/remap_runtime_build.py", limit=1024 * 1024
    )
    require(hashlib.sha256(builder_source.data).hexdigest() == BUILDER_SHA256, "source")
    source = F.ordinary(Path(__file__).resolve(), limit=1024 * 1024)
    fixture = F.ordinary(_path, limit=1024 * 1024)
    spec = importlib.util.spec_from_file_location("signed_observer_builder", builder_source.path)
    builder = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = builder
    exec(compile(builder_source.data, str(builder_source.path), "exec"), builder.__dict__)
    factory = builder._source_factory()
    dependencies = factory.capture_dependencies(
        repository, deadline
    ) + factory.capture_vhd_dependencies(repository, deadline)
    metadata = F.ordinary(owner / "owned-native-build-result.json", 0o600, 2 * 1024 * 1024)
    builder.validate_current_owned_record(builder.parse_json(metadata.data))
    leaf = F.ordinary(public_leaf, 0o644, 1024 * 1024)
    identity = hashlib.sha1(leaf.data).hexdigest().upper()
    unsigned = owner / ".unsigned-runtime-preparation"
    signed = owner / ".signed-runtime-preparation"
    original, old_dirs, old_ancestors = _inventory(unsigned)
    actual, new_dirs, new_ancestors = _inventory(signed)
    require(
        set(original).isdisjoint(RESOURCE_ADDITIONS)
        and set(actual) == set(original) | RESOURCE_ADDITIONS,
        "inventory",
    )
    for relative, held in original.items():
        require(actual[relative].identity[3] == held.identity[3], "mode")
        if relative in PRIMARY:
            layout_unchanged(held.data, actual[relative].data)
        else:
            require(actual[relative].data == held.data, "resource_content")
    # Snapshot native tools themselves. No command endpoints accepted from callers.
    tools = tuple(
        F.ordinary(Path(path), owned=False)
        for path in ("/usr/bin/codesign", "/usr/bin/lipo", "/usr/bin/otool")
    )
    # Native sealed files may have multiple hard links; ordinary conservative refusal is intentional.
    retained = (
        (builder_source, source, fixture, metadata, leaf)
        + tuple(original.values())
        + tuple(actual.values())
        + tools
    )

    def guard():
        F.remaining(deadline)
        F._current_ancestors(capture_ancestors)
        for item in retained:
            F.current(item)
        for root, dirs, ancestors in (
            (unsigned, old_dirs, old_ancestors),
            (signed, new_dirs, new_ancestors),
        ):
            F._current_ancestors(ancestors)
            for directory, stamp in dirs:
                require(F._stamp(directory.lstat()) == stamp, "inventory_changed")
        require(
            set(_inventory(unsigned)[0]) == set(original)
            and set(_inventory(signed)[0]) == set(actual),
            "inventory_changed",
        )
        fresh = factory.capture_dependencies(
            repository, deadline
        ) + factory.capture_vhd_dependencies(repository, deadline)
        require(fresh == dependencies, "source_changed")

    def command(args):
        require(args[0] in ("/usr/bin/codesign", "/usr/bin/lipo", "/usr/bin/otool"), "command")
        guard()
        try:
            result = subprocess.run(
                args,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=F.remaining(deadline),
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as e:
            raise FixtureRefusal("native_command") from e
        guard()
        require(
            result.returncode == 0 and len(result.stdout) + len(result.stderr) <= 2 * 1024 * 1024,
            "native_command",
        )
        return result.stdout, result.stderr

    for index, (relative, identifier) in enumerate(TARGETS):
        path = signed / relative
        requirement = 'identifier "' + identifier + '" and certificate leaf = H"' + identity + '"'
        command(
            [
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                "--all-architectures",
                "-R",
                "=" + requirement,
                str(path),
            ]
        )
        primary = (
            relative
            if relative in PRIMARY
            else next(p for p in PRIMARY if p.startswith(relative + "/"))
        )
        out, err = command(["/usr/bin/lipo", "-archs", str(signed / primary)])
        require(
            set(out.decode("ascii", "strict").split()) == {"x86_64", "arm64"}
            and len(out.split()) == 2,
            "architectures",
        )
        for architecture in ("x86_64", "arm64"):
            out, err = command(
                ["/usr/bin/otool", "-arch", architecture, "-l", str(signed / primary)]
            )
            require(
                b"LC_CODE_SIGNATURE" in out and b"__LINKEDIT" in out and b"__TEXT" in out,
                "native_layout",
            )
            out, err = command(
                ["/usr/bin/codesign", "-d", "-r-", "--architecture", architecture, str(path)]
            )
            require_identifier(out + err, identifier, identity)
            prefix = captures / (str(index) + "_" + architecture + "_leaf_")
            command(
                [
                    "/usr/bin/codesign",
                    "--display",
                    "--extract-certificates",
                    str(prefix),
                    "--architecture",
                    architecture,
                    str(path),
                ]
            )
            expected = prefix.with_name(prefix.name + "0")
            extracted = F.ordinary(expected, limit=1024 * 1024)
            require_leaf(extracted.data, leaf.data)
            require(not os.path.lexists(prefix.with_name(prefix.name + "1")), "leaf_chain")
            retained += (extracted,)
    guard()
    return {
        "schema": 1,
        "status": "observed",
        "test_only": True,
        "identity": identity,
        "targets": 5,
        "architectures": ["x86_64", "arm64"],
        "shipping_qualified": False,
        "installation_qualified": False,
        "authentication_qualified": False,
    }


def main(args):
    try:
        require(len(args) == 4, "arguments")
        print(__import__("json").dumps(observe(*args), sort_keys=True))
        return 0
    except (FixtureRefusal, OSError, ValueError, RuntimeError):
        print("Native signed runtime observation refused", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
