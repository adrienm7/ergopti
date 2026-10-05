"""Controlled diagnostics only: no native acceptance or model processes execute."""

import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SOURCE = None
REPOSITORY = None
MODULE = None
PRIVATE = "private-sentinel-prompt-token-config-error-path-https-secret"


def load_source(path):
    spec = importlib.util.spec_from_file_location("acceptance_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def failed_document():
    return {
        "passed": False,
        "status": "failed",
        "reason": "native_receipt_or_source_qualification_failed",
        "work_phase": "explicit-model-pull",
        "cleanup_phase": "terminal-physical-shutdown",
        "child_status": 1,
        "zero_descendants": True,
        "sources_unchanged": True,
    }


class FailureMetadataTests(unittest.TestCase):
    def test_cleanup_retains_actual_work_phase(self):
        markers = (
            "ACCEPTANCE_PHASE official-https-install\n"
            "ACCEPTANCE_PHASE missing-model-preflight\n"
            "ACCEPTANCE_PHASE explicit-model-pull\n"
            "ACCEPTANCE_PHASE terminal-physical-shutdown\n"
        )
        self.assertEqual(
            MODULE.acceptance_phases(markers),
            {
                "phase": "terminal-physical-shutdown",
                "work_phase": "explicit-model-pull",
                "cleanup_phase": "terminal-physical-shutdown",
            },
        )

    def test_unknown_and_post_cleanup_markers_have_no_authority(self):
        self.assertEqual(
            MODULE.acceptance_phases(
                "ACCEPTANCE_PHASE official-https-install\n"
                "ACCEPTANCE_PHASE " + PRIVATE + "\n"
                "ACCEPTANCE_PHASE real-model-chat \n"
                "ACCEPTANCE_PHASE terminal-physical-shutdown\n"
                "ACCEPTANCE_PHASE real-model-chat\n"
            )["work_phase"],
            "official-https-install",
        )
        self.assertIsNone(MODULE.acceptance_phases({"text": PRIVATE}))

    def test_annotation_exact_closed_projection(self):
        self.assertEqual(
            MODULE.failure_annotation(failed_document()),
            "::error title=Ollama native acceptance::"
            "phase=explicit-model-pull cleanup_phase=terminal-physical-shutdown "
            "status=failed reason=native_receipt_or_source_qualification_failed "
            "child_status=1 zero_descendants=true sources_unchanged=true exception_type=none",
        )

    def test_private_extras_are_never_coerced_or_emitted(self):
        class PrivateValue:
            def __str__(self):
                raise AssertionError("private data must not be coerced")

        document = failed_document()
        document.update(
            error=PrivateValue(),
            private_url=PRIVATE,
            prompt=PRIVATE,
            config=PRIVATE,
            evidence=PRIVATE,
            sources_before={PRIVATE: PRIVATE},
            sources_after={PRIVATE: PRIVATE},
            receipt={"response": PRIVATE},
        )
        self.assertEqual(
            MODULE.failure_annotation(document), MODULE.failure_annotation(failed_document())
        )
        self.assertNotIn(PRIVATE, MODULE.failure_annotation(document))

    def test_unknown_tokens_and_workflow_command_injection_are_refused(self):
        for key in ("status", "reason", "work_phase", "cleanup_phase", "exception_type"):
            for value in (
                PRIVATE,
                "failed\n::error::" + PRIVATE,
                "failed\r" + PRIVATE,
                "failed%0A" + PRIVATE,
                [PRIVATE],
                {"private": PRIVATE},
            ):
                with self.subTest(key=key, value_type=type(value).__name__):
                    document = failed_document()
                    document[key] = value
                    self.assertIsNone(MODULE.safe_failure_metadata(document))
                    self.assertIsNone(MODULE.failure_annotation(document))

    def test_child_status_type_and_bounds_are_exact(self):
        for value in (False, True, 1.0, "1", -65, 256, 10**100):
            with self.subTest(value_type=type(value).__name__):
                document = failed_document()
                document["child_status"] = value
                self.assertIsNone(MODULE.failure_annotation(document))
        for value in (-64, -9, 0, 1, 255):
            document = failed_document()
            document["child_status"] = value
            self.assertEqual(MODULE.safe_failure_metadata(document)["child_status"], value)

    def test_physical_and_source_proofs_never_coerce(self):
        for key in ("zero_descendants", "sources_unchanged"):
            for value in (0, 1, "true", {}, []):
                with self.subTest(key=key, value_type=type(value).__name__):
                    document = failed_document()
                    document[key] = value
                    self.assertIsNone(MODULE.failure_annotation(document))
            for value in (True, False):
                document = failed_document()
                document[key] = value
                self.assertEqual(MODULE.safe_failure_metadata(document)[key], str(value).lower())

    def test_missing_proofs_are_unknown_not_success(self):
        document = failed_document()
        for key in ("child_status", "zero_descendants", "sources_unchanged", "cleanup_phase"):
            del document[key]
        metadata = MODULE.safe_failure_metadata(document)
        self.assertEqual(metadata["child_status"], "unknown")
        self.assertEqual(metadata["zero_descendants"], "unknown")
        self.assertEqual(metadata["sources_unchanged"], "unknown")
        self.assertEqual(metadata["cleanup_phase"], "none")

    def test_success_and_malformed_documents_refuse_failure_annotation(self):
        for value in (None, [], "failed", {}, {"passed": 0}):
            self.assertIsNone(MODULE.failure_annotation(value))
        document = failed_document()
        document["passed"] = True
        self.assertIsNone(MODULE.failure_annotation(document))
        document = failed_document()
        document["status"] = "passed"
        self.assertIsNone(MODULE.failure_annotation(document))

    def test_builtin_subclasses_are_not_diagnostic_authority(self):
        class PretendString(str):
            pass

        class PretendInteger(int):
            pass

        class PretendDocument(dict):
            pass

        document = failed_document()
        document["work_phase"] = PretendString("explicit-model-pull")
        self.assertIsNone(MODULE.failure_annotation(document))
        document = failed_document()
        document["child_status"] = PretendInteger(1)
        self.assertIsNone(MODULE.failure_annotation(document))
        self.assertIsNone(MODULE.failure_annotation(PretendDocument(failed_document())))

    def test_exception_identity_is_closed_and_consistent(self):
        document = failed_document()
        document["reason"] = "qualification_exception"
        self.assertIsNone(MODULE.failure_annotation(document))
        document["exception_type"] = "AssertionError"
        self.assertEqual(MODULE.safe_failure_metadata(document)["exception_type"], "AssertionError")
        document["exception_type"] = PRIVATE
        self.assertIsNone(MODULE.failure_annotation(document))
        document = failed_document()
        document["exception_type"] = "AssertionError"
        self.assertIsNone(MODULE.failure_annotation(document))


class MainDiagnosticTests(unittest.TestCase):
    def run_controlled_main(self, mode):
        with tempfile.TemporaryDirectory(prefix="safe-acceptance-") as directory:
            temporary = Path(directory)
            repository = temporary / "repository"
            relative = Path("static/ergopti_plus/linux/tests/hardware")
            hardware = repository / relative
            hardware.mkdir(parents=True)
            source = hardware / "run_ollama_runtime_acceptance.py"
            shutil.copyfile(SOURCE, source)
            for name in ("run_native_subreaper.py", "run_ollama_runtime_acceptance.lua"):
                shutil.copyfile(REPOSITORY / relative / name, hardware / name)
            shared = repository / "static/ergopti_plus/_shared/modules/llm"
            shared.mkdir(parents=True)
            for name in ("models.json", "ollama_release.json"):
                shutil.copyfile(
                    REPOSITORY / "static/ergopti_plus/_shared/modules/llm" / name, shared / name
                )
            home = temporary / "home"
            home.mkdir(mode=0o700)
            evidence = temporary / "evidence"
            module = load_source(source)
            output = io.StringIO()
            launches = []
            real_stat = Path.stat

            def root_stat(path, *args, **kwargs):
                result = real_stat(path, *args, **kwargs)
                if path == Path("/"):
                    fields = list(result)
                    fields[4] = 65534 if mode == "exception" else 0
                    return os.stat_result(fields)
                return result

            def child(command, **options):
                launches.append(command)
                options["stdout"].write(
                    (
                        "ACCEPTANCE_PHASE official-https-install\n"
                        "ACCEPTANCE_PHASE missing-model-preflight\n"
                        "ACCEPTANCE_PHASE explicit-model-pull\n"
                        "NATIVE_LOG " + PRIVATE + "\n"
                        "{malformed private receipt " + PRIVATE + "\n"
                        "ACCEPTANCE_PHASE terminal-physical-shutdown\n"
                        "Native subreaper: 0 adopted descendants physically reaped\n"
                        'Native subreaper closure: {"pending":0,"rescue":0,"adopted":0}\n'
                    ).encode()
                )
                return subprocess.CompletedProcess(command, 1)

            class Reservation:
                def __enter__(self):
                    return self

                def __exit__(self, *_):
                    return False

                def bind(self, _):
                    pass

                def getsockname(self):
                    return ("127.0.0.1", 17431)

            environment = {
                "GITHUB_ACTIONS": "true",
                "GITHUB_EVENT_NAME": "push" if mode == "refused" else "workflow_dispatch",
            }
            previous_umask = os.umask(0o077)
            try:
                with (
                    patch.object(
                        sys,
                        "argv",
                        [str(source), "--repository", str(repository), "--evidence", str(evidence)],
                    ),
                    patch.dict(os.environ, environment),
                    patch.object(Path, "home", return_value=home),
                    patch.object(Path, "stat", root_stat),
                    patch.object(socket, "socket", return_value=Reservation()),
                    patch.object(subprocess, "run", child),
                    contextlib.redirect_stdout(output),
                ):
                    status = module.main()
            finally:
                os.umask(previous_umask)
            document = json.loads((evidence / "ollama-runtime-acceptance.json").read_text())
            annotations = [
                line for line in output.getvalue().splitlines() if line.startswith("::error ")
            ]
            return status, document, annotations, launches

    def test_failed_child_work_phase_survives_cleanup_in_checks_annotation(self):
        status, document, annotations, launches = self.run_controlled_main("failed-child")
        # Establish the actual failed-child path before checking new diagnostics.
        self.assertEqual(status, 1)
        self.assertEqual(len(launches), 1)
        self.assertFalse(document["passed"])
        self.assertEqual(document["reason"], "native_receipt_or_source_qualification_failed")
        self.assertEqual(document["child_status"], 1)
        self.assertIs(document["sources_unchanged"], True)
        self.assertIs(document["zero_descendants"], True)
        self.assertEqual(document["phase"], "terminal-physical-shutdown")
        self.assertEqual(
            len(annotations), 1, "failure must be available through a GitHub checks annotation"
        )
        self.assertEqual(
            annotations[0],
            "::error title=Ollama native acceptance::phase=explicit-model-pull "
            "cleanup_phase=terminal-physical-shutdown status=failed "
            "reason=native_receipt_or_source_qualification_failed child_status=1 "
            "zero_descendants=true sources_unchanged=true exception_type=none",
        )
        self.assertEqual(document["work_phase"], "explicit-model-pull")
        for private in (
            PRIVATE,
            "/",
            "sources_before",
            "sources_after",
            "private_log",
            "evidence=",
        ):
            self.assertNotIn(private, annotations[0])

    def test_preflight_exception_annotation_contains_no_exception_text(self):
        status, document, annotations, launches = self.run_controlled_main("exception")
        self.assertEqual(status, 1)
        self.assertEqual(launches, [])
        self.assertEqual(document["reason"], "qualification_exception")
        self.assertEqual(len(annotations), 1)
        self.assertIn("phase=preflight", annotations[0])
        self.assertIn("exception_type=AssertionError", annotations[0])
        self.assertIn("zero_descendants=unknown", annotations[0])
        self.assertNotIn("trusted native root inode", annotations[0])

    def test_automatic_event_refusal_emits_no_native_proof(self):
        status, document, annotations, launches = self.run_controlled_main("refused")
        self.assertEqual(status, 2)
        self.assertEqual(launches, [])
        self.assertIs(document["native_executed"], False)
        self.assertEqual(len(annotations), 1)
        self.assertIn("status=refused reason=manual_workflow_dispatch_required", annotations[0])
        self.assertIn(
            "child_status=unknown zero_descendants=unknown sources_unchanged=unknown",
            annotations[0],
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--original-causal", action="store_true")
    args = parser.parse_args()
    SOURCE = args.source.resolve()
    REPOSITORY = args.repository.resolve()
    MODULE = load_source(SOURCE)
    if args.original_causal:
        suite = unittest.TestSuite(
            [
                MainDiagnosticTests(
                    "test_failed_child_work_phase_survives_cleanup_in_checks_annotation"
                )
            ]
        )
    else:
        suite = unittest.TestSuite(
            [
                unittest.defaultTestLoader.loadTestsFromTestCase(FailureMetadataTests),
                unittest.defaultTestLoader.loadTestsFromTestCase(MainDiagnosticTests),
            ]
        )
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
