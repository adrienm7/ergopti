# tools/diagnostics/native_global_switcher/test_owner_control_runner.py
"""Independent portable scope/status controls; mocked calls never qualify Lua."""

from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import run_owner_controls


class PortableRunner(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "source"
        self.source.mkdir()
        subject = Path(__file__).parent
        for name in ("global-switcher.lua", "test_probe_owner.lua"):
            (self.source / name).write_bytes((subject / name).read_bytes())
        self.foreign = self.root / "user-owned.txt"
        self.foreign.write_text("independent user bytes")

    def test_exact_sources_and_forty_independent_scopes_are_retired_without_touching_source(self):
        acquired = []
        before = {path.name: path.read_bytes() for path in self.source.iterdir()}

        def observe(argv, **options):
            self.assertEqual(options, {"check": False})
            self.assertEqual(argv[0], "literal Lua executable 日本")
            scope = Path(argv[2])
            self.assertEqual(Path(argv[1]), scope / "test_probe_owner.lua")
            self.assertNotEqual(scope, self.source)
            acquired.append(scope)
            self.assertEqual(
                sorted(path.name for path in scope.iterdir() if path.is_dir()),
                sorted("control-" + name for name in run_owner_controls.CONTROL_CASES),
            )
            self.assertEqual(len(list(scope.glob("control-*"))), 43)
            for name, content in before.items():
                self.assertEqual((scope / name).read_bytes(), content)
            (scope / "controlled-symlink").symlink_to(self.foreign)
            return SimpleNamespace(returncode=0)

        with patch.object(run_owner_controls.subprocess, "run", side_effect=observe):
            self.assertEqual(
                run_owner_controls.run_controls("literal Lua executable 日本", self.source), 0
            )
        self.assertEqual(len(acquired), 1)
        self.assertFalse(acquired[0].exists())
        self.assertEqual({p.name: p.read_bytes() for p in self.source.iterdir()}, before)
        self.assertEqual(self.foreign.read_text(), "independent user bytes")

    def test_nonzero_and_signalled_child_statuses_are_never_replaced_with_success(self):
        for status, expected in ((1, 1), (7, 7), (64, 64), (-15, 143)):
            with self.subTest(status=status):
                with patch.object(
                    run_owner_controls.subprocess,
                    "run",
                    return_value=SimpleNamespace(returncode=status),
                ):
                    self.assertEqual(run_owner_controls.run_controls("lua", self.source), expected)

    def test_case_inventory_refusal_precedes_any_interpreter_or_temporary_scope(self):
        test = self.source / "test_probe_owner.lua"
        test.write_bytes(test.read_bytes().replace(b'"healthy"', b'"unknown_case"', 1))
        with (
            patch.object(run_owner_controls.subprocess, "run") as launch,
            patch.object(run_owner_controls.tempfile, "TemporaryDirectory") as acquire,
        ):
            with self.assertRaises(ValueError):
                run_owner_controls.run_controls("lua", self.source)
        launch.assert_not_called()
        acquire.assert_not_called()
        self.assertTrue(self.foreign.exists())

    def test_interpreter_creation_refusal_still_retires_only_the_owned_scope(self):
        scopes = []

        def refuse(argv, **options):
            scopes.append(Path(argv[2]))
            raise OSError("independent interpreter refusal")

        with patch.object(run_owner_controls.subprocess, "run", side_effect=refuse):
            with self.assertRaises(OSError):
                run_owner_controls.run_controls("lua", self.source)
        self.assertEqual(len(scopes), 1)
        self.assertFalse(scopes[0].exists())
        self.assertTrue(self.source.is_dir() and self.foreign.is_file())

    def test_cli_delegates_literal_interpreter_and_preserves_failure(self):
        with patch.object(run_owner_controls, "run_controls", return_value=7) as run:
            self.assertEqual(
                run_owner_controls.main(
                    ["--lua", "lua 日本", "--source-directory", str(self.source)]
                ),
                7,
            )
        run.assert_called_once_with("lua 日本", self.source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
