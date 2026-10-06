# tools/build/remap_runtime_artifact_test.py
"""Freeze portable custody controls before implementation; no native build proof."""

import importlib.util
import os
from pathlib import Path
import stat
import shutil
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

MODULE_PATH = Path(
    os.environ.get("WP5_ARTIFACT_MODULE", Path(__file__).with_name("remap_runtime_artifact.py"))
)
SPEC = importlib.util.spec_from_file_location("wp5_artifact_subject", MODULE_PATH)
SUBJECT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SUBJECT
SPEC.loader.exec_module(SUBJECT)

PRODUCTS = (
    ("core", "src/apps/CoreService/build/Release/ErgoptiPlus-Remap-Core.app"),
    ("console", "src/apps/ConsoleUserServer/build/Release/ErgoptiPlus-Remap-Console.app"),
    ("cli", "src/bin/cli/build/Release/ergoptiplus_remap_cli"),
)
DESTINATIONS = (
    "Runtime/ErgoptiPlus-Remap-Core.app",
    "Runtime/ErgoptiPlus-Remap-Console.app",
    "Runtime/bin/ergoptiplus_remap_cli",
)


class RetainedCustodyControls(unittest.TestCase):
    """Real ordinary file incarnations with explicitly synthetic compiler outputs."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.owner = Path(self.temporary.name).resolve()
        self.owner.chmod(0o700)
        self.stage = self.owner / "modeled-compiler-stage"
        self.stage.mkdir(mode=0o700)
        self.deadline = time.monotonic() + 30
        self.executables = {}
        self.plists = {}
        self.resources = {}
        for target, relative in PRODUCTS:
            product = self.stage / relative
            if target == "cli":
                product.parent.mkdir(parents=True, mode=0o755)
                product.write_bytes(b"synthetic cli, not a native Mach-O image\n")
                product.chmod(0o755)
                self.executables[target] = product
                continue
            name = "ErgoptiPlus-Remap-" + ("Core" if target == "core" else "Console")
            executable = product / "Contents/MacOS" / name
            executable.parent.mkdir(parents=True, mode=0o755)
            executable.write_bytes(("synthetic " + target + "\n").encode())
            executable.chmod(0o755)
            plist = product / "Contents/Info.plist"
            plist.write_bytes(b"synthetic plist, not native metadata\n")
            plist.chmod(0o644)
            resource = product / "Contents/Resources/ordinary-resource.txt"
            resource.parent.mkdir(mode=0o755)
            resource.write_bytes(b"original resource bytes\n")
            resource.chmod(0o644)
            self.executables[target] = executable
            self.plists[target] = plist
            self.resources[target] = resource
        for path in self.stage.rglob("*"):
            if path.is_dir():
                path.chmod(0o755)
        self.owner_stamp = SUBJECT.capture_owner(self.owner, self.deadline)

    def capture(self):
        result = []
        members, size = 2048, 512 * 1024 * 1024
        for target, _ in PRODUCTS:
            snapshot = SUBJECT.capture_shipping(
                target,
                self.stage,
                self.deadline,
                remaining_members=members,
                remaining_bytes=size,
            )
            result.append(snapshot)
            members -= len(snapshot.directories) + len(snapshot.files)
            size -= sum(len(row.data) for row in snapshot.files)
        return tuple(result)

    def prepare(self, snapshots=None, guard=None):
        if snapshots is None:
            snapshots = self.capture()
        if guard is None:
            guard = SUBJECT._OneUse()
        return SUBJECT.prepare_unsigned(self.owner_stamp, snapshots, self.deadline, guard)

    def refusal(self, code, operation):
        with self.assertRaises(SUBJECT.ArtifactRefusal) as caught:
            operation()
        self.assertEqual(caught.exception.code, code)

    def replace_same_bytes(self, path):
        replacement = path.with_name(path.name + ".replacement")
        replacement.write_bytes(path.read_bytes())
        replacement.chmod(stat.S_IMODE(path.stat().st_mode))
        replacement.replace(path)

    def test_exact_three_snapshot_only_products(self):
        snapshots = self.capture()
        result = self.prepare(snapshots)
        self.assertEqual(tuple(row.target for row in snapshots), ("core", "console", "cli"))
        self.assertEqual(result.status, "prepared_unsigned_snapshot")
        self.assertEqual(result.root, self.owner / ".unsigned-runtime-preparation")
        self.assertEqual(result.products, DESTINATIONS)
        self.assertFalse(result.signing_qualified)
        self.assertFalse(result.installation_qualified)
        self.assertFalse(result.native_build_qualified)
        self.assertFalse(any(result.root.rglob("libduktape.a")))
        self.assertFalse((self.owner / "unsigned-runtime-preparation-result.json").exists())
        self.assertEqual(
            (
                result.root / DESTINATIONS[0] / "Contents/Resources/ordinary-resource.txt"
            ).read_bytes(),
            b"original resource bytes\n",
        )
        self.assertEqual(stat.S_IMODE((result.root / DESTINATIONS[2]).stat().st_mode), 0o755)

    def test_snapshots_are_immutable_detached_values(self):
        snapshots = self.capture()
        with self.assertRaises((AttributeError, TypeError)):
            snapshots[0].target = "stock"
        self.assertIs(type(snapshots[0].files), tuple)
        resource = next(
            row
            for row in snapshots[0].files
            if row.path == "Contents/Resources/ordinary-resource.txt"
        )
        self.assertEqual(resource.data, b"original resource bytes\n")
        with self.assertRaises((AttributeError, TypeError)):
            resource.data = b"replacement"

    def test_json_metadata_cannot_substitute_for_observations(self):
        self.refusal("inventory", lambda: self.prepare(({"target": "core", "status": "passed"},)))
        self.assertFalse((self.owner / ".unsigned-runtime-preparation").exists())

    def test_missing_cli_cannot_prepare_two_products(self):
        snapshots = self.capture()
        self.refusal("inventory", lambda: self.prepare(snapshots[:2]))

    def test_unexpected_fourth_product_refuses(self):
        snapshots = self.capture()
        self.refusal("inventory", lambda: self.prepare(snapshots + (snapshots[0],)))
        self.refusal(
            "inventory", lambda: SUBJECT.capture_shipping("duktape", self.stage, self.deadline)
        )

    def test_same_byte_executable_replacement_refuses(self):
        snapshots = self.capture()
        self.replace_same_bytes(self.executables["core"])
        self.refusal("identity_changed", lambda: self.prepare(snapshots))
        self.assertFalse((self.owner / ".unsigned-runtime-preparation").exists())

    def test_same_byte_plist_replacement_refuses(self):
        snapshots = self.capture()
        self.replace_same_bytes(self.plists["console"])
        self.refusal("identity_changed", lambda: self.prepare(snapshots))

    def test_same_byte_resource_replacement_refuses(self):
        snapshots = self.capture()
        self.replace_same_bytes(self.resources["core"])
        self.refusal("identity_changed", lambda: self.prepare(snapshots))

    def test_resource_edit_and_byte_restoration_refuses(self):
        snapshots = self.capture()
        path = self.resources["console"]
        original = path.read_bytes()
        path.write_bytes(b"changed resource\n")
        path.write_bytes(original)
        self.refusal("identity_changed", lambda: self.prepare(snapshots))

    def test_member_addition_and_removal_refuse(self):
        snapshots = self.capture()
        added = self.resources["core"].with_name("unconfirmed-resource.txt")
        added.write_bytes(b"unconfirmed\n")
        added.chmod(0o644)
        self.refusal(
            "identity_changed", lambda: SUBJECT.current_shipping(snapshots[0], self.deadline)
        )
        added.unlink()
        snapshots = self.capture()
        self.resources["core"].unlink()
        self.refusal(
            "identity_changed", lambda: SUBJECT.current_shipping(snapshots[0], self.deadline)
        )

    def test_directory_replacement_refuses(self):
        snapshots = self.capture()
        directory = self.resources["core"].parent
        parked = directory.with_name("parked")
        directory.rename(parked)
        directory.mkdir(mode=0o755)
        (directory / self.resources["core"].name).write_bytes(b"original resource bytes\n")
        (directory / self.resources["core"].name).chmod(0o644)
        self.refusal("identity_changed", lambda: self.prepare(snapshots))

    def test_nested_app_and_executable_helpers_refuse(self):
        root = self.resources["core"].parent
        nested = root / "StockHelper.app"
        nested.mkdir(mode=0o755)
        self.refusal("inventory", self.capture)
        nested.rmdir()
        helper = root / "helper"
        helper.write_bytes(b"#!/bin/sh\nexit 0\n")
        helper.chmod(0o755)
        self.refusal("inventory", self.capture)

    def test_secondary_macho_refuses_even_without_execute_mode(self):
        helper = self.resources["core"].with_name("opaque-resource")
        helper.write_bytes(bytes.fromhex("cffaedfe") + b"not qualified native code")
        helper.chmod(0o644)
        self.refusal("inventory", self.capture)

    def test_symlink_hardlink_and_fifo_refuse(self):
        resource = self.resources["core"]
        foreign = self.owner / "foreign.txt"
        foreign.write_bytes(b"foreign bytes\n")
        resource.unlink()
        resource.symlink_to(foreign)
        self.refusal("unsafe_path", self.capture)
        resource.unlink()
        os.link(foreign, resource)
        self.refusal("unsafe_path", self.capture)
        resource.unlink()
        os.mkfifo(resource, mode=0o644)
        self.refusal("unsafe_path", self.capture)

    def test_modes_and_fixed_bounds_are_closed(self):
        self.assertEqual(SUBJECT.MAX_FILE_BYTES, 128 * 1024 * 1024)
        self.assertEqual(SUBJECT.MAX_TOTAL_BYTES, 512 * 1024 * 1024)
        self.assertEqual(SUBJECT.MAX_MEMBERS, 2048)
        self.resources["core"].chmod(0o666)
        self.refusal("unsafe_path", self.capture)
        self.resources["core"].chmod(0o644)
        oversized = self.resources["core"].with_name("oversized-resource")
        with oversized.open("wb") as stream:
            stream.truncate(128 * 1024 * 1024 + 1)
        oversized.chmod(0o644)
        self.refusal("inventory", self.capture)

    def test_capture_cannot_extend_aggregate_capacity(self):
        for quota in (
            {"remaining_bytes": 1},
            {"remaining_members": 1},
            {"remaining_bytes": 512 * 1024 * 1024 + 1},
            {"remaining_members": 2049},
        ):
            with self.subTest(quota=quota):
                self.refusal(
                    "inventory",
                    lambda: SUBJECT.capture_shipping("core", self.stage, self.deadline, **quota),
                )

    def test_aggregate_bounds_have_independent_closed_edges(self):
        SUBJECT._validate_bounds(2048, 512 * 1024 * 1024, 128 * 1024 * 1024)
        for values in (
            (2049, 1, 1),
            (1, 512 * 1024 * 1024 + 1, 1),
            (1, 128 * 1024 * 1024 + 1, 128 * 1024 * 1024 + 1),
            (True, 1, 1),
            (1, float("inf"), 1),
        ):
            with self.subTest(values=values):
                self.refusal("inventory", lambda: SUBJECT._validate_bounds(*values))

    def test_missing_required_primary_and_plist_refuse(self):
        path = self.plists["core"]
        data = path.read_bytes()
        path.unlink()
        self.refusal("inventory", self.capture)
        path.write_bytes(data)
        path.chmod(0o644)
        self.executables["console"].unlink()
        self.refusal("inventory", self.capture)

    def test_earliest_owner_stamp_detects_replacement(self):
        snapshots = self.capture()
        parked = self.owner.with_name(self.owner.name + "-parked")
        self.owner.rename(parked)
        self.owner.mkdir(mode=0o700)
        # Preserve stage/member incarnations so the owner stamp is the causal guard.
        (parked / self.stage.name).rename(self.stage)

        def restore_owner():
            shutil.rmtree(self.owner)
            parked.rename(self.owner)

        self.addCleanup(restore_owner)
        self.refusal("identity_changed", lambda: self.prepare(snapshots))

    def test_foreign_owner_cannot_consume_original_stage(self):
        snapshots = self.capture()
        foreign_owner = self.owner / "other-owner"
        foreign_owner.mkdir(mode=0o700)
        stamp = SUBJECT.capture_owner(foreign_owner, self.deadline)
        self.refusal(
            "unsafe_path",
            lambda: SUBJECT.prepare_unsigned(stamp, snapshots, self.deadline, SUBJECT._OneUse()),
        )
        self.assertFalse((foreign_owner / ".unsigned-runtime-preparation").exists())

    def test_redirected_stage_cannot_mint_observation(self):
        alias = self.owner / "aliased-stage"
        alias.symlink_to(self.stage, target_is_directory=True)
        self.refusal("unsafe_path", lambda: SUBJECT.capture_shipping("core", alias, self.deadline))

    def test_deadline_is_original_and_not_reset(self):
        snapshots = self.capture()
        for value in (time.monotonic() - 1, float("nan"), float("inf"), True):
            with self.subTest(value=value):
                self.refusal(
                    "deadline",
                    lambda: SUBJECT.prepare_unsigned(
                        self.owner_stamp, snapshots, value, SUBJECT._OneUse()
                    ),
                )

    def test_destination_collision_preserves_foreign_bytes(self):
        destination = self.owner / ".unsigned-runtime-preparation"
        destination.mkdir(mode=0o700)
        foreign = destination / "foreign.txt"
        foreign.write_bytes(b"keep collision bytes\n")
        self.refusal("unsafe_path", self.prepare)
        self.assertEqual(foreign.read_bytes(), b"keep collision bytes\n")

    def test_one_use_success_and_failure_cannot_be_reused(self):
        guard = SUBJECT._OneUse()
        with guard.claim():
            pass
        self.refusal("handoff_required", lambda: guard.claim().__enter__())
        failed = SUBJECT._OneUse()
        with self.assertRaisesRegex(RuntimeError, "consumer failure"):
            with failed.claim():
                raise RuntimeError("consumer failure")
        self.refusal("handoff_required", lambda: failed.claim().__enter__())

    def test_caught_reentry_still_poisons_outer_claim(self):
        guard = SUBJECT._OneUse()
        with self.assertRaises(SUBJECT.ArtifactRefusal) as outer:
            with guard.claim():
                self.refusal("reentered", lambda: guard.claim().__enter__())
        self.assertEqual(outer.exception.code, "reentered")
        self.refusal("handoff_required", lambda: guard.claim().__enter__())

    def test_real_write_failure_leaves_no_complete_outcome(self):
        snapshots = self.capture()
        actual_write = os.write
        writes = []

        def failing_write(descriptor, data):
            writes.append(bytes(data))
            actual_write(descriptor, bytes(data)[:1])
            raise OSError("actual output write failure")

        with patch.object(SUBJECT.os, "write", side_effect=failing_write):
            self.refusal("consumer_failed", lambda: self.prepare(snapshots))
        self.assertTrue(writes)
        self.assertFalse((self.owner / "unsigned-runtime-preparation-result.json").exists())

    def test_real_close_failure_leaves_no_complete_outcome(self):
        snapshots = self.capture()
        actual_close = os.close
        closed = []

        def refused_close(descriptor):
            closed.append(descriptor)
            actual_close(descriptor)
            raise OSError("closure cannot be acknowledged")

        with patch.object(SUBJECT.os, "close", side_effect=refused_close):
            self.refusal("consumer_failed", lambda: self.prepare(snapshots))
        self.assertTrue(closed)
        self.assertFalse((self.owner / "unsigned-runtime-preparation-result.json").exists())

    def test_foreign_io_cut_cannot_copy_reopened_resource(self):
        snapshots = self.capture()
        actual_current = SUBJECT.current_shipping
        calls = []

        def after_current(snapshot, deadline):
            actual_current(snapshot, deadline)
            calls.append(snapshot.target)
            if len(calls) == 1:
                self.resources["core"].write_bytes(b"foreign replacement bytes\n")

        with patch.object(SUBJECT, "current_shipping", side_effect=after_current):
            self.refusal("identity_changed", lambda: self.prepare(snapshots))
        copied = (
            self.owner
            / ".unsigned-runtime-preparation"
            / DESTINATIONS[0]
            / "Contents/Resources/ordinary-resource.txt"
        )
        if copied.exists():
            self.assertEqual(copied.read_bytes(), b"original resource bytes\n")
        self.assertFalse((self.owner / "unsigned-runtime-preparation-result.json").exists())

    def test_uncertain_output_close_still_closes_original_parent_descriptor(self):
        snapshots = self.capture()
        actual_open, actual_close = os.open, os.close
        output_pairs, closed = [], []

        def record_open(path, flags, *arguments, **keywords):
            descriptor = actual_open(path, flags, *arguments, **keywords)
            if flags & os.O_WRONLY:
                output_pairs.append((descriptor, keywords["dir_fd"]))
            return descriptor

        def refuse_output_close(descriptor):
            actual_close(descriptor)
            closed.append(descriptor)
            if output_pairs and descriptor == output_pairs[0][0]:
                raise OSError("output close was performed but not acknowledged")

        with (
            patch.object(SUBJECT.os, "open", side_effect=record_open),
            patch.object(SUBJECT.os, "close", side_effect=refuse_output_close),
        ):
            self.refusal("consumer_failed", lambda: self.prepare(snapshots))
        self.assertEqual(len(output_pairs), 1)
        self.assertIn(output_pairs[0][1], closed)
        with self.assertRaises(OSError):
            os.fstat(output_pairs[0][1])

    def test_final_output_inventory_refuses_at_first_unknown_member(self):
        snapshots = self.capture()
        actual_scandir = os.scandir
        destination = self.owner / ".unsigned-runtime-preparation"
        yielded = []
        injected = False

        class ObservedScan:
            def __init__(self, path):
                self.path = Path(path)
                self.stream = actual_scandir(path)

            def __enter__(self):
                self.stream.__enter__()
                return self

            def __exit__(self, *arguments):
                return self.stream.__exit__(*arguments)

            def __iter__(self):
                return self

            def __next__(self):
                entry = next(self.stream)
                if self.path == destination:
                    yielded.append(entry.name)
                return entry

        def observed_scan(path):
            nonlocal injected
            if Path(path) == destination and not injected:
                injected = True
                for number in range(2049):
                    (destination / ("unknown-" + str(number))).write_bytes(b"unconfirmed output\n")
            return ObservedScan(path)

        with patch.object(SUBJECT.os, "scandir", side_effect=observed_scan):
            with self.assertRaises(SUBJECT.ArtifactRefusal):
                self.prepare(snapshots)
        self.assertTrue(injected)
        self.assertLessEqual(len(yielded), 2)
        self.assertFalse((self.owner / "unsigned-runtime-preparation-result.json").exists())


class ActualBuilderCustodyControls(unittest.TestCase):
    """Exercise the actual builder with modeled compiler/factory endpoints only."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.owner = Path(self.temporary.name).resolve()
        self.owner.chmod(0o700)
        # Destructive incarnation controls operate on actual copied source bytes,
        # so normal CI never changes the canonical checkout's files or inodes.
        self.sources = tempfile.TemporaryDirectory()
        self.addCleanup(self.sources.cleanup)
        self.repository = Path(self.sources.name).resolve()
        for relative in (
            "tools/build/remap_runtime_artifact.py",
            "tools/build/remap_runtime_build.py",
            "tools/diagnostics/hs274_native_build.py",
        ):
            source = MODULE_PATH.resolve().parents[2] / relative
            destination = self.repository / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        path = self.repository / "tools/build/remap_runtime_build.py"
        spec = importlib.util.spec_from_file_location("wp5_actual_builder_controls", path)
        self.builder = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.builder
        spec.loader.exec_module(self.builder)
        self.stage = self.owner / "modeled-compiler-stage"
        self.events = []
        self.prebuilt = False
        self.first_phase_hook = None
        self.original_files = ()
        from types import SimpleNamespace

        self.namespace = SimpleNamespace
        self.factory = SimpleNamespace(
            SourceRefusal=RuntimeError,
            capture_dependencies=lambda repository, deadline: None,
            prepare_owned_source=lambda repository, pristine, deadline: self.projection,
            current_staged_source=lambda image, deadline: None,
        )
        self.projection = SimpleNamespace(
            pins={
                "upstream": self.builder.BASE.UPSTREAM,
                "cpm": self.builder.BASE.CPM,
                "vhd": self.builder.BASE.VIRTUAL_HID,
            },
            inventory=tuple(range(4505)),
            replacements=tuple(range(57)),
            repository=self.repository,
        )
        patches = (
            patch.object(self.builder.sys, "platform", "darwin"),
            patch.object(self.builder, "_source_factory", return_value=self.factory),
            patch.object(self.builder.shutil, "which", return_value="/usr/bin/true"),
            patch.object(self.builder, "_RUN_PHASE", side_effect=self.phase),
            patch.object(self.builder.BASE, "acquire_xcodegen", side_effect=self.acquire),
            patch.object(self.builder, "materialize_owned_source", side_effect=self.materialize),
            patch.object(self.builder, "capture_generated_inputs", side_effect=self.generated),
            patch.object(self.builder, "validate_plist", return_value=None),
            # Modeled endpoints cannot satisfy real native inventory metadata.
            patch.object(self.builder, "validate_owned_record", return_value=None),
        )
        for item in patches:
            item.start()
            self.addCleanup(item.stop)

    def acquire(self, owner, deadline):
        return Path("/usr/bin/true"), {
            "schema": 1,
            "phase": "xcodegen_acquisition",
            "status": "passed",
            "elapsed_seconds": 0,
            "operation": "verified-HTTPS-download-and-ordinary-extraction",
            "child_process_executed": False,
        }

    def materialize(self, projection, owner, deadline):
        self.stage.mkdir(mode=0o700)
        expected = {}
        for label, recipe, _ in self.builder.TARGETS:
            directory = self.stage / recipe
            directory.mkdir(parents=True, mode=0o755)
            path = directory / "project.yml"
            path.write_bytes(("name: Model_" + label + "\n").encode())
            path.chmod(0o644)
            expected[str(path.relative_to(self.stage))] = self.builder.BASE.digest(
                path.read_bytes()
            )
        snapshot = self.builder.snapshot_inputs(self.stage, expected, deadline)
        self.original_files = snapshot.files
        self.image = self.namespace(
            root=self.stage,
            root_identity=snapshot.root_identity,
            files=snapshot.files,
            links=(),
            projection=projection,
        )
        return self.image

    def generated(self, image, deadline):
        expected = {row.path: self.builder.BASE.digest(row.data) for row in self.original_files}
        for number in range(12):
            path = self.stage / ("generated-" + str(number).zfill(2))
            path.write_bytes(b"modeled generated version\n")
            path.chmod(0o644)
            expected[path.name] = self.builder.BASE.digest(path.read_bytes())
        if self.prebuilt:
            path = self.stage / self.builder.TARGETS[0][1] / self.builder.TARGETS[0][2]
            path.parent.mkdir(parents=True, mode=0o755)
            path.write_bytes(b"preexisting, not newly built\n")
        return self.builder.snapshot_inputs(self.stage, expected, deadline)

    def phase(self, name, command, cwd, owner, deadline):
        self.events.append(name)
        if len(self.events) == 1 and self.first_phase_hook is not None:
            self.first_phase_hook()
        if name.endswith("_generate"):
            label = name.removesuffix("_generate")
            path = Path(cwd) / ("Model_" + label + ".xcodeproj/project.pbxproj")
            path.parent.mkdir(mode=0o755)
            path.write_bytes(b"modeled generated native project\n")
            path.chmod(0o644)
        if name.endswith("_build"):
            label = name.removesuffix("_build")
            _, recipe, relative = next(row for row in self.builder.TARGETS if row[0] == label)
            executable = self.stage / recipe / relative
            executable.parent.mkdir(parents=True, mode=0o755)
            executable.write_bytes(("modeled native product " + label + "\n").encode())
            executable.chmod(0o644 if label == "duktape" else 0o755)
            if label in ("core", "console"):
                plist = executable.parents[1] / "Info.plist"
                plist.write_bytes(b"modeled plist, not actual native metadata\n")
                plist.chmod(0o644)
                resource = executable.parents[1] / "Resources/ordinary.txt"
                resource.parent.mkdir(mode=0o755)
                resource.write_bytes(b"captured ordinary modeled resource\n")
                resource.chmod(0o644)
            # Model the independently required actual product directory modes;
            # mkdir's requested bits alone are restricted by the process umask.
            for directory in self.stage.rglob("*"):
                if directory.is_dir() and stat.S_IMODE(directory.stat().st_mode) != 0o755:
                    directory.chmod(0o755)
        if name.endswith("_architectures"):
            (self.owner / (name + ".stdout")).write_bytes(b"arm64 x86_64\n")
        return {
            "schema": 1,
            "phase": name,
            "status": "passed",
            "elapsed_seconds": 0,
            "exit_status": 0,
        }

    def invoke(self, preparation=False):
        method = (
            self.builder.compile_owned_and_prepare if preparation else self.builder.compile_owned
        )
        return method(self.repository, self.owner, 300, upstream=self.repository)

    def consumer_mutation(self, callback):
        actual_loader = self.builder._load_artifact

        def load(snapshot, deadline):
            module = actual_loader(snapshot, deadline)
            original = module.prepare_unsigned

            def consume(*arguments):
                callback()
                return original(*arguments)

            module.prepare_unsigned = consume
            return module

        return patch.object(self.builder, "_load_artifact", side_effect=load)

    def test_default_callgraph_performs_zero_artifact_loading_or_capture(self):
        with patch.object(self.builder, "_load_artifact", create=True) as loader:
            result = self.invoke()
        loader.assert_not_called()
        self.assertIs(type(result), dict)
        self.assertEqual(result["status"], "passed")
        self.assertFalse((self.owner / ".unsigned-runtime-preparation").exists())
        self.assertTrue((self.owner / "owned-native-build-result.json").exists())
        self.assertEqual(len(result["products"]), 4)

    def test_fixed_opt_in_runs_actual_builder_and_snapshot_copy(self):
        result = self.invoke(preparation=True)
        self.assertEqual(result.compilation["status"], "passed")
        self.assertEqual(result.preparation.status, "prepared_unsigned_snapshot")
        self.assertFalse(result.preparation.native_build_qualified)
        self.assertFalse(result.preparation.signing_qualified)
        self.assertFalse(result.preparation.installation_qualified)
        copied = result.preparation.root / DESTINATIONS[0] / "Contents/Resources/ordinary.txt"
        self.assertEqual(copied.read_bytes(), b"captured ordinary modeled resource\n")
        self.assertEqual(len(result.compilation["products"]), 4)

    def test_prebuilt_image_still_refuses_through_actual_phase_owner(self):
        self.prebuilt = True
        with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
            self.invoke(preparation=True)
        self.assertEqual(caught.exception.code, "product_identity")
        self.assertNotIn("duktape_generate", self.events)
        self.assertFalse((self.owner / "owned-native-build-result.json").exists())

    def test_retained_source_restoration_after_compile_refuses_preparation(self):
        def mutate():
            path = self.stage / "src/apps/CoreService/project.yml"
            original = path.read_bytes()
            path.write_bytes(b"different recipe\n")
            path.write_bytes(original)

        with self.consumer_mutation(mutate):
            result = self.invoke(preparation=True)
        self.assertEqual(result.compilation["status"], "passed")
        self.assertEqual(result.preparation.code, "source_identity")
        self.assertEqual(result.preparation.status, "refused")
        self.assertTrue((self.owner / "owned-native-build-result.json").exists())
        self.assertFalse((self.owner / "owned-build-refusal.json").exists())

    def test_nonshipping_retained_duktape_replacement_refuses_preparation(self):
        def mutate():
            path = self.stage / "vendor/duktape-src/build/Release/libduktape.a"
            replacement = path.with_name("replacement.a")
            replacement.write_bytes(path.read_bytes())
            replacement.chmod(0o644)
            replacement.replace(path)

        with self.consumer_mutation(mutate):
            result = self.invoke(preparation=True)
        self.assertEqual(result.compilation["status"], "passed")
        self.assertEqual(result.preparation.code, "source_identity")
        self.assertEqual(result.preparation.status, "refused")
        self.assertFalse(any((self.owner / ".unsigned-runtime-preparation").rglob("libduktape.a")))

    def test_captured_consumer_same_bytes_new_inode_refuses_before_first_phase(self):
        path = self.repository / "tools/build/remap_runtime_artifact.py"
        replacement = path.with_name("artifact-control-replacement.py")
        original = path.read_bytes()
        self.addCleanup(lambda: path.write_bytes(original))

        def replace():
            replacement.write_bytes(original)
            replacement.chmod(stat.S_IMODE(path.stat().st_mode))
            replacement.replace(path)

        self.first_phase_hook = replace
        with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
            self.invoke(preparation=True)
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(self.events, ["xcode_version"])
        self.assertFalse((self.owner / "owned-native-build-result.json").exists())

    def test_post_compile_collision_preserves_original_completed_receipt(self):
        def collide():
            destination = self.owner / ".unsigned-runtime-preparation"
            destination.mkdir(mode=0o700)
            (destination / "foreign").write_bytes(b"preserve foreign collision\n")

        with self.consumer_mutation(collide):
            result = self.invoke(preparation=True)
        receipt = self.owner / "owned-native-build-result.json"
        self.assertEqual(self.builder.parse_json(receipt.read_bytes()), result.compilation)
        self.assertEqual(result.preparation.status, "refused")
        self.assertEqual(result.preparation.code, "unsafe_path")
        self.assertEqual(
            (self.owner / ".unsigned-runtime-preparation/foreign").read_bytes(),
            b"preserve foreign collision\n",
        )
        self.assertFalse((self.owner / "owned-build-refusal.json").exists())

    def test_new_cli_refused_snapshot_does_not_rewrite_compile_as_failure(self):
        from contextlib import redirect_stdout, redirect_stderr
        from io import StringIO

        def collide():
            (self.owner / ".unsigned-runtime-preparation").mkdir(mode=0o700)

        output, errors = StringIO(), StringIO()
        with self.consumer_mutation(collide), redirect_stdout(output), redirect_stderr(errors):
            status = self.builder.main(
                [
                    str(self.repository),
                    str(self.owner),
                    "--prepare-owned",
                    "--upstream",
                    str(self.repository),
                ]
            )
        self.assertEqual(status, 2)
        self.assertIn("PASS unsigned actual owned four-target compilation", output.getvalue())
        self.assertIn("Unsigned runtime preparation refused: unsafe_path", errors.getvalue())
        self.assertTrue((self.owner / "owned-native-build-result.json").exists())
        self.assertFalse((self.owner / "owned-build-refusal.json").exists())

    def test_initial_owner_stamp_precedes_artifact_source_loading(self):
        actual_loader = self.builder._load_artifact
        parked = self.owner.with_name(self.owner.name + "-original-owner")

        def restore():
            if parked.exists():
                shutil.rmtree(self.owner)
                parked.rename(self.owner)

        self.addCleanup(restore)

        def replaced_owner(snapshot, deadline):
            module = actual_loader(snapshot, deadline)
            self.owner.rename(parked)
            self.owner.mkdir(mode=0o700)
            return module

        with patch.object(self.builder, "_load_artifact", side_effect=replaced_owner):
            with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
                self.invoke(preparation=True)
        self.assertEqual(caught.exception.code, "owner_identity")
        self.assertEqual(self.events, [])
        self.assertFalse((self.owner / "owned-native-build-result.json").exists())

    def test_displaced_source_after_completed_consumer_is_separate_refusal(self):
        actual_loader = self.builder._load_artifact

        def load(snapshot, deadline):
            module = actual_loader(snapshot, deadline)
            original = module.prepare_unsigned

            def consume(*arguments):
                result = original(*arguments)
                self.stage.rename(self.stage.with_name("displaced-completed-stage"))
                return result

            module.prepare_unsigned = consume
            return module

        with patch.object(self.builder, "_load_artifact", side_effect=load):
            result = self.invoke(preparation=True)
        self.assertEqual(result.compilation["status"], "passed")
        self.assertEqual(result.preparation.status, "refused")
        self.assertEqual(result.preparation.code, "source_identity")
        receipt = self.owner / "owned-native-build-result.json"
        self.assertEqual(self.builder.parse_json(receipt.read_bytes()), result.compilation)
        self.assertFalse((self.owner / "owned-build-refusal.json").exists())


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    passed = result.wasSuccessful() and result.testsRun == 40 and not result.skipped
    print(
        "PASS" if passed else "FAIL",
        "portable retained runtime snapshot tests=" + str(result.testsRun),
        "failures=" + str(len(result.failures)),
        "errors=" + str(len(result.errors)),
        "skipped=" + str(len(result.skipped)),
        "native=unexecuted",
    )
    raise SystemExit(0 if passed else 1)
