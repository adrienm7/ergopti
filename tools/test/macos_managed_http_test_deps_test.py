"""Independent literal tests for the native-client locked dependency exporter."""

import importlib.util
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "locked_client_export", Path(__file__).with_name("export-macos-managed-http-test-deps.py")
)
export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export)


def package(name, dependency="", version="1.2.3", digest="a" * 64):
    edges = (
        f'dependencies = [{{ name = "{dependency}", marker = "sys_platform == \'win32\'" }}]\n'
        if dependency
        else ""
    )
    return (
        f'[[package]]\nname = "{name}"\nversion = "{version}"\n'
        'source = { registry = "https://pypi.org/simple" }\n'
        + edges
        + f'wheels = [{{ url = "https://files.pythonhosted.org/reserved.whl", hash = "sha256:{digest}" }}]\n'
    )


class LockedClosureReceiving(unittest.TestCase):
    def setUp(self):
        self.source = (
            "version = 1\n"
            + package("huggingface-hub", "marker-child")
            + package("httpx")
            + package("truststore")
            + package("marker-child")
            + package("unrelated-mlx")
        )

    def testLiteralClosureRetainsPlatformEdgesAndExcludesUnrelatedRuntime(self):
        result = export.requirements(self.source)
        self.assertEqual(
            result,
            "# Exported from the existing uv.lock; install with --require-hashes --only-binary=:all:.\n"
            + "".join(
                name + "==1.2.3 \\\n    --hash=sha256:" + "a" * 64 + "\n"
                for name in ["httpx", "huggingface-hub", "marker-child", "truststore"]
            ),
        )

    def testHashAndRegistryRefusalCannotBecomeUnqualifiedInstall(self):
        for bad in [
            self.source.replace("a" * 64, "invalid"),
            self.source.replace("https://pypi.org/simple", "https://unqualified.example/simple"),
            self.source.replace("version = 1\n", "version = true\n"),
            self.source.replace("wheels = [", "ignored = ["),
        ]:
            with self.subTest(vector=bad[:35]), self.assertRaises(ValueError):
                export.requirements(bad)

    def testAmbiguousMarkerVersionsRefuseInsteadOfFlattening(self):
        with self.assertRaises(ValueError):
            export.requirements(self.source + package("marker-child", version="9.0"))
        with self.assertRaises(ValueError):
            export.requirements(
                self.source.replace('name = "marker-child", marker', 'name = "absent", marker')
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
