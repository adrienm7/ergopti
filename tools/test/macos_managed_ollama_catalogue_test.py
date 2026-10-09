#!/usr/bin/env python3
"""Receive catalogue admission with independent literal/mutant inputs.

Portable protocol fixtures are not native compilation, execution or signing
qualification. --native receives the actual native producer receipt/archive
and clean source checkout; it never regenerates expected source-policy pins.
"""

from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import shlex

REPOSITORY = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "catalogue", REPOSITORY / "tools/build/stage-macos-managed-ollama-catalogue.py"
)
CATALOGUE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CATALOGUE)
CAPABILITY = "ERGOPTI_OLLAMA_NATIVE_HTTP_V1"
REVIEWED_PREIMAGES = {
    "server/images.go": "517e83b75fa014fc3a3a9d23c316f71e10228e8d2f0c92323c627eb45e8d3887",
    "server/internal/client/ollama/registry.go": "6063de52240e9857334f8af210f71a3073b0b2bb8fac35c8df8b97494edf91c0",
    "x/transfer/download.go": "4cc3da8d3cbeac187eea3bd89dcc10a191fc3d8de53a7c5c5074ba30243be21a",
    "go.mod": "a6b997b339c1de4fcdaaa2e3266d3494863e391e429496973b7da5f05aa898db",
    "go.sum": "27f221ed12b312246074ac797952d26151b1b10f0e2731e3a42445665b950568",
    "auth/auth.go": "ac4c269cb812edc01e2386fce0a7753871851edf76ec46ad26329016dc6f7841",
    "server/routes.go": "2621eef9e33b370d97a460eef80466654e4319ffea5ec0b94b3dbd79d5effd5e",
    "server/download.go": "14ffbdd4c503e7c0fb314e221d6f430a90ad745e910fa601e6b543e4c6a00699",
}
# These vectors are literal independent protocol inputs, not native binaries.
ARM64_HEADER = bytes.fromhex("cffaedfe0c000001000000000200000000000000000000000000000000000000")
AMD64_HEADER = bytes.fromhex("cffaedfe0700000100000000020000000000000000000000000000000000000000")
BINARY = ARM64_HEADER + CAPABILITY.encode("ascii") + b"\0literal protocol fixture"
LIBRARY = b"Independent literal native-library protocol fixture\n"
LICENSE = b"Independent literal upstream license fixture\n"
NATIVE = None


def sha_bytes(value):
    return hashlib.sha256(value).hexdigest()


def archive(path, *, binary, library=LIBRARY, license_bytes=None, extra=None):
    entries = [("ollama", binary, 0o755), ("lib/backend.dylib", library, 0o644)]
    if license_bytes is not None:
        entries.append(("LICENSE.ollama", license_bytes, 0o644))
    if extra is not None:
        entries.append(extra)
    with path.open("xb") as destination:
        with gzip.GzipFile(fileobj=destination, filename="", mode="wb", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as stream:
                directory = tarfile.TarInfo("lib")
                directory.type = tarfile.DIRTYPE
                directory.mode = 0o755
                stream.addfile(directory)
                for name, contents, mode in entries:
                    member = tarfile.TarInfo(name)
                    member.size = len(contents)
                    member.mode = mode
                    stream.addfile(member, io.BytesIO(contents))


class PortableCatalogue(unittest.TestCase):
    def setUp(self):
        self.owner = tempfile.TemporaryDirectory(prefix="managed-ollama-catalogue-unit-")
        self.addCleanup(self.owner.cleanup)
        self.root = Path(self.owner.name)
        self.contract, _ = CATALOGUE.read_contract(REPOSITORY, CATALOGUE.Inputs())
        self.official = self.root / "official.tgz"
        self.asset = self.root / "ollama-ergopti-native-http-darwin-arm64.tgz"
        archive(self.official, binary=b"Independent official CLI fixture\n")
        archive(self.asset, binary=BINARY, license_bytes=LICENSE)
        self.official_identity = {
            "sha256": sha_bytes(self.official.read_bytes()),
            "bytes": self.official.stat().st_size,
        }
        self.official_records, _ = CATALOGUE.archive_snapshot(self.official)
        self.fingerprint = {
            name: sha_bytes((REPOSITORY / name).read_bytes())
            for name in self.contract["source_fingerprint_paths"]
        }
        self.hooks = {
            "server/images.go": "1" * 64,
            "server/internal/client/ollama/registry.go": "2" * 64,
            "x/transfer/download.go": "3" * 64,
            "server/routes.go": "4" * 64,
            "server/download.go": "5" * 64,
        }
        self.repository_commit = subprocess.check_output(
            ["git", "-C", str(REPOSITORY), "rev-parse", "HEAD"], text=True
        ).strip()
        self.receipt = {
            "schema_version": 1,
            "version": "0.24.0",
            "capability": CAPABILITY,
            "source_commit": "c28ddc0a7b273cd286b680a6db0bef0c17bc0ec0",
            "go_version": "go1.26.8",
            "architecture": "arm64",
            "platform": "darwin",
            "cgo_enabled": True,
            "deployment_target": "14.0",
            "cgo_ldflags": "-lc++ -framework Metal -framework Foundation -framework Accelerate -mmacosx-version-min=14.0",
            "sdk_version": "15.5",
            "clang_version": "Apple clang literal fixture",
            "native_dependencies": "ollama: literal fixture dependency observation",
            "signing_mode": "ad-hoc",
            "filename": self.asset.name,
            "sha256": sha_bytes(self.asset.read_bytes()),
            "bytes": self.asset.stat().st_size,
            "binary_sha256": sha_bytes(BINARY),
            "runtime_libraries_sha256": {"lib/backend.dylib": sha_bytes(LIBRARY)},
            "official_archive_sha256": self.official_identity["sha256"],
            "official_archive_bytes": self.official_identity["bytes"],
            "runtime_contract_sha256": sha_bytes((REPOSITORY / CATALOGUE.CONTRACT).read_bytes()),
            "repository_source_sha256": self.fingerprint,
            "repository_commit": self.repository_commit,
            "upstream_preimages": copy.deepcopy(self.contract["upstream_preimages"]),
            "request_hook_sha256": self.hooks,
            "bridge_sha256": {
                Path(name).name: value
                for name, value in self.fingerprint.items()
                if name.endswith(".go")
            },
            "capability_source_sha256": "4" * 64,
        }
        self.receipt_path = self.root / (self.asset.name + ".provenance.json")

    def admit(self, receipt=None):
        self.receipt_path.write_text(json.dumps(self.receipt if receipt is None else receipt))
        return CATALOGUE.admit_asset(
            REPOSITORY,
            self.contract,
            self.official_identity,
            self.official_records,
            self.receipt_path,
            self.asset,
            CATALOGUE.Inputs(),
            self.fingerprint,
            self.hooks,
            "4" * 64,
            self.repository_commit,
            sha_bytes(LICENSE),
        )

    def replace_asset(self, *, binary=BINARY, library=LIBRARY, license_bytes=LICENSE, extra=None):
        # Only this test's exact owned file is replaced; original vectors remain literal.
        self.asset.unlink()
        archive(
            self.asset, binary=binary, library=library, license_bytes=license_bytes, extra=extra
        )
        self.receipt["sha256"] = sha_bytes(self.asset.read_bytes())
        self.receipt["bytes"] = self.asset.stat().st_size

    def test_source_contract_has_reviewed_pins_and_no_future_asset_identity(self):
        self.assertEqual(self.contract["version"], "0.24.0")
        self.assertEqual(self.contract["source_commit"], "c28ddc0a7b273cd286b680a6db0bef0c17bc0ec0")
        self.assertEqual(self.contract["go_version"], "go1.26.8")
        self.assertEqual(self.contract["native_http_capability"], 1)
        self.assertEqual(self.contract["upstream_preimages"], REVIEWED_PREIMAGES)
        self.assertEqual(set(self.contract["assets"]), {"macos-arm64", "macos-amd64"})
        self.assertEqual(
            self.contract["assets"]["macos-arm64"]["filename"],
            "ollama-ergopti-native-http-darwin-arm64.tgz",
        )
        self.assertEqual(
            self.contract["assets"]["macos-amd64"]["filename"],
            "ollama-ergopti-native-http-darwin-amd64.tgz",
        )
        for asset in self.contract["assets"].values():
            self.assertTrue({"sha256", "bytes", "url", "binary_sha256"}.isdisjoint(asset))

    def test_malformed_source_contract_fields_refuse(self):
        repository = self.root / "source-contract-fixture"
        contract_path = repository / CATALOGUE.CONTRACT
        contract_path.parent.mkdir(parents=True)
        official_path = repository / CATALOGUE.OFFICIAL_RELEASE
        official_path.write_bytes((REPOSITORY / CATALOGUE.OFFICIAL_RELEASE).read_bytes())
        mutations = {
            "schema_version": True,
            "version": 24,
            "go_version": None,
            "source_commit": "invalid",
            "native_http_capability": True,
            "deployment_target": "",
            "cgo_cflags": [],
            "cgo_cxxflags": None,
            "official_asset_key": False,
            "request_hook_paths": [[]],
            "source_fingerprint_paths": [None],
        }
        for key, value in mutations.items():
            with self.subTest(key=key):
                contract = copy.deepcopy(self.contract)
                contract[key] = value
                contract_path.write_text(json.dumps(contract), encoding="utf-8")
                with self.assertRaises(ValueError):
                    CATALOGUE.read_contract(repository, CATALOGUE.Inputs())

    def test_matching_literal_byte_and_source_bindings_are_admitted(self):
        host, result = self.admit()
        self.assertEqual(host, "macos-arm64")
        self.assertEqual(result["url"], "")
        self.assertEqual(result["binary_sha256"], sha_bytes(BINARY))
        self.assertEqual(
            result["runtime_libraries_sha256"], {"lib/backend.dylib": sha_bytes(LIBRARY)}
        )
        self.assertEqual(result["provenance_sha256"], sha_bytes(self.receipt_path.read_bytes()))

    def test_missing_unknown_and_tampered_receipt_fields_refuse(self):
        mutations = {
            "schema_version": True,
            "capability": "stock",
            "version": "0.23.0",
            "source_commit": "a" * 40,
            "go_version": "go1.26.7",
            "platform": "linux",
            "architecture": "amd64",
            "cgo_enabled": False,
            "deployment_target": "13.0",
            "cgo_ldflags": "-framework Fake",
            "signing_mode": "unverified",
            "filename": "stock.tgz",
            "sha256": "f" * 64,
            "bytes": 1,
            "binary_sha256": "e" * 64,
            "official_archive_sha256": "d" * 64,
            "official_archive_bytes": 1,
            "runtime_contract_sha256": "c" * 64,
            "repository_commit": "b" * 40,
            "capability_source_sha256": "9" * 64,
            "sdk_version": "",
            "clang_version": "",
            "native_dependencies": "",
            "runtime_libraries_sha256": {"lib/backend.dylib": "8" * 64},
            "request_hook_sha256": {"server/images.go": "7" * 64},
            "bridge_sha256": {"transport.go": "6" * 64},
            "repository_source_sha256": {"producer.py": "5" * 64},
            "upstream_preimages": {},
        }
        for key, value in mutations.items():
            with self.subTest(key=key):
                receipt = copy.deepcopy(self.receipt)
                receipt[key] = value
                with self.assertRaises(ValueError):
                    self.admit(receipt)
        for key in self.receipt:
            with self.subTest(missing=key):
                receipt = copy.deepcopy(self.receipt)
                del receipt[key]
                with self.assertRaises(ValueError):
                    self.admit(receipt)
        receipt = copy.deepcopy(self.receipt)
        receipt["fabricated_publication"] = True
        with self.assertRaises(ValueError):
            self.admit(receipt)

    def test_archive_bytes_refuse_even_when_receipt_shape_is_valid(self):
        self.asset.write_bytes(self.asset.read_bytes() + b"unexpected bytes")
        with self.assertRaises(ValueError):
            self.admit()

    def test_extra_source_payload_refuses_even_with_updated_container_hash(self):
        self.replace_asset(extra=("source/transport.go", b"package forbidden\n", 0o644))
        with self.assertRaisesRegex(ValueError, "additional payload/source"):
            self.admit()

    def test_official_library_mutation_refuses_with_updated_container_hash(self):
        self.replace_asset(library=LIBRARY + b"modified")
        self.receipt["runtime_libraries_sha256"]["lib/backend.dylib"] = sha_bytes(
            LIBRARY + b"modified"
        )
        with self.assertRaisesRegex(ValueError, "runtime closure changed"):
            self.admit()

    def test_license_mutation_refuses_with_updated_container_hash(self):
        self.replace_asset(license_bytes=LICENSE + b"modified")
        with self.assertRaisesRegex(ValueError, "license binding"):
            self.admit()

    def test_native_platform_mutation_refuses_even_when_all_binary_hashes_update(self):
        binary = AMD64_HEADER + CAPABILITY.encode("ascii")
        self.replace_asset(binary=binary)
        self.receipt["binary_sha256"] = sha_bytes(binary)
        with self.assertRaisesRegex(ValueError, "platform/architecture"):
            self.admit()

    def test_missing_capability_refuses_even_when_binary_hash_updates(self):
        binary = ARM64_HEADER + b"stock runtime"
        self.replace_asset(binary=binary)
        self.receipt["binary_sha256"] = sha_bytes(binary)
        with self.assertRaisesRegex(ValueError, "capability marker"):
            self.admit()

    def test_both_literal_native_header_bindings_and_nonexecutables(self):
        CATALOGUE.macho(ARM64_HEADER + CAPABILITY.encode(), "arm64", CAPABILITY)
        CATALOGUE.macho(AMD64_HEADER + CAPABILITY.encode(), "amd64", CAPABILITY)
        for value in (
            b"",
            b"MZ" + BINARY,
            b"\x7fELF" + BINARY,
            BINARY[:12] + b"\x06\0\0\0" + BINARY[16:],
        ):
            with self.subTest(header=value[:16]), self.assertRaises(ValueError):
                CATALOGUE.macho(value, "arm64", CAPABILITY)

    def test_archive_duplicates_traversal_and_external_links_refuse(self):
        for kind in ("duplicate", "traversal", "absolute-link", "outside-link"):
            path = self.root / (kind + ".tgz")
            with tarfile.open(path, "w:gz") as stream:
                member = tarfile.TarInfo(
                    "same"
                    if kind == "duplicate"
                    else "../foreign"
                    if kind == "traversal"
                    else "link"
                )
                member.size = 1
                if "link" in kind:
                    member.type = tarfile.SYMTYPE
                    member.linkname = "/foreign" if kind == "absolute-link" else "../foreign"
                    stream.addfile(member)
                else:
                    stream.addfile(member, io.BytesIO(b"x"))
                    if kind == "duplicate":
                        stream.addfile(member, io.BytesIO(b"y"))
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                CATALOGUE.archive_snapshot(path)

    def test_input_identity_changes_refuse_before_publication(self):
        path = self.root / "input"
        path.write_bytes(b"independent first bytes")
        inputs = CATALOGUE.Inputs()
        inputs.admit(path)
        path.write_bytes(b"independent second bytes")
        with self.assertRaises(ValueError):
            inputs.current()

    def test_in_archive_file_and_directory_links_keep_literal_identities(self):
        records = {
            "lib": {"kind": "directory", "mode": 0o755},
            "lib/backend.dylib": {"kind": "file", "sha256": sha_bytes(LIBRARY)},
            "library-alias": {"kind": "symlink", "resolved": "lib/backend.dylib"},
            "directory-alias": {"kind": "symlink", "resolved": "lib"},
        }
        self.assertEqual(CATALOGUE.file_hash(records, "library-alias"), sha_bytes(LIBRARY))
        self.assertEqual(CATALOGUE.resolved_record(records, "directory-alias")["kind"], "directory")
        for target in ("missing", "library-alias"):
            changed = copy.deepcopy(records)
            changed["library-alias"]["resolved"] = target
            with self.assertRaises(ValueError):
                CATALOGUE.file_hash(changed, "library-alias")

    def test_output_policy_preserves_checkout_and_existing_catalogue(self):
        repository = self.root / "checkout"
        upstream = self.root / "upstream"
        repository.mkdir()
        upstream.mkdir()
        protected = repository / "_shared/modules/llm/managed_ollama_release.json"
        for path in (protected, upstream / "build/managed_ollama_release.json"):
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    CATALOGUE.catalogue_output(repository, upstream, path)
                self.assertFalse(path.parent.exists())
        output = self.root / "build-output/managed_ollama_release.json"
        self.assertEqual(CATALOGUE.catalogue_output(repository, upstream, output), output)
        self.assertFalse(output.parent.exists())
        output.parent.mkdir()
        output.write_bytes(b"Independent existing owned catalogue\n")
        with self.assertRaises(ValueError):
            CATALOGUE.catalogue_output(repository, upstream, output)
        self.assertEqual(output.read_bytes(), b"Independent existing owned catalogue\n")

    def test_duplicate_json_fields_refuse(self):
        path = self.root / "duplicate.json"
        path.write_text('{"schema_version":1,"schema_version":2}')
        with self.assertRaises(ValueError):
            CATALOGUE.Inputs().read_json(path)

    def test_canonical_publication_matches_literal_stable_and_dev_tags(self):
        for tag, version, channel in (
            ("v3.2.1", "3.2.1", "main"),
            ("v0.0.0-dev.17", "0.0.0-dev.17", "dev"),
        ):
            result = CATALOGUE.publication(
                REPOSITORY,
                CATALOGUE.Inputs(),
                release=True,
                tag=tag,
                version=version,
                channel=channel,
            )
            self.assertEqual(
                result,
                {
                    "mode": "planned-release",
                    "tag": tag,
                    "version": version,
                    "channel": channel,
                    "repository": "adrienm7/ergopti",
                },
            )

    def test_manual_ci_has_no_tag_version_or_release_url(self):
        result = CATALOGUE.publication(
            REPOSITORY, CATALOGUE.Inputs(), release=False, tag="", version="", channel="dev"
        )
        self.assertEqual(result["mode"], "unpublished-ci")
        self.assertEqual(result["tag"], "")
        for release, tag, version, channel in (
            (False, "v3.2.1", "3.2.1", "dev"),
            (True, "v3.2.1", "3.2.0", "main"),
            (True, "v3.2.1", "3.2.1", "dev"),
        ):
            with (
                self.subTest(tag=tag, version=version, channel=channel),
                self.assertRaises(ValueError),
            ):
                CATALOGUE.publication(
                    REPOSITORY,
                    CATALOGUE.Inputs(),
                    release=release,
                    tag=tag,
                    version=version,
                    channel=channel,
                )


class NativeBuildEnvironment(unittest.TestCase):
    """Closed command ports qualify SDK propagation, not an actual Darwin build."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "native_builder", REPOSITORY / "tools/build/build-macos-managed-ollama.py"
        )
        self.builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.builder)
        self.owner = tempfile.TemporaryDirectory(prefix="managed-sdk-env-")
        self.addCleanup(self.owner.cleanup)
        self.root = Path(self.owner.name)
        self.sdk = self.root / "macOS SDK with spaces"
        self.sdk.mkdir()
        self.cc = self.root / "clang tool"
        self.cxx = self.root / "clang++ tool"
        self.cc.write_bytes(b"Independent inert compiler path control\n")
        self.cxx.write_bytes(b"Independent inert C++ compiler path control\n")
        self.contract = {
            "cgo_cflags": "-O3 -mmacosx-version-min=14.0",
            "cgo_cxxflags": "-O3 -mmacosx-version-min=14.0",
        }
        self.asset = {
            "os": "darwin",
            "cgo_ldflags": "-framework Foundation -framework SystemConfiguration",
        }
        self.calls = []

    def command(self, argv):
        self.calls.append(argv)
        responses = {
            ("xcrun", "--sdk", "macosx", "--show-sdk-path"): str(self.sdk),
            ("xcrun", "--sdk", "macosx", "--find", "clang"): str(self.cc),
            ("xcrun", "--sdk", "macosx", "--find", "clang++"): str(self.cxx),
            ("xcrun", "--sdk", "macosx", "--show-sdk-version"): "26.0",
        }
        if tuple(argv) not in responses:
            raise AssertionError("Unknown native build command")
        return responses[tuple(argv)]

    def environment(self):
        with mock.patch.object(self.builder, "run", self.command):
            return self.builder.native_build_env(self.contract, self.asset, "arm64", self.root)

    def test_compilers_and_linker_carry_the_exact_selected_sdk(self):
        env = self.environment()
        self.assertEqual(
            [str(self.cc), "-isysroot", str(self.sdk.resolve())], shlex.split(env["CC"])
        )
        self.assertEqual(
            [str(self.cxx), "-isysroot", str(self.sdk.resolve())], shlex.split(env["CXX"])
        )
        self.assertEqual(str(self.sdk.resolve()), env["SDKROOT"])
        self.assertEqual(
            [
                ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                ["xcrun", "--sdk", "macosx", "--find", "clang"],
                ["xcrun", "--sdk", "macosx", "--find", "clang++"],
                ["xcrun", "--sdk", "macosx", "--show-sdk-version"],
            ],
            self.calls,
        )

    def test_ambient_sdk_compilers_and_flags_cannot_replace_reviewed_abi(self):
        ambient = {
            "SDKROOT": "foreign-ios-sdk",
            "CC": "foreign-cc",
            "CXX": "foreign-cxx",
            "CGO_CFLAGS": "-DUNREVIEWED",
            "CGO_LDFLAGS": "-Lforeign",
        }
        with mock.patch.dict(self.builder.os.environ, ambient):
            env = self.environment()
        self.assertEqual(str(self.sdk.resolve()), env["SDKROOT"])
        self.assertEqual(self.contract["cgo_cflags"], env["CGO_CFLAGS"])
        self.assertEqual(self.contract["cgo_cxxflags"], env["CGO_CXXFLAGS"])
        self.assertEqual(self.asset["cgo_ldflags"], env["CGO_LDFLAGS"])
        self.assertEqual("", env["CGO_CPPFLAGS"])
        self.assertEqual("1", env["CGO_ENABLED"])
        self.assertEqual("darwin", env["GOOS"])
        self.assertEqual("arm64", env["GOARCH"])
        self.assertEqual("local", env["GOTOOLCHAIN"])

    def test_missing_sdk_refuses_before_compiler_selection(self):
        self.sdk.rmdir()
        with self.assertRaises(FileNotFoundError):
            self.environment()
        self.assertEqual([["xcrun", "--sdk", "macosx", "--show-sdk-path"]], self.calls)

    def test_missing_compiler_refuses_without_substituting_path(self):
        self.cc.unlink()
        with self.assertRaisesRegex(ValueError, "compilers are unavailable"):
            self.environment()
        self.assertEqual(3, len(self.calls))

    def test_empty_relative_and_regular_file_sdk_paths_refuse_before_compilers(self):
        for raw in ("", ".", str(self.cc)):
            with self.subTest(raw=raw):
                self.calls.clear()

                def query(argv):
                    if argv == ["xcrun", "--sdk", "macosx", "--show-sdk-path"]:
                        return raw
                    return self.command(argv)

                with mock.patch.object(self.builder, "run", query):
                    with self.assertRaisesRegex(ValueError, "selected native macOS SDK"):
                        self.builder.native_build_env(self.contract, self.asset, "arm64", self.root)
                self.assertEqual([], self.calls)

    def test_native_query_refusal_preserves_exact_error(self):
        refusal = subprocess.CalledProcessError(73, ["xcrun", "--sdk", "macosx", "--show-sdk-path"])
        with mock.patch.object(self.builder, "run", side_effect=refusal):
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                self.builder.native_build_env(self.contract, self.asset, "arm64", self.root)
        self.assertIs(refusal, raised.exception)


class NativeCatalogue(unittest.TestCase):
    """This profile requires actual native producer output, not portable fixtures."""

    def setUp(self):
        self.owner = tempfile.TemporaryDirectory(prefix="managed-ollama-catalogue-native-")
        self.addCleanup(self.owner.cleanup)
        self.root = Path(self.owner.name)
        self.options = SimpleNamespace(
            repository=REPOSITORY,
            source=NATIVE.source,
            official_archive=NATIVE.official_archive,
            producer_receipt=[NATIVE.producer_receipt],
            archive=[NATIVE.archive],
            go=NATIVE.go,
            node="node",
            release=False,
            release_tag="",
            release_version="",
            release_channel="dev",
            output=self.root / "managed_ollama_release.json",
        )

    def test_actual_producer_archive_source_and_library_tree_join(self):
        output = CATALOGUE.stage(self.options)
        data = json.loads(output.read_text())
        receipt = json.loads(NATIVE.producer_receipt.read_text())
        asset = data["assets"]["macos-" + receipt["architecture"]]
        self.assertEqual(data["version"], "0.24.0")
        self.assertEqual(data["source_commit"], "c28ddc0a7b273cd286b680a6db0bef0c17bc0ec0")
        self.assertEqual(asset["sha256"], sha_bytes(NATIVE.archive.read_bytes()))
        self.assertEqual(asset["bytes"], NATIVE.archive.stat().st_size)
        self.assertEqual(asset["binary_sha256"], receipt["binary_sha256"])
        self.assertEqual(asset["runtime_libraries_sha256"], receipt["runtime_libraries_sha256"])
        self.assertEqual(asset["url"], "")
        self.assertEqual(data["publication"]["mode"], "unpublished-ci")
        before = output.read_bytes()
        with self.assertRaises(ValueError):
            CATALOGUE.stage(self.options)
        self.assertEqual(output.read_bytes(), before)

    def test_actual_receipt_mutants_refuse_without_output(self):
        original = json.loads(NATIVE.producer_receipt.read_text())
        for key, value in (
            ("source_commit", "0" * 40),
            ("binary_sha256", "0" * 64),
            ("runtime_contract_sha256", "0" * 64),
            ("platform", "linux"),
            ("request_hook_sha256", {}),
            ("capability_source_sha256", "0" * 64),
        ):
            with self.subTest(key=key):
                changed = copy.deepcopy(original)
                changed[key] = value
                receipt = self.root / (key + ".json")
                receipt.write_text(json.dumps(changed))
                options = copy.copy(self.options)
                options.producer_receipt = [receipt]
                with self.assertRaises(ValueError):
                    CATALOGUE.stage(options)
                self.assertFalse(options.output.exists())

    def test_actual_archive_tamper_refuses_even_with_matching_filename(self):
        altered = self.root / NATIVE.archive.name
        with NATIVE.archive.open("rb") as source, altered.open("xb") as destination:
            while contents := source.read(1024 * 1024):
                destination.write(contents)
            destination.write(b"independent unexpected archive suffix")
        self.options.archive = [altered]
        with self.assertRaises(ValueError):
            CATALOGUE.stage(self.options)
        self.assertFalse(self.options.output.exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--official-archive", type=Path)
    parser.add_argument("--producer-receipt", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--go", type=Path)
    options = parser.parse_args()
    if options.native and any(
        getattr(options, key) is None
        for key in ("source", "official_archive", "producer_receipt", "archive", "go")
    ):
        parser.error("The native receiving profile requires every actual producer/source input")
    NATIVE = options
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PortableCatalogue)
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(NativeBuildEnvironment))
    if options.native:
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(NativeCatalogue))
    else:
        print("Portable input admission only; actual native producer receiving was not requested.")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
