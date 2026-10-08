# tools/diagnostics/hs274_native_metadata_caller_test.py
"""Frozen actual caller-boundary controls; synthetic credential, real POSIX child, Native0."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid

REPOSITORY = Path(__file__).resolve().parents[2]
if "--repository" in sys.argv:
    index = sys.argv.index("--repository")
    REPOSITORY = Path(sys.argv[index + 1]).resolve(strict=True)
    del sys.argv[index : index + 2]
PURPOSE = "ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN"
TOKEN = "ghs_SYNTHETIC_COMPILER_CALLER_CONTROL_ONLY"
AMBIENT = {
    "GH_TOKEN": "ghs_SYNTHETIC_AMBIENT_GH_ONLY",
    "GITHUB_TOKEN": "ghs_SYNTHETIC_AMBIENT_GITHUB_ONLY",
    "ERGOPTI_NATIVE_HS_METADATA_TOKEN": "ghs_SYNTHETIC_AMBIENT_HS_ONLY",
    "ERGOPTI_COMPILER_NEIGHBOR": "synthetic-neighbor-preserved",
}
BOUNDARY = "review_metadata_boundary"


def load(path):
    name = "independent_metadata_caller_" + uuid.uuid4().hex
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class CompilerCallerContracts(unittest.TestCase):
    def setUp(self):
        self.private = tempfile.TemporaryDirectory(prefix="compiler-caller-")
        self.addCleanup(self.private.cleanup)
        self.owner = Path(self.private.name).resolve()
        self.owner.chmod(0o700)
        self.observations = []
        self.acquisitions = []
        self.stream = io.StringIO()

    def environment(self, value):
        values = {"PATH": os.defpath, **AMBIENT}
        if value is not None:
            values[PURPOSE] = value
        return mock.patch.dict(os.environ, values, clear=True)

    def observe(self, phase):
        # The actual process inherits the tested caller's current environment;
        # only JSON booleans are emitted, never a credential or native result.
        program = (
            'import json,os;print(json.dumps({"purpose_absent":"ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN" not in os.environ,"ambient":'
            + repr(AMBIENT)
            + "=={key:os.environ.get(key) for key in "
            + repr(list(AMBIENT))
            + "}}))"
        )
        child = subprocess.run(
            [sys.executable, "-c", program], capture_output=True, text=True, timeout=10
        )
        self.assertEqual(child.returncode, 0)
        self.assertEqual(child.stderr, "")
        packet = json.loads(child.stdout)
        self.observations.append(
            {
                "phase": phase,
                "parent_absent": PURPOSE not in os.environ,
                "parent_ambient": all(
                    os.environ.get(key) == value for key, value in AMBIENT.items()
                ),
                "child_absent": packet["purpose_absent"],
                "child_ambient": packet["ambient"],
            }
        )

    def acquire(self, module):
        def metadata(owner, deadline, *, metadata_token=None):
            self.observe("metadata")
            self.acquisitions.append(
                {
                    "held": type(metadata_token) is str and metadata_token == TOKEN,
                    "absent": metadata_token is None,
                }
            )
            raise module.NativeBuildError(BOUNDARY, "Independent controlled metadata boundary")

        return metadata

    def phase(self, name, *arguments):
        self.observe("native-phase:" + name)
        return {"phase": name, "status": "passed", "elapsed_seconds": 0.0}

    def factory(self):
        self.observe("factory")
        return SimpleNamespace(
            capture_dependencies=lambda *args: None,
            capture_vhd_dependencies=lambda *args: None,
            prepare_owned_source=lambda *args: None,
        )

    def verify(self, value, code):
        self.assertNotIn(TOKEN, self.stream.getvalue())
        self.assertTrue(all(os.environ.get(key) == value for key, value in AMBIENT.items()))
        self.assertNotIn(PURPOSE, os.environ)
        if value is not None and value != TOKEN:
            self.assertEqual(code, "xcodegen_metadata_token")
            self.assertEqual(self.observations, [])
            self.assertEqual(self.acquisitions, [])
        else:
            self.assertEqual(code, BOUNDARY)
            self.assertTrue(self.observations)
            self.assertTrue(
                all(
                    row["parent_absent"]
                    and row["parent_ambient"]
                    and row["child_absent"]
                    and row["child_ambient"]
                    for row in self.observations
                )
            )
            self.assertEqual(self.acquisitions, [{"held": value == TOKEN, "absent": value is None}])

    def base(self, value):
        module = load(REPOSITORY / "tools/diagnostics/hs274_native_build.py")
        args = [
            "independent-base",
            str(REPOSITORY / "tools/diagnostics"),
            str(self.owner),
            "--budget",
            "300",
        ]
        with (
            self.environment(value),
            mock.patch.object(sys, "argv", args),
            mock.patch.object(sys, "platform", "darwin"),
            mock.patch.object(module.shutil, "which", return_value=sys.executable),
            mock.patch.object(module, "run_phase", side_effect=self.phase),
            mock.patch.object(module, "acquire_xcodegen", side_effect=self.acquire(module)),
            contextlib.redirect_stderr(self.stream),
        ):
            status = module.main()
            self.assertEqual(status, 1)
            code = (
                "xcodegen_metadata_token"
                if "xcodegen_metadata_token;" in self.stream.getvalue()
                else BOUNDARY
            )
            self.verify(value, code)

    def owned(self, value):
        module = load(REPOSITORY / "tools/build/remap_runtime_build.py")
        with (
            self.environment(value),
            mock.patch.object(module, "_source_factory", side_effect=self.factory),
            mock.patch.object(sys, "platform", "darwin"),
            mock.patch.object(module.shutil, "which", return_value=sys.executable),
            mock.patch.object(module, "_observed_run_phase", side_effect=self.phase),
            mock.patch.object(
                module.BASE, "acquire_xcodegen", side_effect=self.acquire(module.BASE)
            ),
        ):
            try:
                module._compile_owned(REPOSITORY, self.owner, 300)
            except module.BASE.NativeBuildError as failure:
                code = failure.code
            else:
                self.fail("Controlled metadata boundary must refuse without building")
            self.verify(value, code)

    def core(self, value):
        module = load(
            REPOSITORY / "tools/diagnostics/owned_runtime_service_reference_core_fixture_build.py"
        )
        fixed = module._FixedInputs
        real_path = module.Path
        shim_info = Path(sys.executable).stat()

        class AppleShim:
            def __init__(self, name):
                if name not in ("xcodebuild", "xcrun"):
                    raise AssertionError("Unknown modeled Apple shim")
                self.name = name

            def __str__(self):
                return "/usr/bin/" + self.name

            def resolve(self, *, strict=False):
                return self

            def is_file(self):
                return True

            def stat(self):
                return shim_info

        class AppleDirectory:
            def __truediv__(self, name):
                return AppleShim(name)

        def native_path(value):
            return AppleDirectory() if value == "/usr/bin" else real_path(value)

        def verified_inputs(repository):
            owner = fixed(repository)  # Actual fixed source bytes/hash/FD admission.
            self.assertEqual(len(owner.holds), 4)
            self.assertTrue(all(not hold.closed and not hold.failed for hold in owner.holds))
            owner.module._source_factory = self.factory
            owner.module._observed_run_phase = self.phase
            owner.module.BASE.acquire_xcodegen = self.acquire(owner.module.BASE)
            return owner

        with (
            self.environment(value),
            mock.patch.object(module, "_FixedInputs", side_effect=verified_inputs),
            mock.patch.object(module, "Path", side_effect=native_path),
            mock.patch.object(sys, "platform", "darwin"),
        ):
            try:
                module.produce(REPOSITORY, self.owner / "unacquired-pristine", self.owner, 300)
            except module.Refusal as failure:
                code = failure.code
                self.assertIsInstance(failure.owner, module.CoreFixtureBuild)
                self.assertTrue(failure.owner.close_retained())
            else:
                self.fail("Controlled metadata boundary must refuse without building")
            self.verify(value, code)

    def test_base_valid_purpose_is_held_for_metadata_before_any_native_child(self):
        self.base(TOKEN)

    def test_base_absent_purpose_keeps_ambient_credentials_without_borrowing(self):
        self.base(None)

    def test_base_malformed_purpose_is_consumed_before_any_native_child(self):
        self.base(TOKEN + "\n")

    def test_owned_valid_purpose_is_held_before_factory_and_native_child(self):
        self.owned(TOKEN)

    def test_owned_absent_purpose_keeps_ambient_credentials_without_borrowing(self):
        self.owned(None)

    def test_owned_malformed_purpose_is_consumed_before_factory(self):
        self.owned(TOKEN + "\n")

    def test_core_valid_purpose_is_held_after_verified_inputs_before_factory(self):
        self.core(TOKEN)

    def test_core_absent_purpose_keeps_ambient_credentials_without_borrowing(self):
        self.core(None)

    def test_core_malformed_purpose_is_consumed_before_factory(self):
        self.core(TOKEN + "\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
