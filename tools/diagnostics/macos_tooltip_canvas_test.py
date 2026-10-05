# tools/diagnostics/macos_tooltip_canvas_test.py
"""Pure supervisor refusals and independent observer controls; no native Mac proof."""

from copy import deepcopy
import json
from pathlib import Path
import plistlib
import subprocess
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import macos_tooltip_canvas as probe
import macos_tooltip_canvas_observer as observer


class SupervisorAdmissionControls(unittest.TestCase):
    """Doubles model refusal/control flow only, never Cocoa/Win32/native execution."""

    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.group = Mock()
        self.group.process.pid = 711
        self.group.observe_exit.return_value = None

    def receipt(self, **changes):
        value = {"pid": 711, "version": "1.1.1"}
        value.update(changes)
        (self.root / "result.json").write_text(json.dumps(value), encoding="utf-8")

    def observe(self, unchanged=None):
        return probe.supervise(self.group, self.root, "1.1.1", unchanged or Mock(), timeout=1)

    def test_missing_native_platform_fails_before_any_output_or_spawn(self):
        with (
            patch.object(probe.sys, "platform", "linux"),
            patch.object(probe.owner, "acquire_owned") as spawn,
        ):
            with self.assertRaisesRegex(ValueError, "native macOS"):
                probe.run(self.root, self.root, self.root / "not-created")
        spawn.assert_not_called()
        self.assertFalse((self.root / "not-created").exists())

    def test_cli_native_refusal_has_nonzero_exit_without_skip_green(self):
        with (
            patch.object(probe.sys, "platform", "linux"),
            patch.object(
                sys,
                "argv",
                [
                    "probe",
                    "--repo",
                    str(self.root),
                    "--app",
                    str(self.root),
                    "--output",
                    str(self.root / "not-created"),
                ],
            ),
            patch.object(probe.sys, "stderr"),
        ):
            self.assertEqual(probe.main(), 1)

    def test_old_mac_python_refuses_missing_native_nonreaping_wait_before_output(self):
        with (
            patch.object(probe.sys, "platform", "darwin"),
            patch.object(probe.sys, "version_info", (3, 12)),
        ):
            with self.assertRaisesRegex(ValueError, "CPython 3.13"):
                probe.run(self.root, self.root, self.root / "not-created")
        self.assertFalse((self.root / "not-created").exists())

    def test_native_exit_before_receipt_refuses_without_a_pixel_observation(self):
        self.receipt()
        self.group.observe_exit.return_value = object()
        with (
            patch.object(observer, "observe") as pixels,
            self.assertRaisesRegex(ValueError, "exited before"),
        ):
            self.observe()
        pixels.assert_not_called()

    def test_receipt_foreign_pid_refuses_before_pixel_observation(self):
        self.receipt(pid=712)
        with (
            patch.object(observer, "observe") as pixels,
            self.assertRaisesRegex(ValueError, "exact acquired"),
        ):
            self.observe()
        pixels.assert_not_called()

    def test_boolean_pid_cannot_borrow_integer_identity(self):
        self.group.process.pid = 1
        self.receipt(pid=True)
        with (
            patch.object(observer, "observe") as pixels,
            self.assertRaisesRegex(ValueError, "exact acquired"),
        ):
            self.observe()
        pixels.assert_not_called()

    def test_other_runtime_version_refuses_before_pixel_observation(self):
        self.receipt(version="1.0.0")
        with (
            patch.object(observer, "observe") as pixels,
            self.assertRaisesRegex(ValueError, "version differs"),
        ):
            self.observe()
        pixels.assert_not_called()

    def test_redirected_result_is_refused(self):
        target = self.root / "foreign.json"
        target.write_text("{}")
        (self.root / "result.json").symlink_to(target)
        with self.assertRaisesRegex(ValueError, "Redirected native result"):
            self.observe()

    def test_invalid_atomic_json_fails_instead_of_waiting_or_admitting(self):
        (self.root / "result.json").write_text("{")
        with self.assertRaises(json.JSONDecodeError):
            self.observe()

    def test_absent_gui_result_reaches_deadline_failure(self):
        with patch.object(probe.time, "monotonic", side_effect=[0, 2]):
            with self.assertRaisesRegex(ValueError, "exceeded its deadline"):
                self.observe()

    def test_native_owner_exit_during_pixel_observation_refuses(self):
        self.receipt()
        self.group.observe_exit.side_effect = [None, object()]
        with (
            patch.object(observer, "observe", return_value=[]),
            self.assertRaisesRegex(ValueError, "during pixel"),
        ):
            self.observe()

    def test_independent_pixel_failure_is_not_relabelled_as_a_pass(self):
        self.receipt()
        with patch.object(observer, "observe", side_effect=ValueError("native pixel failure")):
            with self.assertRaisesRegex(ValueError, "native pixel failure"):
                self.observe()

    def test_source_drift_after_native_output_fails(self):
        self.receipt()
        with patch.object(observer, "observe", return_value=[]):
            with self.assertRaisesRegex(ValueError, "source changed"):
                self.observe(Mock(side_effect=ValueError("source changed")))

    def test_selected_version_has_no_missing_or_ambiguous_fallback(self):
        source = self.root / "tools/build/build_macos_app.sh"
        source.parent.mkdir(parents=True)
        for text in ("", 'HAMMERSPOON_VERSION="${HAMMERSPOON_VERSION:-1.1.1}"\n' * 2):
            with self.subTest(source=text):
                source.write_text(text)
                with self.assertRaisesRegex(ValueError, "ambiguous or absent"):
                    probe.selected_version(self.root)
        source.write_text('HAMMERSPOON_VERSION="${HAMMERSPOON_VERSION:-1.1.1}"\n')
        self.assertEqual(probe.selected_version(self.root), "1.1.1")

    def test_changed_source_root_is_not_followed(self):
        directory = self.root / "static/ergopti_plus"
        directory.mkdir(parents=True)
        target = self.root / "foreign"
        target.mkdir()
        (directory / "macos").symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "Source root unavailable"):
            probe.identities(self.root)

    def test_changed_source_descendant_is_not_followed(self):
        directory = self.root / "static/ergopti_plus/macos"
        directory.mkdir(parents=True)
        (directory / "foreign.lua").symlink_to(self.root / "other")
        with self.assertRaisesRegex(ValueError, "Redirected production"):
            probe.identities(self.root)

    def app(self, version="1.1.1"):
        app = self.root / "Hammerspoon.app"
        executable = app / "Contents/MacOS/Hammerspoon"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"independent-signed-app-test-bytes-not-a-native-binary")
        executable.chmod(0o700)
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleShortVersionString": version}, stream)
        return app

    def test_app_version_refuses_before_codesign(self):
        app = self.app(version="1.0.0")
        with patch.object(probe.subprocess, "run") as verify:
            with self.assertRaisesRegex(ValueError, "selected Hammerspoon version"):
                probe.admit_runtime(app, "1.1.1", self.root, "original")
        verify.assert_not_called()

    def test_strict_signature_failure_is_retained_and_refused(self):
        app = self.app()
        reply = SimpleNamespace(returncode=1, stdout=b"", stderr=b"independent signature refusal")
        with patch.object(probe.subprocess, "run", return_value=reply) as verify:
            with self.assertRaisesRegex(ValueError, "signature verify refused"):
                probe.admit_runtime(app, "1.1.1", self.root, "original")
        self.assertEqual(
            verify.call_args.args[0],
            ["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)],
        )
        self.assertEqual(
            (self.root / "original-signature-verify.stderr").read_bytes(), reply.stderr
        )

    def test_integrity_only_receipt_never_claims_publisher_authentication(self):
        app = self.app()
        replies = [
            SimpleNamespace(returncode=0, stdout=b"", stderr=b"strict reply"),
            SimpleNamespace(returncode=0, stdout=b"", stderr=b"actual signer reply"),
        ]
        with patch.object(probe.subprocess, "run", side_effect=replies) as verify:
            receipt = probe.admit_runtime(app, "1.1.1", self.root, "original")
        self.assertIs(receipt["publisher_authenticated_by_supervisor"], False)
        self.assertEqual(len(verify.call_args_list), 2)
        self.assertEqual(
            (self.root / "original-signature-signer.stderr").read_bytes(), b"actual signer reply"
        )


class SupervisorRetirementControls(unittest.TestCase):
    """Independent mocked native ports test orchestration, not native process-group syscalls."""

    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name)
        self.group = Mock(reaped=True)
        self.group.settle.return_value = True
        self.group.receipt.return_value = {"closed": True, "escaped_sessions_managed": False}
        self.current = {}
        self.previous = object()
        self.install = patch.object(probe.signal, "signal", side_effect=self.set_handler)
        self.install.start()
        self.addCleanup(self.install.stop)
        self.original = patch.object(probe.signal, "getsignal", return_value=self.previous)
        self.original.start()
        self.addCleanup(self.original.stop)

    def set_handler(self, sig, handler):
        self.current[sig] = handler

    def acquired(self, _arguments, _native, register, **_options):
        register(self.group)
        return self.group

    def run_operation(self, operation):
        return probe.owned_observation(
            self.output / "Hammerspoon", self.output / "probe.lua", self.output, operation, Mock()
        )

    def test_direct_arguments_and_native_register_before_observation(self):
        operation = Mock(return_value={"native_execution": "executed"})
        with patch.object(probe.owner, "acquire_owned", side_effect=self.acquired) as acquire:
            receipt = self.run_operation(operation)
        self.assertEqual(
            acquire.call_args.args[0],
            [str(self.output / "Hammerspoon"), "-MJConfigFile", str(self.output / "probe.lua")],
        )
        self.assertEqual(acquire.call_args.kwargs["cwd"], self.output)
        operation.assert_called_once_with(self.group)
        self.group.settle.assert_called_once_with()
        self.assertEqual(receipt["status"], "ok")
        self.assertTrue(all(handler is self.previous for handler in self.current.values()))

    def test_operation_refusal_still_retires_without_erasing_failure(self):
        with patch.object(probe.owner, "acquire_owned", side_effect=self.acquired):
            receipt = self.run_operation(Mock(side_effect=ValueError("pixel contract refused")))
        self.assertEqual(receipt["status"], "error")
        self.assertEqual(receipt["operation_error"], "pixel contract refused")
        self.group.settle.assert_called_once_with()

    def test_timeout_still_retires_and_never_claims_success(self):
        with patch.object(probe.owner, "acquire_owned", side_effect=self.acquired):
            receipt = self.run_operation(Mock(side_effect=subprocess.TimeoutExpired("pixels", 60)))
        self.assertEqual(receipt["status"], "error")
        self.assertIn("timed out", receipt["operation_error"])
        self.group.settle.assert_called_once_with()

    def test_acquisition_interrupt_keeps_registered_group_available_for_retirement(self):
        def interrupted(arguments, native, register, **options):
            self.acquired(arguments, native, register, **options)
            raise probe.owner.OwnedProcessInterrupted("acquisition interruption")

        operation = Mock()
        with patch.object(probe.owner, "acquire_owned", side_effect=interrupted):
            receipt = self.run_operation(operation)
        operation.assert_not_called()
        self.group.settle.assert_called_once_with()
        self.assertEqual(receipt["operation_error"], "acquisition interruption")
        self.assertEqual(receipt["status"], "error")

    def test_signal_cancellation_is_ignored_only_during_retirement_then_restored(self):
        def cancelled(_group):
            self.current[probe.signal.SIGTERM](probe.signal.SIGTERM, None)

        def settle():
            self.assertTrue(
                all(handler == probe.signal.SIG_IGN for handler in self.current.values())
            )
            return True

        self.group.settle.side_effect = settle
        with patch.object(probe.owner, "acquire_owned", side_effect=self.acquired):
            receipt = self.run_operation(cancelled)
        self.assertEqual(receipt["status"], "error")
        self.assertIn("interrupted", receipt["operation_error"])
        self.assertTrue(all(handler is self.previous for handler in self.current.values()))

    def test_unacquired_child_never_authorizes_a_retirement_call(self):
        with patch.object(probe.owner, "acquire_owned", side_effect=OSError("spawn refused")):
            receipt = self.run_operation(Mock())
        self.group.settle.assert_not_called()
        self.assertEqual(receipt["status"], "error")
        self.assertIsNone(receipt["native_owner"])

    def test_retirement_debt_overrides_an_otherwise_successful_observation(self):
        self.group.settle.return_value = False
        self.group.reaped = False
        with patch.object(probe.owner, "acquire_owned", side_effect=self.acquired):
            receipt = self.run_operation(Mock(return_value={"native_execution": "executed"}))
        self.assertEqual(receipt["status"], "error")
        self.assertIn("retirement debt", receipt["cleanup_errors"][0])
        self.assertIn("unconfirmed", receipt["application_cleanup"])

    def test_observation_payload_cannot_override_failed_retirement(self):
        self.group.settle.return_value = False
        self.group.reaped = False
        with patch.object(probe.owner, "acquire_owned", side_effect=self.acquired):
            receipt = self.run_operation(Mock(return_value={"status": "ok", "cleanup_errors": []}))
        self.assertEqual(receipt["status"], "error")
        self.assertTrue(receipt["cleanup_errors"])

    def test_reservation_loss_cannot_be_relabelled_as_confirmed_cleanup(self):
        self.group.reaped = False
        self.group.settle.side_effect = probe.owner.OwnedProcessError("native reservation lost")
        with patch.object(probe.owner, "acquire_owned", side_effect=self.acquired):
            receipt = self.run_operation(Mock(return_value={"native_execution": "executed"}))
        self.assertEqual(receipt["status"], "error")
        self.assertIn("native reservation lost", receipt["cleanup_errors"][0])
        self.assertIn("unconfirmed", receipt["application_cleanup"])


class IndependentObserverControls(unittest.TestCase):
    """Literal attributed-text inputs and color samples; no synthetic native PNG receipts."""

    def case(self):
        # Independent fixed indent-zero/selected-row-one input, not a formatter output.
        rows = [("✨ ", True), ("\u2009", False), ("\u2009", False)]
        styled = ["✨ MMMMMMMM MMMM\n\u2009MMMMMMMM MMMM\n\u2009MMMMMMMM MMMM"]
        offset = 1
        for prefix, chosen in rows:
            pieces = [
                (prefix, (0.98, 0.88, 0.22), "regular", 1 if chosen else 0),
                ("MMMM", (0.5, 0.5, 0.5), "regular", 1),
                (
                    "MMMM",
                    (0.25, 0.90, 0.40) if chosen else (0.5, 0.5, 0.5),
                    "regular" if chosen else "bold",
                    1,
                ),
                (
                    " MMMM",
                    (1.0, 0.62, 0.10) if chosen else (0.5, 0.5, 0.5),
                    "regular" if chosen else "bold",
                    1,
                ),
            ]
            for text, (r, g, b), font, alpha in pieces:
                length = len(text.encode("utf-8"))
                styled.append(
                    {
                        "starts": offset,
                        "ends": offset + length - 1,
                        "attributes": {
                            "color": {"red": r, "green": g, "blue": b, "alpha": alpha},
                            "font": {"name": font, "size": 14},
                        },
                    }
                )
                offset += length
            offset += 1
        return {"styled": styled, "indent": 0, "selected": 1, "font_names": ["regular", "bold"]}

    def test_independent_literal_byte_ranges_are_admitted(self):
        observer.validate_attributes(self.case())

    def test_colored_typed_text_is_rejected(self):
        case = self.case()
        case["styled"][2]["attributes"]["color"]["green"] = 0.90
        with self.assertRaisesRegex(ValueError, "role color differs"):
            observer.validate_attributes(case)

    def test_wrong_selected_correction_color_is_rejected(self):
        case = self.case()
        case["styled"][3]["attributes"]["color"]["red"] = 0.5
        with self.assertRaisesRegex(ValueError, "role color differs"):
            observer.validate_attributes(case)

    def test_regular_unselected_correction_is_rejected(self):
        case = self.case()
        case["styled"][7]["attributes"]["font"]["name"] = "regular"
        with self.assertRaisesRegex(ValueError, "bold role differs"):
            observer.validate_attributes(case)

    def test_visible_inactive_prefix_is_rejected(self):
        case = self.case()
        case["styled"][5]["attributes"]["color"]["alpha"] = 1
        with self.assertRaisesRegex(ValueError, "compensating native prefix is visible"):
            observer.validate_attributes(case)

    def test_wrong_indent_text_is_rejected(self):
        case = self.case()
        case["styled"][0] = case["styled"][0].replace("✨ ", "  ✨ ")
        with self.assertRaisesRegex(ValueError, "text/prefix expectation"):
            observer.validate_attributes(case)

    def test_overlapping_native_ranges_are_rejected(self):
        case = self.case()
        case["styled"].append(deepcopy(case["styled"][2]))
        with self.assertRaisesRegex(ValueError, "missing or overlapping"):
            observer.validate_attributes(case)

    def test_missing_canvas_cleanup_fails_before_png_reads(self):
        result = {
            "status": "ok",
            "runtime": "native Hammerspoon",
            "canvas_cleanup": False,
            "production_errors": [],
        }
        with patch.object(observer, "validate_pixels") as pixels:
            with self.assertRaisesRegex(ValueError, "canvas/error debt"):
                observer.observe(result, Path("never-read"))
        pixels.assert_not_called()

    def test_missing_gui_receipt_fails_before_png_reads(self):
        with patch.object(observer, "validate_pixels") as pixels:
            with self.assertRaisesRegex(ValueError, "producer did not succeed"):
                observer.observe(
                    {"status": "error", "error": "no native GUI screen"}, Path("never-read")
                )
        pixels.assert_not_called()

    def test_independent_color_samples_retain_role_and_opacity_boundaries(self):
        for pixel, expected in [
            ((128, 128, 128, 255), "gray"),
            ((64, 230, 102, 255), "green"),
            ((255, 158, 26, 255), "orange"),
            ((64, 230, 102, 0), None),
            ((255, 255, 255, 255), None),
            ((0, 0, 0, 255), None),
        ]:
            with self.subTest(pixel=pixel):
                self.assertEqual(observer.color_class(pixel), expected)


class TypedBodyRasterControls(unittest.TestCase):
    """Independent bitmap geometry, not regenerated native or production expectations."""

    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def capture(self, *, marker=False, missing=False, fragment=False, typed_shift=0, other_shift=0):
        from PIL import Image, ImageDraw

        image = Image.new("RGBA", (210, 60), (32, 32, 32, 255))
        draw = ImageDraw.Draw(image)
        # Four independently authored regular M glyphs advance by 12 pixels.
        # A thicker second run supplies the existing independent bold-ink proof.
        bitmap = [
            "1000000001",
            "1100000011",
            "1010000101",
            "1001001001",
            "1000110001",
            "1000110001",
            "1000000001",
            "1000000001",
            "1000000001",
            "1000000001",
        ]

        def run(left, top, color, bold=False):
            for letter in range(4):
                for y, row in enumerate(bitmap):
                    for x, value in enumerate(row):
                        if value == "1":
                            draw.point((left + letter * 12 + x, top + y), fill=color)
                            if bold:
                                draw.point((left + letter * 12 + x + 1, top + y), fill=color)

        for row, top in enumerate((4, 24, 44), 1):
            if row == 1:
                if marker:
                    # Marker antialiasing is gray, but it is not a typed glyph.
                    draw.rectangle((12, top, 14, top + 9), fill=(128, 128, 128, 255))
                if fragment:
                    draw.rectangle((34, top, 36, top + 9), fill=(128, 128, 128, 255))
                elif not missing:
                    run(34 + typed_shift, top, (128, 128, 128, 255))
                run(82, top, (64, 230, 102, 255))
                run(130, top, (255, 158, 26, 255))
            else:
                left = 10 + (other_shift if row == 2 else 0)
                run(left, top, (128, 128, 128, 255))
                run(left + 48, top, (128, 128, 128, 255), bold=True)
        path = self.root / "independent-bitmap.png"
        image.save(path, "PNG")
        return {
            "image": path.name,
            "frame": {"w": 210, "h": 60},
            "predictions_frame": {"x": 0, "y": 0, "w": 210, "h": 60},
            "selected": 1,
            "prefix_advances": [27, 3],
            "glyph_widths": [48, 48],
        }

    def test_independent_typed_bitmap_keeps_literal_prefix_alignment(self):
        case = self.capture()
        pixels = observer.validate_pixels(case, self.root)
        self.assertEqual([row["typed_left"] for row in pixels["rows"]], [34, 10, 10])

    def test_gray_marker_antialias_cannot_own_the_typed_start(self):
        case = self.capture(marker=True)
        before = (self.root / case["image"]).read_bytes()
        pixels = observer.validate_pixels(case, self.root)
        self.assertEqual([row["typed_left"] for row in pixels["rows"]], [34, 10, 10])
        self.assertEqual((self.root / case["image"]).read_bytes(), before)

    def test_marker_only_cannot_replace_the_missing_typed_body(self):
        with self.assertRaisesRegex(ValueError, "typed body missing"):
            observer.validate_pixels(self.capture(marker=True, missing=True), self.root)

    def test_gray_fragment_cannot_borrow_the_regular_typed_glyph_width(self):
        with self.assertRaisesRegex(ValueError, "typed body width"):
            observer.validate_pixels(self.capture(fragment=True), self.root)

    def test_typed_body_moved_left_cannot_borrow_the_correction_anchor(self):
        with self.assertRaisesRegex(ValueError, "typed body"):
            observer.validate_pixels(self.capture(typed_shift=-8), self.root)

    def test_typed_body_moved_right_cannot_borrow_the_correction_anchor(self):
        with self.assertRaisesRegex(ValueError, "typed body"):
            observer.validate_pixels(self.capture(typed_shift=6), self.root)

    def test_wrong_inactive_indent_still_fails_with_marker_contamination(self):
        with self.assertRaisesRegex(ValueError, "indentation"):
            observer.validate_pixels(self.capture(marker=True, other_shift=8), self.root)


class BoldContrastRasterControls(unittest.TestCase):
    """Literal foreground coverage controls, independent of native captured pixels."""

    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def capture(self, weight):
        from PIL import Image, ImageDraw

        case = TypedBodyRasterControls.capture(self)
        path = self.root / case["image"]
        with Image.open(path) as decoded:
            image = decoded.convert("RGBA")
        draw = ImageDraw.Draw(image)
        bitmap = [
            "1000000001",
            "1100000011",
            "1010000101",
            "1001001001",
            "1000110001",
            "1000110001",
            "1000000001",
            "1000000001",
            "1000000001",
            "1000000001",
        ]
        for top in (24, 44):
            draw.rectangle((10, top, 107, top + 9), fill=(32, 32, 32, 255))
            for left, bold in ((10, False), (58, True)):
                for letter in range(4):
                    for y, row in enumerate(bitmap):
                        for x, value in enumerate(row):
                            if value != "1" or (bold and weight == "less" and x not in (0, 9)):
                                continue
                            point = (left + letter * 12 + x, top + y)
                            draw.point(point, fill=(128, 128, 128, 255))
                            if bold and weight == "antialiased":
                                # Solid neutral cores remain visible even above
                                # the separate role classifier's upper bound.
                                draw.point((point[0] + 1, point[1]), fill=(146, 146, 146, 255))
        image.save(path, "PNG")
        return case

    def test_antialiased_bold_cores_add_visible_contrast(self):
        case = self.capture("antialiased")
        before = (self.root / case["image"]).read_bytes()
        observed = observer.validate_pixels(case, self.root)
        for row in observed["rows"][1:]:
            self.assertGreater(row["bold_ink"], row["regular_ink"] * 1.03)
        self.assertEqual((self.root / case["image"]).read_bytes(), before)

    def test_equal_regular_and_correction_coverage_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "not visibly heavier"):
            observer.validate_pixels(self.capture("equal"), self.root)

    def test_less_correction_coverage_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "not visibly heavier"):
            observer.validate_pixels(self.capture("less"), self.root)


if __name__ == "__main__":
    unittest.main()
