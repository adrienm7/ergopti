# tools/build/remap_runtime_macho_test.py
"""Frozen independent signing transformations; no native compiler/signature proof."""

import importlib.util
from pathlib import Path
import struct
import sys
import time
import unittest

HERE = Path(__file__).parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


FIXTURE = load("independent_signing_layouts", HERE / "remap_runtime_signing_fixture.py")
SUBJECT = load("bounded_signing_macho", HERE / "remap_runtime_macho.py")


class SigningImageControls(unittest.TestCase):
    def deadline(self):
        return time.monotonic() + 30

    def compare(self, original=None, signed=None):
        if original is None:
            original = FIXTURE.universal()
        if signed is None:
            signed = FIXTURE.universal(signed=True)
        return SUBJECT.compare_macho(original, signed, self.deadline())

    def refuse(self, original, signed, code):
        with self.assertRaises(SUBJECT.MachORefusal) as caught:
            self.compare(original, signed)
        self.assertEqual(caught.exception.code, code)

    def alter(self, data, offset, value):
        result = bytearray(data)
        result[offset : offset + len(value)] = value
        return bytes(result)

    def test_independent_hand_layout_offsets_are_literal(self):
        image = FIXTURE.thin()
        self.assertEqual(len(image), 1152)
        self.assertEqual(image[:4], b"\xcf\xfa\xed\xfe")
        self.assertEqual(struct.unpack_from("<II", image, 16), (2, 224))
        self.assertEqual(struct.unpack_from("<I", image, 224), (1024,))
        self.assertEqual(image[512:539], b"ORIGINAL EXECUTABLE CONTENT")
        self.assertEqual(image[1024:1049], b"LINKEDIT ORIGINAL CONTENT")

    def test_exact_universal_unsigned_to_signed_preserves_both_architectures(self):
        self.assertEqual(self.compare(), ("x86_64", "arm64"))

    def test_thin_x86_added_signature_is_supported(self):
        self.assertEqual(self.compare(FIXTURE.thin(), FIXTURE.thin(signed=True)), ("x86_64",))

    def test_thin_arm_original_adhoc_signature_is_preserved_semantically(self):
        self.assertEqual(
            self.compare(
                FIXTURE.thin(FIXTURE.ARM, original_adhoc=True),
                FIXTURE.thin(FIXTURE.ARM, signed=True),
            ),
            ("arm64",),
        )

    def test_external_native_verify_success_cannot_admit_substituted_executable(self):
        self.refuse(
            FIXTURE.universal(),
            FIXTURE.universal(signed=True, code=b"FOREIGN CODE"),
            "content",
        )

    def test_header_identity_change_refuses(self):
        self.refuse(
            FIXTURE.thin(),
            self.alter(FIXTURE.thin(signed=True), 24, struct.pack("<I", 0)),
            "content",
        )

    def test_non_signing_load_command_change_refuses(self):
        self.refuse(
            FIXTURE.thin(),
            self.alter(FIXTURE.thin(signed=True), 88, struct.pack("<I", 7)),
            "content",
        )

    def test_text_padding_change_refuses(self):
        self.refuse(FIXTURE.thin(), self.alter(FIXTURE.thin(signed=True), 400, b"X"), "content")

    def test_linkedit_content_change_refuses(self):
        self.refuse(FIXTURE.thin(), self.alter(FIXTURE.thin(signed=True), 1100, b"X"), "content")

    def test_signature_must_be_terminal_and_bounded(self):
        original, signed = FIXTURE.thin(), FIXTURE.thin(signed=True)
        self.refuse(original, signed + b"foreign", "shape")
        self.refuse(original, self.alter(signed, 268, struct.pack("<I", 2**32 - 1)), "bounds")

    def test_signed_adhoc_and_missing_cms_refuse(self):
        self.refuse(FIXTURE.thin(), FIXTURE.thin(original_adhoc=True), "signature")

    def test_malformed_signature_indices_refuse_before_payload_access(self):
        signed = FIXTURE.thin(signed=True)
        self.refuse(
            FIXTURE.thin(),
            self.alter(signed, 1160, struct.pack(">I", 2**32 - 1)),
            "bounds",
        )

    def test_bad_superblob_magic_refuses(self):
        self.refuse(
            FIXTURE.thin(),
            self.alter(FIXTURE.thin(signed=True), 1152, b"BAD!"),
            "signature",
        )

    def test_unknown_load_command_refuses(self):
        self.refuse(
            FIXTURE.thin(),
            self.alter(FIXTURE.thin(signed=True), 32, struct.pack("<I", 0x7777)),
            "shape",
        )

    def test_zero_command_size_refuses_without_loop(self):
        self.refuse(
            FIXTURE.thin(),
            self.alter(FIXTURE.thin(signed=True), 36, struct.pack("<I", 0)),
            "bounds",
        )

    def test_declared_command_count_and_size_are_bounded(self):
        signed = FIXTURE.thin(signed=True)
        self.refuse(
            FIXTURE.thin(),
            self.alter(signed, 16, struct.pack("<I", 2**32 - 1)),
            "bounds",
        )
        self.refuse(
            FIXTURE.thin(),
            self.alter(signed, 20, struct.pack("<I", 2**32 - 1)),
            "bounds",
        )

    def test_missing_or_duplicate_architectures_refuse(self):
        signed = FIXTURE.universal(signed=True)
        self.refuse(FIXTURE.universal(), FIXTURE.thin(signed=True), "content")
        self.refuse(
            FIXTURE.universal(),
            self.alter(signed, 28, struct.pack(">I", FIXTURE.X86)),
            "shape",
        )

    def test_foreign_fat_padding_refuses(self):
        self.refuse(
            FIXTURE.universal(),
            self.alter(FIXTURE.universal(signed=True), 100, b"X"),
            "shape",
        )

    def test_overlapping_fat_slices_refuse(self):
        self.refuse(
            FIXTURE.universal(),
            self.alter(FIXTURE.universal(signed=True), 36, struct.pack(">I", 4096)),
            "shape",
        )

    def test_unsupported_cpu_and_format_refuse(self):
        self.refuse(
            FIXTURE.thin(),
            self.alter(FIXTURE.thin(signed=True), 4, struct.pack("<I", 12)),
            "shape",
        )
        self.refuse(FIXTURE.thin(), b"\xca\xfe\xba\xbf" + bytes(64), "shape")

    def test_linkedit_execute_protection_refuses(self):
        self.refuse(
            FIXTURE.thin(),
            self.alter(FIXTURE.thin(signed=True), 244, struct.pack("<I", 5)),
            "shape",
        )

    def test_linkedit_unnecessary_vm_growth_refuses(self):
        self.refuse(
            FIXTURE.thin(),
            self.alter(FIXTURE.thin(signed=True), 216, struct.pack("<Q", 2**30)),
            "shape",
        )

    def test_image_extent_refuses_before_scan(self):
        with self.assertRaises(SUBJECT.MachORefusal) as caught:
            SUBJECT.compare_macho(b"x", b"y", self.deadline())
        self.assertEqual(caught.exception.code, "shape")

    def test_deadline_is_not_reset(self):
        with self.assertRaises(SUBJECT.MachORefusal) as caught:
            SUBJECT.compare_macho(FIXTURE.thin(), FIXTURE.thin(signed=True), time.monotonic() - 1)
        self.assertEqual(caught.exception.code, "deadline")


if __name__ == "__main__":
    unittest.main()
