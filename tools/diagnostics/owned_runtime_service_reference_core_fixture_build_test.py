# tools/diagnostics/owned_runtime_service_reference_core_fixture_build_test.py
"""Handwritten file/owner/lifetime controls; real POSIX observations, no native build proof."""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).with_name("owned_runtime_service_reference_core_fixture_build.py")


class CoreFixtureContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        spec = importlib.util.spec_from_file_location("core_fixture_controls", SOURCE)
        self.api = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.api)
        self.path = self.root / "actual.bin"
        self.path.write_bytes(b"held-original")
        self.holds = []
        self.addCleanup(self.finish_holds)

    def finish_holds(self):
        for hold in self.holds:
            if not hold.closed and not hold.failed:
                hold.close()

    def hold(self):
        result = self.api._HeldFile.capture(self.path, 64)
        self.holds.append(result)
        return result

    def refusal(self, code, call):
        with self.assertRaises(self.api.Refusal) as caught:
            call()
        self.assertEqual(caught.exception.code, code)
        return caught.exception

    def test_genuine_current_held_file(self):
        hold = self.hold()
        self.assertEqual(hold.data, b"held-original")
        hold.current()
        self.assertEqual(os.pread(hold.descriptor, 64, 0), b"held-original")

    def test_read_induced_access_time_is_not_drift(self):
        hold = self.hold()
        s = self.path.stat()
        os.utime(self.path, ns=(s.st_atime_ns + 5000000, s.st_mtime_ns))
        # utime changes ctime, so observe actual reads instead of fabricating unchanged ctime.
        hold.close()
        hold = self.hold()
        self.path.read_bytes()
        hold.current()
        self.assertEqual(hold.data, b"held-original")

    def test_same_bytes_new_inode_refuses(self):
        hold = self.hold()
        replacement = self.root / "replacement"
        replacement.write_bytes(b"held-original")
        replacement.replace(self.path)
        self.refusal("file_changed", hold.current)
        self.assertEqual(os.pread(hold.descriptor, 64, 0), b"held-original")

    def test_in_place_changed_bytes_refuse(self):
        hold = self.hold()
        self.path.write_bytes(b"held-modified")
        self.refusal("file_changed", hold.current)

    def test_changed_mode_refuses(self):
        hold = self.hold()
        self.path.chmod(0o600)
        self.refusal("file_changed", hold.current)

    def test_unlinked_name_refuses_keeps_fd(self):
        hold = self.hold()
        self.path.unlink()
        self.refusal("file_changed", hold.current)
        self.assertEqual(os.pread(hold.descriptor, 64, 0), b"held-original")

    def test_symlink_admission_refuses(self):
        actual = self.root / "original"
        self.path.rename(actual)
        self.path.symlink_to(actual)
        self.refusal("file_identity", lambda: self.api._HeldFile.capture(self.path, 64))
        self.assertEqual(actual.read_bytes(), b"held-original")

    def test_hardlink_admission_refuses(self):
        os.link(self.path, self.root / "alias")
        self.refusal("file_identity", lambda: self.api._HeldFile.capture(self.path, 64))
        self.assertEqual(self.path.stat().st_nlink, 2)

    def test_oversized_file_refuses(self):
        self.refusal("file_identity", lambda: self.api._HeldFile.capture(self.path, 3))
        self.assertEqual(self.path.read_bytes(), b"held-original")

    def test_empty_file_refuses(self):
        self.path.write_bytes(b"")
        self.refusal("file_identity", lambda: self.api._HeldFile.capture(self.path, 64))

    def test_close_ack_is_actual_closed_descriptor(self):
        hold = self.hold()
        fd = hold.descriptor
        hold.close()
        self.assertTrue(hold.closed)
        with self.assertRaises(OSError):
            os.fstat(fd)
        self.refusal("retired", hold.current)

    def test_close_error_never_retries_reused_fd(self):
        hold = self.hold()
        fd = hold.descriptor
        original_close = os.close
        calls = []
        recycled = []

        def close_then_error(descriptor):
            calls.append(descriptor)
            original_close(descriptor)
            recycled.append(os.open(self.path, os.O_RDONLY))
            raise OSError("ambiguous close receipt")

        with mock.patch.object(self.api.os, "close", close_then_error):
            error = self.refusal("close_unknown", hold.close)
            self.refusal("close_unknown", hold.close)
        self.assertEqual(calls, [fd])
        self.assertIs(error.owner, hold)
        self.assertTrue(hold.failed)
        self.assertFalse(hold.closed)
        self.assertEqual(os.pread(recycled[0], 64, 0), b"held-original")
        original_close(recycled[0])

    def test_borrowed_read_reentry_cannot_close_fd(self):
        hold = self.hold()
        pread = os.pread
        seen = []

        def borrowed(descriptor, count, offset):
            error = self.refusal("owner_busy", hold.close)
            self.assertIs(error.owner, hold)
            seen.append(os.fstat(descriptor).st_ino)
            return pread(descriptor, count, offset)

        with mock.patch.object(self.api.os, "pread", borrowed):
            hold.current()
        self.assertTrue(seen)
        self.assertFalse(hold.closed)

    def test_private_directory_current(self):
        owner = self.api._HeldOwner.capture(self.root)
        self.holds.append(owner)
        owner.current()
        self.assertEqual(os.fstat(owner.descriptor).st_ino, self.root.stat().st_ino)

    def test_private_directory_additions_are_ordinary(self):
        owner = self.api._HeldOwner.capture(self.root)
        self.holds.append(owner)
        (self.root / "generated").mkdir()
        owner.current()
        self.assertFalse(owner.closed)

    def test_directory_mode_change_refuses(self):
        owner = self.api._HeldOwner.capture(self.root)
        self.holds.append(owner)
        self.root.chmod(0o755)
        self.refusal("owner_changed", owner.current)

    def test_directory_same_path_replacement_refuses(self):
        owner = self.api._HeldOwner.capture(self.root)
        self.holds.append(owner)
        self.root.rename(self.root.with_name(self.root.name + "-old"))
        self.root.mkdir(mode=0o700)
        try:
            self.refusal("owner_changed", owner.current)
            self.assertFalse(owner.closed)
        finally:
            self.root.rmdir()
            self.root.with_name(self.root.name + "-old").rename(self.root)

    def test_owner_symlink_refuses(self):
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        self.refusal("owner_identity", lambda: self.api._HeldOwner.capture(link))

    def test_owner_not_private_refuses(self):
        self.root.chmod(0o755)
        self.refusal("owner_identity", lambda: self.api._HeldOwner.capture(self.root))

    def test_budget_exact_integer_300(self):
        for value in (True, 299, 301, 300.0, None):
            with self.subTest(value=value):
                self.refusal("invalid_budget", lambda: self.api._budget(value))
        self.assertEqual(self.api._budget(300), 300)

    def test_linux_native_boundary_refuses(self):
        with mock.patch.object(self.api.sys, "platform", "linux"):
            self.refusal("native_unavailable", self.api._darwin)

    def test_unsigned_release_command_has_exact_both_architectures(self):
        self.assertEqual(
            self.api._release_command("/actual/xcodebuild", self.root),
            [
                "/actual/xcodebuild",
                "-configuration",
                "Release",
                "-alltargets",
                "SYMROOT=" + str(self.root / "build"),
                "ARCHS=arm64 x86_64",
                "ONLY_ACTIVE_ARCH=NO",
                "CODE_SIGNING_ALLOWED=NO",
                "CODE_SIGNING_REQUIRED=NO",
                "GCC_GENERATE_DEBUGGING_SYMBOLS=NO",
            ],
        )

    def test_actual_produce_loop_keeps_native_commands_and_limits_asset_symbols_to_core(self):
        # Execute the source's real dispatch loop with explicitly modeled native
        # leaves. This proves command policy, not Darwin compiler completion.
        import ast
        from types import SimpleNamespace

        parsed = ast.parse(SOURCE.read_text())
        producer = next(
            node
            for node in parsed.body
            if isinstance(node, ast.FunctionDef) and node.name == "produce"
        )
        loops = [node for node in producer.body[-1].body if isinstance(node, ast.For)]
        self.assertEqual(len(loops), 2)
        loop = next(node for node in loops if isinstance(node.target, ast.Tuple))
        image = self.root / "modeled-source"
        image.mkdir()
        recipes = ("vendor/duktape-src", "src/apps/CoreService")
        outputs = (
            "build/Release/libduktape.a",
            "build/Release/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",
        )
        names = ("duktape", "ErgoptiPlus-Remap-Core")
        for recipe, name in zip(recipes, names):
            project = image / recipe
            project.mkdir(parents=True)
            (project / "project.yml").write_text("name: " + name + "\n")
        calls, current_cuts = [], []
        result = SimpleNamespace(
            image=SimpleNamespace(root=image), products=[], owner=SimpleNamespace(path=self.root)
        )
        deadline = __import__("time").monotonic() + 10

        def run(name, arguments, project, supplied_deadline):
            self.assertEqual(supplied_deadline, deadline)
            calls.append((name, arguments, project))
            index = recipes.index(str(project.relative_to(image)))
            if name.endswith("_generate"):
                target = project / (names[index] + ".xcodeproj") / "project.pbxproj"
                target.parent.mkdir()
                target.write_bytes(b"modeled-generated-recipe")
            elif name.endswith("_build"):
                target = project / outputs[index]
                target.parent.mkdir(parents=True)
                target.write_bytes(self.actual_two_slice_bytes())
                if index == 1:
                    (target.parents[1] / "Info.plist").write_bytes(b"modeled-plist")
            elif name.endswith("_architectures"):
                (self.root / (name + ".stdout")).write_bytes(b"arm64 x86_64\n")
            else:
                self.fail("Unknown modeled native operation")

        def current(supplied_deadline):
            self.assertEqual(supplied_deadline, deadline)
            current_cuts.append("current")

        result._run, result._current = run, current
        builder = SimpleNamespace(
            BASE=SimpleNamespace(MAX_INPUT_BYTES=131072),
            _ordinary=lambda path, root, maximum: SimpleNamespace(data=path.read_bytes()),
            architectures=lambda data: tuple(data.decode("ascii").split()),
            validate_plist=mock.Mock(),
        )
        namespace = dict(vars(self.api))
        namespace.update(
            result=result,
            builder=builder,
            tools={
                "xcodegen": "/actual/xcodegen",
                "xcodebuild": "/actual/xcodebuild",
                "xcrun": "/actual/xcrun",
            },
            deadline=deadline,
            repository=self.root,
        )
        try:
            exec(compile(ast.Module(body=[loop], type_ignores=[]), str(SOURCE), "exec"), namespace)
            self.assertEqual(current_cuts, ["current", "current"])
            self.assertEqual(len(calls), 6)
            for index, (recipe, output, label) in enumerate(
                zip(recipes, outputs, ("duktape", "core"))
            ):
                project = image / recipe
                expected = [
                    "/actual/xcodebuild",
                    "-configuration",
                    "Release",
                    "-alltargets",
                    "SYMROOT=" + str(project / "build"),
                    "ARCHS=arm64 x86_64",
                    "ONLY_ACTIVE_ARCH=NO",
                    "CODE_SIGNING_ALLOWED=NO",
                    "CODE_SIGNING_REQUIRED=NO",
                    "GCC_GENERATE_DEBUGGING_SYMBOLS=NO",
                ]
                if label == "core":
                    expected.append("ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS=NO")
                self.assertEqual(
                    calls[3 * index],
                    (
                        "core_fixture_" + label + "_generate",
                        ["/actual/xcodegen", "generate"],
                        project,
                    ),
                )
                self.assertEqual(
                    calls[3 * index + 1], ("core_fixture_" + label + "_build", expected, project)
                )
                self.assertEqual(
                    calls[3 * index + 2],
                    (
                        "core_fixture_" + label + "_architectures",
                        ["/actual/xcrun", "lipo", "-archs", str(project / output)],
                        project,
                    ),
                )
            builder.validate_plist.assert_called_once_with(
                b"modeled-plist", "core", repository=self.root, deadline=deadline
            )
            self.assertEqual(len(result.products), 7)
        finally:
            self.holds.extend(result.products)

    def test_fat64_executable_has_exact_two_slices(self):
        self.assertEqual(self.api._macho_slices(self.actual_two_slice_bytes()), ("arm64", "x86_64"))

    def test_architecture_strings_do_not_qualify_non_macho(self):
        self.refusal("macho_identity", lambda: self.api._macho_slices(b"arm64 x86_64"))

    def test_overlapping_real_fat_ranges_refuse(self):
        data = bytearray(self.actual_two_slice_bytes())
        data[36:40] = (64).to_bytes(4, "big")
        self.refusal("macho_identity", lambda: self.api._macho_slices(bytes(data)))

    def test_duplicate_real_cpu_identity_refuses(self):
        data = bytearray(self.actual_two_slice_bytes())
        data[28:32] = (16777228).to_bytes(4, "big")
        self.refusal("macho_identity", lambda: self.api._macho_slices(bytes(data)))

    def test_slice_header_filetype_not_executable_refuses(self):
        data = bytearray(self.actual_two_slice_bytes())
        data[76:80] = (6).to_bytes(4, "little")
        self.refusal("macho_identity", lambda: self.api._macho_slices(bytes(data)))

    def actual_two_slice_bytes(self):
        # Literal independent thin64 executable headers inside an ordinary fat32 table.
        # These portable parser bytes are not products of a native compiler.
        import struct

        fat = struct.pack(">II", 0xCAFEBABE, 2)
        fat += struct.pack(">IIIII", 16777228, 0, 64, 32, 0)
        fat += struct.pack(">IIIII", 16777223, 3, 96, 32, 0)
        fat += bytes(64 - len(fat))
        for cpu, subtype in ((16777228, 0), (16777223, 3)):
            fat += struct.pack("<IIIIIIII", 0xFEEDFACF, cpu, subtype, 2, 0, 0, 0, 0)
        return fat

    def fixed_copy(self):
        import shutil

        repo = self.root / "repository"
        repo.mkdir()
        supplied = Path(__file__).resolve().parents[2]
        for relative, _ in self.api.SOURCE_PINS:
            destination = repo / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(supplied / relative, destination)
        return repo

    def test_actual_cold_fixed_loader_requires_original_four_hashes(self):
        repo = self.fixed_copy()
        held = self.api._FixedInputs(repo)
        try:
            self.assertEqual(
                [__import__("hashlib").sha256(h.data).hexdigest() for h in held.holds],
                [
                    "d34f55714ce094d7a43d0c4ea36cc8bf4070c92c8009e0677939146d394030b8",
                    "26cbd216dcbd4c03619c43a1823bd00757ad0043865575a783936f50dfdec9a8",
                    "c29ceb96e73655cadea7763805b9468c32744033c2f177bae492e4ce9fe4100a",
                    "6ba213bd8fe086f7b8807974242189917f1cd8ae2b69d30e107ba171ad0d674f",
                ],
            )
            self.assertEqual(
                held.module.TARGETS,
                (
                    ("duktape", "vendor/duktape-src", "build/Release/libduktape.a"),
                    (
                        "core",
                        "src/apps/CoreService",
                        "build/Release/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",
                    ),
                    (
                        "console",
                        "src/apps/ConsoleUserServer",
                        "build/Release/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console",
                    ),
                    ("cli", "src/bin/cli", "build/Release/ergoptiplus_remap_cli"),
                ),
            )
            held.current()
        finally:
            self.assertTrue(held.close_retained())

    def test_each_genuine_fixed_source_wrong_bytes_refuses_loading(self):
        repo = self.fixed_copy()
        for relative, _ in self.api.SOURCE_PINS:
            path = repo / relative
            original = path.read_bytes()
            with self.subTest(relative=relative):
                path.write_bytes(original + b"\n# genuine later source mutation\n")
                error = self.refusal("source_identity", lambda: self.api._FixedInputs(repo))
                self.assertIsInstance(error.owner, self.api._FixedInputs)
                self.assertTrue(error.owner.close_retained())
                path.write_bytes(original)

    def test_loaded_fixed_source_each_later_comment_refuses(self):
        repo = self.fixed_copy()
        for relative, _ in self.api.SOURCE_PINS:
            held = self.api._FixedInputs(repo)
            try:
                path = repo / relative
                original = path.read_bytes()
                path.write_bytes(original + b"\n# genuine change after actual provider execution\n")
                self.refusal("file_changed", held.current)
                path.write_bytes(original)
            finally:
                self.assertTrue(held.close_retained())

    def test_loaded_fixed_provider_same_bytes_new_inode_refuses(self):
        repo = self.fixed_copy()
        held = self.api._FixedInputs(repo)
        try:
            path = repo / "tools/build/remap_runtime_patch.py"
            replacement = repo / "replacement"
            replacement.write_bytes(path.read_bytes())
            replacement.replace(path)
            self.refusal("file_changed", held.current)
            self.assertNotEqual(os.fstat(held.holds[2].descriptor).st_ino, path.stat().st_ino)
        finally:
            self.assertTrue(held.close_retained())

    def test_fixed_source_failed_capture_preserves_unknown_close_owner(self):
        repo = self.fixed_copy()
        source = repo / "tools/build/remap_runtime_patch.py"
        os.link(source, repo / "provider-alias")
        close = os.close
        recycled = []

        def close_then_error(descriptor):
            close(descriptor)
            recycled.append(os.open(source, os.O_RDONLY))
            raise OSError("actual close completion is unknown")

        with mock.patch.object(self.api.os, "close", close_then_error):
            error = self.refusal("close_unknown", lambda: self.api._FixedInputs(repo))
        self.assertIsInstance(error.owner, self.api._FixedInputs)
        self.assertEqual(len(error.owner.refusal_debt), 1)
        self.assertTrue(error.owner.refusal_debt[0].failed)
        self.assertFalse(error.owner.close_retained())
        self.assertEqual(len(recycled), 1)
        self.assertTrue(os.pread(recycled[0], 16, 0))
        close(recycled[0])

    def test_nonempty_build_owner_refuses_before_source_or_native_acquisition(self):
        marker = self.root / "foreign-marker"
        marker.write_bytes(b"foreign owner input")
        error = self.refusal(
            "owner_not_empty", lambda: self.api.produce(self.root, self.root, self.root)
        )
        self.assertIsNone(error.owner.fixed)
        self.assertEqual(marker.read_bytes(), b"foreign owner input")
        self.assertTrue(error.owner.close_retained())
        self.assertTrue(marker.exists())
        self.assertFalse(error.owner.owner.descriptor)
        self.assertFalse(error.owner.ready)

    def test_core_build_unknown_close_debt_cannot_acknowledge_retirement(self):
        owner = self.api.CoreFixtureBuild(self.root)
        close = os.close
        descriptor = owner.owner.descriptor
        calls = []

        def unknown(fd):
            calls.append(fd)
            close(fd)
            raise OSError("unknown directory close receipt")

        with mock.patch.object(self.api.os, "close", unknown):
            self.assertFalse(owner.close_retained())
            self.assertFalse(owner.close_retained())
        self.assertEqual(calls, [descriptor])
        self.assertFalse(owner.owner.closed)
        self.assertTrue(owner.failed)
        self.assertFalse(owner.observation()["child_group_retirement_qualified"])

    def test_compiler_owner_current_frame_refuses_reentrant_descriptor_release(self):
        owner = self.api.CoreFixtureBuild(self.root)
        owner.ready = True
        current = owner.owner.current
        calls = []

        def borrowing():
            error = self.refusal("owner_busy", owner.close_retained)
            self.assertIs(error.owner, owner)
            calls.append(os.fstat(owner.owner.descriptor).st_ino)
            return current()

        with mock.patch.object(owner.owner, "current", borrowing):
            owner._lock.acquire()
            try:
                # This is the actual producer's locked owner-frame boundary, not a Core positive.
                owner._current(__import__("time").monotonic() + 5)
            finally:
                owner._lock.release()
        self.assertTrue(calls)
        self.assertFalse(owner.owner.closed)
        self.assertTrue(owner.close_retained())

    def test_marked_ready_without_actual_core_images_still_refuses(self):
        owner = self.api.CoreFixtureBuild(self.root)
        owner.ready = True
        try:
            self.refusal(
                "fixture_lifecycle", lambda: owner.current(__import__("time").monotonic() + 5)
            )
            self.assertFalse(owner.observation()["ready"])
        finally:
            self.assertTrue(owner.close_retained())


if __name__ == "__main__":
    unittest.main()
