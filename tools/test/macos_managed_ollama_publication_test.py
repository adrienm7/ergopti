#!/usr/bin/env python3
"""Independent producer-input and sealed publication boundary controls."""

from __future__ import annotations

import importlib.util
import io
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    owner = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(owner)
    return owner


STAGE = module("managed_inputs", ROOT / "tools/build/stage-macos-managed-ollama-inputs.py")
PUBLICATION = module(
    "managed_publication", ROOT / "tools/build/verify-macos-managed-ollama-publication.py"
)


class ProducerInputs(unittest.TestCase):
    def setUp(self):
        self.owner = tempfile.TemporaryDirectory()
        self.addCleanup(self.owner.cleanup)
        self.root = Path(self.owner.name)
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        self.contract = {
            "assets": {
                "macos-arm64": {"filename": "independent-arm64.tgz"},
                "macos-amd64": {"filename": "independent-amd64.tgz"},
            }
        }
        for name in (
            "independent-arm64.tgz",
            "independent-arm64.tgz.provenance.json",
            "independent-amd64.tgz",
            "independent-amd64.tgz.provenance.json",
        ):
            (self.inputs / name).write_bytes(b"Independent nonempty boundary input\n")

    def test_both_hosts_have_separate_archive_receipt_pairs(self):
        pairs = STAGE.physical_inputs(self.inputs, self.contract)
        self.assertEqual(
            [(archive.name, receipt.name) for archive, receipt in pairs],
            [
                ("independent-arm64.tgz", "independent-arm64.tgz.provenance.json"),
                ("independent-amd64.tgz", "independent-amd64.tgz.provenance.json"),
            ],
        )

    def test_single_host_refuses_before_catalogue_owner(self):
        (self.inputs / "independent-amd64.tgz").unlink()
        with self.assertRaises(ValueError):
            STAGE.physical_inputs(self.inputs, self.contract)

    def test_missing_provenance_refuses(self):
        (self.inputs / "independent-arm64.tgz.provenance.json").unlink()
        with self.assertRaises(ValueError):
            STAGE.physical_inputs(self.inputs, self.contract)

    def test_extra_foreign_file_refuses(self):
        (self.inputs / "foreign-secret").write_bytes(b"Foreign input\n")
        with self.assertRaises(ValueError):
            STAGE.physical_inputs(self.inputs, self.contract)

    def test_archive_symlink_refuses(self):
        path = self.inputs / "independent-arm64.tgz"
        foreign = self.root / "foreign"
        path.rename(foreign)
        path.symlink_to(foreign)
        with self.assertRaises(ValueError):
            STAGE.physical_inputs(self.inputs, self.contract)

    def test_provenance_hardlink_refuses(self):
        (self.root / "foreign").hardlink_to(self.inputs / "independent-arm64.tgz.provenance.json")
        with self.assertRaises(ValueError):
            STAGE.physical_inputs(self.inputs, self.contract)

    def test_directory_alias_refuses(self):
        alias = self.root / "alias"
        alias.symlink_to(self.inputs, target_is_directory=True)
        with self.assertRaises(ValueError):
            STAGE.physical_inputs(alias, self.contract)

    def test_empty_input_refuses(self):
        (self.inputs / "independent-amd64.tgz").write_bytes(b"")
        with self.assertRaises(ValueError):
            STAGE.physical_inputs(self.inputs, self.contract)


class SealedCatalogues(unittest.TestCase):
    def setUp(self):
        self.owner = tempfile.TemporaryDirectory()
        self.addCleanup(self.owner.cleanup)
        self.root = Path(self.owner.name)
        self.expected = b"Independent exact catalogue bytes\n"

    def archive(self, format, *, payload=None, records=1, link=False):
        payload = self.expected if payload is None else payload
        path = self.root / ("ErgoptiPlus.app." + format)
        if format == "zip":
            with zipfile.ZipFile(path, "w") as archive:
                for _ in range(records):
                    info = zipfile.ZipInfo(PUBLICATION.BUNDLE_CATALOGUE)
                    info.create_system = 3
                    info.external_attr = (0o120777 if link else 0o100644) << 16
                    archive.writestr(info, payload)
        else:
            with tarfile.open(path, "w:xz") as archive:
                for _ in range(records):
                    info = tarfile.TarInfo(PUBLICATION.BUNDLE_CATALOGUE)
                    info.size = len(payload)
                    if link:
                        info.type = tarfile.SYMTYPE
                        info.linkname = "foreign"
                        info.size = 0
                    archive.addfile(info, None if link else io.BytesIO(payload))
        return path

    def test_exact_zip_catalogue_passes(self):
        PUBLICATION.bound_catalogue(self.archive("zip"), self.expected)

    def test_exact_tar_catalogue_passes(self):
        PUBLICATION.bound_catalogue(self.archive("tar.xz"), self.expected)

    def test_zip_different_bytes_refuse(self):
        with self.assertRaises(ValueError):
            PUBLICATION.bound_catalogue(self.archive("zip", payload=b"Foreign\n"), self.expected)

    def test_tar_different_bytes_refuse(self):
        with self.assertRaises(ValueError):
            PUBLICATION.bound_catalogue(self.archive("tar.xz", payload=b"Foreign\n"), self.expected)

    def test_zip_missing_catalogue_refuses(self):
        with self.assertRaises(ValueError):
            PUBLICATION.bound_catalogue(self.archive("zip", records=0), self.expected)

    def test_tar_duplicate_catalogue_refuses(self):
        with self.assertRaises(ValueError):
            PUBLICATION.bound_catalogue(self.archive("tar.xz", records=2), self.expected)

    def test_zip_link_catalogue_refuses(self):
        with self.assertRaises(ValueError):
            PUBLICATION.bound_catalogue(self.archive("zip", link=True), self.expected)

    def test_tar_link_catalogue_refuses(self):
        with self.assertRaises(ValueError):
            PUBLICATION.bound_catalogue(self.archive("tar.xz", link=True), self.expected)


class PublicationAdmission(unittest.TestCase):
    """Synthetic publication bytes qualify admission only, never native production."""

    def setUp(self):
        self.owner = tempfile.TemporaryDirectory()
        self.addCleanup(self.owner.cleanup)
        self.assets = Path(self.owner.name)
        self.repository = Path(os.environ.get("ERGOPTI_CATALOGUE_TEST_REPOSITORY", ROOT))
        self.contract = json.loads((self.repository / PUBLICATION.OWNER.CONTRACT).read_bytes())
        defaults = json.loads((self.repository / PUBLICATION.OWNER.DEFAULTS).read_bytes())
        github = defaults["github"]["owner"] + "/" + defaults["github"]["repo"]
        self.options = SimpleNamespace(
            repository=self.repository,
            assets=self.assets,
            tag="v0.0.0-dev.166",
            version="0.0.0-dev.166",
            channel="dev",
            node="node",
        )
        self.catalogue = {
            "schema_version": 1,
            **{
                name: self.contract[name]
                for name in (
                    "version",
                    "source_commit",
                    "capability",
                    "native_http_capability",
                )
            },
            "runtime_contract_sha256": hashlib.sha256(
                (self.repository / PUBLICATION.OWNER.CONTRACT).read_bytes()
            ).hexdigest(),
            "repository_commit": subprocess.check_output(
                ["git", "-C", str(self.repository), "rev-parse", "HEAD"], text=True
            ).strip(),
            "repository_source_sha256": {
                name: hashlib.sha256((self.repository / name).read_bytes()).hexdigest()
                for name in self.contract["source_fingerprint_paths"]
            },
            "publication": {
                "mode": "planned-release",
                "tag": "v0.0.0-dev.166",
                "version": "0.0.0-dev.166",
                "channel": "dev",
                "repository": github,
            },
            "assets": {},
        }
        for host in ("macos-arm64", "macos-amd64"):
            binding = self.contract["assets"][host]
            payload = ("Independent publication-only asset: " + host + "\n").encode()
            (self.assets / binding["filename"]).write_bytes(payload)
            self.catalogue["assets"][host] = {
                **{name: binding[name] for name in ("os", "architecture", "filename")},
                **{
                    name: self.contract[name]
                    for name in (
                        "version",
                        "source_commit",
                        "capability",
                        "native_http_capability",
                    )
                },
                "url": "https://github.com/"
                + github
                + "/releases/download/v0.0.0-dev.166/"
                + binding["filename"],
                "bytes": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
                "binary_sha256": "1" * 64,
                "provenance_sha256": "2" * 64,
                "runtime_libraries_sha256": {"lib/independent.dylib": "3" * 64},
            }
        self.seal()

    def seal(self):
        encoded = (json.dumps(self.catalogue, sort_keys=True) + "\n").encode()
        (self.assets / PUBLICATION.CATALOGUE).write_bytes(encoded)
        with zipfile.ZipFile(self.assets / "ErgoptiPlus.app.zip", "w") as archive:
            info = zipfile.ZipInfo(PUBLICATION.BUNDLE_CATALOGUE)
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, encoded)
        with tarfile.open(self.assets / "ErgoptiPlus.app.tar.xz", "w:xz") as archive:
            info = tarfile.TarInfo(PUBLICATION.BUNDLE_CATALOGUE)
            info.size = len(encoded)
            archive.addfile(info, io.BytesIO(encoded))

    def test_exact_both_assets_and_sealed_catalogues_pass(self):
        self.assertEqual(PUBLICATION.verify(self.options), 2)

    def test_missing_native_asset_refuses(self):
        (self.assets / self.contract["assets"]["macos-arm64"]["filename"]).unlink()
        with self.assertRaises(FileNotFoundError):
            PUBLICATION.verify(self.options)

    def test_same_size_native_byte_change_refuses(self):
        asset = self.assets / self.contract["assets"]["macos-amd64"]["filename"]
        asset.write_bytes(b"X" * asset.stat().st_size)
        with self.assertRaises(ValueError):
            PUBLICATION.verify(self.options)

    def test_foreign_url_with_same_filename_refuses(self):
        asset = self.catalogue["assets"]["macos-arm64"]
        asset["url"] = "https://foreign.invalid/" + asset["filename"]
        self.seal()
        with self.assertRaises(ValueError):
            PUBLICATION.verify(self.options)

    def test_unpublished_manual_catalogue_refuses_publication(self):
        self.catalogue["publication"]["mode"] = "unpublished-ci"
        self.seal()
        with self.assertRaises(ValueError):
            PUBLICATION.verify(self.options)

    def test_stale_repository_commit_refuses(self):
        self.catalogue["repository_commit"] = "0" * 40
        self.seal()
        with self.assertRaises(ValueError):
            PUBLICATION.verify(self.options)

    def test_wrong_source_fingerprint_refuses(self):
        name = next(iter(self.catalogue["repository_source_sha256"]))
        self.catalogue["repository_source_sha256"][name] = "0" * 64
        self.seal()
        with self.assertRaises(ValueError):
            PUBLICATION.verify(self.options)

    def test_actual_plan_version_tag_mismatch_refuses(self):
        self.options.version = "0.0.0-dev.167"
        with self.assertRaises(ValueError):
            PUBLICATION.verify(self.options)


if __name__ == "__main__":
    unittest.main()
