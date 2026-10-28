# tools/test/macos_dev_ollama_catalogue_test.py

"""Admit only the published catalogue that binds the clone's managed Ollama contract.

The macOS developer app reads the clone's shared data, where no catalogue is
committed, so its owned Ollama install refused with
OLLAMA_MANAGED_CATALOGUE_MISSING. These cases drive the real stager against a
copied clone and an injected GitHub listing; no network is used.
"""

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
STAGER = ROOT / "tools/dev/stage-macos-dev-ollama-catalogue.py"
INPUTS = (
    "static/ergopti_plus/_shared/modules/llm/managed_ollama_runtime.json",
    "static/ergopti_plus/_shared/modules/updater/defaults.json",
    "static/ergopti_plus/_shared/python/managed_ollama_runtime.py",
)
CATALOGUE = "managed_ollama_release.json"


def load_stager():
    specification = importlib.util.spec_from_file_location("ergopti_dev_catalogue_stager", STAGER)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class DevCatalogueStagerTests(unittest.TestCase):
    def setUp(self):
        self.stager = load_stager()
        owned = tempfile.TemporaryDirectory(prefix="ergopti-dev-catalogue-")
        self.addCleanup(owned.cleanup)
        self.root = Path(owned.name)
        for relative in INPUTS:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        self.contract_bytes = (self.root / INPUTS[0]).read_bytes()
        self.contract = json.loads(self.contract_bytes)
        github = json.loads((self.root / INPUTS[1]).read_text(encoding="utf-8"))["github"]
        self.repository = github["owner"] + "/" + github["repo"]
        self.output = self.root / self.stager.OUTPUT
        self.resources = {}

    def release(self, tag, *, contract_sha256=None, immutable=True, tamper=None):
        """Publish one synthetic release whose catalogue satisfies the runtime policy."""
        base = "https://github.com/%s/releases/download/%s/" % (self.repository, tag)
        assets = []
        catalogue_assets = {}
        for host, binding in self.contract["assets"].items():
            archive = ("native archive %s %s" % (tag, host)).encode()
            catalogue_assets[host] = {
                "os": binding["os"],
                "architecture": binding["architecture"],
                "filename": binding["filename"],
                "url": base + binding["filename"],
                "sha256": sha256(archive),
                "bytes": len(archive),
                "version": self.contract["version"],
                "source_commit": self.contract["source_commit"],
                "capability": self.contract["capability"],
                "native_http_capability": self.contract["native_http_capability"],
                "binary_sha256": "b" * 64,
                "runtime_libraries_sha256": {"lib/ollama/libggml-base.dylib": "c" * 64},
                "provenance_sha256": "d" * 64,
            }
            assets.append(
                {
                    "name": binding["filename"],
                    "digest": "sha256:" + sha256(archive),
                    "size": len(archive),
                    "browser_download_url": base + binding["filename"],
                }
            )
        catalogue = {
            "schema_version": 1,
            "version": self.contract["version"],
            "source_commit": self.contract["source_commit"],
            "capability": self.contract["capability"],
            "native_http_capability": self.contract["native_http_capability"],
            "runtime_contract_sha256": contract_sha256 or sha256(self.contract_bytes),
            "repository_commit": "a" * 40,
            "repository_source_sha256": {
                name: "e" * 64 for name in self.contract["source_fingerprint_paths"]
            },
            "publication": {
                "mode": "planned-release",
                "tag": tag,
                "version": tag[1:],
                "channel": "main",
                "repository": self.repository,
            },
            "assets": catalogue_assets,
        }
        if tamper == "publication":
            catalogue["publication"]["tag"] = "v0.0.1"
        data = (json.dumps(catalogue, sort_keys=True) + "\n").encode()
        recorded = sha256(data)
        if tamper == "digest":
            recorded = sha256(data + b" ")
        if tamper == "native":
            assets[0]["digest"] = "sha256:" + "f" * 64
        url = base + CATALOGUE
        self.resources[url] = data
        assets.append(
            {"name": CATALOGUE, "digest": "sha256:" + recorded, "browser_download_url": url}
        )
        return {"tag_name": tag, "draft": False, "immutable": immutable, "assets": assets}, data

    def fetch_from(self, releases):
        listing = "https://api.github.com/repos/%s/releases?per_page=%d" % (
            self.repository,
            self.stager.RELEASES_PER_PAGE,
        )

        def fetch(url, accept):
            if url == listing:
                return json.dumps(releases).encode()
            return self.resources[url]

        return fetch

    def stage(self, releases):
        streams = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(streams[0]), contextlib.redirect_stderr(streams[1]):
            code = self.stager.stage(self.root, self.fetch_from(releases))
        return code, streams[0].getvalue() + streams[1].getvalue()

    def test_stages_the_newest_binding_release_and_skips_other_contracts(self):
        newer, _ = self.release("v9.0.1", contract_sha256="0" * 64)
        binding, data = self.release("v9.0.0")
        older, _ = self.release("v8.0.0")
        code, output = self.stage([newer, binding, older])
        self.assertEqual(code, 0)
        self.assertEqual(self.output.read_bytes(), data)
        self.assertIn("v9.0.0", output)
        code, output = self.stage([newer, binding, older])
        self.assertEqual((code, self.output.read_bytes()), (0, data))
        self.assertIn("already staged", output)

    def test_without_a_binding_release_removes_the_stale_catalogue(self):
        self.output.write_bytes(b"stale")
        newer, _ = self.release("v9.0.1", contract_sha256="0" * 64)
        code, output = self.stage([newer])
        self.assertEqual(code, self.stager.NO_BINDING_RELEASE)
        self.assertFalse(self.output.exists())
        self.assertIn("OLLAMA_MANAGED_CATALOGUE_MISSING", output)

    def refused(self, **tamper):
        refused, _ = self.release("v9.0.0", **tamper)
        older, _ = self.release("v8.0.0")
        with self.assertRaises(self.stager.CatalogueRefusal):
            self.stage([refused, older])
        # The newest binding release decides: no fallback to an older catalogue.
        self.assertFalse(self.output.exists())

    def test_refuses_catalogue_bytes_that_differ_from_the_recorded_digest(self):
        self.refused(tamper="digest")

    def test_refuses_a_mutable_release(self):
        self.refused(immutable=False)

    def test_refuses_a_native_asset_that_differs_from_its_catalogue_pin(self):
        self.refused(tamper="native")

    def test_refuses_a_catalogue_that_names_another_publication(self):
        self.refused(tamper="publication")


if __name__ == "__main__":
    unittest.main()
