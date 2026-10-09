# tools/diagnostics/pkgutil_capability_fixture_test.py
"""Focused modeled leaves; these controls do not prove Darwin tool capability."""

import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "capability", Path(__file__).with_name("pkgutil_capability_fixture.py")
)
SUBJECT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUBJECT)

# Independently handwritten model inputs and expectations, not imported from the
# generator. Only real Darwin execution can qualify the actual package format.
MARKER = b"Ergopti pkgutil capability fixture\n"
PACKAGE = b"xar!" + b"model inert package, not a real Darwin fixture" * 2


class CapabilityControls(unittest.TestCase):
    def setUp(self):
        self.previous_umask = os.umask(0o022)
        self.temporary = tempfile.TemporaryDirectory()
        self.owner = Path(self.temporary.name).resolve(strict=True)
        self.reference = SUBJECT.reference()
        self.calls = []
        self.effect = lambda _phase: None
        self.stage = ["entry"]

    def tearDown(self):
        try:
            self.temporary.cleanup()
        finally:
            os.umask(self.previous_umask)

    def native(self, arguments, _deadline):
        self.calls.append(arguments)
        if "--root" in arguments:
            source = Path(arguments[arguments.index("--root") + 1])
            self.assertEqual((source / "ergopti-capability.txt").read_bytes(), MARKER)
            self.assertEqual(set(p.name for p in source.iterdir()), {"ergopti-capability.txt"})
            Path(arguments[-1]).write_bytes(PACKAGE)
            self.effect("generate")
        elif Path(arguments[-2]).name == "positive.pkg":
            output = Path(arguments[-1])
            output.mkdir(mode=0o755)
            (output / "Bom").write_bytes(b"independent model metadata")
            (output / "PackageInfo").write_bytes(b"independent model metadata")
            (output / "Payload").mkdir(mode=0o755)
            (output / "Payload" / "ergopti-capability.txt").write_bytes(MARKER)
            for name in ["Bom", "PackageInfo", "Payload/ergopti-capability.txt"]:
                (output / name).chmod(0o644)
            (output / "Payload").chmod(0o755)
            self.effect("positive")
        else:
            self.effect("negative")
            raise self.reference.Refusal("native_status")
        return subprocess.CompletedProcess(arguments, 0, b"", b"")

    def execute(self, native=None):
        real_capture = SUBJECT.captured

        def modeled_tool_capture(path, maximum):
            body, identity = real_capture(path, maximum)
            if path == Path("/usr/bin/true"):
                # Only the native tool leaf is modeled: some Linux containers
                # expose their system binaries as user-owned. Never weaken the
                # production root-owner check to accommodate this test host.
                identity = identity[:3] + (0,) + identity[4:]
            return body, identity

        with (
            patch.object(SUBJECT.sys, "platform", "darwin"),
            patch.object(
                SUBJECT,
                "TOOLS",
                {"pkgbuild": Path("/usr/bin/true"), "pkgutil": Path("/usr/bin/true")},
            ),
            patch.object(SUBJECT, "captured", modeled_tool_capture),
            patch.object(self.reference, "native", native or self.native),
        ):
            return SUBJECT.prepare(self.owner, time.monotonic() + 25, self.reference, self.stage)

    def test_modeled_positive_and_negative_preserve_exact_inputs_and_one_generation(self):
        packet = self.execute()
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(sum("--root" in call for call in self.calls), 1)
        self.assertEqual(packet["package_generation_count"], 1)
        self.assertEqual(base64.b64decode(packet["packages"]["positive.pkg"]["base64"]), PACKAGE)
        self.assertEqual(
            base64.b64decode(packet["packages"]["corrupt-header.pkg"]["base64"]),
            b"BAD!" + PACKAGE[4:],
        )
        self.assertEqual(base64.b64decode(packet["expected_marker_base64"]), MARKER)
        self.assertLessEqual(len(json.dumps(packet).encode()), 65536)
        for key in ("installation_qualified", "reference_qualified", "runtime_qualified"):
            self.assertIs(packet[key], False)

    def test_changed_payload_marker_cannot_pass(self):
        def changed_marker():
            (self.owner / "expanded-positive/Payload/ergopti-capability.txt").write_bytes(b"wrong")

        self.effect = lambda phase: changed_marker() if phase == "positive" else None
        with self.assertRaisesRegex(SUBJECT.Refusal, "expanded_marker"):
            self.execute()
        self.assertEqual(len(self.calls), 2)

    def test_compressed_payload_without_expanded_marker_cannot_pass(self):
        def compressed():
            payload = self.owner / "expanded-positive/Payload"
            (payload / "ergopti-capability.txt").unlink()
            payload.rmdir()
            payload.write_bytes(b"compressed bytes are not an expanded payload")

        self.effect = lambda phase: compressed() if phase == "positive" else None
        with self.assertRaisesRegex(SUBJECT.Refusal, "expanded_tree"):
            self.execute()

    def test_extra_expanded_member_cannot_pass(self):
        foreign = self.owner / "expanded-positive/Payload/FOREIGN"
        self.effect = lambda phase: (
            foreign.write_bytes(b"preserve") if phase == "positive" else None
        )
        with self.assertRaisesRegex(SUBJECT.Refusal, "expanded_tree"):
            self.execute()
        self.assertEqual(foreign.read_bytes(), b"preserve")

    def test_extra_generated_member_refuses_and_retains_foreign_file(self):
        foreign = self.owner / "FOREIGN"
        self.effect = lambda phase: (
            foreign.write_bytes(b"preserve") if phase == "generate" else None
        )
        with self.assertRaisesRegex(SUBJECT.Refusal, "owner_inventory"):
            self.execute()
        self.assertEqual(foreign.read_bytes(), b"preserve")
        self.assertEqual(len(self.calls), 1)

    def test_positive_native_nonzero_cannot_be_redeemed_by_a_package(self):
        def failed(arguments, deadline):
            if "--expand-full" in arguments:
                raise self.reference.Refusal("native_status")
            return self.native(arguments, deadline)

        with self.assertRaisesRegex(self.reference.Refusal, "native_status"):
            self.execute(failed)
        self.assertEqual(self.stage[0], "expand_positive")

    def test_negative_unexpected_success_refuses(self):
        def succeeded(arguments, deadline):
            if Path(arguments[-2]).name == "corrupt-header.pkg":
                return subprocess.CompletedProcess(arguments, 0, b"", b"")
            return self.native(arguments, deadline)

        with self.assertRaisesRegex(SUBJECT.Refusal, "negative_accepted"):
            self.execute(succeeded)

    def test_negative_transport_refusals_cannot_count_as_expected_corruption(self):
        def deadline_refused(arguments, deadline):
            if Path(arguments[-2]).name == "corrupt-header.pkg":
                raise self.reference.Refusal("deadline")
            return self.native(arguments, deadline)

        with self.assertRaisesRegex(SUBJECT.Refusal, "negative_transport"):
            self.execute(deadline_refused)

    def test_positive_input_changed_during_expansion_is_retained_and_refused(self):
        package = self.owner / "positive.pkg"
        self.effect = lambda phase: (
            package.write_bytes(b"replacement") if phase == "positive" else None
        )
        with self.assertRaisesRegex(SUBJECT.Refusal, "package_changed"):
            self.execute()
        self.assertEqual(package.read_bytes(), b"replacement")

    def test_positive_package_modified_during_negative_is_retained_and_refused(self):
        package = self.owner / "positive.pkg"

        def mutate(phase):
            if phase == "negative":
                self.assertEqual(package.read_bytes(), PACKAGE)
                package.write_bytes(b"FOREIGN REPLACEMENT")
                self.assertNotEqual(package.read_bytes(), PACKAGE)

        self.effect = mutate
        with self.assertRaisesRegex(SUBJECT.Refusal, "package_changed"):
            self.execute()
        self.assertEqual(package.read_bytes(), b"FOREIGN REPLACEMENT")

    def test_payload_root_mode_modified_during_generation_is_retained_and_refused(self):
        source = self.owner / "payload-source"

        def mutate(phase):
            if phase == "generate":
                self.assertEqual(source.stat().st_mode & 0o777, 0o755)
                source.chmod(0o700)
                self.assertEqual(source.stat().st_mode & 0o777, 0o700)

        self.effect = mutate
        with self.assertRaisesRegex(SUBJECT.Refusal, "directory_changed"):
            self.execute()
        self.assertEqual(source.stat().st_mode & 0o777, 0o700)


if __name__ == "__main__":
    unittest.main()
