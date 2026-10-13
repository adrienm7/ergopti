# tools/build/remap_runtime_macho.py
"""Bounded comparison of the retained Mach-O signing shapes.

This proves byte preservation, not CMS trust. Native strict/all-architecture
verification against the fixed leaf designated requirement remains mandatory.
Unsupported formats, commands, or allocation changes fail closed.
"""

from dataclasses import dataclass
import math
import struct
import time


MAX_FILE = 128 * 1024 * 1024
MAX_SIGNATURE = 2 * 1024 * 1024
MAX_COMMANDS = 128
_CPUS = {0x01000007: "x86_64", 0x0100000C: "arm64"}
_COMMANDS = {
    0x19,
    0x1B,
    0x1D,
    0x2,
    0x26,
    0x29,
    0x2A,
    0x32,
    0x80000018,
    0x8000001C,
    0x80000028,
    0x80000033,
    0x80000034,
    0xB,
    0xC,
    0xE,
}
_LINK_DATA = {0x26, 0x29, 0x80000033, 0x80000034}


class MachORefusal(ValueError):
    """Stable fail-closed category, without attacker-controlled diagnostics."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


def _require(condition, code):
    if not condition:
        raise MachORefusal(code)


def _tick(deadline):
    _require(time.monotonic() < deadline, "deadline")


def _extent(offset, size, limit):
    _require(0 <= offset <= limit and 0 <= size <= limit - offset, "bounds")


def _zero(data, start, end, deadline):
    _extent(start, end - start, len(data))
    for offset in range(start, end, 65536):
        _tick(deadline)
        _require(not any(data[offset : min(offset + 65536, end)]), "shape")


def _equal(left, right, start, end, deadline):
    for offset in range(start, end, 65536):
        _tick(deadline)
        stop = min(offset + 65536, end)
        _require(left[offset:stop] == right[offset:stop], "content")


@dataclass(frozen=True)
class _Thin:
    data: memoryview
    cpu: int
    subtype: int
    alignment: int | None
    commands: tuple
    commands_end: int
    link_command: int
    link_size: int
    link_vm: int
    signature: tuple | None
    payload_end: int


def _signature(data, offset, size, signed, deadline):
    _extent(offset, size, len(data))
    _require(12 <= size <= MAX_SIGNATURE, "bounds")
    magic, length, count = struct.unpack_from(">III", data, offset)
    _require(magic == 0xFADE0CC0, "signature")
    _require(12 <= length <= size and count <= 32, "bounds")
    table_end = 12 + count * 8
    _extent(0, table_end, length)
    _require(size - length <= 15, "signature")
    _zero(data, offset + length, offset + size, deadline)
    slots, ranges = {}, []
    known = {0, 2, 5, 7, 0x10000} | set(range(0x1000, 0x1006))
    for index in range(count):
        _tick(deadline)
        slot, relative = struct.unpack_from(">II", data, offset + 12 + index * 8)
        _require(slot in known and slot not in slots, "signature")
        _require(relative >= table_end, "bounds")
        _extent(relative, 8, length)
        blob_magic, blob_length = struct.unpack_from(">II", data, offset + relative)
        _require(blob_length >= 8, "bounds")
        _extent(relative, blob_length, length)
        slots[slot] = (relative, blob_length, blob_magic)
        ranges.append((relative, relative + blob_length))
    previous = table_end
    for start, end in sorted(ranges):
        _tick(deadline)
        _require(start >= previous, "bounds")
        previous = end
    _require(0 in slots, "signature")
    for slot, (relative, blob_length, blob_magic) in slots.items():
        _tick(deadline)
        if slot == 0 or 0x1000 <= slot <= 0x1005:
            _require(blob_magic == 0xFADE0C02 and blob_length >= 44, "signature")
            base = offset + relative
            fields = struct.unpack_from(">9I4BI", data, base)
            version, flags, hashes, identifier, special, pages, limit = fields[2:9]
            hash_size, hash_type, platform, page_shift = fields[9:13]
            _require(0x20001 <= version <= 0x20600, "signature")
            _require(bool(flags & 2) != signed, "signature")
            _require(limit == offset and page_shift <= 16, "signature")
            _require((hash_type, hash_size) in {(1, 20), (2, 32), (3, 20), (4, 48)}, "signature")
            _require(platform <= 14, "signature")
            _require(pages == (limit + (1 << page_shift) - 1) // (1 << page_shift), "signature")
            _extent(hashes, pages * hash_size, blob_length)
            _require(hashes >= special * hash_size + 44, "bounds")
            hash_start = hashes - special * hash_size
            _require(44 <= identifier < hash_start, "bounds")
            _require(0 in data[base + identifier : base + hash_start], "signature")
        else:
            expected = {2: 0xFADE0C01, 5: 0xFADE7171, 7: 0xFADE7172, 0x10000: 0xFADE0B01}
            _require(blob_magic == expected[slot] and blob_length > 8, "signature")
    if signed:
        _require(2 in slots and 0x10000 in slots, "signature")
    else:
        _require(set(slots) == {0}, "signature")


def _command_shape(data, position, command, size, deadline):
    fixed = {0x1B: 24, 0x1D: 16, 0x2: 24, 0xB: 80, 0x2A: 16, 0x80000028: 24}
    if command in fixed or command in _LINK_DATA:
        _require(size == fixed.get(command, 16), "shape")
    elif command == 0x32:
        _require(size >= 24, "bounds")
        tools = struct.unpack_from("<I", data, position + 20)[0]
        _require(tools <= 128 and size == 24 + tools * 8, "bounds")
    elif command in {0xC, 0x80000018, 0xE, 0x8000001C}:
        minimum = 24 if command in {0xC, 0x80000018} else 12
        _require(size >= minimum, "bounds")
        string = struct.unpack_from("<I", data, position + 8)[0]
        _require(minimum <= string < size, "bounds")
        _require(0 in data[position + string : position + size], "shape")
    elif command == 0x19:
        _require(size >= 72, "bounds")
        sections = struct.unpack_from("<I", data, position + 64)[0]
        _require(sections <= 128 and size == 72 + sections * 80, "bounds")
        for index in range(sections):
            _tick(deadline)
            section = position + 72 + index * 80
            length, offset, alignment = struct.unpack_from("<QII", data, section + 40)
            flags = struct.unpack_from("<I", data, section + 64)[0]
            _require(alignment <= 30, "bounds")
            if flags & 0xFF not in {1, 0xC, 0x12}:
                _extent(offset, length, len(data))


def _thin(data, alignment, deadline):
    _tick(deadline)
    _require(len(data) >= 32 and data[:4] == b"\xcf\xfa\xed\xfe", "shape")
    _, cpu, subtype, filetype, count, total, _, _ = struct.unpack_from("<8I", data)
    _require(cpu in _CPUS and filetype == 2, "shape")
    _require(0 < count <= MAX_COMMANDS and total <= MAX_FILE, "bounds")
    _extent(32, total, len(data))
    commands_end = 32 + total
    position, commands, link, signature, segments = 32, [], None, None, []
    for index in range(count):
        _tick(deadline)
        _extent(position, 8, commands_end)
        command, size = struct.unpack_from("<II", data, position)
        _require(size >= 8 and size % 8 == 0, "bounds")
        _extent(position, size, commands_end)
        _require(command in _COMMANDS, "shape")
        _command_shape(data, position, command, size, deadline)
        if command == 0x19:
            name = bytes(data[position + 8 : position + 24]).rstrip(b"\0")
            vm, vm_size, file_offset, file_size, maxprot, initprot, sections, _ = (
                struct.unpack_from("<4Q4I", data, position + 24)
            )
            _extent(file_offset, file_size, len(data))
            _require(vm + vm_size < 1 << 64 and vm_size >= file_size, "bounds")
            if file_size:
                segments.append((file_offset, file_offset + file_size))
            if name == b"__LINKEDIT":
                _require(link is None and sections == 0, "shape")
                _require(not (maxprot & 4 or initprot & 4), "shape")
                _require(
                    file_offset >= commands_end and file_offset + file_size == len(data), "shape"
                )
                link = (position, file_offset, file_size, vm_size)
        elif command == 0x1D:
            _require(signature is None and index == count - 1, "shape")
            offset, length = struct.unpack_from("<II", data, position + 8)
            _extent(offset, length, len(data))
            _require(0 < length <= MAX_SIGNATURE, "bounds")
            _require(offset >= commands_end and offset + length == len(data), "shape")
            signature = (position, offset, length)
        commands.append((command, position, size))
        position += size
    _require(position == commands_end and link is not None, "shape")
    previous = 0
    for start, end in sorted(segments):
        _tick(deadline)
        _require(start >= previous, "shape")
        previous = end
    link_position, link_offset, link_size, link_vm = link
    payload_end = signature[1] if signature else len(data)
    _require(link_offset <= payload_end, "shape")
    return _Thin(
        data,
        cpu,
        subtype,
        alignment,
        tuple(commands),
        commands_end,
        link_position,
        link_size,
        link_vm,
        signature,
        payload_end,
    )


def _images(image, deadline):
    _tick(deadline)
    _require(isinstance(image, bytes) and 4 <= len(image) <= MAX_FILE, "shape")
    data = memoryview(image)
    if data[:4] == b"\xcf\xfa\xed\xfe":
        return (_thin(data, None, deadline),)
    _require(data[:4] == b"\xca\xfe\xba\xbe" and len(data) >= 8, "shape")
    count = struct.unpack_from(">I", data, 4)[0]
    _require(0 < count <= 2, "bounds")
    _extent(8, count * 20, len(data))
    previous, seen, result = 8 + count * 20, set(), []
    for index in range(count):
        _tick(deadline)
        cpu, subtype, offset, size, alignment = struct.unpack_from(">5I", data, 8 + index * 20)
        _require(cpu in _CPUS and cpu not in seen, "shape")
        _require(alignment <= 24, "bounds")
        unit = 1 << alignment
        _require(offset == (previous + unit - 1) // unit * unit, "shape")
        _extent(offset, size, len(data))
        _zero(data, previous, offset, deadline)
        thin = _thin(data[offset : offset + size], alignment, deadline)
        _require((thin.cpu, thin.subtype) == (cpu, subtype), "shape")
        result.append(thin)
        seen.add(cpu)
        previous = offset + size
    _require(previous == len(data), "shape")
    return tuple(result)


def _compare(original, signed, deadline):
    _require(
        (original.cpu, original.subtype, original.alignment)
        == (signed.cpu, signed.subtype, signed.alignment),
        "content",
    )
    _require(signed.signature is not None, "signature")
    if original.signature:
        _require(original.cpu == 0x0100000C, "shape")
        _signature(original.data, original.signature[1], original.signature[2], False, deadline)
    _signature(signed.data, signed.signature[1], signed.signature[2], True, deadline)
    before = [item for item in original.commands if item[0] != 0x1D]
    after = [item for item in signed.commands if item[0] != 0x1D]
    _require(len(before) == len(after), "content")
    exclusions = [(16, 24)]
    for left, right in zip(before, after, strict=True):
        _tick(deadline)
        _require(left == right, "content")
        command, position, size = left
        if position == original.link_command:
            _require(position == signed.link_command, "content")
            exclusions.extend([(position + 32, position + 40), (position + 48, position + 56)])
        else:
            _equal(original.data, signed.data, position, position + size, deadline)
    page = 4096 if original.cpu == 0x01000007 else 16384
    rounded = (signed.link_size + page - 1) // page * page
    _require(
        signed.link_vm == rounded
        or (signed.link_vm == original.link_vm and original.link_vm >= signed.link_size),
        "shape",
    )
    _require(0 <= signed.payload_end - original.payload_end <= 15, "shape")
    _zero(signed.data, original.payload_end, signed.payload_end, deadline)
    if original.signature:
        _require(
            original.signature[0] == signed.signature[0]
            and original.commands_end == signed.commands_end,
            "content",
        )
        exclusions.append((original.signature[0], original.signature[0] + 16))
    else:
        _require(
            signed.commands_end == original.commands_end + 16
            and signed.signature[0] == original.commands_end,
            "content",
        )
        _zero(original.data, original.commands_end, signed.commands_end, deadline)
        exclusions.append((original.commands_end, signed.commands_end))
    previous = 0
    for start, end in sorted(exclusions):
        _equal(original.data, signed.data, previous, start, deadline)
        previous = end
    _equal(original.data, signed.data, previous, original.payload_end, deadline)


def compare_macho(original, signed, deadline):
    """Return ordered architecture names only for a preserved signing transform."""
    _require(type(deadline) in {int, float}, "deadline")
    if isinstance(deadline, float):
        _require(math.isfinite(deadline), "deadline")
    _tick(deadline)
    before = _images(original, deadline)
    after = _images(signed, deadline)
    _require(len(before) == len(after), "content")
    for left, right in zip(before, after, strict=True):
        _tick(deadline)
        _compare(left, right, deadline)
    _tick(deadline)
    return tuple(_CPUS[item.cpu] for item in before)
