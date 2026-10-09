# tools/build/remap_runtime_preparation_observation_test.py
"""Independent read-only filesystem controls; product/receipt bytes are modeled."""

import contextlib
import hashlib
import importlib.util
import io
import json
import marshal
import os
from pathlib import Path
import plistlib
import shutil
import struct
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


SUBJECT = load("independent_prepared_observer", HERE / "remap_runtime_preparation_observation.py")
ORIGINAL = load("original_owned_record_controls", HERE / "remap_runtime_build_test.py")
PRODUCTS = (
    ("duktape", "vendor/duktape-src/build/Release/libduktape.a"),
    (
        "core",
        "src/apps/CoreService/build/Release/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",
    ),
    (
        "console",
        "src/apps/ConsoleUserServer/build/Release/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console",
    ),
    ("cli", "src/bin/cli/build/Release/ergoptiplus_remap_cli"),
)
APPS = (
    (
        "core",
        "src/apps/CoreService/build/Release/ErgoptiPlus-Remap-Core.app",
        "ErgoptiPlus-Remap-Core",
        "com.ergoptiplus.remap.core",
    ),
    (
        "console",
        "src/apps/ConsoleUserServer/build/Release/ErgoptiPlus-Remap-Console.app",
        "ErgoptiPlus-Remap-Console",
        "com.ergoptiplus.remap.console",
    ),
)
FULL_PASS = "PASS observed unsigned prepared runtime products=3; custody, signing and installation unqualified\n"
COMPILATION_PASS = "PASS observed completed compilation metadata; unsigned snapshot unqualified\n"


class ObservationControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="prepared-observer-controls-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.repository = self.root / "repository"
        for relative in (
            "tools/build/remap_runtime_build.py",
            "tools/build/remap_runtime_patch.py",
            "tools/build/remap_runtime_source.py",
            "tools/build/remap_runtime_vhd.hpp",
            "tools/build/remap_runtime_vhd_transport.py",
            "tools/diagnostics/hs274_native_build.py",
        ):
            source = HERE.parents[1] / relative
            path = self.repository / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, path)
            path.chmod(0o644)
        self.owner = self.root / "owner"
        self.owner.mkdir(mode=0o700)
        self.owner.chmod(0o700)
        self.stage = self.owner / "upstream"
        self.stage.mkdir(mode=0o700)
        self.stage.chmod(0o700)
        for label, relative in PRODUCTS:
            self.write(self.stage / relative, b"\xca\xfe\xba\xbeMODELED-" + label.encode(), 0o755)
        for _, relative, executable, identifier in APPS:
            bundle = self.stage / relative
            self.write(
                bundle / "Contents/Info.plist",
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": identifier,
                        "CFBundleExecutable": executable,
                        "CFBundlePackageType": "APPL",
                    }
                ),
            )
            self.write(bundle / "Contents/PkgInfo", b"APPL????")
            self.write(bundle / "Contents/Resources/app.icns", b"icnsMODELED-RESOURCE")
        self.output = self.owner / ".unsigned-runtime-preparation"
        self.output.mkdir(mode=0o700)
        self.output.chmod(0o700)
        self.directory(self.output / "Runtime/bin")
        for _, relative, executable, _ in APPS:
            shutil.copytree(self.stage / relative, self.output / "Runtime" / (executable + ".app"))
        shutil.copyfile(
            self.stage / PRODUCTS[3][1], self.output / "Runtime/bin/ergoptiplus_remap_cli"
        )
        (self.output / "Runtime/bin/ergoptiplus_remap_cli").chmod(0o755)
        self.record = ORIGINAL.OwnedRecordControls().record()
        # Handwritten following-profile metadata from the independently frozen
        # genuine4505 inventory; synthetic product bytes grant no native authority.
        self.record.update(
            schema=2,
            source_profile="owned_vhd_broker_source_v1",
            source_factory_sha256="50fb679becd85980354858e38a4231488839bedfbf013b203505b7a5912c66bc",
            source_inventory_entries=4505,
            owned_replacements=64,
            staged_files=4528,
            staged_links=4,
        )
        for row, (_, relative) in zip(self.record["products"], PRODUCTS, strict=True):
            data = (self.stage / relative).read_bytes()
            row.update(sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))
        self.receipt = self.owner / "owned-native-build-result.json"
        self.save_record()

    def directory(self, path):
        absent = []
        current = path
        while not current.exists():
            absent.append(current)
            current = current.parent
        for item in reversed(absent):
            item.mkdir()
            item.chmod(0o755)

    def write(self, path, data, mode=0o644):
        self.directory(path.parent)
        path.write_bytes(data)
        path.chmod(mode)

    def save_record(self):
        self.write(self.receipt, (json.dumps(self.record) + "\n").encode(), 0o600)

    def pair(self, relative="Contents/Resources/app.icns", app=0):
        _, source, executable, _ = APPS[app]
        return self.stage / source / relative, self.output / "Runtime" / (
            executable + ".app"
        ) / relative

    def refuses(self, code):
        with self.assertRaises(SUBJECT.ObservationRefusal) as caught:
            SUBJECT.observe(self.repository, self.owner)
        self.assertEqual(caught.exception.code, code)

    def image(self):
        result = {}
        for path in [self.owner, *self.owner.rglob("*")]:
            info = path.lstat()
            result[str(path.relative_to(self.owner))] = (
                info.st_mode,
                info.st_ino,
                info.st_mtime_ns,
                info.st_ctime_ns,
                path.read_bytes() if path.is_file() else None,
            )
        return result

    def test_complete_modeled_products_and_resources_are_observed_without_writes(self):
        before = self.image()
        self.assertIsNone(SUBJECT.observe(self.repository, self.owner))
        self.assertEqual(self.image(), before)

    def test_observation_creates_no_repository_cache_or_other_files(self):
        before = {str(path.relative_to(self.repository)) for path in self.repository.rglob("*")}
        self.assertIsNone(SUBJECT.observe(self.repository, self.owner))
        after = {str(path.relative_to(self.repository)) for path in self.repository.rglob("*")}
        self.assertEqual(after, before)

    def test_additional_paired_ordinary_resource_is_observed(self):
        source, output = self.pair("Contents/Resources/independent-extra.dat")
        self.write(source, b"independent ordinary resource")
        self.write(output, b"independent ordinary resource")
        self.assertIsNone(SUBJECT.observe(self.repository, self.owner))

    def test_missing_detached_resource_refuses(self):
        self.pair()[1].unlink()
        self.refuses("inventory")

    def test_unpaired_detached_resource_refuses(self):
        self.write(self.pair("Contents/Resources/unpaired.dat")[1], b"extra")
        self.refuses("inventory")

    def test_missing_required_icon_in_both_trees_refuses(self):
        for path in self.pair():
            path.unlink()
        self.refuses("product_identity")

    def test_different_resource_bytes_refuse(self):
        self.pair()[1].write_bytes(b"icnsCHANGED-RESOURCE")
        self.refuses("content")

    def test_different_primary_bytes_refuse(self):
        self.pair("Contents/MacOS/ErgoptiPlus-Remap-Core")[1].write_bytes(b"changed primary")
        self.refuses("content")

    def test_matching_changed_primaries_do_not_match_original_product_receipt(self):
        for path in self.pair("Contents/MacOS/ErgoptiPlus-Remap-Core"):
            path.write_bytes(b"\xca\xfe\xba\xbeMODELED-changed")
        self.refuses("product_identity")

    def test_source_secondary_macho_refuses(self):
        for path in self.pair("Contents/Resources/second-code"):
            self.write(path, b"\xca\xfe\xba\xbeSECONDARY")
        self.refuses("inventory")

    def test_source_nested_library_refuses(self):
        for path in self.pair("Contents/Resources/secondary.dylib"):
            self.write(path, b"ordinary-looking bytes")
        self.refuses("inventory")

    def test_nested_framework_directory_refuses(self):
        for path in self.pair("Contents/Frameworks/Secondary.framework"):
            self.directory(path)
        self.refuses("inventory")

    def test_source_symlink_refuses(self):
        source, output = self.pair("Contents/Resources/symlink")
        source.symlink_to(self.pair()[0])
        self.write(output, b"icnsMODELED-RESOURCE")
        self.refuses("unsafe_path")

    def test_detached_symlink_refuses(self):
        output = self.pair()[1]
        output.unlink()
        output.symlink_to(self.pair()[0])
        self.refuses("unsafe_path")

    def test_hardlinked_detached_file_refuses(self):
        source, output = self.pair()
        output.unlink()
        os.link(source, output)
        self.refuses("unsafe_path")

    def test_fifo_refuses_without_blocking(self):
        source = self.pair()[0]
        source.unlink()
        os.mkfifo(source)
        self.refuses("unsafe_path")

    def test_source_directory_mode_refuses(self):
        self.pair()[0].parent.chmod(0o700)
        self.refuses("unsafe_path")

    def test_detached_directory_mode_refuses(self):
        self.pair()[1].parent.chmod(0o700)
        self.refuses("unsafe_path")

    def test_primary_mode_refuses(self):
        (self.output / "Runtime/bin/ergoptiplus_remap_cli").chmod(0o644)
        self.refuses("unsafe_path")

    def test_resource_execute_mode_refuses(self):
        self.pair()[0].chmod(0o755)
        self.refuses("unsafe_path")

    def test_preparation_root_mode_refuses(self):
        self.output.chmod(0o755)
        self.refuses("unsafe_path")

    def test_extra_shipping_root_refuses(self):
        self.write(self.output / "Runtime/extra-product", b"extra")
        self.refuses("inventory")

    def test_wrong_owned_plist_identifier_refuses(self):
        for path in self.pair("Contents/Info.plist"):
            value = plistlib.loads(path.read_bytes())
            value["CFBundleIdentifier"] = "org.pqrs.Karabiner-Core-Service"
            path.write_bytes(plistlib.dumps(value))
        self.refuses("product_identity")

    def test_wrong_owned_plist_executable_refuses(self):
        for path in self.pair("Contents/Info.plist", app=1):
            value = plistlib.loads(path.read_bytes())
            value["CFBundleExecutable"] = "Karabiner-ConsoleUserServer"
            path.write_bytes(plistlib.dumps(value))
        self.refuses("product_identity")

    def test_wrong_plist_package_type_refuses(self):
        for path in self.pair("Contents/Info.plist"):
            value = plistlib.loads(path.read_bytes())
            value["CFBundlePackageType"] = "BNDL"
            path.write_bytes(plistlib.dumps(value))
        self.refuses("product_identity")

    def test_nonclosed_original_compilation_metadata_refuses(self):
        self.record["extra"] = True
        self.save_record()
        self.refuses("metadata")

    def test_signed_compilation_flag_refuses(self):
        self.record["signing_executed"] = True
        self.save_record()
        self.refuses("metadata")

    def test_missing_second_architecture_in_metadata_refuses(self):
        self.record["products"][1]["architectures"] = ["arm64"]
        self.save_record()
        self.refuses("metadata")

    def test_original_receipt_digest_mismatch_refuses(self):
        self.record["products"][3]["sha256"] = "f" * 64
        self.save_record()
        self.refuses("product_identity")

    def test_absent_original_compilation_record_refuses(self):
        self.receipt.unlink()
        self.refuses("unsafe_path")

    def test_completed_compilation_observation_does_not_require_or_qualify_snapshot(self):
        shutil.rmtree(self.output)
        self.assertIsNone(SUBJECT.observe(self.repository, self.owner, compilation_only=True))
        self.refuses("unsafe_path")

    def test_resource_mutation_during_actual_read_refuses(self):
        selected = self.pair()[0]
        inode = selected.stat().st_ino
        original = os.read
        changed = False

        def mutate(descriptor, count):
            nonlocal changed
            data = original(descriptor, count)
            if not changed and os.fstat(descriptor).st_ino == inode:
                changed = True
                selected.write_bytes(b"changed during observation")
            return data

        with mock.patch.object(SUBJECT.os, "read", side_effect=mutate):
            self.refuses("identity")
        self.assertTrue(changed)

    def test_owner_replacement_during_code_load_refuses_original_incarnation(self):
        original = os.read
        code_inode = (self.repository / "tools/build/remap_runtime_build.py").stat().st_ino
        changed = False

        def replace(descriptor, count):
            nonlocal changed
            data = original(descriptor, count)
            if not changed and os.fstat(descriptor).st_ino == code_inode:
                changed = True
                previous = self.root / "previous-owner"
                self.owner.rename(previous)
                shutil.copytree(previous, self.owner)
            return data

        with mock.patch.object(SUBJECT.os, "read", side_effect=replace):
            self.refuses("identity")
        self.assertTrue(changed)

    def test_source_member_bound_is_enforced_during_iteration(self):
        directory = self.pair()[0].parent
        for index in range(2051):
            self.write(directory / f"member-{index}", b"")
        original = os.scandir
        count = 0

        class Counted:
            def __init__(self, path):
                self.entries = original(path)
                self.selected = Path(path) == directory

            def __enter__(self):
                return self

            def __exit__(self, *args):
                self.entries.close()

            def __iter__(self):
                return self

            def __next__(self):
                nonlocal count
                entry = next(self.entries)
                if self.selected:
                    count += 1
                return entry

        with mock.patch.object(SUBJECT.os, "scandir", side_effect=Counted):
            self.refuses("bounds")
        self.assertGreater(count, 0)
        self.assertLessEqual(count, 2049)

    def test_output_unknown_member_refuses_before_complete_enumeration(self):
        directory = self.output / "Runtime"
        for index in range(2051):
            self.write(directory / f"unpaired-{index}", b"")
        original = os.scandir
        count = 0

        class Counted:
            def __init__(self, path):
                self.entries = original(path)
                self.selected = Path(path) == directory

            def __enter__(self):
                return self

            def __exit__(self, *args):
                self.entries.close()

            def __iter__(self):
                return self

            def __next__(self):
                nonlocal count
                entry = next(self.entries)
                if self.selected:
                    count += 1
                return entry

        with mock.patch.object(SUBJECT.os, "scandir", side_effect=Counted):
            self.refuses("inventory")
        self.assertGreater(count, 0)
        self.assertLessEqual(count, 4)

    def test_scan_deadline_is_enforced_during_iteration(self):
        directory = self.pair()[0].parent
        original = os.scandir
        now = 1000.0
        count = 0

        class Counted:
            def __init__(self, path):
                self.entries = original(path)
                self.selected = Path(path) == directory

            def __enter__(self):
                return self

            def __exit__(self, *args):
                self.entries.close()

            def __iter__(self):
                return self

            def __next__(self):
                nonlocal count, now
                entry = next(self.entries)
                if self.selected:
                    count += 1
                    now = 1040.0
                return entry

        with (
            mock.patch.object(SUBJECT.time, "monotonic", side_effect=lambda: now),
            mock.patch.object(SUBJECT.os, "scandir", side_effect=Counted),
        ):
            self.refuses("deadline")
        self.assertEqual(count, 1)

    def test_oversized_sparse_source_file_refuses_before_read(self):
        selected = self.pair("Contents/Resources/oversized.dat")[0]
        with selected.open("wb") as stream:
            stream.truncate(128 * 1024 * 1024 + 1)
        selected.chmod(0o644)
        self.refuses("bounds")

    def test_source_mutation_after_capture_before_detached_scan_refuses(self):
        selected = self.pair()[0]
        original = os.scandir
        changed = False

        def mutate(path):
            nonlocal changed
            if not changed and Path(path) == self.output:
                changed = True
                selected.write_bytes(b"late source mutation")
            return original(path)

        with mock.patch.object(SUBJECT.os, "scandir", side_effect=mutate):
            self.refuses("identity")
        self.assertTrue(changed)

    def ancestor_replacement_refuses(self, selected):
        original = os.scandir
        changed = False

        def replace(path):
            nonlocal changed
            if not changed and Path(path) == self.output:
                changed = True
                held = selected.with_name(selected.name + "-held")
                selected.rename(held)
                selected.symlink_to(held, target_is_directory=True)
            return original(path)

        with mock.patch.object(SUBJECT.os, "scandir", side_effect=replace):
            self.refuses("identity")
        self.assertTrue(changed)
        self.assertTrue(selected.is_symlink())

    def test_source_ancestor_replacement_after_capture_refuses(self):
        self.ancestor_replacement_refuses(self.stage / "src/apps/CoreService/build/Release")

    def test_repository_ancestor_replacement_after_capture_refuses(self):
        self.ancestor_replacement_refuses(self.repository / "tools/build")

    def test_nonenumerated_ancestor_mode_change_after_capture_refuses(self):
        for selected in (
            self.stage / "src/apps/CoreService/build/Release",
            self.repository / "tools/build",
        ):
            with self.subTest(ancestor=str(selected)):
                original = os.scandir
                changed = False
                mode = 0o750 if (selected.stat().st_mode & 0o777) != 0o750 else 0o700

                def replace(path):
                    nonlocal changed
                    if not changed and Path(path) == self.output:
                        changed = True
                        selected.chmod(mode)
                    return original(path)

                with mock.patch.object(SUBJECT.os, "scandir", side_effect=replace):
                    self.refuses("identity")
                self.assertTrue(changed)

    def test_foreign_timestamp_bytecode_is_not_executed_with_matching_source_pins(self):
        sources = [
            self.repository / relative
            for relative in (
                "tools/diagnostics/hs274_native_build.py",
                "tools/build/remap_runtime_build.py",
                "tools/build/remap_runtime_patch.py",
            )
        ]
        before = [hashlib.sha256(path.read_bytes()).hexdigest() for path in sources]
        source = sources[0]
        marker = self.repository / "foreign-code-executed"
        cache = Path(importlib.util.cache_from_source(str(source)))
        self.directory(cache.parent)
        code = compile(
            "from pathlib import Path\nPath("
            + repr(str(marker))
            + ").write_text('foreign bytecode executed')\n"
            + "raise RuntimeError('foreign bytecode marker')\n",
            str(source),
            "exec",
        )
        info = source.stat()
        self.write(
            cache,
            importlib.util.MAGIC_NUMBER
            + struct.pack("<III", 0, int(info.st_mtime) & 0xFFFFFFFF, info.st_size & 0xFFFFFFFF)
            + marshal.dumps(code),
        )
        self.assertIsNone(SUBJECT.observe(self.repository, self.owner))
        self.assertFalse(marker.exists())
        self.assertEqual(
            [hashlib.sha256(path.read_bytes()).hexdigest() for path in sources], before
        )

    def test_changed_pinned_builder_source_refuses(self):
        path = self.repository / "tools/build/remap_runtime_build.py"
        path.write_bytes(path.read_bytes() + b"\n# changed\n")
        self.refuses("source_identity")

    def test_changed_size_is_rebounded_before_payload_read(self):
        directory = self.root / "bounded-current-size"
        self.directory(directory)
        selected = directory / "growing.dat"
        self.write(selected, b"x")
        inode = selected.stat().st_ino
        original_stat, original_read = Path.lstat, os.read
        changed, read_bytes = False, 0

        def grow(path, *args, **kwargs):
            nonlocal changed
            info = original_stat(path, *args, **kwargs)
            if not changed and Path(path) == selected:
                changed = True
                selected.write_bytes(b"elevenbytes")
            return info

        def watched(descriptor, count):
            nonlocal read_bytes
            data = original_read(descriptor, count)
            if os.fstat(descriptor).st_ino == inode:
                read_bytes += len(data)
            return data

        with (
            mock.patch.object(Path, "lstat", autospec=True, side_effect=grow),
            mock.patch.object(SUBJECT.os, "read", side_effect=watched),
        ):
            with self.assertRaises(SUBJECT.ObservationRefusal) as caught:
                SUBJECT._scan(
                    directory,
                    SUBJECT.time.monotonic() + 30,
                    [],
                    primary=set(),
                    members=2048,
                    byte_limit=10,
                )
        self.assertEqual(caught.exception.code, "bounds")
        self.assertTrue(changed)
        self.assertEqual(read_bytes, 0)

    def test_cli_success_and_compilation_only_outputs_are_distinct(self):
        for extra, wanted in (([], FULL_PASS), (["--compilation-only"], COMPILATION_PASS)):
            output, errors = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                status = SUBJECT.main([str(self.repository), str(self.owner), *extra])
            self.assertEqual(status, 0)
            self.assertEqual(output.getvalue(), wanted)
            self.assertEqual(errors.getvalue(), "")

    def test_cli_refusal_never_emits_success(self):
        self.pair()[1].unlink()
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            status = SUBJECT.main([str(self.repository), str(self.owner)])
        self.assertEqual(status, 2)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(errors.getvalue(), "Unsigned preparation observation refused: inventory\n")


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ObservationControls)
    result = unittest.TextTestRunner().run(suite)
    successful = result.testsRun == 46 and result.wasSuccessful() and not result.skipped
    if successful:
        print(
            "PASS portable prepared runtime observation tests=46 failures=0 errors=0 skipped=0 native=unexecuted"
        )
    raise SystemExit(0 if successful else 1)
