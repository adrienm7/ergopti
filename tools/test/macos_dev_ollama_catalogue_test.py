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
CONTRACT = SHARED + "/ai/data/managed_ollama_runtime.json"
OFFICIAL_RELEASE = SHARED + "/ai/data/ollama_release.json"
RUNTIME = "static/ergopti_plus/macos/modules/llm/managed_ollama_runtime.py"
INPUTS = (
    CONTRACT,
    OFFICIAL_RELEASE,
    SHARED + "/updater/data/channels.json",
    SHARED + "/core/text/data/identifiers.json",
    SHARED + "/ai/adapters/python/managed_ollama_runtime.py",
    SHARED + "/core/network/adapters/python_network_proxy_policy.py",
    SHARED + "/ai/adapters/python/managed_source_alias.py",
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
        # Ad hoc signing gives every rebuild a new binary, so a new archive.
        self.binary = BINARY

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
        native_archive(output / filename, self.binary)
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
            "binary_sha256": sha256(self.binary),
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

    def install(self, signatures=None):
        """Run the real installer CLI; return its exit code and stderr.

        renameatx_np is modeled for RENAME_EXCL and RENAME_SWAP; signatures
        lists codesign exit codes in call order (all valid when None).
        """
        target = self.home / "Library/Application Support/Ergopti/ollama-native-http"
        self.renames = []

        def rename_at(_, source, __, destination, flags):
            self.renames.append(flags)
            if flags == 0x00000004:
                if os.path.lexists(destination):
                    return -1
                os.rename(source, destination)
                return 0
            if flags == 0x00000002:
                if not (os.path.lexists(source) and os.path.lexists(destination)):
                    return -1
                parked = os.fsdecode(destination) + ".swap-fixture"
                os.rename(destination, parked)
                os.rename(source, destination)
                os.rename(parked, source)
                return 0
            return -1

        library = mock.Mock()
        library.renameatx_np.side_effect = rename_at
        codesign = mock.Mock()
        if signatures is None:
            codesign.return_value.wait.return_value = 0
        else:
            codesign.return_value.wait.side_effect = list(signatures)
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

    def rebuild(self):
        """Edit a pinned source and restage: the ad hoc rebuild has a new archive."""
        changed = self.root / self.contract["source_fingerprint_paths"][1]
        changed.write_bytes(changed.read_bytes() + b"\n// edited\n")
        self.ports.binary = BINARY + b"rebuilt\n"
        self.assertEqual(self.stage()[0], 0)

    def receipt_of(self, target):
        return json.loads((target / ".ergopti-managed-runtime.json").read_text())

    def test_a_rebuild_replaces_the_runtime_its_earlier_build_installed(self):
        # dev-ollama-rebuild-replaces: every dev pull ended in exit 78 because
        # the earlier owned install's receipt binds the earlier archive.
        self.assertEqual(self.stage()[0], 0)
        code, stderr, target = self.install()
        self.assertEqual(code, 0, stderr)
        earlier = self.receipt_of(target)
        self.rebuild()
        code, stderr, target = self.install()
        self.assertEqual(code, 0, stderr)
        self.assertIn("replaced an earlier owned install", stderr)
        self.assertEqual((target / "ollama").read_bytes(), BINARY + b"rebuilt\n")
        receipt = self.receipt_of(target)
        self.assertNotEqual(receipt["asset_sha256"], earlier["asset_sha256"])
        self.assertEqual(receipt["binary_sha256"], sha256(BINARY + b"rebuilt\n"))
        self.assertEqual(self.renames, [0x00000002])
        self.assertEqual(
            sorted(path.name for path in target.parent.iterdir()), ["ollama-native-http"]
        )

    def test_a_modified_earlier_runtime_is_never_displaced(self):
        self.assertEqual(self.stage()[0], 0)
        self.assertEqual(self.install()[0], 0)
        target = self.install()[2]
        (target / "ollama").write_bytes(BINARY + b"edited by hand\n")
        self.rebuild()
        code, stderr, target = self.install()
        self.assertEqual((code, stderr), (78, "Managed Ollama runtime admission refused.\n"))
        self.assertEqual((target / "ollama").read_bytes(), BINARY + b"edited by hand\n")
        self.assertEqual(self.renames, [])

    def test_a_folder_without_an_ergopti_receipt_is_never_displaced(self):
        self.assertEqual(self.stage()[0], 0)
        target = self.home / "Library/Application Support/Ergopti/ollama-native-http"
        target.mkdir(parents=True)
        (target / "ollama").write_bytes(BINARY)
        code, stderr, _ = self.install()
        self.assertEqual((code, stderr), (78, "Managed Ollama runtime admission refused.\n"))
        self.assertEqual(sorted(path.name for path in target.iterdir()), ["ollama"])
        self.assertEqual(self.renames, [])

    def test_a_live_operation_keeps_the_earlier_runtime(self):
        self.assertEqual(self.stage()[0], 0)
        target = self.install()[2]
        (target / (".ergopti-image-" + "0" * 32)).write_bytes(BINARY)
        self.rebuild()
        self.assertEqual(self.install()[0], 78)
        self.assertEqual((target / "ollama").read_bytes(), BINARY)

    def test_a_replacement_that_fails_in_place_restores_the_earlier_runtime(self):
        self.assertEqual(self.stage()[0], 0)
        target = self.install()[2]
        earlier = self.receipt_of(target)
        self.rebuild()
        # Both stage verifications pass, the one in place fails (each
        # verification waits twice on its codesign child).
        code, stderr, target = self.install(signatures=[0, 0, 0, 0, 1, 1])
        self.assertEqual((code, stderr), (78, "Managed Ollama runtime admission refused.\n"))
        self.assertEqual(self.renames, [0x00000002, 0x00000002])
        self.assertEqual(self.receipt_of(target), earlier)
        self.assertEqual((target / "ollama").read_bytes(), BINARY)
        self.assertEqual(
            sorted(path.name for path in target.parent.iterdir()), ["ollama-native-http"]
        )

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

    def test_the_go_pins_follow_the_contract_version(self):
        pins = json.loads((ROOT / "tools/dev/macos-dev-go.json").read_text())
        contract = json.loads((ROOT / CONTRACT).read_text())
        self.assertEqual(pins["version"], contract["go_version"])
        self.assertEqual(set(pins["archives"]), set(self.stager.HOSTS))

    def go_archive(self, version):
        """Writes the pins of one fake official archive whose go reports version."""
        buffer = io.BytesIO()
        script = (
            '#!/bin/sh\nif [ "$1 $2" = "env GOVERSION" ]; then echo %s; exit 0; fi\nexit 9\n'
            % version
        ).encode()
        with tarfile.open(fileobj=buffer, mode="w:gz") as bundle:
            entry = tarfile.TarInfo("go/bin/go")
            entry.size = len(script)
            entry.mode = 0o755
            bundle.addfile(entry, io.BytesIO(script))
        data = buffer.getvalue()
        (self.root / "tools/dev").mkdir(parents=True, exist_ok=True)
        filename = "%s.darwin-arm64.tar.gz" % version
        pins = {
            "version": version,
            "url": "https://example.invalid/{filename}",
            "archives": {
                "arm64": {
                    "filename": filename,
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "size": len(data),
                }
            },
        }
        (self.root / "tools/dev/macos-dev-go.json").write_text(json.dumps(pins))
        return data

    def host_without_go(self, served):
        ports = self.stager.HostPorts(None, self.root)
        ports.machine = lambda: "arm64"
        ports.download = lambda url, destination: Path(destination).write_bytes(served)
        return ports

    def test_a_mac_without_go_gets_the_pinned_archive(self):
        data = self.go_archive("go1.26.8")
        with mock.patch.object(self.stager.shutil, "which", return_value=None):
            go = self.host_without_go(data).pinned_go("go1.26.8")
        self.assertEqual(go, (self.root / "build/macos-dev-go/go1.26.8/go/bin/go").resolve())

    def test_refuses_a_go_archive_that_differs_from_its_pin(self):
        data = self.go_archive("go1.26.8")
        with mock.patch.object(self.stager.shutil, "which", return_value=None):
            with self.assertRaises(self.stager.StageRefusal):
                self.host_without_go(data + b"x").pinned_go("go1.26.8")
        self.assertFalse((self.root / "build/macos-dev-go/go1.26.8").exists())

    def test_refuses_go_pins_of_another_version(self):
        data = self.go_archive("go1.26.7")
        with mock.patch.object(self.stager.shutil, "which", return_value=None):
            with self.assertRaises(self.stager.StageRefusal):
                self.host_without_go(data).pinned_go("go1.26.8")

    def resolve_for_the_relay(self, on_path, served=None):
        """Runs the relay's resolver; a download is an error unless bytes are served."""
        contract = self.root / CONTRACT
        contract.parent.mkdir(parents=True, exist_ok=True)
        contract.write_text(json.dumps({"go_version": "go1.26.8"}))
        fetched = []

        def fetch(url, destination):
            fetched.append(url)
            if served is None:
                raise subprocess.CalledProcessError(6, ["curl"])
            Path(destination).write_bytes(served)

        with mock.patch.object(self.stager.DEV_GO.shutil, "which", return_value=on_path):
            return self.stager.DEV_GO.resolve(self.root, "arm64", fetch), fetched

    def test_the_relay_gets_the_private_copy_on_a_mac_without_go(self):
        data = self.go_archive("go1.26.8")
        go, fetched = self.resolve_for_the_relay(None, data)
        self.assertEqual(go, str(self.root / "build/macos-dev-go/go1.26.8/go/bin/go"))
        self.assertEqual(len(fetched), 1)
        self.assertEqual(self.resolve_for_the_relay(None)[0], go)

    def test_the_relay_uses_a_go_of_the_pin_on_path(self):
        self.go_archive("go1.26.8")
        go = self.go("go1.26.8", {})
        self.assertEqual(self.resolve_for_the_relay(go), (go, []))

    def test_the_relay_replaces_a_go_of_another_version(self):
        data = self.go_archive("go1.26.8")
        go, fetched = self.resolve_for_the_relay(self.go("go1.25.0", {}), data)
        self.assertEqual(go, str(self.root / "build/macos-dev-go/go1.26.8/go/bin/go"))
        self.assertEqual(len(fetched), 1)

    def test_an_impossible_download_is_a_named_exit(self):
        self.go_archive("go1.26.8")
        with self.assertRaises(subprocess.CalledProcessError):
            self.resolve_for_the_relay(None)
        self.assertEqual(list((self.root / "build/macos-dev-go").iterdir()), [])
        dev_go = self.stager.DEV_GO
        message = io.StringIO()
        refusal = dev_go.GoRefusal("no route to the archive")
        with mock.patch.object(dev_go, "resolve", side_effect=refusal):
            with contextlib.redirect_stderr(message):
                self.assertEqual(dev_go.main(), 1)
        self.assertIn("no route to the archive", message.getvalue())

    def test_the_python_of_the_xcode_tools_unpacks_the_archive(self):
        data = self.go_archive("go1.26.8")
        filter_function = getattr(tarfile, "data_filter", None)
        if filter_function is not None:
            del tarfile.data_filter
            self.addCleanup(setattr, tarfile, "data_filter", filter_function)
        go, _ = self.resolve_for_the_relay(None, data)
        self.assertTrue(Path(go).is_file())


if __name__ == "__main__":
    unittest.main()
