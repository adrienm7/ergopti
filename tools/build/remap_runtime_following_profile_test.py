# tools/build/remap_runtime_following_profile_test.py
"""Handwritten current-profile metadata/source controls; native execution unqualified."""

import ast
import hashlib
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import time
import unittest

BUILD = Path(__file__).resolve().parent
REPOSITORY = BUILD.parent.parent
FIXED = "5fec1b43e836d53ad986400210f5b59e2d634f2584b564c85c6b33df580dcee5"


def retained_module(name, path):
    data = path.read_bytes()
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    exec(compile(data, str(path), "exec"), module.__dict__)
    return module


class PrivateCurrentSourceCase(unittest.TestCase):
    """Each case owns a genuine fixed sparse cohort; only private copies mutate."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="current-profile-controls-")
        self.addCleanup(temporary.cleanup)
        self.candidate = Path(temporary.name).resolve()
        self.candidate.chmod(0o700)
        for relative in (
            "tools/build/remap_runtime_build.py",
            "tools/build/remap_runtime_source.py",
            "tools/build/remap_runtime_build_test.py",
            "tools/diagnostics/hs274_native_build.py",
        ):
            destination = self.candidate / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPOSITORY / relative, destination)
        self.assertEqual(
            hashlib.sha256(
                (self.candidate / "tools/build/remap_runtime_source.py").read_bytes()
            ).hexdigest(),
            FIXED,
            "The exact independently frozen following factory prerequisite is unavailable",
        )
        self.subject = retained_module(
            "following_current_builder_" + str(id(self)),
            self.candidate / "tools/build/remap_runtime_build.py",
        )
        self.factory = self.subject._source_factory()
        # Copy the genuine fixed recipe inputs; these are fixtures, never expected
        # metadata regenerated from the implementation. Counts/profile are handwritten.
        for relative, _ in self.factory.DEPENDENCIES + self.factory.VHD_DEPENDENCIES:
            destination = self.candidate / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPOSITORY / relative, destination)
        self.previous = retained_module(
            "following_historical_receipt_fixture_" + str(id(self)),
            self.candidate / "tools/build/remap_runtime_build_test.py",
        )


class FollowingProfileControls(PrivateCurrentSourceCase):
    def record(self, fresh=True):
        record = self.previous.OwnedRecordControls().record(fresh)
        record.update(
            schema=2,
            source_profile="owned_vhd_broker_source_v1",
            source_factory_sha256=FIXED,
            owned_replacements=60,
            staged_files=4527,
        )
        return record

    def refused(self, record):
        with self.assertRaises(self.subject.BASE.NativeBuildError) as caught:
            self.subject.validate_current_owned_record(record)
        self.assertEqual(caught.exception.code, "owned_receipt_refused")

    def test_exact_following_fresh_and_explicit_receipts(self):
        for fresh in (True, False):
            with self.subTest(fresh=fresh):
                self.assertIsNone(self.subject.validate_current_owned_record(self.record(fresh)))

    def test_historical_receipt_has_no_current_authority(self):
        self.refused(self.previous.OwnedRecordControls().record())

    def test_following_receipt_is_not_the_historical_oracle(self):
        with self.assertRaises(self.subject.BASE.NativeBuildError) as caught:
            self.subject.validate_owned_record(self.record())
        self.assertEqual(caught.exception.code, "owned_receipt_refused")

    def test_wrong_profile_cannot_select_compatibility(self):
        for value in ("owned_source_v1", "", True, None, 1):
            record = self.record()
            record["source_profile"] = value
            self.refused(record)

    def test_receipt_factory_binding_is_exact(self):
        for value in (
            "8485a317bb3e1f0cd6a4b290246114e42266b5b9771f12cb1fe1f45e18ace265",
            "0" * 64,
            True,
            None,
        ):
            record = self.record()
            record["source_factory_sha256"] = value
            self.refused(record)

    def test_keyset_and_schema_are_closed(self):
        for operation in (
            lambda r: r.update(extra=True),
            lambda r: r.pop("source_factory_sha256"),
            lambda r: r.pop("source_profile"),
            lambda r: r.update(schema=1),
            lambda r: r.update(schema=True),
            lambda r: r.update(budget_seconds=300.0),
        ):
            record = self.record()
            operation(record)
            self.refused(record)

    def test_counts_are_exact_following_integers(self):
        for key, legacy in (
            ("source_inventory_entries", 4504),
            ("owned_replacements", 57),
            ("staged_files", 4526),
            ("staged_links", 5),
        ):
            for value in (legacy, True, 0, -1, 4531, 4527.0):
                record = self.record()
                record[key] = value
                self.refused(record)

    def test_all_capture_install_sign_auth_flags_stay_false(self):
        for key in (
            "native_capture_executed",
            "installation_executed",
            "signing_executed",
            "auth_executed",
        ):
            for value in (True, 0, None):
                record = self.record()
                record[key] = value
                self.refused(record)

    def test_phase_oracle_conserved_under_following_profile(self):
        for operation in (
            lambda r: r["phases"].reverse(),
            lambda r: r["phases"][0].update(elapsed_seconds=301),
            lambda r: r["phases"][1].update(child_process_executed=True),
        ):
            record = self.record()
            operation(record)
            self.refused(record)

    def test_product_oracle_conserved_under_following_profile(self):
        for operation in (
            lambda r: r["products"].pop(),
            lambda r: r["products"][0].update(architectures=["arm64"]),
            lambda r: r["products"][1].update(path="foreign/Core"),
        ):
            record = self.record()
            operation(record)
            self.refused(record)

    def test_generated_oracle_conserved_under_following_profile(self):
        for operation in (
            lambda r: r["generated_inputs"].pop(),
            lambda r: r["generated_inputs"].reverse(),
            lambda r: r["generated_inputs"][0].update(bytes=True),
        ):
            record = self.record()
            operation(record)
            self.refused(record)

    def test_wrong_bound_factory_refuses_before_metadata_acceptance(self):
        original = self.subject.SOURCE_FACTORY_SHA256
        try:
            self.subject.SOURCE_FACTORY_SHA256 = (
                "8485a317bb3e1f0cd6a4b290246114e42266b5b9771f12cb1fe1f45e18ace265"
            )
            with self.assertRaises(self.subject.BASE.NativeBuildError) as caught:
                self.subject.validate_current_owned_record(self.record())
            self.assertEqual(caught.exception.code, "dependency_unreleased")
        finally:
            self.subject.SOURCE_FACTORY_SHA256 = original

    def test_actual_factory_mutation_after_cache_refuses(self):
        self.assertIsNone(self.subject.validate_current_owned_record(self.record()))
        path = self.candidate / "tools/build/remap_runtime_source.py"
        original = path.read_bytes()
        try:
            path.write_bytes(original + b"\n# genuine later source mutation\n")
            with self.assertRaises(self.subject.BASE.NativeBuildError) as caught:
                self.subject.validate_current_owned_record(self.record())
            self.assertEqual(caught.exception.code, "source_identity")
        finally:
            path.write_bytes(original)


class FollowingDependencyControls(PrivateCurrentSourceCase):
    def setUp(self):
        super().setUp()
        self.observer = REPOSITORY / "tools/diagnostics/hs274_signed_runtime_observation.py"
        fixture = REPOSITORY / "tools/diagnostics/hs274_native_signing_fixture.py"
        syntax = ast.parse(fixture.read_bytes())
        ports = [
            node
            for node in syntax.body
            if isinstance(node, (ast.ClassDef, ast.FunctionDef))
            and node.name in ("FixtureRefusal", "require")
        ]
        self.assertEqual(len(ports), 2)
        self.scope = {
            "factory": self.factory,
            "repository": self.candidate,
            "deadline": time.monotonic() + 25,
        }
        # Actual unchanged refusal port and exact capture/re-capture statements;
        # the signed observer's native remainder is not executed by these controls.
        exec(compile(ast.Module(body=ports, type_ignores=[]), str(fixture), "exec"), self.scope)
        observe = next(
            node
            for node in ast.parse(self.observer.read_bytes()).body
            if isinstance(node, ast.FunctionDef) and node.name == "observe"
        )
        self.initial = next(
            node
            for node in observe.body
            if isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name) and target.id == "dependencies"
                for target in node.targets
            )
        )
        guard = next(
            node
            for node in observe.body
            if isinstance(node, ast.FunctionDef) and node.name == "guard"
        )
        self.recut = guard.body[-2:]
        self.assertIsInstance(self.recut[0], ast.Assign)
        self.assertEqual(self.recut[0].targets[0].id, "fresh")
        self.assertIsInstance(self.recut[1], ast.Expr)
        self.assertEqual(self.recut[1].value.func.id, "require")

    def owner(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name).resolve()
        path.chmod(0o700)
        return path

    def mutate_header(self):
        path = self.candidate / "tools/build/remap_runtime_vhd.hpp"
        original = path.read_bytes()
        path.write_bytes(original + b"\n// genuine dependency mutation\n")
        self.addCleanup(path.write_bytes, original)

    def test_dependency_ready_refuses_new_dependency_change(self):
        self.assertIs(
            self.subject.dependency_ready(self.candidate, self.owner(), 300), self.factory
        )
        self.mutate_header()
        with self.assertRaises(self.subject.BASE.NativeBuildError) as caught:
            self.subject.dependency_ready(self.candidate, self.owner(), 300)
        self.assertEqual(caught.exception.code, "dependency_changed")

    def test_actual_compile_preflight_refuses_before_platform(self):
        self.mutate_header()
        with self.assertRaises(self.subject.BASE.NativeBuildError) as caught:
            self.subject.compile_owned(self.candidate, self.owner(), 300)
        self.assertEqual(caught.exception.code, "dependency_changed")

    def test_observer_initial_cut_holds_all34_real_inputs(self):
        actual = dict(self.scope)
        exec(
            compile(ast.Module(body=[self.initial], type_ignores=[]), str(self.observer), "exec"),
            actual,
        )
        self.assertEqual(len(actual["dependencies"]), 34)
        self.assertEqual(
            tuple(row.path for row in actual["dependencies"][-2:]),
            ("tools/build/remap_runtime_vhd.hpp", "tools/build/remap_runtime_vhd_transport.py"),
        )

    def test_observer_actual_recut_refuses_changed_new_input(self):
        actual = dict(self.scope)
        exec(
            compile(ast.Module(body=[self.initial], type_ignores=[]), str(self.observer), "exec"),
            actual,
        )
        self.mutate_header()
        with self.assertRaises(
            (self.factory.SourceRefusal, self.scope["FixtureRefusal"])
        ) as caught:
            exec(
                compile(ast.Module(body=self.recut, type_ignores=[]), str(self.observer), "exec"),
                actual,
            )
        self.assertIn(caught.exception.code, ("dependency_changed", "source_changed"))


if __name__ == "__main__":
    suite = unittest.TestSuite(
        [
            unittest.defaultTestLoader.loadTestsFromTestCase(FollowingProfileControls),
            unittest.defaultTestLoader.loadTestsFromTestCase(FollowingDependencyControls),
        ]
    )
    result = unittest.TextTestRunner().run(suite)
    passed = result.wasSuccessful() and result.testsRun == 17 and not result.skipped
    print(
        "PASS" if passed else "FAIL",
        "portable current owned source profile tests=" + str(result.testsRun),
        "failures=" + str(len(result.failures)),
        "errors=" + str(len(result.errors)),
        "skipped=" + str(len(result.skipped)),
        "native=unexecuted",
    )
    raise SystemExit(0 if passed else 1)
