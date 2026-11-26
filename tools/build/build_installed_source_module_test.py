#!/usr/bin/env python3
"""The app build compiles the installed-source module with the runtime roster.

Run by tools/test/test-macos-bundle-payload.cjs, so the JS gate covers it on
every host; the compile itself needs a Mac and runs in the macOS app build.
"""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parent.parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


builder = load("build_installed_source_module", HERE / "build_installed_source_module.py")
product = builder.load_product(REPOSITORY)


class ModuleRosterTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.scratch.name))
        for name in ("work", "MacOSX.sdk", "lua"):
            (self.root / name).mkdir()

    def tearDown(self):
        self.scratch.cleanup()

    def rows(self):
        return builder.module_rows(
            product, REPOSITORY, self.root / "work", self.root / "MacOSX.sdk", self.root / "lua"
        )

    def test_rows_are_the_runtime_build_module_rows_unchanged(self):
        roster = dict(
            product.compile_commands(
                REPOSITORY, self.root / "work", self.root / "MacOSX.sdk", self.root / "lua"
            )
        )
        rows = self.rows()
        self.assertEqual(
            [name for name, _ in rows], ["module_arm64", "module_x86_64", "module_universal"]
        )
        for name, arguments in rows:
            self.assertEqual(arguments, roster[name])

    def test_rows_compile_the_module_source_against_the_given_lua_headers(self):
        for name, arguments in self.rows()[:2]:
            self.assertIn(str(REPOSITORY / product.MODULE_SOURCE), arguments, name)
            self.assertIn("-bundle", arguments, name)
            self.assertEqual(arguments[arguments.index("-I") + 1], str(self.root / "lua"), name)
        universal = self.rows()[2][1]
        self.assertEqual(universal[:2], ["/usr/bin/lipo", "-create"])
        self.assertEqual(universal[-1], str(self.root / "work" / "module.so"))

    def test_a_roster_without_module_rows_is_refused(self):
        fake = mock.Mock(ARCHITECTURES=("arm64",))
        fake.compile_commands.return_value = (("installer_arm64", ["swiftc"]),)
        with self.assertRaises(builder.ModuleBuildRefusal):
            builder.module_rows(fake, REPOSITORY, self.root, self.root, self.root)

    def test_a_non_darwin_host_is_refused_before_any_compile(self):
        with (
            mock.patch.object(builder.sys, "platform", "linux"),
            mock.patch.object(builder.subprocess, "run") as run,
        ):
            with self.assertRaises(builder.ModuleBuildRefusal):
                builder.build(
                    REPOSITORY,
                    self.root,
                    self.root / "fresh",
                    self.root / builder.OUTPUT_NAME,
                )
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
