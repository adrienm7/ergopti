# tools/build/remap_runtime_lexical_closure_test.py
"""Genuine sparse source closure and refusal controls; native execution unqualified."""

import ast
import base64
import hashlib
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import zlib

ROOT = Path(__file__).resolve().parents[2]
FIXED_PROVIDER = "c29ceb96e73655cadea7763805b9468c32744033c2f177bae492e4ce9fe4100a"
FIXED_FACTORY = "854dc3ef556e2540d4a64e0d935610a2a2fe8c947e3f7fe315c1641ceaaedd7d"
FIXED_BUILDER = "855a36af664122bcb199157eefff63cddbd498ba327e4388aa474fe420bdb8c1"
OLD_PROVIDER_SHA256 = "a4ef0f4b7bd2c9cdabb4b8eb9e0a7249eab4f9e06f9991bcdb2f59a230220b4f"
OLD_FACTORY_SHA256 = "70d90ede3bdfbf44e146ba4a26f101ebfec2a1745bc05a8260db001d5a236537"
# Exact historical producer source bytes, frozen before the closure edit.
# They are private negative inputs, never replacement policy or expected data
# regenerated from the successor. Hashes below bind both complete preimages.
OLD_PROVIDER = zlib.decompress(
    base64.b64decode(
        "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"
        "Qh576pIVhTTehiwUXBNOU0FuGNDpT9kdZkTf1tXJJ3ZbX82s0UJFTL0NEHdIAXGnOqBImJOS9GQGCxrLgDKa29MiyYs1D538KmQF"
        "Hp1A1aTIPtJ3Jib3d2eyym6hklO9kkpnEX9G6SrFo5Zs+0ck/4chofqnn+APRnY18cMWjghxIZnqYQe+mU4GHdBnegeHokTnJvsy"
        "mlyDAq+MUtjwtkWvsVhmk1sQ4w3nuTv+oyWcL/SRVPEzDRL71HROIvVgQzqjDH30mo31arx93DBlQL43aCDYYj39fdZIcEphfJHG"
        "qdWs8KDQ8obBw04WyRzT16TxRrGxrhyOnLDLcUazKmnZ84Dd+/E83P4XwVIJsvzo02lylQ3Xy8nqrqP1Qu+bc+zpYpoO3elHjB57"
        "osRfv/3jb2/e93/56b9/efX26tRo4ttJp7Mj/vsT2jhf7ozWn1bpItumcVpPpqOd92I6d4B/5MtOCi2qWc9/wGYL5zAKn99E/YbC"
        "9nSQ31oNMnMhOFAsHTRXwfh0YCI8dqu51f8vOENC3g=="
    )
)
OLD_FACTORY = zlib.decompress(
    base64.b64decode(
        "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"
        "Y4dSm0ask6n/F52Wgp4="
    )
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load(name, path, data=None):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    exec(compile(path.read_bytes() if data is None else data, str(path), "exec"), module.__dict__)
    return module


class LexicalSourceClosureControls(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="lexical-source-closure-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.root.chmod(0o700)
        self.provider_path = self.root / "tools/build/remap_runtime_patch.py"
        self.factory_path = self.root / "tools/build/remap_runtime_source.py"
        self.builder_path = self.root / "tools/build/remap_runtime_build.py"
        factory_data = (ROOT / "tools/build/remap_runtime_source.py").read_bytes()
        dependencies = []
        for node in ast.parse(factory_data).body:
            if isinstance(node, ast.Assign) and any(
                isinstance(target, ast.Name) and target.id in {"DEPENDENCIES", "VHD_DEPENDENCIES"}
                for target in node.targets
            ):
                dependencies.extend(ast.literal_eval(node.value))
        self.assertEqual(len(dependencies), 34)
        paths = {path for path, _ in dependencies} | {
            "tools/build/remap_runtime_source.py",
            "tools/build/remap_runtime_build.py",
            "tools/diagnostics/hs274_native_build.py",
        }
        for relative in sorted(paths):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
        self.builder = load("lexical_closure_builder_" + str(id(self)), self.builder_path)
        self.assertEqual(digest(OLD_PROVIDER), OLD_PROVIDER_SHA256)
        self.assertEqual(digest(OLD_FACTORY), OLD_FACTORY_SHA256)

    def test_actual_coherent_fixed_source_loads_and_captures_all_dependencies(self):
        self.assertEqual(digest(self.provider_path.read_bytes()), FIXED_PROVIDER)
        self.assertEqual(digest(self.factory_path.read_bytes()), FIXED_FACTORY)
        self.assertEqual(digest(self.builder_path.read_bytes()), FIXED_BUILDER)
        self.assertEqual(self.builder_path.stat().st_size, 132154)
        self.assertEqual(self.builder.PROVIDER_SHA256, FIXED_PROVIDER)
        self.assertEqual(self.builder.SOURCE_FACTORY_SHA256, FIXED_FACTORY)
        self.assertEqual(self.builder.CURRENT_OWNED_SOURCE_FACTORY_SHA256, FIXED_FACTORY)
        factory = self.builder._source_factory()
        deadline = time.monotonic() + 60
        self.assertEqual(len(factory.capture_dependencies(self.root, deadline)), 32)
        self.assertEqual(len(factory.capture_vhd_dependencies(self.root, deadline)), 2)
        self.assertEqual(
            self.builder._identifiers(),
            {
                "core": "com.ergoptiplus.remap.core",
                "console": "com.ergoptiplus.remap.console",
                "cli": "com.ergoptiplus.remap.cli",
            },
        )
        self.assertEqual(
            self.builder._identifiers(repository=self.root, deadline=deadline),
            self.builder._identifiers(),
        )

    def test_genuine_historical_provider_refuses_current_direct_loader(self):
        self.provider_path.write_bytes(OLD_PROVIDER)
        with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
            self.builder._identifiers()
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(caught.exception.args, ("Reviewed single identity provider changed",))

    def test_genuine_historical_factory_refuses_current_captured_loader(self):
        self.factory_path.write_bytes(OLD_FACTORY)
        with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
            self.builder._source_factory()
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(caught.exception.args, ("The fixed current source factory changed",))

    def test_actual_old_factory_refuses_current_provider_dependency(self):
        old_factory = load(
            "lexical_actual_old_factory_" + str(id(self)), self.factory_path, OLD_FACTORY
        )
        with self.assertRaises(old_factory.SourceRefusal) as caught:
            old_factory.capture_dependencies(self.root, time.monotonic() + 60)
        self.assertEqual(caught.exception.code, "dependency_changed")

    def test_actual_current_factory_refuses_old_provider_dependency(self):
        factory = self.builder._source_factory()
        self.provider_path.write_bytes(OLD_PROVIDER)
        with self.assertRaises(factory.SourceRefusal) as caught:
            factory.capture_dependencies(self.root, time.monotonic() + 60)
        self.assertEqual(caught.exception.code, "dependency_changed")

    def test_genuine_factory_write_restore_after_first_read_refuses_incarnation(self):
        ordinary = self.builder._ordinary
        observations = []

        def observed(path, *arguments):
            result = ordinary(path, *arguments)
            if Path(path) == self.factory_path:
                observations.append(result)
                if len(observations) == 1:
                    original = self.factory_path.read_bytes()
                    self.factory_path.write_bytes(original + b"\n# changed retained factory\n")
                    self.factory_path.write_bytes(original)
            return result

        with patch.object(self.builder, "_ordinary", side_effect=observed):
            with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
                self.builder._source_factory()
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(
            caught.exception.args, ("The actual source factory changed during loading",)
        )
        self.assertEqual(len(observations), 2)

    def test_genuine_provider_restore_after_actual_execution_refuses_dependency_incarnation(self):
        factory = self.builder._source_factory()
        actual_load = factory.load_fixed
        entered = []

        def observed(name, row):
            module = actual_load(name, row)
            if row.path == "tools/build/remap_runtime_patch.py":
                entered.append(row)
                original = self.provider_path.read_bytes()
                self.provider_path.write_bytes(original + b"\n# changed retained provider\n")
                self.provider_path.write_bytes(original)
            return module

        with patch.object(factory, "load_fixed", side_effect=observed):
            with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
                self.builder._identifiers(repository=self.root, deadline=time.monotonic() + 60)
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(
            caught.exception.args, ("Actual fixed identity provider changed across loading",)
        )
        self.assertEqual(len(entered), 1)

    def test_genuine_same_byte_factory_replacement_after_read_refuses_named_incarnation(self):
        ordinary = self.builder._ordinary
        observations = []

        def observed(path, *arguments):
            result = ordinary(path, *arguments)
            if Path(path) == self.factory_path:
                observations.append(result)
                if len(observations) == 1:
                    replacement = self.factory_path.with_name("replacement.py")
                    replacement.write_bytes(self.factory_path.read_bytes())
                    replacement.replace(self.factory_path)
            return result

        with patch.object(self.builder, "_ordinary", side_effect=observed):
            with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
                self.builder._source_factory()
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(
            caught.exception.args, ("The actual source factory changed during loading",)
        )
        self.assertEqual(len(observations), 2)


if __name__ == "__main__":
    unittest.main()
