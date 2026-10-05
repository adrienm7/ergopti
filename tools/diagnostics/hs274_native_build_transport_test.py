# tools/diagnostics/hs274_native_build_transport_test.py
"""Additive offline controls for safe acquisition refusal evidence, frozen before code."""

import errno
import http.client
import importlib.util
import json
from pathlib import Path
import socket
import ssl
import tempfile
import unittest
from unittest import mock
import urllib.error

spec = importlib.util.spec_from_file_location(
    "native_build_transport_subject", Path(__file__).with_name("hs274_native_build.py")
)
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)
SECRET = "PRIVATE_SENTINEL_URL_HEADER_MESSAGE"


def certificate(code=10):
    error = ssl.SSLCertVerificationError(1, SECRET)
    error.verify_code = code
    error.verify_message = SECRET
    return error


def metadata_bytes():
    return json.dumps(
        {
            "id": 478866069,
            "name": "xcodegen.zip",
            "size": 4278764,
            "digest": "sha256:4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806",
            "browser_download_url": "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip",
        }
    ).encode()


class TransportDiagnosticContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ergopti-transport-controls-")
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.context = ssl.create_default_context()

    def tearDown(self):
        self.temporary.cleanup()

    def refusal(
        self,
        error=None,
        archive=False,
        read_error=False,
        status=200,
        context_error=False,
        deadline=20.0,
        clock=None,
        metadata=None,
        expire_after_metadata=False,
    ):
        requests = []
        current = [0.0]
        payload = metadata_bytes() if metadata is None else metadata

        class Response:
            def __init__(self, url, data, terminal=False):
                self.url, self.data = url, data
                self.status = status if terminal else 200
                self.headers = {"Content-Length": str(len(data))}
                self.terminal = terminal

            def __enter__(self):
                return self

            def __exit__(self, *args):
                if expire_after_metadata and archive and len(requests) == 1:
                    current[0] = deadline + 1
                return False

            def geturl(self):
                return self.url

            def read(self, maximum):
                if self.terminal and read_error:
                    raise error
                data, self.data = self.data[:maximum], self.data[maximum:]
                return data

        class Opener:
            def open(self, request, timeout):
                requests.append((request.full_url, timeout))
                if archive and len(requests) == 1:
                    return Response(request.full_url, payload)
                if error is not None and not read_error:
                    raise error
                return Response(request.full_url, payload, terminal=True)

        context_options = (
            {"side_effect": error} if context_error else {"return_value": self.context}
        )
        with (
            mock.patch.object(subject.time, "monotonic", side_effect=clock or (lambda: current[0])),
            mock.patch.object(subject.ssl, "create_default_context", **context_options),
            mock.patch.object(subject.urllib.request, "build_opener", return_value=Opener()),
        ):
            with self.assertRaises(subject.NativeBuildError) as failed:
                subject.acquire_xcodegen(self.root, deadline)
        receipt = json.loads((self.root / "xcodegen_acquisition.receipt.json").read_text())
        self.assertEqual(receipt["status"], "refused")
        self.assertEqual(receipt["code"], failed.exception.code)
        self.assertFalse((self.root / "native-build-result.json").exists())
        self.assertFalse((self.root / "xcodegen-identity.json").exists())
        self.assertFalse((self.root / "xcodegen-official.zip").exists())
        self.assertFalse((self.root / "xcodegen-package").exists())
        encoded = json.dumps(receipt)
        self.assertNotIn(SECRET, encoded)
        self.assertNotIn("https://", encoded)
        self.assertNotIn(SECRET, str(failed.exception))
        self.assertEqual(self.context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(self.context.check_hostname)
        return failed.exception, receipt, requests

    def diagnostic(self, error, expected, **kwargs):
        failure, receipt, requests = self.refusal(error, **kwargs)
        self.assertEqual(failure.code, "xcodegen_transport")
        self.assertEqual(str(failure), "Official tool HTTPS acquisition failed")
        self.assertIs(failure.__cause__, error)
        self.assertEqual(
            receipt["acquisition_stage"], "archive" if kwargs.get("archive") else "metadata"
        )
        self.assertEqual(receipt["transport_diagnostic"], expected)
        return receipt, requests

    def test_metadata_wrapped_certificate_verification_has_numeric_code(self):
        self.diagnostic(
            urllib.error.URLError(certificate()),
            {"kind": "tls_certificate_verification", "verify_code": 10},
        )

    def test_archive_direct_certificate_verification_has_exact_stage(self):
        self.diagnostic(
            certificate(), {"kind": "tls_certificate_verification", "verify_code": 10}, archive=True
        )

    def test_tls_error_is_distinct_from_certificate_verification(self):
        self.diagnostic(urllib.error.URLError(ssl.SSLError(1, SECRET)), {"kind": "tls_error"})

    def test_timeout_is_distinct_from_deadline(self):
        self.diagnostic(urllib.error.URLError(socket.timeout(SECRET)), {"kind": "timeout"})

    def test_dns_resolution_does_not_export_name(self):
        self.diagnostic(
            urllib.error.URLError(socket.gaierror(socket.EAI_NONAME, SECRET)),
            {"kind": "dns_resolution"},
        )

    def test_connection_refusal_is_distinct(self):
        self.diagnostic(
            ConnectionRefusedError(errno.ECONNREFUSED, SECRET), {"kind": "connection_refused"}
        )

    def test_connection_reset_is_distinct(self):
        self.diagnostic(
            ConnectionResetError(errno.ECONNRESET, SECRET), {"kind": "connection_reset"}
        )

    def test_unreachable_connection_is_distinct(self):
        self.diagnostic(OSError(errno.ENETUNREACH, SECRET), {"kind": "connection_error"})

    def test_unclassified_os_error_has_only_public_errno(self):
        self.diagnostic(OSError(errno.EIO, SECRET), {"kind": "os_error", "errno": errno.EIO})

    def test_http_error_exports_only_valid_numeric_status(self):
        for code in (403, 429, 503):
            with self.subTest(code=code):
                owner = self.root / str(code)
                owner.mkdir(mode=0o700)
                original = self.root
                self.root = owner
                try:
                    error = urllib.error.HTTPError(
                        "https://" + SECRET, code, SECRET, {"Secret": SECRET}, None
                    )
                    self.diagnostic(error, {"kind": "http_status", "http_status": code})
                finally:
                    self.root = original

    def test_malformed_http_error_status_is_not_coerced(self):
        for index, code in enumerate((True, "403", 999)):
            with self.subTest(code=code):
                owner = self.root / str(index)
                owner.mkdir(mode=0o700)
                original = self.root
                self.root = owner
                try:
                    self.diagnostic(
                        urllib.error.HTTPError(SECRET, code, SECRET, {}, None),
                        {"kind": "http_status"},
                    )
                finally:
                    self.root = original

    def test_http_protocol_exception_is_distinct(self):
        self.diagnostic(
            http.client.IncompleteRead(SECRET.encode(), 100), {"kind": "protocol_error"}
        )

    def test_string_url_error_reason_is_never_parsed(self):
        self.diagnostic(
            urllib.error.URLError("certificate verify failed timeout " + SECRET),
            {"kind": "other_transport"},
        )

    def test_nested_url_errors_use_bounded_typed_reason(self):
        error = urllib.error.URLError(
            urllib.error.URLError(socket.gaierror(socket.EAI_AGAIN, SECRET))
        )
        self.diagnostic(error, {"kind": "dns_resolution"})

    def test_cyclic_url_error_reason_terminates_as_unknown(self):
        error = urllib.error.URLError(SECRET)
        error.reason = error
        self.diagnostic(error, {"kind": "other_transport"})

    def test_certificate_code_is_optional_and_never_coerced(self):
        for index, code in enumerate((None, True, "10", -1, 2**40)):
            with self.subTest(code=code):
                owner = self.root / str(index)
                owner.mkdir(mode=0o700)
                original = self.root
                self.root = owner
                try:
                    self.diagnostic(certificate(code), {"kind": "tls_certificate_verification"})
                finally:
                    self.root = original

    def test_archive_body_read_transport_error_retains_archive_stage(self):
        self.diagnostic(
            ssl.SSLError(1, SECRET), {"kind": "tls_error"}, archive=True, read_error=True
        )

    def test_tls_eof_during_archive_read_does_not_claim_handshake_failure(self):
        self.diagnostic(
            ssl.SSLEOFError(8, SECRET),
            {"kind": "tls_error"},
            archive=True,
            read_error=True,
        )

    def test_non_200_response_is_refused_with_numeric_status(self):
        failure, receipt, _ = self.refusal(status=503)
        self.assertEqual(failure.code, "xcodegen_transport")
        self.assertEqual(str(failure), "Official tool HTTP status is not 200")
        self.assertEqual(receipt["acquisition_stage"], "metadata")
        self.assertEqual(
            receipt["transport_diagnostic"], {"kind": "http_status", "http_status": 503}
        )

    def test_default_tls_context_failure_has_typed_native_refusal(self):
        self.diagnostic(
            certificate(),
            {"kind": "tls_certificate_verification", "verify_code": 10},
            context_error=True,
        )

    def test_initial_deadline_refuses_before_request_with_metadata_stage(self):
        failure, receipt, requests = self.refusal(deadline=-1)
        self.assertEqual(failure.code, "phase_deadline")
        self.assertEqual(receipt["acquisition_stage"], "metadata")
        self.assertEqual(receipt["transport_diagnostic"], {"kind": "deadline"})
        self.assertEqual(requests, [])

    def test_archive_deadline_cannot_become_transport_success(self):
        failure, receipt, requests = self.refusal(archive=True, expire_after_metadata=True)
        self.assertEqual(failure.code, "phase_deadline")
        self.assertEqual(receipt["acquisition_stage"], "archive")
        self.assertEqual(receipt["transport_diagnostic"], {"kind": "deadline"})
        self.assertEqual(len(requests), 1)

    def test_invalid_metadata_keeps_semantic_refusal_without_transport_claim(self):
        failure, receipt, _ = self.refusal(metadata=b"{}")
        self.assertEqual(failure.code, "xcodegen_metadata")
        self.assertEqual(receipt["acquisition_stage"], "metadata")
        self.assertNotIn("transport_diagnostic", receipt)

    def test_official_redirect_refusal_never_exports_raw_url(self):
        refusal = subject.NativeBuildError(
            "xcodegen_transport", "Official tool URL redirects outside verified HTTPS"
        )
        failure, receipt, _ = self.refusal(refusal)
        self.assertIs(failure, refusal)
        self.assertEqual(receipt["acquisition_stage"], "metadata")
        self.assertNotIn("transport_diagnostic", receipt)

    def test_tls_failure_does_not_export_trust_paths_or_certificate_bytes(self):
        error = certificate()
        error.certificate = SECRET
        error.trust_path = SECRET
        receipt, _ = self.diagnostic(
            error, {"kind": "tls_certificate_verification", "verify_code": 10}
        )
        self.assertEqual(
            set(receipt),
            {
                "schema",
                "phase",
                "status",
                "code",
                "elapsed_seconds",
                "acquisition_stage",
                "transport_diagnostic",
            },
        )


def _independent_errno_cases():
    """Preserve the reviewer's original private sentinel and four assertion bodies."""
    SECRET = "PRIVATE_INDEPENDENT_MESSAGE_HOST_HEADER_CERTIFICATE"

    class IndependentErrnoControl(unittest.TestCase):
        def test_real_native_errno_healthy(self):
            self.assertEqual(
                subject._tool_transport_failure(OSError(errno.ENETUNREACH, SECRET)),
                {"kind": "connection_error"},
            )
            self.assertEqual(
                subject._tool_transport_failure(OSError(errno.EIO, SECRET)),
                {"kind": "os_error", "errno": errno.EIO},
            )

        def test_float_errno_cannot_claim_unreachable_native_connection(self):
            for value in (float(errno.ENETUNREACH), float(errno.EHOSTUNREACH)):
                with self.subTest(value=value):
                    error = OSError(value, SECRET)
                    self.assertIs(type(error.errno), float)
                    self.assertEqual(subject._tool_transport_failure(error), {"kind": "os_error"})

        def test_unhashable_errno_still_has_closed_sanitized_classification(self):
            for value in ([SECRET], {"private": SECRET}):
                with self.subTest(value=type(value).__name__):
                    error = OSError(value, SECRET)
                    self.assertEqual(subject._tool_transport_failure(error), {"kind": "os_error"})

        def test_download_error_mapping_is_preserved_with_unhashable_errno(self):
            error = OSError([SECRET], SECRET)

            class Opener:
                def open(self, *args, **kwargs):
                    raise error

            with (
                mock.patch.object(subject.urllib.request, "build_opener", return_value=Opener()),
                mock.patch.object(subject.time, "monotonic", return_value=0.0),
            ):
                with self.assertRaises(subject.NativeBuildError) as captured:
                    subject._download_tool_input(
                        subject.XCODEGEN_URL, subject.XCODEGEN_ARCHIVE_BYTES, 20.0
                    )
            self.assertEqual(captured.exception.code, "xcodegen_transport")
            self.assertIs(captured.exception.__cause__, error)
            self.assertEqual(str(captured.exception), "Official tool HTTPS acquisition failed")
            self.assertNotIn(SECRET, str(captured.exception))

    return IndependentErrnoControl


IndependentErrnoControl = _independent_errno_cases()


if __name__ == "__main__":
    suite = unittest.TestSuite(
        [
            unittest.defaultTestLoader.loadTestsFromTestCase(TransportDiagnosticContract),
            unittest.defaultTestLoader.loadTestsFromTestCase(IndependentErrnoControl),
        ]
    )
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    successful = result.testsRun == 29 and result.wasSuccessful() and not result.skipped
    if successful:
        print(
            "PASS independent native transport diagnostics tests=29 failures=0 errors=0 skipped=0"
        )
    raise SystemExit(0 if successful else 1)
