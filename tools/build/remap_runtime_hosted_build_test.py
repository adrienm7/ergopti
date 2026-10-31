# tools/build/remap_runtime_hosted_build_test.py
"""Pin the controls the owned runtime build needs on a hosted macOS runner.

A hosted run once waited two hours on three xcodebuild children because the
phase owner only compared the clock after the child exited. These tests run
real children: a phase still running at its deadline is killed with its whole
process tree, refused with a named code and receipt, and progress is streamed.
They also pin the background-ctime tolerance of held files and the parse of
the self-signed identity that find-identity reports as not trusted.
"""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import textwrap
import time
import types
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    "remap_runtime_build_deadline_subject", Path(__file__).with_name("remap_runtime_build.py")
)
BUILD = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BUILD
SPEC.loader.exec_module(BUILD)
BASE = BUILD.BASE

# The child would sleep this long; the original unbounded wait outlives the
# assertion bound below, so it fails instead of passing late.
CHILD_SLEEP_SECONDS = 60
DEADLINE_SECONDS = 1.5
KILL_BOUND_SECONDS = 20
PROGRESS_SECONDS = 0.2

CHILD = textwrap.dedent(
    """
    import subprocess, sys, time
    grandchild = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(%d)"], start_new_session=True
    )
    with open(sys.argv[1], "w") as handle:
        handle.write(str(grandchild.pid))
    print("CompileC modeled/main.o main.cpp", flush=True)
    print("    indented command detail", flush=True)
    time.sleep(%d)
    """
    % (CHILD_SLEEP_SECONDS, CHILD_SLEEP_SECONDS)
)


def alive(pid):
    """Report whether a pid names a live, non-zombie process on macOS or Linux."""
    result = subprocess.run(
        ["ps", "-o", "stat=", "-p", str(pid)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    )
    state = result.stdout.decode().strip()
    return bool(state) and not state.startswith("Z")


class PhaseDeadlineControls(unittest.TestCase):
    def setUp(self):
        self.owner = Path(tempfile.mkdtemp(prefix="phase-deadline-")).resolve()
        self.addCleanup(shutil.rmtree, self.owner, True)
        self.marker = self.owner / "grandchild.pid"
        self.script = self.owner / "child.py"
        self.script.write_text(CHILD)
        self.addCleanup(self.reap_grandchild)
        progress = mock.patch.object(BASE, "PHASE_PROGRESS_SECONDS", PROGRESS_SECONDS)
        progress.start()
        self.addCleanup(progress.stop)

    def reap_grandchild(self):
        if self.marker.exists():
            pid = int(self.marker.read_text())
            if alive(pid):
                os.kill(pid, 9)

    def command(self):
        return [sys.executable, str(self.script), str(self.marker)]

    def wait_for_marker(self):
        bound = time.monotonic() + KILL_BOUND_SECONDS
        while not self.marker.exists() or not self.marker.read_text():
            self.assertLess(time.monotonic(), bound, "the modeled child never started")
            time.sleep(0.05)
        return int(self.marker.read_text())

    def assert_killed(self, name, caught, elapsed, log):
        self.assertEqual(caught.exception.code, "phase_deadline")
        self.assertIn("killed: " + name, str(caught.exception))
        self.assertLess(elapsed, KILL_BOUND_SECONDS)
        receipt = json.loads((self.owner / (name + ".receipt.json")).read_text())
        self.assertEqual(receipt["status"], "refused")
        self.assertEqual(receipt["refusal"], "phase_deadline_killed")
        self.assertLess(receipt["exit_status"], 0)
        grandchild = int(self.marker.read_text())
        bound = time.monotonic() + 5
        while alive(grandchild) and time.monotonic() < bound:
            time.sleep(0.05)
        self.assertFalse(alive(grandchild), "a descendant in its own session survived")
        self.assertIn("[native-phase] " + name + ": started", log)
        self.assertIn("last: CompileC modeled/main.o main.cpp", log)
        self.assertIn("calibration deadline reached", log)
        self.assertIn("[native-phase] " + name + ": refused in", log)

    def test_foreground_phase_is_killed_at_its_deadline(self):
        log = io.StringIO()
        started = time.monotonic()
        with contextlib.redirect_stderr(log):
            with self.assertRaises(BASE.NativeBuildError) as caught:
                BASE.run_phase(
                    "core_build",
                    self.command(),
                    self.owner,
                    self.owner,
                    started + DEADLINE_SECONDS,
                )
        self.assert_killed("core_build", caught, time.monotonic() - started, log.getvalue())

    def test_retained_phase_is_killed_at_its_deadline(self):
        log, owners = io.StringIO(), []
        started = time.monotonic()
        with contextlib.redirect_stderr(log):
            operation = BASE.begin_phase(
                "console_build",
                self.command(),
                self.owner,
                self.owner,
                started + DEADLINE_SECONDS,
                owners.append,
            )
            self.assertEqual(owners, [operation])
            self.wait_for_marker()
            with self.assertRaises(BASE.NativeBuildError) as caught:
                BASE.finish_phase(operation)
        self.assertTrue(operation.waited)
        self.assertTrue(operation.finished)
        self.assert_killed("console_build", caught, time.monotonic() - started, log.getvalue())

    def test_phase_within_its_deadline_passes_without_refusal(self):
        log = io.StringIO()
        with contextlib.redirect_stderr(log):
            record = BASE.run_phase(
                "cli_build",
                [sys.executable, "-c", "print('done')"],
                self.owner,
                self.owner,
                time.monotonic() + KILL_BOUND_SECONDS,
            )
        self.assertEqual(record["status"], "passed")
        self.assertNotIn("refusal", record)
        self.assertIn("[native-phase] cli_build: passed in", log.getvalue())

    def test_build_command_bounds_compiler_jobs(self):
        command = BUILD.build_command("/usr/bin/xcodebuild", self.owner)
        self.assertEqual(command[command.index("-jobs") + 1], "2")


class IdentityChangeReportControls(unittest.TestCase):
    """A currentness refusal names the changed retained file and its fields."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="identity-change-")).resolve()
        self.addCleanup(shutil.rmtree, self.root, True)

    def test_metadata_only_change_of_a_held_product_is_named(self):
        image = self.root / "build/Release/product"
        image.parent.mkdir(parents=True)
        image.write_bytes(b"compiled image\n")
        held = BUILD.product_snapshot(image, self.root)
        os.chmod(image, 0o700)
        log = io.StringIO()
        with contextlib.redirect_stderr(log):
            with self.assertRaises(BASE.NativeBuildError) as caught:
                BUILD.current_product(held, self.root)
        self.assertEqual(caught.exception.code, "source_identity")
        line = log.getvalue()
        self.assertIn("[owned-build] retained product changed: build/Release/product (", line)
        self.assertIn("mode", line)
        self.assertIn("ctime", line)
        self.assertNotIn("data", line)

    def test_ctime_only_change_of_a_held_product_stays_current(self):
        image = self.root / "duktape.xcodeproj/project.pbxproj"
        image.parent.mkdir(parents=True)
        image.write_bytes(b"generated project\n")
        held = BUILD.product_snapshot(image, self.root)
        time.sleep(0.01)
        # chmod to the same mode changes only ctime, as a background xattr does.
        os.chmod(image, image.stat().st_mode & 0o7777)
        self.assertNotEqual(image.stat().st_ctime_ns, held.identity[7])
        log = io.StringIO()
        with contextlib.redirect_stderr(log):
            BUILD.current_product(held, self.root)
        self.assertIn(
            "[owned-build] retained product ctime changed, bytes and incarnation unchanged: "
            "duktape.xcodeproj/project.pbxproj (ctime)",
            log.getvalue(),
        )

    def test_rewritten_bytes_of_a_held_product_are_refused(self):
        image = self.root / "product"
        image.write_bytes(b"compiled image\n")
        held = BUILD.product_snapshot(image, self.root)
        time.sleep(0.01)
        with open(image, "r+b") as stream:
            stream.write(b"C")
        log = io.StringIO()
        with contextlib.redirect_stderr(log):
            with self.assertRaises(BASE.NativeBuildError) as caught:
                BUILD.current_product(held, self.root)
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertIn("data", log.getvalue())

    def test_unchanged_product_reports_nothing(self):
        image = self.root / "product"
        image.write_bytes(b"compiled image\n")
        held = BUILD.product_snapshot(image, self.root)
        log = io.StringIO()
        with contextlib.redirect_stderr(log):
            BUILD.current_product(held, self.root)
        self.assertEqual(log.getvalue(), "")


class SigningIdentityListingControls(unittest.TestCase):
    """find-identity output for the stable self-signed identity (run 41232985096)."""

    IDENTITY = "759D8AAE58886BAC8886D834F9EEAE52274051BC"
    LISTING = (
        "Policy: Code Signing\n"
        "  Matching identities\n"
        '  1) 759D8AAE58886BAC8886D834F9EEAE52274051BC "ErgoptiPlus Self-Signed"'
        " (CSSMERR_TP_NOT_TRUSTED)\n"
        "     1 identities found\n"
        "\n"
        "  Valid identities only\n"
        "     0 valid identities found\n"
    )

    def test_untrusted_self_signed_identity_is_listed(self):
        self.assertTrue(BUILD.signing_identity_listed(self.LISTING, self.IDENTITY))

    def test_trusted_identity_is_listed(self):
        listing = self.LISTING.replace(" (CSSMERR_TP_NOT_TRUSTED)", "")
        self.assertTrue(BUILD.signing_identity_listed(listing, self.IDENTITY))

    def test_other_certificate_status_is_refused(self):
        for status in ("CSSMERR_TP_CERT_EXPIRED", "CSSMERR_TP_CERT_REVOKED"):
            with self.subTest(status=status):
                listing = self.LISTING.replace("CSSMERR_TP_NOT_TRUSTED", status)
                self.assertFalse(BUILD.signing_identity_listed(listing, self.IDENTITY))

    def test_absent_or_duplicated_identity_is_refused(self):
        self.assertFalse(BUILD.signing_identity_listed(self.LISTING, "A" * 40))
        twice = self.LISTING.replace(
            "     1 identities found",
            '  2) 759D8AAE58886BAC8886D834F9EEAE52274051BC "Copy" (CSSMERR_TP_NOT_TRUSTED)\n'
            "     2 identities found",
        )
        self.assertFalse(BUILD.signing_identity_listed(twice, self.IDENTITY))


class SigningTargetControls(unittest.TestCase):
    """Each signing level names the one resource seal codesign may write."""

    def test_bundle_executable_level_may_write_the_bundle_seal(self):
        seal = "Runtime/ErgoptiPlus-Remap-Core.app/Contents/_CodeSignature/CodeResources"
        self.assertEqual(
            BUILD._signing_targets("Runtime/ErgoptiPlus-Remap-Core.app", "ErgoptiPlus-Remap-Core"),
            (
                (
                    "Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",
                    seal,
                ),
                ("Runtime/ErgoptiPlus-Remap-Core.app", seal),
            ),
        )

    def test_bare_executable_writes_no_seal(self):
        self.assertEqual(
            BUILD._signing_targets("Runtime/bin/ergoptiplus_remap_cli", None),
            (("Runtime/bin/ergoptiplus_remap_cli", None),),
        )

    def test_every_signed_product_has_a_seal_at_each_bundle_level(self):
        for destination, _, executable in BUILD._SIGNED_PRODUCTS:
            with self.subTest(destination=destination):
                levels = BUILD._signing_targets(destination, executable)
                self.assertEqual(len(levels), 2 if executable else 1)
                self.assertEqual(
                    {seal for _, seal in levels},
                    {destination + "/Contents/_CodeSignature/CodeResources"}
                    if executable
                    else {None},
                )


class MachODifferenceControls(unittest.TestCase):
    """A refused signing transform reports the comparator line and slice layouts."""

    def test_differing_ranges_merge_and_stop_at_the_common_length(self):
        left = bytes(10000)
        right = bytearray(left)
        right[16:24] = b"\x01" * 8
        right[5000] = 1
        self.assertEqual(
            BUILD._differing_ranges(left, bytes(right) + b"tail"), [[16, 24], [5000, 5001]]
        )
        self.assertEqual(BUILD._differing_ranges(left, left), [])

    def test_report_names_comparator_line_and_each_slice(self):
        slices = [
            types.SimpleNamespace(
                cpu=0x0100000C,
                data=data,
                commands_end=1000,
                commands=(1, 2),
                signature=(992, 4096, 512),
                link_size=600,
                link_vm=16384,
                payload_end=4096,
            )
            for data in (bytes(64), bytes(32) + b"\x01" + bytes(31))
        ]
        macho = types.SimpleNamespace(_images=lambda image, deadline: [slices[image]])

        def refuse():
            raise ValueError("modeled")

        try:
            refuse()
        except ValueError as error:
            error.code = "content"
            caught = error
        log = io.StringIO()
        with contextlib.redirect_stderr(log):
            BUILD._report_macho_difference(macho, "Runtime/x", 0, 1, caught, 10**9)
        text = log.getvalue()
        self.assertIn("Mach-O comparison of Runtime/x refused content at ", text)
        self.assertIn("(refuse)", text)
        self.assertIn("slice cpu=0x100000c bytes 64 -> 64", text)
        self.assertIn("differing ranges [[32, 33]]", text)

    def test_report_failure_never_raises(self):
        macho = types.SimpleNamespace(_images=None)
        error = ValueError("modeled")
        error.code = "content"
        log = io.StringIO()
        with contextlib.redirect_stderr(log):
            BUILD._report_macho_difference(macho, "Runtime/x", b"", b"", error, 10**9)
        self.assertIn("Mach-O difference report failed: TypeError", log.getvalue())


class MachOAlignmentControls(unittest.TestCase):
    """codesign may re-align a fat slice to a page size; nothing else may change."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "remap_runtime_macho_alignment_subject",
            Path(__file__).with_name("remap_runtime_macho.py"),
        )
        self.macho = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.macho)

    def outcome(self, original, signed):
        def thin(cpu, subtype, alignment):
            return types.SimpleNamespace(
                cpu=cpu, subtype=subtype, alignment=alignment, signature=None
            )

        with self.assertRaises(self.macho.MachORefusal) as caught:
            self.macho._compare(thin(*original), thin(*signed), 10**9)
        return caught.exception.code

    def test_page_realignment_passes_the_slice_identity_check(self):
        # Run 41245238523: lipo and codesign disagreed on one slice's alignment.
        # Past the identity check, the unsigned stub stops at "signature".
        x86, arm = 0x01000007, 0x0100000C
        for original, signed in (((x86, 3, 14), (x86, 3, 12)), ((arm, 0, 12), (arm, 0, 14))):
            with self.subTest(original=original, signed=signed):
                self.assertEqual(self.outcome(original, signed), "signature")
        self.assertEqual(self.outcome((x86, 3, None), (x86, 3, None)), "signature")

    def test_cpu_subtype_or_non_page_alignment_changes_are_refused(self):
        x86 = 0x01000007
        for original, signed in (
            ((x86, 3, 12), (0x0100000C, 3, 12)),
            ((x86, 3, 12), (x86, 4, 12)),
            ((x86, 3, 12), (x86, 3, 16)),
            ((x86, 3, None), (x86, 3, 12)),
        ):
            with self.subTest(original=original, signed=signed):
                self.assertEqual(self.outcome(original, signed), "content")


class SignatureSlackControls(unittest.TestCase):
    """codesign zero-pads its reserved signature space; the linker's is tight."""

    OFFSET = 4096

    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "remap_runtime_macho_slack_subject",
            Path(__file__).with_name("remap_runtime_macho.py"),
        )
        self.macho = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.macho)

    def image(self, signed, padding, fill=b"\0"):
        """Return file bytes and the reserved size of one minimal signature superblob."""
        identifier = b"x\0\0\0"
        directory = struct.pack(
            ">9I4BI",
            0xFADE0C02,
            48 + 32,
            0x20400,
            0 if signed else 2,
            48,
            44,
            0,
            1,
            self.OFFSET,
            32,
            2,
            0,
            12,
            0,
        )
        directory += identifier + bytes(32)
        blobs = [(0, directory)]
        if signed:
            blobs += [(2, struct.pack(">II", 0xFADE0C01, 12) + bytes(4))]
            blobs += [(0x10000, struct.pack(">II", 0xFADE0B01, 12) + bytes(4))]
        table_end = 12 + len(blobs) * 8
        table, body, position = b"", b"", table_end
        for slot, blob in blobs:
            table += struct.pack(">II", slot, position)
            body += blob
            position += len(blob)
        superblob = struct.pack(">III", 0xFADE0CC0, position, len(blobs)) + table + body
        reserved = len(superblob) + padding
        data = bytes(self.OFFSET) + superblob + fill * padding
        return data, reserved

    def check(self, signed, padding, fill=b"\0"):
        data, reserved = self.image(signed, padding, fill)
        self.macho._signature(data, self.OFFSET, reserved, signed, 10**9)

    def test_codesign_reserved_zero_padding_is_admitted(self):
        # Run 41247532775: codesign reserved far more than its superblob length.
        self.check(True, 4096)

    def test_codesign_padding_must_stay_zero(self):
        with self.assertRaises(self.macho.MachORefusal) as caught:
            self.check(True, 4096, b"\1")
        self.assertEqual(caught.exception.code, "shape")

    def test_linker_signature_stays_tight(self):
        self.check(False, 15)
        with self.assertRaises(self.macho.MachORefusal) as caught:
            self.check(False, 16)
        self.assertEqual(caught.exception.code, "signature")


class LinkeditRoundingControls(unittest.TestCase):
    """The signed __LINKEDIT vmsize is its size rounded to an admitted page."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "remap_runtime_macho_linkedit_subject",
            Path(__file__).with_name("remap_runtime_macho.py"),
        )
        self.macho = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.macho)

    def test_observed_codesign_rounding_is_admitted(self):
        # Run 41247532775: both slices as codesign laid them out.
        admitted = self.macho._linkedit_vm_admitted
        self.assertTrue(admitted(0x01000007, 5214208, 5304272, 5308416))
        self.assertTrue(admitted(0x0100000C, 5275648, 5288064, 5292032))

    def test_x86_64_admits_either_page_and_arm64_only_16k(self):
        admitted = self.macho._linkedit_vm_admitted
        self.assertTrue(admitted(0x01000007, 0, 5304272, 5304320))
        self.assertFalse(admitted(0x0100000C, 0, 5304272, 5304320))
        self.assertFalse(admitted(0x01000007, 0, 5304272, 5308416 + 16384))
        self.assertTrue(admitted(0x0100000C, 6000000, 5288064, 6000000))
        self.assertFalse(admitted(0x0100000C, 5000000, 5288064, 5000000))


class RefusalOriginControls(unittest.TestCase):
    """Signing collapses a dozen checks into one code; the report names the line."""

    def test_origin_names_type_code_and_innermost_builder_line(self):
        try:
            BUILD.check_deadline(0)
        except BASE.NativeBuildError as error:
            caught = error
        log = io.StringIO()
        with contextlib.redirect_stderr(log):
            BUILD._report_refusal_origin("signing", caught)
        self.assertRegex(
            log.getvalue(),
            r"^\[owned-build\] signing refused by NativeBuildError phase_deadline "
            r"at line \d+ \(check_deadline\)\n$",
        )

    def test_error_without_builder_frame_is_reported_as_unknown(self):
        log = io.StringIO()
        with contextlib.redirect_stderr(log):
            BUILD._report_refusal_origin("signing", OSError("modeled"))
        self.assertEqual(
            log.getvalue(), "[owned-build] signing refused by OSError  at unknown line\n"
        )


if __name__ == "__main__":
    unittest.main()
