# tools/diagnostics/macos_managed_ollama_receiving_test.py
"""Actual portable TLS registry peers; no native daemon or PAC credit."""

import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import ssl
import unittest

ROOT = Path(os.environ.get("ERGOPTI_RECEIVING_REPOSITORY", Path(__file__).resolve().parents[2]))


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


RECEIVING = load(
    "registry_receiving", Path(__file__).with_name("macos_managed_ollama_receiving.py")
)
WIRE = load(
    "registry_wire", ROOT / "static/ergopti_plus/macos/tests/support/native_http_wire_fixture.py"
)
MODEL = load("registry_model", ROOT / "tools/diagnostics/ollama_native_tiny_gguf.py")


class ActualPeerReceiving(unittest.TestCase):
    def setUp(self):
        self.fixture = WIRE.WireFixture(native=False)
        self.addCleanup(self.fixture.close)
        self.registry = RECEIVING.Registry(self.fixture)
        self.model = MODEL.model_bytes()
        self.assertEqual(
            hashlib.sha256(self.model).hexdigest(),
            "a85aba87b0e9e724d0b499d12d4dcb9fd2ede378c96ffad75a70a919f2c00c0a",
        )
        self.model_digest = "sha256:" + hashlib.sha256(self.model).hexdigest()
        self.config = b'{"architecture":"llama"}'
        config_digest = "sha256:" + hashlib.sha256(self.config).hexdigest()
        self.manifest = json.dumps(
            {
                "schemaVersion": 2,
                "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
                "config": {
                    "mediaType": "application/vnd.docker.container.image.v1+json",
                    "digest": config_digest,
                    "size": len(self.config),
                },
                "layers": [
                    {
                        "mediaType": "application/vnd.ollama.image.model",
                        "digest": self.model_digest,
                        "size": len(self.model),
                    }
                ],
            }
        ).encode()
        self.registry.set_model(
            self.manifest, {self.model_digest: self.model, config_digest: self.config}
        )
        self.context = ssl.create_default_context(cafile=str(self.fixture.ca))

    def connect(self):
        connection = http.client.HTTPSConnection(
            "127.0.0.1", self.fixture.origin_port, context=self.context, timeout=3
        )
        self.addCleanup(connection.close)
        return connection

    def test_actual_redirect_retains_literal_full_path_and_query_and_exact_manifest(self):
        connection = self.connect()
        path = "/v2/library/native-pulled/manifests/latest"
        connection.request("GET", path)
        response = connection.getresponse()
        self.assertEqual(response.status, 302)
        self.assertEqual(
            response.getheader("Location"),
            f"https://{self.fixture.host}:{self.fixture.origin_port}{path}?native=manifest",
        )
        self.assertEqual(response.read(), b"")
        connection.request("GET", path + "?native=manifest")
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(), self.manifest)

    def test_actual_head_range_size_digest_and_location_use_real_blob_bytes(self):
        connection = self.connect()
        path = "/v2/library/native-pulled/blobs/" + self.model_digest
        connection.request("HEAD", path)
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("Content-Length"), "51072")
        self.assertEqual(response.read(), b"")
        connection.request("GET", path + "?native=blob", headers={"Range": "bytes=2-17"})
        response = connection.getresponse()
        self.assertEqual(response.status, 206)
        self.assertEqual(response.getheader("Content-Range"), "bytes 2-17/51072")
        self.assertEqual(response.read(), self.model[2:18])

    def test_cancelled_actual_tls_body_reports_eof_and_zero_socket_debt(self):
        connection = self.connect()
        path = "/v2/library/native-cancel/blobs/" + self.registry.held_digest + "?native=blob"
        connection.request("GET", path, headers={"Range": "bytes=0-51071"})
        response = connection.getresponse()
        self.assertEqual(response.status, 206)
        self.assertEqual(len(response.read(1024)), 1024)
        response.close()
        connection.close()
        snapshot = self.fixture.stats()
        self.assertEqual(snapshot["active"], 0)
        self.assertIn({"event": "held_closed", "closed": True}, snapshot["records"])

    def test_pac_discriminates_initial_manifest_redirect_and_blob_full_urls(self):
        pac = self.registry.pac()
        base = f"https://{self.fixture.host}:{self.fixture.origin_port}"
        manifest = "/v2/library/native-pulled/manifests/latest"
        self.assertIn(
            "if (url == "
            + json.dumps(base + manifest)
            + ") return "
            + json.dumps(f"PROXY 127.0.0.1:{self.fixture.ports['first']}"),
            pac,
        )
        self.assertIn(
            "if (url == "
            + json.dumps(base + manifest + "?native=manifest")
            + ") return "
            + json.dumps(f"PROXY 127.0.0.1:{self.fixture.ports['second']}"),
            pac,
        )
        self.assertIn(
            f"PROXY 127.0.0.1:{self.fixture.ports['refused']}; PROXY 127.0.0.1:{self.fixture.ports['second']}",
            pac,
        )
        self.assertNotIn("FindProxyForURL(url, host) { return", pac)


if __name__ == "__main__":
    unittest.main()
