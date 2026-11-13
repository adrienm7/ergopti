"""The managed network diagnostic reports scratch failures as closed verdicts."""

import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "managed_network_check",
    ROOT / "static/ergopti_plus/macos/ai/engine/bootstrap/managed_network_check.py",
)
NETWORK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NETWORK)


class WorkspaceFailure(unittest.TestCase):
    def test_scratch_creation_failure_produces_digest_verdict(self):
        class Bootstrap:
            BootstrapFailure = type("BootstrapFailure", (Exception,), {})

        output = io.StringIO()
        with mock.patch.object(
            NETWORK.tempfile, "TemporaryDirectory", side_effect=OSError("disk full")
        ):
            with contextlib.redirect_stdout(output):
                NETWORK.digest_step(Bootstrap, {})
        self.assertEqual(output.getvalue(), "step digest fail unavailable\n")

    def test_scratch_cleanup_failure_does_not_report_success(self):
        class Bootstrap:
            BootstrapFailure = type("BootstrapFailure", (Exception,), {})
            download = staticmethod(lambda *args: None)

        class Workspace:
            def __enter__(self):
                return "/tmp/fixture"

            def __exit__(self, *_args):
                raise OSError("cleanup refused")

        output = io.StringIO()
        source = {"url": "https://example.test", "sha256": "0" * 64, "bytes": 1}
        with mock.patch.object(NETWORK.tempfile, "TemporaryDirectory", return_value=Workspace()):
            with contextlib.redirect_stdout(output):
                NETWORK.digest_step(Bootstrap, source)
        self.assertEqual(output.getvalue(), "step digest fail unavailable\n")


if __name__ == "__main__":
    unittest.main()
