# tools/build/remap_runtime_signing_fixture.py
"""Handwritten byte layouts, independent of the signing parser and native commands."""

import struct

X86 = 0x01000007
ARM = 0x0100000C
LEAF = b"\x30\x03\x02\x01\x07"  # Modeled DER only; not a real certificate.
IDENTITY = "C0D2E618BB15C1A7F45AEB9FD6E99C822AF82E73"
TEXT_OFFSET = 512
LINKEDIT_OFFSET = 1024
SIGNATURE_OFFSET = 1152


def signature(*, adhoc=False):
    """Finite independent SuperBlob structure; the CMS/requirements are modeled."""
    identifier = b"modeled.original\0"
    directory = struct.pack(
        ">9I4BI",
        0xFADE0C02,
        44 + len(identifier) + 32,
        0x20400,
        2 if adhoc else 0,
        44 + len(identifier),
        44,
        0,
        1,
        SIGNATURE_OFFSET,
        32,
        2,
        0,
        12,
        0,
    )
    directory += identifier + bytes(range(32))
    blobs = [(0, directory)]
    if not adhoc:
        for slot, magic, content in (
            (2, 0xFADE0C01, b"MODELED REQUIREMENT"),
            (0x10000, 0xFADE0B01, b"MODELED CMS"),
        ):
            blobs.append((slot, struct.pack(">II", magic, 8 + len(content)) + content))
    offset = 12 + len(blobs) * 8
    indices, payload = b"", b""
    for slot, blob in blobs:
        indices += struct.pack(">II", slot, offset)
        offset += len(blob)
        payload += blob
    result = struct.pack(">III", 0xFADE0CC0, offset, len(blobs)) + indices + payload
    return result + b"\0" * (-len(result) % 16)


def thin(cpu=X86, *, signed=False, original_adhoc=False, code=b"ORIGINAL EXECUTABLE CONTENT"):
    """Declared header/section offsets and immutable non-signing payload bytes."""
    if len(code) > 512:
        raise ValueError("Fixed text region exceeded")
    signed_blob = signature(adhoc=original_adhoc) if signed or original_adhoc else b""
    file_size = SIGNATURE_OFFSET + len(signed_blob)
    page = 4096 if cpu == X86 else 16384
    link_size = file_size - LINKEDIT_OFFSET
    link_vm = (link_size + page - 1) // page * page
    segment = struct.pack(
        "<II16sQQQQIIII",
        0x19,
        152,
        b"__TEXT",
        0x100000000,
        page,
        0,
        LINKEDIT_OFFSET,
        5,
        5,
        1,
        0,
    )
    section = struct.pack(
        "<16s16sQQIIIIIIII",
        b"__text",
        b"__TEXT",
        0x100000000 + TEXT_OFFSET,
        512,
        TEXT_OFFSET,
        4,
        0,
        0,
        0x80000400,
        0,
        0,
        0,
    )
    link = struct.pack(
        "<II16sQQQQIIII",
        0x19,
        72,
        b"__LINKEDIT",
        0x100000000 + page,
        link_vm,
        LINKEDIT_OFFSET,
        link_size,
        1,
        1,
        0,
        0,
    )
    commands = segment + section + link
    if signed_blob:
        commands += struct.pack("<IIII", 0x1D, 16, SIGNATURE_OFFSET, len(signed_blob))
    header = struct.pack(
        "<IIIIIIII",
        0xFEEDFACF,
        cpu,
        3 if cpu == X86 else 0,
        2,
        3 if signed_blob else 2,
        len(commands),
        0x200085,
        0,
    )
    prefix = header + commands
    prefix += b"\0" * (TEXT_OFFSET - len(prefix))
    prefix += code + b"\0" * (512 - len(code))
    prefix += b"LINKEDIT ORIGINAL CONTENT" + b"\0" * (128 - 25)
    return prefix + signed_blob


def universal(*, signed=False, code=b"ORIGINAL EXECUTABLE CONTENT"):
    """FAT32 two fixed architecture descriptors, minimal zero-filled alignment."""
    slices = (
        thin(X86, signed=signed, code=code),
        thin(ARM, signed=signed, original_adhoc=not signed, code=code),
    )
    payload, entries, previous = bytearray(), [], 48
    for cpu, subtype, alignment, data in (
        (X86, 3, 12, slices[0]),
        (ARM, 0, 14, slices[1]),
    ):
        offset = (previous + (1 << alignment) - 1) // (1 << alignment) * (1 << alignment)
        entries.append(struct.pack(">IIIII", cpu, subtype, offset, len(data), alignment))
        if len(payload) < offset:
            payload.extend(b"\0" * (offset - len(payload)))
        payload.extend(data)
        previous = offset + len(data)
    payload[:48] = struct.pack(">II", 0xCAFEBABE, 2) + b"".join(entries)
    return bytes(payload)
