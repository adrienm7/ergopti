"""Portable source routing/profile controls; native/signing authority is unqualified."""

from contextlib import ExitStack
import importlib.util
import inspect
import subprocess
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


BUILD = load("sdk_route_controls_build", Path(__file__).with_name("remap_runtime_build.py"))
PRODUCT = load(
    "sdk_route_controls_product", Path(__file__).with_name("owned_runtime_product_build.py")
)
ORIGINAL = load(
    "sdk_route_original_controls", Path(__file__).with_name("remap_runtime_build_test.py")
)


class StopBeforeNative(RuntimeError):
    """Finite control boundary; neither compilation nor packaging completes."""


class SDKRouteControls(unittest.TestCase):
    def record(self, *, sdk=False, production=False, previous=False):
        record = ORIGINAL.OwnedRecordControls().record(fresh=False)
        record.update(
            schema=2 if previous else 3,
            source_profile=(
                "owned_vhd_broker_source_v1"
                if previous
                else "owned_installed_sdk_source_v1"
                if sdk
                else "owned_vhd_broker_source_v2"
            ),
            source_factory_sha256=(
                "26b6a3ab3ea334659f485f7b8526015f956f0b23d7aa0c3b964cde758f7963ce"
                if previous
                else BUILD.SOURCE_FACTORY_SHA256
            ),
            owned_replacements=101 if sdk else 65,
            staged_files=4557 if sdk else 4529,
        )
        if sdk:
            record["sdk_supplier_sha256"] = (
                "aeb2949e50e628ed6db88aaa9d4726c4d485a48d94adccb67ba1203563b1668f"
            )
        if production:
            record["phases"].insert(
                4,
                {
                    "schema": 1,
                    "phase": "production_core_idle_controls",
                    "status": "passed",
                    "elapsed_seconds": 0.25,
                    "exit_status": 0,
                },
            )
        return record

    def refused_record(self, record):
        with self.assertRaises(BUILD.BASE.NativeBuildError) as caught:
            BUILD.validate_current_owned_record(record)
        self.assertEqual(caught.exception.code, "owned_receipt_refused")

    def selected_source(self, sdk, *, production=True):
        events = []
        legacy, installed = object(), object()
        cuts = []

        def prepare(kind, projection):
            def callback(repository, pristine, deadline):
                cuts.append(deadline)
                events.append(kind)
                return projection

            return callback

        factory = SimpleNamespace(
            SourceRefusal=RuntimeError,
            capture_dependencies=lambda *args: events.append("dependencies"),
            capture_vhd_dependencies=lambda *args: events.append("vhd_dependencies"),
            prepare_owned_source=prepare("legacy_source", legacy),
            prepare_sdk_owned_source=prepare("sdk_source", installed),
        )

        class FiniteSink:
            def __init__(self, *args):
                events.append("sink")

            def current(self, deadline):
                cuts.append(deadline)

            def core_idle_controls(self, pristine, deadline):
                cuts.append(deadline)
                events.append("idle_controls")
                return {"phase": "production_core_idle_controls"}

        def materialize(projection, owner, deadline):
            cuts.append(deadline)
            events.append("materialize")
            self.assertIs(projection, installed if sdk is True else legacy)
            raise StopBeforeNative("No source image, native product or signed claim was minted")

        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            owner = Path(temporary).resolve()
            owner.chmod(0o700)
            for target, name, keywords in (
                (BUILD, "_source_factory", {"return_value": factory}),
                (BUILD, "_ProductionSink", {"new": FiniteSink}),
                (BUILD.sys, "platform", {"new": "darwin"}),
                (BUILD.shutil, "which", {"return_value": "/usr/bin/true"}),
                (BUILD, "_observed_run_phase", {"side_effect": lambda *args: {"phase": args[0]}}),
                (
                    BUILD.BASE,
                    "acquire_xcodegen",
                    {"return_value": (Path("/usr/bin/true"), {"phase": "xcodegen_acquisition"})},
                ),
                (BUILD, "materialize_owned_source", {"side_effect": materialize}),
            ):
                stack.enter_context(patch.object(target, name, **keywords))

            def callback():
                return BUILD._compile_owned(
                    owner,
                    owner,
                    300,
                    upstream=owner,
                    prepare=production,
                    signing=("finite", "finite", "finite") if production else None,
                    production=owner if production else None,
                    installed_sdk=sdk,
                )

            if type(sdk) is bool and (not sdk or production):
                with self.assertRaises(StopBeforeNative):
                    callback()
                self.assertTrue(cuts and all(cut == cuts[0] for cut in cuts))
                self.assertEqual(
                    events[-2:], ["sdk_source" if sdk else "legacy_source", "materialize"]
                )
                if production:
                    self.assertLess(
                        events.index("idle_controls"),
                        events.index("sdk_source" if sdk else "legacy_source"),
                    )
            else:
                with self.assertRaises(BUILD.BASE.NativeBuildError) as caught:
                    callback()
                self.assertEqual(caught.exception.code, "invalid_budget")
                self.assertEqual(events, [])
            self.assertFalse((owner / "owned-native-build-result.json").exists())

    def test_single_genuine_sdk_roster_is_read_through_the_source_issuer(self):
        source = load(
            "sdk_source_roster_control",
            Path(__file__).parent / "core_sdk/operational_core_source.py",
        )
        repository = Path(__file__).resolve().parents[2]
        rows = source.rows(repository, time.monotonic() + 30)
        self.assertEqual(len(rows), 53)
        self.assertEqual(len({row[0] for row in rows}), 53)
        posts = {row[0]: row[2] for row in rows}
        self.assertEqual(
            posts["src/bin/cli/src/main.cpp"],
            "962bac224e17d29728b711e280be7aac115c663d78018eea24d5db9ca7dd217e",
        )
        self.assertEqual(
            posts["vendor/vendor/include/pqrs/osx/iokit_hid_manager.hpp"],
            "7b7811cc829307d55da5edc545abc4a22e415a74bddd11c74ac736978e534c03",
        )
        self.assertFalse(hasattr(source, "_Image"))
        with self.assertRaises(source._BUILD.BASE.NativeBuildError) as caught:
            source.rows(repository, time.monotonic() - 1)
        self.assertEqual(caught.exception.code, "phase_deadline")

    def test_current_source_rejects_detached_image_and_borrowed_issuer_root(self):
        source = load(
            "sdk_source_detached_control",
            Path(__file__).parent / "core_sdk/operational_core_source.py",
        )
        repository = Path(__file__).resolve().parents[2]
        source._load_build(repository, time.monotonic() + 30)

        class DetachedImage:
            @property
            def projection(self):
                raise AssertionError("Detached object selected a source repository")

        with self.assertRaisesRegex(RuntimeError, "No original factory-issued SDK image"):
            source.current(DetachedImage(), time.monotonic() + 30)
        with tempfile.TemporaryDirectory() as temporary:
            alternate = Path(temporary).resolve()
            copied = alternate / "tools/build/remap_runtime_build.py"
            copied.parent.mkdir(parents=True)
            copied.write_bytes((repository / "tools/build/remap_runtime_build.py").read_bytes())
            with self.assertRaisesRegex(
                RuntimeError, "Original SDK build owner incarnation changed"
            ):
                source._load_build(alternate, time.monotonic() + 30)

    def test_legacy_default_selects_original_source(self):
        self.assertIs(
            inspect.signature(BUILD.compile_owned_prepare_sign_and_package)
            .parameters["installed_sdk"]
            .default,
            False,
        )
        self.selected_source(False)
        self.selected_source(False, production=False)

    def test_sdk_selects_genuine_supplier_before_original_materializer(self):
        self.selected_source(True)

    def test_sdk_requires_exclusive_signed_production(self):
        self.selected_source(True, production=False)
        for value in (1, 0, None, "true"):
            with self.subTest(value=value):
                self.selected_source(value)

    def test_original_schema_one_and_two_oracles_remain(self):
        BUILD.validate_owned_record(ORIGINAL.OwnedRecordControls().record(fresh=False))
        BUILD.validate_current_owned_record(self.record(previous=True))
        record = self.record(previous=True)
        record["owned_replacements"] = 101
        self.refused_record(record)

    def test_current_vhd_and_sdk_profiles_are_closed(self):
        for sdk, production in ((False, False), (False, True), (True, True)):
            with self.subTest(sdk=sdk, production=production):
                BUILD.validate_current_owned_record(self.record(sdk=sdk, production=production))

    def test_sdk_requires_actual_idle_control_in_exact_order(self):
        self.refused_record(self.record(sdk=True))
        record = self.record(sdk=True, production=True)
        record["phases"][4], record["phases"][5] = record["phases"][5], record["phases"][4]
        self.refused_record(record)
        record = self.record(sdk=True, production=True)
        record["phases"][4]["exit_status"] = 70
        self.refused_record(record)

    def test_sdk_metadata_cannot_replace_source_supplier_or_closed_counts(self):
        for field, value in (
            ("sdk_supplier_sha256", "0" * 64),
            ("source_factory_sha256", "0" * 64),
            ("owned_replacements", 65),
            ("staged_files", 4529),
            ("signing_executed", True),
            ("budget_seconds", 330),
            ("extra", "unowned"),
        ):
            with self.subTest(field=field):
                record = self.record(sdk=True, production=True)
                record[field] = value
                self.refused_record(record)

    def package_boundary(self, record, source_current=None):
        events = []

        def claim():
            events.append("claim")

        def compiled(*args):
            events.append("native_compile_boundary")
            raise StopBeforeNative()

        with (
            patch.object(PRODUCT.sys, "platform", "darwin"),
            patch.object(PRODUCT, "compile_native_parts", side_effect=compiled),
        ):
            kwargs = {} if source_current is None else {"source_current": source_current}
            PRODUCT._package_live(
                Path("/finite"),
                Path("/finite"),
                Path("/finite"),
                record,
                {},
                {},
                b"finite certificate",
                "A" * 40,
                Path("/finite"),
                claim,
                time.monotonic() + 30,
                **kwargs,
            )
        return events

    def test_unavailable_live_source_refuses_before_native_packaging(self):
        primary = PRODUCT.ProductBuildRefusal("finite owned source refusal")

        def source_current():
            raise primary

        with patch.object(PRODUCT, "compile_native_parts") as compiled:
            with self.assertRaises(PRODUCT.ProductBuildRefusal) as caught:
                self.package_boundary(self.record(sdk=True, production=True), source_current)
            self.assertIs(caught.exception, primary)
            compiled.assert_not_called()

    def test_current_metadata_without_live_source_remains_refused(self):
        with self.assertRaises(PRODUCT.ProductBuildRefusal):
            self.package_boundary(self.record(sdk=True, production=True))

    def test_original_signed_claim_identity_gate_still_refuses_detached_inputs(self):
        sink = object.__new__(BUILD._ProductionSink)
        record, inputs, image, directories, files = {}, object(), object(), {}, {}
        claim = SimpleNamespace(
            current=lambda: None,
            members=lambda: (directories, files),
            inputs=lambda: (record, inputs, image),
        )
        sink._distribution_claim = claim
        sink.current = lambda deadline: None
        sink.production_module = SimpleNamespace(
            ProductBuildRefusal=RuntimeError,
            _package_live=lambda *args, **kwargs: self.fail("Detached claim reached packaging"),
        )
        sink.export_signed(
            dict(record),
            inputs,
            image,
            directories,
            files,
            b"leaf",
            "identity",
            claim,
            time.monotonic() + 10,
        )
        self.assertEqual(sink.packaged.code, "handoff_required")

    def report_package_route(self, *, sdk=False, refuse_source=False):
        """Exercise the real continuation with finite claims, never native authority."""
        sink = object.__new__(BUILD._ProductionSink)
        record = self.record(sdk=sdk, production=True)
        repository = Path(__file__).resolve().parents[2]
        inputs = SimpleNamespace(root=Path("/finite/source"))

        class FiniteImage:
            root = inputs.root
            projection = SimpleNamespace(repository=repository, sdk_dependencies=sdk)

        image = FiniteImage()
        directories, files, events = {}, {}, []
        claim = SimpleNamespace(
            current=lambda: events.append("claim"),
            members=lambda: (directories, files),
            inputs=lambda: (record, inputs, image),
        )
        payload = SimpleNamespace(image=image)

        def source_current(actual, deadline):
            self.assertIs(actual, image)
            if refuse_source:
                raise BUILD.BASE.NativeBuildError("source_identity", "Finite source retired")
            events.append("source")

        def package(*args, **kwargs):
            self.assertIs(args[3], record)
            self.assertIs(args[4], directories)
            self.assertIs(args[5], files)
            self.assertIs(kwargs["daemon_report"], not sdk)
            self.assertIs(kwargs["staged_source"], image if sdk else None)
            self.assertIs(kwargs["driver_payload"], payload if sdk else None)
            args[9]()
            kwargs["source_current"]()
            if sdk:
                kwargs["driver_payload_current"]()
            events.append("package")
            return "finite package boundary only"

        factory = SimpleNamespace(
            StagedSource=FiniteImage,
            SourceRefusal=RuntimeError,
            current_staged_source=source_current,
            capture_virtual_hid_driver_payload=lambda actual, deadline: payload,
            current_virtual_hid_driver_payload=lambda actual, deadline: self.assertIs(
                actual, payload
            ),
        )
        sink._distribution_claim = claim
        sink.current = lambda deadline: None
        sink.source = SimpleNamespace(root=repository)
        sink.owner = SimpleNamespace(path=Path("/finite/owner"))
        sink.lua_build = Path("/finite/lua")
        sink.credentials = ("identity", Path("/finite/keychain"))
        sink.production_module = SimpleNamespace(
            ProductBuildRefusal=RuntimeError, _package_live=package
        )
        # Authenticate the real metadata before replacing the source issuer with
        # a finite model. The existing detached-claim refusal stays independent.
        BUILD.validate_current_owned_record(record)
        with patch.object(BUILD, "_source_factory", return_value=factory):
            sink.export_signed(
                record,
                inputs,
                image,
                directories,
                files,
                b"leaf",
                "identity",
                claim,
                time.monotonic() + 10,
            )
        if refuse_source:
            self.assertEqual(sink.packaged.code, "source_identity")
            self.assertNotIn("package", events)
        else:
            self.assertEqual(sink.packaged, "finite package boundary only")
            self.assertIn("package", events)
            self.assertGreater(events.count("source"), 1)

    def test_live_vhd_report_and_sdk_routes_keep_original_claim_scope(self):
        for sdk in (False, True):
            with self.subTest(sdk=sdk):
                self.report_package_route(sdk=sdk)

    def test_retired_source_never_reaches_either_report_package_route(self):
        for sdk in (False, True):
            with self.subTest(sdk=sdk):
                self.report_package_route(sdk=sdk, refuse_source=True)

    QUEUE_BUILD_SHA = "24065c518469ac9d60ba3d0888e053ee0158642e5720c4caff64121dd280ceee"
    PREVIOUS_BUILD_SHA = "a59fa9603e6be88f7ec701f808c6789bcdeff1371de65de143fdf9a3d8f07f5c"

    def protected_source_fixture(self, root):
        repository = Path(__file__).resolve().parents[2]
        for relative in (
            "tools/diagnostics/hs274_native_build.py",
            "tools/build/remap_runtime_source.py",
            "tools/build/remap_runtime_build.py",
            "tools/build/core_sdk/operational_core_source.py",
            "tools/build/core_sdk/receive_core_sdk.py",
            "tools/build/core_sdk/run_core_sdk.py",
        ):
            leaf = root / relative
            leaf.parent.mkdir(parents=True, exist_ok=True)
            leaf.write_bytes((repository / relative).read_bytes())
        return root / "tools/build/core_sdk"

    def previous_protected_builder(self, current):
        fixture_paths = (
            b'"tools/build/fixtures/owned_runtime_queue_test.cpp":',
            b'"tools/build/fixtures/owned_runtime_queue_ports.hpp":',
            b'"tools/build/fixtures/owned_runtime_dispatcher_test.cpp":',
        )
        previous = b"".join(
            line
            for line in current.splitlines(keepends=True)
            if not any(path in line for path in fixture_paths)
        ).replace(
            b"afdd012bee750b713d10665e28c35705318bc6f4ae1bb9a54f7e96105912b22a",
            b"ca54e61d19dd071fc23ce991efc1a9a2798304a6486872261a092019ad97ec58",
        )
        self.assertEqual(BUILD.BASE.digest(previous), self.PREVIOUS_BUILD_SHA)
        return previous

    def test_queue_only_builder_has_genuine_source_issuer(self):
        repository = Path(__file__).resolve().parents[2]
        current = (repository / "tools/build/remap_runtime_build.py").read_bytes()
        self.assertEqual(BUILD.BASE.digest(current), self.QUEUE_BUILD_SHA)
        source = load(
            "queue_sdk_actual_source", Path(__file__).parent / "core_sdk/operational_core_source.py"
        )
        with (
            patch.object(subprocess, "run", side_effect=AssertionError("No native command")),
            patch.object(subprocess, "Popen", side_effect=AssertionError("No child")),
        ):
            build, factory, path, _, data = source._load_build(repository, time.monotonic() + 30)
            self.assertEqual(data, current)
            self.assertEqual(path, repository / "tools/build/remap_runtime_build.py")
            self.assertIs(build._source_factory(), factory)
            self.assertEqual(
                build.SOURCE_FACTORY_SHA256,
                "9caa7c6b7a89fd1420452b59c4c5697a7a2aaaa9293498652f6b8a6628094c9d",
            )
            self.assertFalse(hasattr(build, "DRIVER_UPDATE_OWNED_SOURCE_PROFILE"))

    def test_old_or_altered_builder_refuses_before_native(self):
        repository = Path(__file__).resolve().parents[2]
        current = (repository / "tools/build/remap_runtime_build.py").read_bytes()
        self.assertEqual(BUILD.BASE.digest(current), self.QUEUE_BUILD_SHA)
        for data in (self.previous_protected_builder(current), current + b"\n# altered builder\n"):
            with (
                self.subTest(digest=BUILD.BASE.digest(data)),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary).resolve()
                directory = self.protected_source_fixture(root)
                (root / "tools/build/remap_runtime_build.py").write_bytes(data)
                source = load("queue_sdk_refused_source", directory / "operational_core_source.py")
                with (
                    patch.object(
                        subprocess, "run", side_effect=AssertionError("No native command")
                    ),
                    patch.object(subprocess, "Popen", side_effect=AssertionError("No child")),
                ):
                    with self.assertRaisesRegex(RuntimeError, "Fixed SDK build owner changed"):
                        source._load_build(root, time.monotonic() + 30)
                self.assertIsNone(source._BUILD)

    def test_actual_sdk_entry_import_binds_receiver_and_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            directory = self.protected_source_fixture(root)
            with (
                patch.object(subprocess, "run", side_effect=AssertionError("No native command")),
                patch.object(subprocess, "Popen", side_effect=AssertionError("No child")),
            ):
                entry = load("queue_sdk_actual_entry", directory / "run_core_sdk.py")
                receiver = sys.modules[entry.receive.__module__]
                self.assertIs(entry.receive, receiver.receive)
                self.assertEqual(receiver.source.BUILD_SHA, self.QUEUE_BUILD_SHA)
                receiver.source._load_build(root, time.monotonic() + 30)
                for filename, message in (
                    ("operational_core_source.py", "Fixed operational source owner changed"),
                    ("receive_core_sdk.py", "Fixed SDK receiving source changed"),
                ):
                    with self.subTest(filename=filename):
                        leaf = directory / filename
                        original = leaf.read_bytes()
                        try:
                            leaf.write_bytes(original + b"\n# altered dependency\n")
                            with self.assertRaisesRegex(RuntimeError, message):
                                load("queue_sdk_tampered_entry", directory / "run_core_sdk.py")
                        finally:
                            leaf.write_bytes(original)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(SDKRouteControls)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print("SDK portable route controls", result.testsRun, "native/signing/packaging unqualified")
    raise SystemExit(
        0 if result.wasSuccessful() and result.testsRun == 17 and not result.skipped else 1
    )
