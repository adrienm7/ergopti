"""Portable real-filesystem and fixed native-command planning controls.

No Darwin compilation, CMS, installed capability, physical capture or shipping
qualification is created by these tests. Native validator controls stay separate.
"""

import hashlib
import os
from pathlib import Path
import tempfile
import time
import re
import unittest
import owned_runtime_product_build as product


class ProductionBuildControls(unittest.TestCase):
    def setUp(self):
        self.owner = tempfile.TemporaryDirectory(prefix="ergopti-production-build-controls-")
        self.addCleanup(self.owner.cleanup)
        self.root = Path(self.owner.name).resolve()
        self.leaf = self.root / "source"
        self.leaf.write_bytes(b"fixed independent source bytes\n")

    def held(self):
        fd = os.open(self.leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        item = product.HeldSource(
            self.leaf,
            fd,
            product.identity(os.fstat(fd)),
            self.leaf.read_bytes(),
            "filesystem-control-not-git-qualification",
        )
        self.addCleanup(item.close)
        return item

    def test_held_read_and_atime_only_stay_current(self):
        held = self.held()
        before = os.fstat(held.descriptor)
        self.assertEqual(os.pread(held.descriptor, before.st_size, 0), held.data)
        held.current()

        # The explicit fingerprint omits access time and retains every stable
        # identity/content field; no filesystem-dependent atime assumption.
        class AccessTimeOnly:
            def __getattr__(self, name):
                if name == "st_atime":
                    return before.st_atime + 3600
                if name == "st_atime_ns":
                    return before.st_atime_ns + 3600000000000
                return getattr(before, name)

        self.assertEqual(product.identity(before), product.identity(AccessTimeOnly()))

    def test_named_inode_replacement_refuses(self):
        held = self.held()
        replacement = self.root / "replacement"
        replacement.write_bytes(held.data)
        os.replace(replacement, self.leaf)
        with self.assertRaises(product.ProductBuildRefusal):
            held.current()

    def test_held_content_mutation_refuses(self):
        held = self.held()
        self.leaf.write_bytes(b"changed independent source bytes\n")
        with self.assertRaises(product.ProductBuildRefusal):
            held.current()

    def test_source_mode_change_refuses(self):
        held = self.held()
        os.chmod(self.leaf, 0o600 if self.leaf.stat().st_mode & 0o077 else 0o644)
        with self.assertRaises(product.ProductBuildRefusal):
            held.current()

    def test_product_hardlink_refuses(self):
        os.link(self.leaf, self.root / "alias")
        with self.assertRaises(product.ProductBuildRefusal):
            product._snapshot(self.root, time.monotonic() + 10)

    def test_product_directory_symlink_refuses(self):
        outside = self.root / "real"
        outside.mkdir()
        (self.root / "linked").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(product.ProductBuildRefusal):
            product._snapshot(self.root, time.monotonic() + 10)

    def test_existing_destination_refuses(self):
        before = self.leaf.read_bytes()
        with self.assertRaises(FileExistsError):
            product._write_exclusive(self.leaf, b"not a replacement", 0o644, time.monotonic() + 10)
        self.assertEqual(self.leaf.read_bytes(), before)

    def test_compiled_copy_hash_mismatch_refuses(self):
        stamp = product.identity(self.leaf.stat())
        with self.assertRaises(product.ProductBuildRefusal):
            product._compiled_bytes(
                self.leaf,
                (stamp, hashlib.sha256(b"other bytes").hexdigest()),
                time.monotonic() + 10,
            )

    def commands(self):
        work = self.root / "work"
        work.mkdir()
        sdk = self.root / "MacOSX.sdk"
        sdk.mkdir()
        headers = self.root / "hs-lua-headers"
        headers.mkdir()
        return dict(product.compile_commands(self.root, work, sdk, headers))

    def test_exact_both_architecture_compile_rosters(self):
        commands = self.commands()
        self.assertEqual(
            set(commands),
            {
                "lifecycle_arm64",
                "lifecycle_x86_64",
                "installer_arm64",
                "installer_x86_64",
                "validator_arm64",
                "validator_x86_64",
                "module_arm64",
                "module_x86_64",
                "installer_universal",
                "validator_universal",
                "module_universal",
            },
        )
        for arch in ("arm64", "x86_64"):
            self.assertIn(arch + "-apple-macosx13.0", commands["installer_" + arch])
            self.assertIn(
                str(self.root / product.SWIFT / "OwnedRuntimePublisherIdentity.swift"),
                commands["installer_" + arch],
            )
            self.assertIn(
                str(self.root / product.SWIFT / "OwnedRuntimePublisherIdentity.swift"),
                commands["validator_" + arch],
            )
            self.assertNotIn(
                str(self.root / product.SWIFT / "Main.swift"), commands["installer_" + arch]
            )

    def test_lifecycle_object_links_only_installer_once(self):
        commands = self.commands()
        for arch in ("arm64", "x86_64"):
            object_path = str(self.root / "work" / ("lifecycle_" + arch + ".o"))
            self.assertEqual(commands["installer_" + arch].count(object_path), 1)
            self.assertNotIn(object_path, commands["validator_" + arch])
            self.assertNotIn(object_path, commands["module_" + arch])

    def test_module_uses_only_fixed_repository_and_hs_headers(self):
        commands = self.commands()
        for arch in ("arm64", "x86_64"):
            argv = commands["module_" + arch]
            self.assertEqual(
                [argv[i + 1] for i, v in enumerate(argv) if v == "-I"],
                [str(self.root / "hs-lua-headers"), str(self.root / "tools/build")],
            )
            self.assertIn("-bundle", argv)
            self.assertIn(str(self.root / product.MODULE_SOURCE), argv)

    def test_signature_header_reaches_both_native_swift_products(self):
        commands = self.commands()
        self.assertEqual(
            product.SIGNATURE_HEADER,
            product.LAUNCHER + "CPOSIXCompatibility/include/OwnedRuntimeSignatureCompatibility.h",
        )
        self.assertEqual(product.SOURCE_PATHS.count(product.SIGNATURE_HEADER), 1)
        header = str(self.root / product.SIGNATURE_HEADER)
        for arch in ("arm64", "x86_64"):
            for role in ("installer", "validator"):
                argv = commands[role + "_" + arch]
                self.assertEqual(argv.count("-import-objc-header"), 1)
                self.assertEqual(argv[argv.index("-import-objc-header") + 1], header)
            self.assertNotIn("-import-objc-header", commands["module_" + arch])

    def test_expired_copy_deadline_refuses(self):
        stamp = (
            product.identity(self.leaf.stat()),
            hashlib.sha256(self.leaf.read_bytes()).hexdigest(),
        )
        with self.assertRaises(product.ProductBuildRefusal):
            product._compiled_bytes(self.leaf, stamp, time.monotonic() - 1)


class DaemonReportBuildControls(unittest.TestCase):
    """Command/source models only; these never compile or mint a native owner."""

    def setUp(self):
        self.owner = tempfile.TemporaryDirectory(prefix="ergopti-report-build-controls-")
        self.addCleanup(self.owner.cleanup)
        self.root = Path(self.owner.name).resolve()
        self.work = self.root / "work"
        self.sdk = self.root / "MacOSX.sdk"
        self.headers = self.root / "hs-lua-headers"
        for path in (self.work, self.sdk, self.headers):
            path.mkdir()

    def commands(self, report):
        return dict(
            product.compile_commands(
                self.root, self.work, self.sdk, self.headers, daemon_report=report
            )
        )

    def test_default_source_rosters_are_exact_and_report_is_additive(self):
        self.assertEqual(len(product.HELPER_SOURCES), 10)
        self.assertEqual(len(product.VALIDATOR_SOURCES), 7)
        self.assertEqual(product.product_source_paths(), product.SOURCE_PATHS)
        expected = tuple(
            product.SWIFT + "OwnedVirtualHIDDaemonReport" + name + ".swift"
            for name in (
                "Protocol",
                "Observer",
                "RequestChannel",
                "StageOwner",
                "Worker",
                "Clock",
                "Reference",
            )
        ) + (product.SWIFT + "LauncherTimings.generated.swift",)
        self.assertEqual(product.REPORT_SWIFT_SOURCES, expected)
        selected = product.product_source_paths(daemon_report=True)
        self.assertEqual(len(selected), len(set(selected)))
        for path in expected + product.SOURCE_PATHS:
            self.assertIn(path, selected)
        for forbidden in ("MainOperation", "DriverPublication", "ActivationSession", "Choice"):
            self.assertFalse(any(forbidden in path for path in selected))

    def test_report_has_exact_native_objects_for_both_architectures(self):
        commands = self.commands(True)
        expected = {
            name + "_" + arch
            for arch in ("arm64", "x86_64")
            for name in (
                "lifecycle",
                "installer",
                "validator",
                "module",
                "report_cposixcompatibility",
                "report_ownedprogramcompatibility",
                "report_ownedvhdreportsocketidentity",
            )
        }
        expected.update(("installer_universal", "validator_universal", "module_universal"))
        self.assertEqual(set(commands), expected)
        # Every name becomes a native phase; the backend admits only this shape.
        for name in commands:
            self.assertRegex("production_" + name, r"^[a-z][a-z0-9_]{0,63}$")
        for arch in ("arm64", "x86_64"):
            installer = commands["installer_" + arch]
            for stem in (
                "lifecycle",
                "CPOSIXCompatibility",
                "OwnedProgramCompatibility",
                "OwnedVHDReportSocketIdentity",
            ):
                self.assertEqual(installer.count(str(self.work / (stem + "_" + arch + ".o"))), 1)
            self.assertIn("-fmodule-map-file=" + str(self.work / "report.modulemap"), installer)
            self.assertEqual(installer.count("ERGOPTI_DAEMON_REPORT"), 1)
            self.assertEqual(installer.count("SWIFT_PACKAGE"), 1)
            for relative in product.REPORT_SWIFT_SOURCES:
                self.assertEqual(installer.count(str(self.root / relative)), 1)

    def test_live_helper_enrolls_the_idle_core_service_and_default_does_not(self):
        # WP6 install half: before this, the live helper published files only
        # and nothing wrote or started com.ergoptiplus.runtime.core.
        expected = tuple(
            product.SWIFT + "OwnedRuntime" + name + ".swift"
            for name in (
                "IdleServiceEntry",
                "CoreProvisionOwner",
                "CoreServiceOwner",
                "CoreLaunchctl",
                "CorePlistCustody",
                "CoreExitObservation",
                # WP8: the first install also loads the VirtualHIDDevice daemon job.
                "VirtualHIDProvisionOwner",
            )
        )
        self.assertEqual(product.IDLE_CORE_SWIFT_SOURCES, expected)
        selected = product.product_source_paths(daemon_report=True)
        original, report = self.commands(False), self.commands(True)
        for relative in expected:
            self.assertEqual(selected.count(relative), 1)
            self.assertNotIn(relative, product.SOURCE_PATHS)
        for arch in ("arm64", "x86_64"):
            live, default = report["installer_" + arch], original["installer_" + arch]
            self.assertEqual(live.count("ERGOPTI_OWNED_IDLE_CORE"), 1)
            self.assertNotIn("ERGOPTI_OWNED_IDLE_CORE", default)
            for relative in expected:
                self.assertEqual(live.count(str(self.root / relative)), 1)
                self.assertNotIn(str(self.root / relative), default)
            self.assertNotIn("ERGOPTI_OWNED_IDLE_CORE", report["validator_" + arch])

    def test_installer_main_selects_the_idle_core_entry_only_in_the_live_profile(self):
        text = (
            Path(__file__).resolve().parent / "owned-runtime-installer/InstallerMain.swift"
        ).read_text(encoding="utf-8")
        live, _, rest = text.partition("#if ERGOPTI_OWNED_IDLE_CORE")[2].partition("#else")
        files_only = rest.partition("#endif")[0]
        self.assertIn("OwnedRuntimeIdleServiceEntry.runFirstInstallation()", live)
        self.assertNotIn("OwnedRuntimeInstallerEntry", live)
        self.assertIn("OwnedRuntimeInstallerEntry.runFirstInstallation()", files_only)
        self.assertNotIn("OwnedRuntimeIdleServiceEntry", files_only)

    def test_validator_module_lifecycle_and_lipo_commands_are_unchanged(self):
        original, report = self.commands(False), self.commands(True)
        for name, argv in original.items():
            if not name.startswith("installer_arm64") and not name.startswith("installer_x86_64"):
                self.assertEqual(report[name], argv)
        self.assertEqual(len(original), 11)
        self.assertEqual(len(report), 17)

    def test_nonboolean_profile_refuses_without_creating_compile_files(self):
        for invalid in (0, 1, None, "report", (), {}):
            with self.subTest(profile=invalid):
                with self.assertRaises(product.ProductBuildRefusal):
                    self.commands(invalid)
                with self.assertRaises(product.ProductBuildRefusal):
                    product.product_source_paths(daemon_report=invalid)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_module_map_is_exact_owned_umbrella_and_no_caller_declarations(self):
        header = str(
            self.root / (product.LAUNCHER + "CPOSIXCompatibility/include/CPOSIXCompatibility.h")
        )
        self.assertEqual(
            product.report_module_map(self.root),
            ('module CPOSIXCompatibility { header "' + header + '" export * }\n').encode(),
        )
        with self.assertRaises(product.ProductBuildRefusal):
            product.report_module_map(Path("/tmp/bad\nmodule Other"))

    def test_full_repository_header_closure_is_held_in_report_profile(self):
        prefix = product.LAUNCHER + "CPOSIXCompatibility/include/"
        expected = tuple(
            prefix + name
            for name in (
                "CPOSIXCompatibility.h",
                "OwnedProgramCompatibility.h",
                "OwnedChildReapingCompatibility.h",
                "OwnedInstalledConfiguration.h",
                "LoopbackListenerCompatibility.h",
                "OwnedImageAliasCompatibility.h",
                "OwnedSuspendedImageCompatibility.h",
                "OwnedListenerEventCompatibility.h",
                "OwnedRuntimeSignatureCompatibility.h",
                "OwnedVHDReportSocketIdentity.h",
            )
        )
        self.assertEqual(product.REPORT_HEADERS, expected)
        for header in expected:
            self.assertEqual(product.product_source_paths(daemon_report=True).count(header), 1)
        self.assertEqual(
            product.REPORT_C_SOURCES,
            tuple(
                product.LAUNCHER + "CPOSIXCompatibility/" + name
                for name in (
                    "CPOSIXCompatibility.c",
                    "OwnedProgramCompatibility.c",
                    "OwnedVHDReportSocketIdentity.c",
                )
            ),
        )


class SwiftRosterClosureControls(unittest.TestCase):
    """Each Swift roster declares the generated identifiers it references."""

    REPOSITORY = Path(__file__).resolve().parents[2]

    def test_rosters_using_identifiers_compile_their_declaration(self):
        # Run 41263664973: LauncherConstants used Identifiers without its file.
        for name, roster in (
            (
                "helper",
                product.HELPER_SOURCES
                + product.REPORT_SWIFT_SOURCES
                + product.IDLE_CORE_SWIFT_SOURCES,
            ),
            ("validator", product.VALIDATOR_SOURCES),
        ):
            with self.subTest(roster=name):
                texts = {
                    relative: (self.REPOSITORY / relative).read_text(encoding="utf-8")
                    for relative in roster
                    if relative.endswith(".swift")
                }
                users = [path for path, text in texts.items() if "Identifiers." in text]
                declarations = [path for path, text in texts.items() if "enum Identifiers" in text]
                self.assertTrue(users, "the roster no longer references Identifiers")
                self.assertEqual(len(declarations), 1, users)

    def test_rosters_declare_every_owned_type_they_reference(self):
        # Remap runtime build 42524447885: the helper's report stage owner called
        # OwnedRuntimeInstallMainOperation.codeDirectoryHashes, whose file no
        # helper roster compiles, so the signed artifact could not be built.
        for name, roster in (
            ("report", product.REPORT_SOURCE_PATHS),
            ("validator", product.VALIDATOR_SOURCES),
        ):
            with self.subTest(roster=name):
                texts = {}
                for relative in roster:
                    if relative.endswith(".swift"):
                        text = (self.REPOSITORY / relative).read_text(encoding="utf-8")
                        # Comments and string literals name folders and types that are no reference.
                        text = re.sub(r"//[^\n]*", "", text)
                        texts[relative] = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)
                declared = set()
                for text in texts.values():
                    declared |= set(
                        re.findall(
                            r"\b(?:enum|struct|class|protocol|actor|typealias)\s+(Owned\w+)", text
                        )
                    )
                for relative, text in texts.items():
                    missing = (
                        set(re.findall(r"\b(Owned(?:Runtime|VirtualHID)\w*)\b", text)) - declared
                    )
                    self.assertEqual(missing, set(), relative)


class ArchitectureCheckControls(unittest.TestCase):
    """lipo receives the universal output before the -verify_arch list."""

    def test_input_precedes_the_architecture_list(self):
        self.assertEqual(
            product.architecture_check_command(Path("/work/installer")),
            ["/usr/bin/lipo", "/work/installer", "-verify_arch", "arm64", "x86_64"],
        )


class ModuleMapWriteControls(unittest.TestCase):
    """The daemon-report module map is written with an admitted output mode."""

    def test_module_map_mode_is_admitted_by_the_exclusive_writer(self):
        # Run 41257077872 refused "output leaf bytes or mode refused" at 0o600.
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.modulemap"
            product._write_exclusive(
                path, b"module Report {}\n", product.REPORT_MODULE_MAP_MODE, time.monotonic() + 30
            )
            self.assertEqual(path.read_bytes(), b"module Report {}\n")
            self.assertEqual(path.stat().st_mode & 0o777, product.REPORT_MODULE_MAP_MODE)

    def test_private_mode_is_not_an_admitted_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(product.ProductBuildRefusal):
                product._write_exclusive(
                    Path(temporary) / "leaf", b"x", 0o600, time.monotonic() + 30
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
