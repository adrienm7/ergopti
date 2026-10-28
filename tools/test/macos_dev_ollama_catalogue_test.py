# tools/test/macos_dev_ollama_catalogue_test.py

"""Build the developer app's managed Ollama from the clone's pins, never a release.

The macOS developer app reads the clone's shared data, where no catalogue is
committed, so its owned Ollama install refused with
OLLAMA_MANAGED_CATALOGUE_MISSING (exit 78). Copying a published catalogue only
worked once the clone's version was published: field run 2026-10-28 14:16 on
the unpublished v1.0.7 still refused. These cases drive the real stager against
a copied clone with injected downloads and release tools (no network, no Go),
then the real runtime installer with only the Darwin codesign and rename calls
modeled, and prove the staged catalogue installs (dev-ollama-unpublished).
"""

import contextlib
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import runpy
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
STAGER = ROOT / "tools/dev/stage-macos-dev-ollama-catalogue.py"
SHARED = "static/ergopti_plus/_shared"
CONTRACT = SHARED + "/modules/llm/managed_ollama_runtime.json"
OFFICIAL_RELEASE = SHARED + "/modules/llm/ollama_release.json"
RUNTIME = "static/ergopti_plus/macos/modules/llm/managed_ollama_runtime.py"
INPUTS = (
    CONTRACT,
    OFFICIAL_RELEASE,
    SHARED + "/modules/updater/channels.json",
    SHARED + "/data/identifiers.json",
    SHARED + "/python/managed_ollama_runtime.py",
    SHARED + "/python/network_proxy_policy.py",
    SHARED + "/python/managed_source_alias.py",
    RUNTIME,
    "static/ergopti_plus/macos/modules/llm/managed_bootstrap_http.py",
)
CATALOGUE = "managed_ollama_release.json"
LIBRARY = "lib/ollama/libggml-base.dylib"
# A thin arm64 Mach-O header: the installer checks the magic and CPU type.
BINARY = b"\xcf\xfa\xed\xfe" + struct.pack("<I", 0x0100000C) + b"\0" * 24 + b"ollama fixture\n"
OFFICIAL = b"official Ollama archive fixture\n"


def load_stager():
    specification = importlib.util.spec_from_file_location("ergopti_dev_ollama_stager", STAGER)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def native_archive(path, binary=BINARY):
    """Write a runtime-only archive with the layout the producer seals."""
    with path.open("wb") as stream:
        with gzip.GzipFile(fileobj=stream, filename="", mode="wb", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as bundle:
                for name, data, mode in (
                    ("ollama", binary, 0o755),
                    (LIBRARY, b"library fixture\n", 0o644),
                    ("LICENSE.ollama", b"license fixture\n", 0o644),
                ):
                    record = tarfile.TarInfo(name)
                    record.size, record.mode, record.mtime = len(data), mode, 0
                    bundle.addfile(record, io.BytesIO(data))


class FixturePorts:
    """Downloads, toolchain and release tools of a Mac, recorded instead of run."""

    def __init__(self, test):
        self.test = test
        self.calls = []
        self.official = OFFICIAL
        self.produce_failure = None
        self.catalogue_tamper = None

    def machine(self):
        return "arm64"

    def download(self, url, destination):
        self.calls.append(("download", url))
        destination.write_bytes(self.official)

    def source_head(self, source):
        marker = source / "HEAD-fixture"
        return marker.read_text() if marker.exists() else None

    def fetch_source(self, source, url, commit):
        self.calls.append(("fetch_source", url, commit))
        source.mkdir()
        (source / "HEAD-fixture").write_text(commit)

    def pinned_go(self, version):
        self.calls.append(("go", version))
        return Path("/fixture/go")

    def produce(self, root, source, official, go, output):
        self.calls.append(("produce",))
        if self.produce_failure:
            raise subprocess.CalledProcessError(1, ["build-macos-managed-ollama.py"])
        filename = self.test.contract["assets"]["macos-arm64"]["filename"]
        native_archive(output / filename)
        (output / (filename + ".provenance.json")).write_text("{}\n")

    def generate(self, root, source, official, go, receipt, archive, channel, output):
        """Write what the release generator writes in unpublished mode."""
        self.calls.append(("generate", channel))
        contract = self.test.contract
        data = archive.read_bytes()
        asset = {
            "os": "darwin",
            "architecture": "arm64",
            "filename": archive.name,
            "url": "",
            "sha256": sha256(data),
            "bytes": len(data),
            "version": contract["version"],
            "source_commit": contract["source_commit"],
            "capability": contract["capability"],
            "native_http_capability": contract["native_http_capability"],
            "binary_sha256": sha256(BINARY),
            "runtime_libraries_sha256": {LIBRARY: sha256(b"library fixture\n")},
            "provenance_sha256": sha256(receipt.read_bytes()),
        }
        if self.catalogue_tamper == "archive":
            asset["sha256"] = "0" * 64
        catalogue = {
            "schema_version": 1,
            "version": contract["version"],
            "source_commit": contract["source_commit"],
            "capability": contract["capability"],
            "native_http_capability": contract["native_http_capability"],
            "runtime_contract_sha256": sha256((root / CONTRACT).read_bytes()),
            "repository_commit": "a" * 40,
            "repository_source_sha256": {
                name: sha256((root / name).read_bytes())
                for name in contract["source_fingerprint_paths"]
            },
            "publication": {
                "mode": "unpublished-ci",
                "tag": "",
                "version": "",
                "channel": channel,
                "repository": "fixture/fixture",
            },
            "assets": {"macos-arm64": asset},
        }
        output.parent.mkdir(parents=True)
        output.write_text(json.dumps(catalogue, indent="\t", sort_keys=True) + "\n")


class DevManagedOllamaTests(unittest.TestCase):
    def setUp(self):
        self.stager = load_stager()
        owned = tempfile.TemporaryDirectory(prefix="ergopti-dev-ollama-")
        self.addCleanup(owned.cleanup)
        self.root = Path(owned.name).resolve()
        self.contract = json.loads((ROOT / CONTRACT).read_text(encoding="utf-8"))
        for relative in (*INPUTS, *self.contract["source_fingerprint_paths"]):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        # The fixture pins a small official archive; the real pin is 160 MB.
        official = json.loads((self.root / OFFICIAL_RELEASE).read_text(encoding="utf-8"))
        identity = official["assets"][self.contract["official_asset_key"]]
        identity.update(sha256=sha256(OFFICIAL), bytes=len(OFFICIAL))
        (self.root / OFFICIAL_RELEASE).write_text(json.dumps(official), encoding="utf-8")
        self.output = self.root / self.stager.OUTPUT
        self.state = self.root / "build/macos-dev-ollama"
        self.archive = self.state / self.contract["assets"]["macos-arm64"]["filename"]
        self.home = self.root / "home"
        self.home.mkdir()
        self.ports = FixturePorts(self)

    def stage(self):
        streams = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(streams[0]), contextlib.redirect_stderr(streams[1]):
            code = self.stager.stage(self.root, self.ports)
        return code, streams[0].getvalue() + streams[1].getvalue()

    def install(self):
        """Run the real installer CLI; return its exit code and stderr."""
        target = self.home / "Library/Application Support/Ergopti/ollama-native-http"

        def rename_exclusive(_, source, __, destination, ___):
            if os.path.lexists(destination):
                return -1
            os.rename(source, destination)
            return 0

        library = mock.Mock()
        library.renameatx_np.side_effect = rename_exclusive
        codesign = mock.Mock()
        codesign.return_value.wait.return_value = 0
        codesign.return_value.poll.return_value = 0
        arguments = [
            RUNTIME,
            "install",
            "--timeout",
            "60",
            "--idle-timeout",
            "30",
            "--connect-timeout",
            "10",
            "--minimum-bytes-per-second",
            "1",
        ]
        stderr = io.StringIO()
        code = 0
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(sys, "platform", "darwin"))
            stack.enter_context(mock.patch("platform.machine", return_value="arm64"))
            stack.enter_context(mock.patch.dict(os.environ, {"HOME": str(self.home)}))
            stack.enter_context(mock.patch("subprocess.Popen", codesign))
            stack.enter_context(mock.patch("ctypes.CDLL", return_value=library))
            stack.enter_context(mock.patch.object(sys, "argv", arguments))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            stack.enter_context(contextlib.redirect_stderr(stderr))
            try:
                runpy.run_path(str(self.root / RUNTIME), run_name="__main__")
            except SystemExit as exit_status:
                code = exit_status.code
        return code, stderr.getvalue(), target

    def test_unpublished_version_gets_a_catalogue_that_installs(self):
        # dev-ollama-unpublished: no Ergopti release is asked for or needed.
        code, output = self.stage()
        self.assertEqual(code, 0, output)
        policy = self.stager.load_policy(self.root)
        _, asset = policy.select_asset(
            (self.root / CONTRACT).read_bytes(), self.output.read_bytes(), "macos-arm64"
        )
        self.assertEqual((asset["url"], sha256(self.archive.read_bytes())), ("", asset["sha256"]))
        official = json.loads((ROOT / OFFICIAL_RELEASE).read_text(encoding="utf-8"))
        self.assertEqual(
            self.ports.calls,
            [
                (
                    "download",
                    "https://github.com/ollama/ollama/releases/download/v%s/%s"
                    % (official["version"], "ollama-darwin.tgz"),
                ),
                (
                    "fetch_source",
                    "https://github.com/ollama/ollama.git",
                    self.contract["source_commit"],
                ),
                ("go", self.contract["go_version"]),
                ("produce",),
                ("generate", "dev"),
            ],
        )
        code, stderr, target = self.install()
        self.assertEqual(code, 0, stderr)
        self.assertNotIn("OLLAMA_MANAGED_CATALOGUE_MISSING", stderr)
        self.assertEqual((target / "ollama").read_bytes(), BINARY)
        self.assertTrue((target / ".ergopti-managed-runtime.json").is_file())

    def test_reuses_the_staged_build_while_its_sources_hold(self):
        self.assertEqual(self.stage()[0], 0)
        self.ports.calls.clear()
        code, output = self.stage()
        self.assertEqual((code, self.ports.calls), (0, []))
        self.assertIn("is staged", output)

    def test_a_changed_fingerprinted_source_rebuilds_and_a_failed_build_leaves_no_catalogue(self):
        self.assertEqual(self.stage()[0], 0)
        changed = self.root / self.contract["source_fingerprint_paths"][1]
        changed.write_bytes(changed.read_bytes() + b"\n// edited\n")
        self.ports.produce_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.stage()
        self.assertFalse(self.output.exists())
        self.assertEqual(self.install()[:2], (78, "OLLAMA_MANAGED_CATALOGUE_MISSING\n"))

    def test_refuses_an_official_archive_that_differs_from_its_pin(self):
        self.ports.official = b"tampered official archive\n"
        with self.assertRaises(self.stager.StageRefusal):
            self.stage()
        self.assertFalse(self.output.exists())
        self.assertEqual(list((self.state / "official").iterdir()), [])
        self.assertNotIn(("produce",), self.ports.calls)

    def test_refuses_a_catalogue_that_does_not_pin_the_built_archive(self):
        self.ports.catalogue_tamper = "archive"
        with self.assertRaises(self.stager.StageRefusal):
            self.stage()
        self.assertFalse(self.output.exists() or self.archive.exists())

    def test_the_installer_refuses_a_local_archive_that_differs_from_the_catalogue(self):
        self.assertEqual(self.stage()[0], 0)
        native_archive(self.archive, BINARY + b"tampered")
        code, stderr, target = self.install()
        self.assertEqual((code, stderr), (78, "Managed Ollama runtime admission refused.\n"))
        self.assertFalse(target.exists())

    def test_a_bundle_without_the_developer_archive_stays_unavailable(self):
        self.assertEqual(self.stage()[0], 0)
        self.archive.unlink()
        code, stderr, target = self.install()
        self.assertEqual((code, stderr), (78, "Managed Ollama runtime admission refused.\n"))
        self.assertFalse(target.exists())


class PinnedGoTests(unittest.TestCase):
    """The toolchain resolver against a recording `go` executable."""

    def setUp(self):
        self.stager = load_stager()
        owned = tempfile.TemporaryDirectory(prefix="ergopti-dev-go-")
        self.addCleanup(owned.cleanup)
        self.root = Path(owned.name)

    def go(self, version, settings):
        script = self.root / "go"
        script.write_text(
            "#!/bin/sh\n"
            'if [ "$1 $2" = "env GOVERSION" ]; then echo %s; exit 0; fi\n'
            'if [ "$1 $2" = "env -json" ]; then printf %%s %s; exit 0; fi\n'
            "exit 9\n" % (version, json.dumps(json.dumps(settings)))
        )
        script.chmod(0o755)
        return str(script)

    def test_uses_a_local_go_of_the_pinned_version(self):
        go = self.go("go1.26.8", {})
        self.assertEqual(self.stager.HostPorts(go).pinned_go("go1.26.8"), Path(go).resolve())

    def test_refuses_a_download_that_skips_the_checksum_database(self):
        for settings in (
            {"GOSUMDB": "off"},
            {"GOSUMDB": "sum.golang.org", "GONOSUMDB": "*"},
            {"GOSUMDB": "sum.golang.org", "GOINSECURE": "golang.org"},
        ):
            with self.assertRaises(self.stager.StageRefusal):
                self.stager.HostPorts(self.go("go1.25.0", settings)).pinned_go("go1.26.8")


if __name__ == "__main__":
    unittest.main()
