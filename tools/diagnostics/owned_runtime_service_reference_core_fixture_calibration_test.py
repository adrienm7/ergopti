# tools/diagnostics/owned_runtime_service_reference_core_fixture_calibration_test.py
"""Independent ordinary source/FIFO-free calibration controls. Native0."""

import importlib.util
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).with_name("owned_runtime_service_reference_core_fixture_calibration.py")
CORE = "tools/diagnostics/owned_runtime_service_reference_core_fixture_build.py"
CORE_SHA = "dddb305314151e0d50b4a36482c38b8f4614651bfc535c04d7547dadc70b5a42"


class CoreCalibrationContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repository = self.root / "repository"
        self.repository.mkdir()
        self.core = self.repository / CORE
        self.core.parent.mkdir(parents=True)
        supplied = SOURCE.parents[2]
        shutil.copyfile(supplied / CORE, self.core)
        specification = importlib.util.spec_from_file_location(
            "actual_calibration_controls", SOURCE
        )
        self.api = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(self.api)
        self.images = []
        self.addCleanup(self.release_images)

    def release_images(self):
        for image in self.images:
            if not image.closed and not image.failed:
                self.assertTrue(image.close_retained())

    def capture(self):
        image = self.api.FixedProducerImage.capture(self.repository)
        self.images.append(image)
        return image

    def refusal(self, code, call):
        with self.assertRaises(self.api.CalibrationRefusal) as caught:
            call()
        self.assertEqual(caught.exception.code, code)
        return caught.exception

    def test_actual_cold_producer_source_is_fixed_and_typed(self):
        image = self.capture()
        self.assertEqual(__import__("hashlib").sha256(image.data).hexdigest(), CORE_SHA)
        self.assertIs(type(image.program_source), image.module._HeldFile)
        self.assertEqual(image.program_source.path, self.core)
        self.assertEqual(image.program_source.data, image.data)
        image.current(__import__("time").monotonic() + 5)

    def test_preload_changed_source_refuses_execution(self):
        self.core.write_bytes(self.core.read_bytes() + b"\n# changed before verified execution\n")
        error = self.refusal("program_source_identity", self.capture)
        self.assertIsInstance(error.owner, self.api.FixedProducerImage)
        self.assertTrue(error.owner.close_retained())

    def test_preload_symlink_is_not_source(self):
        original = self.core.with_name("original.py")
        self.core.rename(original)
        self.core.symlink_to(original)
        self.refusal("program_source_identity", self.capture)
        self.assertTrue(original.exists())

    def test_preload_hardlink_is_not_source(self):
        os.link(self.core, self.root / "linked.py")
        error = self.refusal("program_source_identity", self.capture)
        self.assertTrue(error.owner.close_retained())
        self.assertEqual(self.core.stat().st_nlink, 2)

    def test_cached_program_later_comment_refuses(self):
        image = self.capture()
        self.core.write_bytes(
            self.core.read_bytes() + b"\n# changed after verified source execution\n"
        )
        self.refusal(
            "program_source_changed", lambda: image.current(__import__("time").monotonic() + 5)
        )

    def test_cached_program_same_bytes_new_inode_refuses(self):
        image = self.capture()
        replacement = self.root / "replacement.py"
        replacement.write_bytes(self.core.read_bytes())
        old = os.fstat(image.descriptor).st_ino
        replacement.replace(self.core)
        self.refusal(
            "program_source_changed", lambda: image.current(__import__("time").monotonic() + 5)
        )
        self.assertEqual(os.fstat(image.descriptor).st_ino, old)
        self.assertNotEqual(self.core.stat().st_ino, old)

    def test_source_read_induced_atime_does_not_refuse(self):
        image = self.capture()
        self.core.read_bytes()
        image.current(__import__("time").monotonic() + 5)
        self.assertEqual(image.data, self.core.read_bytes())

    def test_retirement_has_both_actual_descriptor_acknowledgements(self):
        image = self.capture()
        descriptors = [image.descriptor, image.program_source.descriptor]
        self.assertTrue(image.close_retained())
        self.assertTrue(image.closed)
        for descriptor in descriptors:
            with self.assertRaises(OSError):
                os.fstat(descriptor)
        self.refusal(
            "program_source_retired", lambda: image.current(__import__("time").monotonic() + 5)
        )

    def test_unknown_primary_close_never_retries_recycled_descriptor(self):
        image = self.capture()
        descriptor = image.descriptor
        close = os.close
        calls, recycled = [], []
        image.program_source.close()

        def uncertain(fd):
            calls.append(fd)
            close(fd)
            recycled.append(os.open(self.core, os.O_RDONLY))
            raise OSError("actual close receipt unknown")

        with mock.patch.object(self.api.os, "close", uncertain):
            self.assertFalse(image.close_retained())
            self.assertFalse(image.close_retained())
        self.assertTrue(image.failed)
        self.assertFalse(image.closed)
        self.assertEqual(calls, [descriptor])
        self.assertEqual(recycled[0], descriptor)
        self.assertTrue(os.pread(recycled[0], 16, 0))
        close(recycled[0])

    def test_single_absolute_budget_not_three_fresh_budgets(self):
        for value in (True, None, 299, 301, 300.0):
            with self.subTest(value=value):
                self.refusal("invalid_budget", lambda: self.api.budget(value))
        self.assertEqual(self.api.budget(300), 300)

    def test_expired_absolute_deadline_refuses_source_call(self):
        image = self.capture()
        self.refusal("deadline", lambda: image.current(__import__("time").monotonic() - 1))

    def test_bool_cannot_supply_executing_source_to_actual_producer(self):
        image = self.capture()
        owner = self.root / "owned"
        owner.mkdir(mode=0o700)
        with self.assertRaises(image.module.Refusal) as caught:
            image.module.produce(
                self.repository, self.repository, owner, current_program_source=True
            )
        self.assertEqual(caught.exception.code, "program_source_identity")
        self.assertTrue(caught.exception.owner.close_retained())

    def test_arbitrary_ordinary_source_file_cannot_be_executing_core(self):
        image = self.capture()
        path = self.root / "arbitrary.py"
        path.write_bytes(b"ordinary bytes but not the actual executing Core producer")
        source = image.module._HeldFile.capture(path, 1024)
        owner = self.root / "owned"
        owner.mkdir(mode=0o700)
        try:
            with self.assertRaises(image.module.Refusal) as caught:
                image.module.produce(
                    self.repository, self.repository, owner, current_program_source=source
                )
            self.assertEqual(caught.exception.code, "program_source_identity")
            self.assertTrue(caught.exception.owner.close_retained())
            self.assertFalse(source.closed)
        finally:
            source.close()

    def test_cli_unknown_option_refuses_without_source_or_native(self):
        self.assertEqual(self.api.main(["--unknown", "ignored"]), 64)

    def test_cli_nonexact_budget_refuses_without_source_or_native(self):
        self.assertEqual(
            self.api.main(
                ["--owner", str(self.root), "--pristine", str(self.root), "--budget", "299"]
            ),
            64,
        )

    def test_cli_missing_prepared_input_refuses_without_source_or_native(self):
        self.assertEqual(self.api.main(["--owner", str(self.root), "--budget", "300"]), 64)


if __name__ == "__main__":
    unittest.main()
