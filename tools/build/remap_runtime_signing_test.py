# tools/build/remap_runtime_signing_test.py
"""Frozen live-file custody controls with explicitly modeled compiler/native endpoints."""

import hashlib
import importlib.util
from pathlib import Path
import plistlib
import stat
import sys
import unittest
from unittest import mock

HERE = Path(__file__).parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ORIGINAL = load("unchanged_unsigned40_controls", HERE / "remap_runtime_artifact_test.py")
LAYOUT = load("independent_live_signing_layout", HERE / "remap_runtime_signing_fixture.py")
BUILDER = load("fixed_signing_builder_subject", HERE / "remap_runtime_build.py")
DESTINATIONS = (
    "Runtime/ErgoptiPlus-Remap-Core.app",
    "Runtime/ErgoptiPlus-Remap-Console.app",
    "Runtime/bin/ergoptiplus_remap_cli",
)
IDENTIFIERS = (
    "com.ergoptiplus.remap.core",
    "com.ergoptiplus.remap.console",
    "com.ergoptiplus.remap.cli",
)


class SigningCustodyControls(unittest.TestCase):
    def setUp(self):
        self.case = ORIGINAL.RetainedCustodyControls()
        self.case.setUp()
        self.addCleanup(self.case.doCleanups)
        self.owner = self.case.owner
        self.deadline = self.case.deadline
        for target, path in self.case.executables.items():
            path.write_bytes(LAYOUT.universal())
            path.chmod(0o755)
        for target, path in self.case.plists.items():
            identifier = IDENTIFIERS[0 if target == "core" else 1]
            path.write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": identifier,
                        "CFBundleExecutable": "ErgoptiPlus-Remap-"
                        + ("Core" if target == "core" else "Console"),
                        "CFBundlePackageType": "APPL",
                    }
                )
            )
            icon = path.parent / "Resources/app.icns"
            icon.write_bytes(b"icnsMODELED-ORDINARY-RESOURCE")
            icon.chmod(0o644)
        self.credentials = self.owner / "credentials"
        self.credentials.mkdir(mode=0o700)
        self.keychain = self.credentials / "existing-owned.keychain-db"
        self.keychain.write_bytes(b"MODELED EXISTING KEYCHAIN; NO PRIVATE KEY")
        self.keychain.chmod(0o600)
        self.leaf = self.credentials / "existing-public-leaf.der"
        self.leaf.write_bytes(LAYOUT.LEAF)
        self.leaf.chmod(0o644)
        self.inputs, self.image = object(), object()
        self.record = {"qualification": "MODELED COMPILER ENDPOINT", "signing_executed": False}
        self.calls, self.factory_calls = [], []
        self.hook = None
        self.foreign_leaf = False
        self.foreign_requirement = False
        self.foreign_code = False
        self.fail_phase = False

    def sink(self, identity=LAYOUT.IDENTITY, keychain="default", leaf="default"):
        if keychain == "default":
            keychain = self.keychain
        if leaf == "default":
            leaf = self.leaf
        sink = BUILDER._SigningSink(
            HERE.parents[1],
            self.owner,
            self.deadline,
            BUILDER._directory_identity(self.owner.lstat()),
            identity,
            keychain,
            leaf,
        )
        for target in ("core", "console", "cli"):
            sink.capture(target, self.case.stage, self.deadline)
        return sink

    def compilation_current(self, inputs, deadline, image):
        self.assertIs(inputs, self.inputs)
        self.assertIs(image, self.image)
        self.assertEqual(deadline, self.deadline)
        self.factory_calls.append(len(self.calls))

    def target_identity(self, target):
        name = Path(target).name
        if name in ("ErgoptiPlus-Remap-Core", "ErgoptiPlus-Remap-Core.app"):
            return IDENTIFIERS[0]
        if name in ("ErgoptiPlus-Remap-Console", "ErgoptiPlus-Remap-Console.app"):
            return IDENTIFIERS[1]
        self.assertEqual(name, "ergoptiplus_remap_cli")
        return IDENTIFIERS[2]

    def native_phase(self, name, args, cwd, owner, deadline):
        # All commands below are modeled. No native tool or key is invoked.
        self.assertEqual(deadline, self.deadline)
        self.assertEqual(owner, self.owner)
        self.calls.append((name, tuple(args)))
        if self.fail_phase:
            raise BUILDER.BASE.NativeBuildError("phase_failed", "MODELED native refusal")
        output = ""
        if args[0] == "/usr/bin/security":
            self.assertIn("find-identity", args)
            self.assertEqual(args[-1], str(self.keychain))
            output = "  1) " + LAYOUT.IDENTITY + ' "MODELED EXISTING STABLE IDENTITY"\n'
        else:
            self.assertEqual(args[0], "/usr/bin/codesign")
            target = Path(args[-1])
            identifier = self.target_identity(target)
            if "--sign" in args:
                self.assertEqual(args[args.index("--sign") + 1], LAYOUT.IDENTITY)
                self.assertEqual(args[args.index("--keychain") + 1], str(self.keychain))
                self.assertEqual(args[args.index("--identifier") + 1], identifier)
                self.assertIn("--timestamp=none", args)
                self.assertNotIn("--deep", args)
                executable = target
                if target.suffix == ".app":
                    executable = target / "Contents/MacOS" / target.stem
                    folder = target / "Contents/_CodeSignature"
                    folder.mkdir(mode=0o755, exist_ok=True)
                    folder.chmod(0o755)
                    resources = folder / "CodeResources"
                    resources.write_bytes(plistlib.dumps({"files2": {}, "MODELED": True}))
                    resources.chmod(0o644)
                data = LAYOUT.universal(
                    signed=True,
                    code=b"FOREIGN EXECUTABLE"
                    if self.foreign_code
                    else b"ORIGINAL EXECUTABLE CONTENT",
                )
                executable.write_bytes(data)
                executable.chmod(0o755)
            elif "--extract-certificates" in args:
                prefix = args[args.index("--extract-certificates") + 1]
                path = Path(prefix + "0")
                path.write_bytes(b"FOREIGN PUBLIC LEAF" if self.foreign_leaf else LAYOUT.LEAF)
                path.chmod(0o644)
            elif "-r-" in args:
                selected = "com.foreign.remap.cli" if self.foreign_requirement else identifier
                output = (
                    'designated => identifier "'
                    + selected
                    + '" and certificate leaf = H"'
                    + LAYOUT.IDENTITY
                    + '"\n'
                )
            else:
                self.assertIn("--verify", args)
                self.assertIn("--strict", args)
                self.assertIn("-R", args)
                requirement = args[args.index("-R") + 1]
                self.assertIn(identifier, requirement)
                self.assertIn(LAYOUT.IDENTITY, requirement)
        if self.hook is not None:
            self.hook(name, args)
        (self.owner / (name + ".stdout")).write_text(output)
        (self.owner / (name + ".stderr")).write_text("")
        return {
            "schema": 1,
            "phase": name,
            "status": "passed",
            "exit_status": 0,
            "elapsed_seconds": 0.0,
        }

    def prepare(self, sink=None):
        if sink is None:
            sink = self.sink()
        with (
            mock.patch.object(
                BUILDER, "_current_build_inputs", side_effect=self.compilation_current
            ),
            mock.patch.object(BUILDER, "_RUN_PHASE", side_effect=self.native_phase),
        ):
            return sink.prepare(self.record, self.inputs, self.image, (), self.deadline)

    def failed(self, code, sink=None):
        result = self.prepare(sink)
        self.assertIs(result.compilation, self.record)
        self.assertEqual(result.preparation.status, "prepared_unsigned_snapshot")
        self.assertEqual(result.signing.status, "refused")
        self.assertEqual(result.signing.code, code)
        self.assertFalse(self.record["signing_executed"])
        return result

    def replace_same_bytes(self, path):
        replacement = path.with_name(path.name + ".replacement")
        replacement.write_bytes(path.read_bytes())
        replacement.chmod(stat.S_IMODE(path.stat().st_mode))
        replacement.replace(path)

    def test_explicit_existing_configuration_matches_independent_public_der(self):
        self.assertEqual(hashlib.sha1(LAYOUT.LEAF).hexdigest().upper(), LAYOUT.IDENTITY)

    def test_complete_fixed_pipeline_uses_live_unsigned_bytes(self):
        result = self.prepare()
        self.assertIs(result.compilation, self.record)
        self.assertEqual(result.preparation.status, "prepared_unsigned_snapshot")
        self.assertEqual(result.signing.status, "prepared_signed_snapshot")
        self.assertEqual(result.signing.root, self.owner / ".signed-runtime-preparation")
        self.assertEqual(result.signing.products, DESTINATIONS)
        self.assertFalse(result.signing.shipping_qualified)
        self.assertFalse(result.signing.installation_qualified)
        self.assertFalse(result.signing.authentication_qualified)
        self.assertEqual(
            (result.preparation.root / DESTINATIONS[2]).read_bytes(), LAYOUT.universal()
        )
        self.assertEqual(
            (result.signing.root / DESTINATIONS[2]).read_bytes(), LAYOUT.universal(signed=True)
        )
        self.assertFalse(any(result.signing.root.rglob("libduktape.a")))
        self.assertFalse((result.signing.root / "Applications").exists())

    def test_signing_order_and_identifiers_are_fixed_inside_out(self):
        self.prepare()
        sign = [
            (Path(args[-1]).name, args[args.index("--identifier") + 1])
            for _, args in self.calls
            if "--sign" in args
        ]
        self.assertEqual(
            sign,
            [
                ("ErgoptiPlus-Remap-Core", IDENTIFIERS[0]),
                ("ErgoptiPlus-Remap-Core.app", IDENTIFIERS[0]),
                ("ErgoptiPlus-Remap-Console", IDENTIFIERS[1]),
                ("ErgoptiPlus-Remap-Console.app", IDENTIFIERS[1]),
                ("ergoptiplus_remap_cli", IDENTIFIERS[2]),
            ],
        )

    def test_complete_source_recuts_surround_every_native_boundary(self):
        self.prepare()
        for n in range(len(self.calls) + 1):
            self.assertIn(n, self.factory_calls)
        self.assertGreaterEqual(len(self.factory_calls), len(self.calls) * 2)

    def test_default_prepare_creates_no_signed_stage_or_native_commands(self):
        result = self.case.prepare()
        self.assertEqual(result.status, "prepared_unsigned_snapshot")
        self.assertFalse((self.owner / ".signed-runtime-preparation").exists())
        self.assertEqual(self.calls, [])

    def test_private_handoff_current_and_held_members_refuse_after_lexical_exit(self):
        subject = ORIGINAL.SUBJECT
        with subject._unsigned_handoff_scope(
            self.case.owner_stamp, self.case.capture(), self.deadline, subject._OneUse()
        ) as live:
            self.assertIsNone(live.current())
            directories, files = live.members()
            self.assertTrue(directories)
            self.assertTrue(files)
        for operation in (live.current, live.members):
            with self.assertRaises(subject.ArtifactRefusal) as caught:
                operation()
            self.assertEqual(caught.exception.code, "handoff_required")

    def test_retired_outcome_or_receipt_is_not_live_unsigned_authority(self):
        subject = ORIGINAL.SUBJECT
        outcome = self.case.prepare()
        for fake in (outcome, {"status": "passed", "root": str(outcome.root)}):
            with self.assertRaises(subject.ArtifactRefusal) as caught:
                with subject._unsigned_handoff_scope(
                    self.case.owner_stamp, fake, self.deadline, subject._OneUse()
                ):
                    self.fail("Retired metadata admitted")
            self.assertEqual(caught.exception.code, "inventory")

    def test_absent_credentials_refuse_after_unsigned_completion(self):
        self.failed("signing_credentials", self.sink(None, None, None))
        self.assertEqual(self.calls, [])

    def test_partial_credentials_refuse_after_unsigned_completion(self):
        self.failed("signing_credentials", self.sink(LAYOUT.IDENTITY, None, self.leaf))
        self.assertEqual(self.calls, [])

    def test_adhoc_identity_refuses_without_native_fallback(self):
        self.failed("signing_credentials", self.sink("-"))
        self.assertEqual(self.calls, [])

    def test_wrong_identity_for_public_der_refuses(self):
        self.failed("signing_credentials", self.sink("0" * 40))
        self.assertEqual(self.calls, [])

    def test_unowned_keychain_mode_refuses(self):
        self.keychain.chmod(0o644)
        self.failed("signing_credentials")
        self.assertEqual(self.calls, [])

    def test_keychain_symlink_refuses(self):
        source = self.keychain.with_suffix(".original")
        self.keychain.rename(source)
        self.keychain.symlink_to(source)
        self.failed("signing_credentials")
        self.assertEqual(self.calls, [])

    def test_same_byte_public_leaf_replacement_during_native_boundary_refuses(self):
        self.hook = lambda *_: self.replace_same_bytes(self.leaf)
        self.failed("identity_changed")

    def test_same_byte_original_resource_replacement_during_native_boundary_refuses(self):
        self.hook = lambda *_: self.replace_same_bytes(self.case.resources["core"])
        self.failed("identity_changed")

    def test_same_byte_unsigned_primary_replacement_during_native_boundary_refuses(self):
        self.hook = lambda *_: self.replace_same_bytes(
            self.owner
            / ".unsigned-runtime-preparation"
            / DESTINATIONS[0]
            / "Contents/MacOS/ErgoptiPlus-Remap-Core"
        )
        self.failed("identity_changed")

    def test_unsigned_inventory_injection_during_native_boundary_refuses(self):
        def inject(*_):
            path = self.owner / ".unsigned-runtime-preparation/Runtime/foreign.txt"
            path.write_bytes(b"extra object")
            path.chmod(0o644)

        self.hook = inject
        self.failed("identity_changed")

    def test_exclusive_signed_stage_collision_refuses(self):
        (self.owner / ".signed-runtime-preparation").mkdir(mode=0o700)
        self.failed("signed_collision")
        self.assertEqual(self.calls, [])

    def test_signed_stage_link_collision_refuses(self):
        (self.owner / ".signed-runtime-preparation").symlink_to(
            self.case.stage, target_is_directory=True
        )
        self.failed("signed_collision")
        self.assertEqual(self.calls, [])

    def test_signature_work_collision_refuses(self):
        (self.owner / ".signed-runtime-verification").mkdir(mode=0o700)
        self.failed("signed_collision")
        self.assertEqual(self.calls, [])

    def test_wrong_actual_extracted_leaf_refuses(self):
        self.foreign_leaf = True
        self.failed("signature_leaf")

    def test_wrong_actual_designated_identifier_refuses(self):
        self.foreign_requirement = True
        self.failed("signature_requirement")

    def test_native_command_failure_preserves_original_completed_unsigned_facts(self):
        self.fail_phase = True
        self.failed("phase_failed")

    def test_valid_modeled_external_verify_cannot_admit_substituted_executable(self):
        self.foreign_code = True
        self.failed("signed_content")

    def test_secondary_execute_object_refuses_after_native_boundary(self):
        def inject(_, args):
            if "--sign" in args:
                path = self.owner / ".signed-runtime-preparation/Runtime/foreign-tool"
                path.write_bytes(LAYOUT.thin(signed=True))
                path.chmod(0o755)

        self.hook = inject
        self.failed("signed_inventory")

    def test_signed_source_resource_mutation_refuses(self):
        def inject(_, args):
            if "--sign" in args:
                path = (
                    self.owner
                    / ".signed-runtime-preparation"
                    / DESTINATIONS[0]
                    / "Contents/Resources/ordinary-resource.txt"
                )
                path.write_bytes(b"FOREIGN ORDINARY CONTENT")

        self.hook = inject
        self.failed("signed_content")

    def test_signature_inventory_file_bound_refuses_before_payload_read(self):
        def inject(_, args):
            if "--sign" in args:
                target = Path(args[-1])
                with target.open("r+b") as stream:
                    stream.truncate(128 * 1024 * 1024 + 1)

        self.hook = inject
        self.failed("signed_inventory")

    def test_signature_inventory_symlink_refuses(self):
        def inject(_, args):
            if "--sign" in args:
                path = self.owner / ".signed-runtime-preparation/Runtime/foreign-link"
                if not path.is_symlink():
                    path.symlink_to(self.case.stage)

        self.hook = inject
        self.failed("signed_inventory")

    def test_native_verification_requires_two_architectures(self):
        self.prepare()
        verified = [args for _, args in self.calls if "--verify" in args]
        self.assertTrue(verified)
        self.assertTrue(any("--all-architectures" in args for args in verified))
        extracted = [args for _, args in self.calls if "--extract-certificates" in args]
        self.assertEqual(len(extracted), 10)
        self.assertEqual(
            {args[args.index("--architecture") + 1] for args in extracted}, {"x86_64", "arm64"}
        )

    def test_caught_nested_entry_refuses_outer_signing_without_reusing_claim(self):
        sink = self.sink()
        nested = []

        def reenter(*_):
            if nested:
                return
            try:
                with sink.module._unsigned_handoff_scope(
                    sink.owner, tuple(sink.snapshots), self.deadline, sink.guard
                ):
                    self.fail("Nested active handoff admitted")
            except sink.module.ArtifactRefusal as error:
                nested.append(error.code)

        self.hook = reenter
        self.failed("reentered", sink)
        self.assertEqual(nested, ["reentered"])

    def test_expired_deadline_refuses_without_renewal(self):
        sink = self.sink()
        patcher = mock.patch.object(BUILDER.time, "monotonic", return_value=self.deadline + 1)

        def expire(*_):
            patcher.start()
            self.addCleanup(patcher.stop)

        self.hook = expire
        self.failed("deadline", sink)


if __name__ == "__main__":
    unittest.main()
