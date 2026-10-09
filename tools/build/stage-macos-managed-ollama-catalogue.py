#!/usr/bin/env python3
"""Admit actual native Ollama assets and generate a build-only catalogue.

The receipt is an input binding, not native execution or signing authority.
Native CI owns those observations. This tool independently checks source bytes,
reviewed hook outputs, archive contents and the official runtime-library closure.
An unpublished CI catalogue has empty download URLs; it publishes no release.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile

CONTRACT = "static/ergopti_plus/_shared/modules/llm/managed_ollama_runtime.json"
OFFICIAL_RELEASE = "static/ergopti_plus/_shared/modules/llm/ollama_release.json"
DEFAULTS = "static/ergopti_plus/_shared/modules/updater/defaults.json"
CHANNELS = "static/ergopti_plus/_shared/modules/updater/channels.json"
PRODUCER = "tools/build/build-macos-managed-ollama.py"
SHA256 = re.compile(r"[a-f0-9]{64}\Z")
SOURCE_COMMIT = re.compile(r"[a-f0-9]{40}\Z")
RECEIPT_FIELDS = {
    "schema_version",
    "capability",
    "version",
    "source_commit",
    "upstream_preimages",
    "request_hook_sha256",
    "bridge_sha256",
    "go_version",
    "architecture",
    "cgo_enabled",
    "deployment_target",
    "cgo_ldflags",
    "sdk_version",
    "clang_version",
    "official_archive_sha256",
    "official_archive_bytes",
    "runtime_libraries_sha256",
    "binary_sha256",
    "native_dependencies",
    "signing_mode",
    "filename",
    "sha256",
    "bytes",
    "runtime_contract_sha256",
    "repository_source_sha256",
    "capability_source_sha256",
    "repository_commit",
    "platform",
}


def digest(path: Path) -> str:
    """Hash an admitted regular file without interpreting its contents."""
    result = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            result.update(chunk)
    return result.hexdigest()


def ordinary(path: Path) -> os.stat_result:
    fact = path.lstat()
    if not stat.S_ISREG(fact.st_mode):
        raise ValueError("An ordinary input file is required")
    return fact


def relative(value: str) -> str:
    if not isinstance(value, str) or not value or "\\" in value or any(ord(c) < 32 for c in value):
        raise ValueError("An archive/source path was refused")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or str(path) != value:
        raise ValueError("An archive/source path was refused")
    return value


def source_file(root: Path, name: str) -> Path:
    path = root
    parts = PurePosixPath(relative(name)).parts
    for index, part in enumerate(parts):
        path /= part
        fact = path.lstat()
        if index == len(parts) - 1:
            if not stat.S_ISREG(fact.st_mode):
                raise ValueError("A source input is not an ordinary file")
        elif not stat.S_ISDIR(fact.st_mode):
            raise ValueError("A source input parent is not a physical directory")
    return path


def physical_directory(path: Path) -> Path:
    path = path.absolute()
    if not stat.S_ISDIR(path.lstat().st_mode):
        raise ValueError("A physical input directory is required")
    return path.resolve(strict=True)


def json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON keys were refused")
        result[key] = value
    return result


class Inputs:
    """Recheck exact input identities immediately before catalogue publication."""

    def __init__(self):
        self.files = {}

    def admit(self, path: Path) -> str:
        fact = ordinary(path)
        identity = (fact.st_dev, fact.st_ino, fact.st_size, fact.st_mode, fact.st_mtime_ns)
        value = digest(path)
        if path in self.files and self.files[path] != (identity, value):
            raise ValueError("An input changed during admission")
        self.files[path] = (identity, value)
        return value

    def read_json(self, path: Path):
        self.admit(path)
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=json_object)

    def current(self):
        for path in tuple(self.files):
            self.admit(path)


def exact_keys(value, names):
    if not isinstance(value, dict) or set(value) != set(names):
        raise ValueError("A missing or unknown metadata field was refused")


def hash_map(value, names=None):
    if not isinstance(value, dict) or not value or (names is not None and set(value) != set(names)):
        raise ValueError("A source/runtime hash map was refused")
    for name, value_hash in value.items():
        relative(name)
        if not isinstance(value_hash, str) or not SHA256.fullmatch(value_hash):
            raise ValueError("A source/runtime hash value was refused")


def read_contract(repository: Path, inputs: Inputs):
    contract = inputs.read_json(source_file(repository, CONTRACT))
    exact_keys(
        contract,
        [
            "schema_version",
            "version",
            "source_commit",
            "go_version",
            "capability",
            "native_http_capability",
            "deployment_target",
            "cgo_cflags",
            "cgo_cxxflags",
            "official_asset_key",
            "binary_path",
            "license_path",
            "allowed_signing_modes",
            "upstream_preimages",
            "request_hook_paths",
            "source_fingerprint_paths",
            "native_http_go_test_policy",
            "assets",
        ],
    )
    if (
        type(contract["schema_version"]) is not int
        or contract["schema_version"] != 1
        or type(contract["native_http_capability"]) is not int
        or contract["native_http_capability"] != 1
        or not isinstance(contract["source_commit"], str)
        or not SOURCE_COMMIT.fullmatch(contract["source_commit"])
        or not isinstance(contract["version"], str)
        or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", contract["version"])
        or not isinstance(contract["go_version"], str)
        or not re.fullmatch(r"go[0-9]+\.[0-9]+\.[0-9]+", contract["go_version"])
        or contract["capability"] != "ERGOPTI_OLLAMA_NATIVE_HTTP_V1"
    ):
        raise ValueError("The native Ollama source contract was refused")
    for key in ("deployment_target", "cgo_cflags", "cgo_cxxflags", "official_asset_key"):
        if not isinstance(contract[key], str) or not contract[key].strip():
            raise ValueError("A native source/toolchain policy field was refused")
    for key in ("binary_path", "license_path"):
        relative(contract[key])
        if "/" in contract[key]:
            raise ValueError("The native runtime root layout was refused")
    hash_map(contract["upstream_preimages"])
    for key in ("request_hook_paths", "source_fingerprint_paths"):
        values = contract[key]
        if (
            not isinstance(values, list)
            or not values
            or any(not isinstance(value, str) for value in values)
            or len(set(values)) != len(values)
        ):
            raise ValueError("The source fingerprint policy was refused")
        for value in values:
            relative(value)
    if (
        PRODUCER not in contract["source_fingerprint_paths"]
        or not set(contract["request_hook_paths"]) <= set(contract["upstream_preimages"])
        or contract["allowed_signing_modes"] != ["ad-hoc", "configured-certificate"]
    ):
        raise ValueError("The native producer policy was refused")
    policy = contract["native_http_go_test_policy"]
    exact_keys(policy, ["timeout_seconds", "maximum_log_bytes", "required_passes"])
    for key in ("timeout_seconds", "maximum_log_bytes"):
        if type(policy[key]) is not int or policy[key] <= 0:
            raise ValueError("A native Go receiving bound was refused")
    identities = policy["required_passes"]
    if (
        not isinstance(identities, list)
        or not identities
        or any(
            not isinstance(name, str)
            or not name.startswith("Test")
            or any(ord(character) < 32 for character in name)
            for name in identities
        )
        or len(set(identities)) != len(identities)
    ):
        raise ValueError("The frozen native Go receiving identities were refused")
    exact_keys(contract["assets"], ["macos-arm64", "macos-amd64"])
    for key, asset in contract["assets"].items():
        exact_keys(asset, ["os", "architecture", "filename", "cgo_ldflags"])
        if (
            asset["os"] != "darwin"
            or not isinstance(asset["architecture"], str)
            or asset["architecture"] not in {"arm64", "amd64"}
            or key != "macos-" + asset["architecture"]
            or not isinstance(asset["filename"], str)
            or not re.fullmatch(r"[A-Za-z0-9._-]+\.tgz", asset["filename"])
            or not isinstance(asset["cgo_ldflags"], str)
            or not asset["cgo_ldflags"]
        ):
            raise ValueError("A native macOS host binding was refused")
    official = inputs.read_json(source_file(repository, OFFICIAL_RELEASE))
    if (
        type(official["schema_version"]) is not int
        or official["schema_version"] != 1
        or official["version"] != contract["version"]
    ):
        raise ValueError("The managed and official Ollama versions differ")
    official_identity = official["assets"][contract["official_asset_key"]]
    if (
        not isinstance(official_identity["sha256"], str)
        or not SHA256.fullmatch(official_identity["sha256"])
        or type(official_identity["bytes"]) is not int
        or official_identity["bytes"] <= 0
    ):
        raise ValueError("The canonical official archive identity was refused")
    return contract, official_identity


def run(arguments, *, cwd=None):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_NOSYSTEM="1",
        GIT_OPTIONAL_LOCKS="0",
        GOTOOLCHAIN="local",
    )
    result = subprocess.run(
        arguments,
        cwd=cwd,
        env=environment,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
    )
    return result.stdout.strip()


def publication(repository: Path, inputs: Inputs, *, release, tag, version, channel, node="node"):
    """Resolve publication URLs through the existing canonical channel interpreter."""
    if type(release) is not bool or any(
        not isinstance(value, str) for value in (tag, version, channel)
    ):
        raise ValueError("The actual release plan fields were refused")
    defaults = inputs.read_json(source_file(repository, DEFAULTS))
    channels = inputs.read_json(source_file(repository, CHANNELS))
    github = defaults["github"]
    for key in ("owner", "repo"):
        if not isinstance(github[key], str) or not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9._-]*", github[key]
        ):
            raise ValueError("The canonical release repository was refused")
    if release:
        if not tag or tag != "v" + version:
            raise ValueError("The release plan tag and version differ")
        for name in (
            "tools/build/release-channel.cjs",
            "static/ergopti_plus/_shared/ui/update_channels.js",
        ):
            inputs.admit(source_file(repository, name))
        actual = run(
            [node, str(repository / "tools/build/release-channel.cjs"), tag], cwd=repository
        )
        if actual != channel:
            raise ValueError("The release plan channel differs from the canonical tag owner")
    elif tag or version or channel != channels["unreleased_build_channel"]:
        raise ValueError("An unpublished CI plan cannot advertise a release")
    return {
        "mode": "planned-release" if release else "unpublished-ci",
        "tag": tag,
        "version": version,
        "channel": channel,
        "repository": github["owner"] + "/" + github["repo"],
    }


def archive_snapshot(path: Path, *, binary_path=None):
    """Read bytes and link identities in place; never extract or follow archive links."""
    ordinary(path)
    records = {}
    case_names = set()
    binary = None
    with tarfile.open(path, "r|gz") as archive:
        for member in archive:
            name = member.name
            while name.startswith("./"):
                name = name[2:]
            if name in {"", "."} and member.isdir():
                continue
            name = relative(name.rstrip("/") if member.isdir() else name)
            if name in records or name.casefold() in case_names:
                raise ValueError("A duplicate native archive member was refused")
            case_names.add(name.casefold())
            record = {"mode": member.mode}
            if member.isdir():
                record["kind"] = "directory"
            elif member.isfile():
                if member.size < 0 or member.size > 2 * 1024**3:
                    raise ValueError("A native archive member size was refused")
                record.update(kind="file", bytes=member.size)
                content = archive.extractfile(member)
                value_hash = hashlib.sha256()
                chunks = [] if name == binary_path else None
                while chunk := content.read(1024 * 1024):
                    value_hash.update(chunk)
                    if chunks is not None:
                        chunks.append(chunk)
                record["sha256"] = value_hash.hexdigest()
                if chunks is not None:
                    binary = b"".join(chunks)
            elif member.issym() or member.islnk():
                target = member.linkname
                if (
                    not isinstance(target, str)
                    or "\\" in target
                    or any(ord(c) < 32 for c in target)
                ):
                    raise ValueError("An archive link was refused")
                if PurePosixPath(target).is_absolute():
                    raise ValueError("An external archive link was refused")
                parts = list(PurePosixPath(name).parent.parts) if member.issym() else []
                for part in PurePosixPath(target).parts:
                    if part == "..":
                        if not parts:
                            raise ValueError("An external archive link was refused")
                        parts.pop()
                    elif part != ".":
                        parts.append(part)
                record.update(
                    kind="symlink" if member.issym() else "hardlink",
                    target=target,
                    resolved=relative("/".join(parts)),
                )
            else:
                raise ValueError("A special native archive member was refused")
            records[name] = record
    return records, binary


def resolved_record(records, name, visited=None):
    visited = set() if visited is None else visited
    if name in visited or name not in records:
        raise ValueError("A missing or cyclic runtime link was refused")
    visited.add(name)
    record = records[name]
    if record["kind"] in {"symlink", "hardlink"}:
        return resolved_record(records, record["resolved"], visited)
    return record


def file_hash(records, name):
    record = resolved_record(records, name)
    if record["kind"] == "file":
        return record["sha256"]
    raise ValueError("A runtime library does not resolve to file bytes")


def macho(binary: bytes, architecture: str, capability: str):
    """Admit an executable thin Mach-O for the declared host, not a capability claim alone."""
    if not isinstance(binary, bytes) or len(binary) < 32:
        raise ValueError("The native CLI is missing")
    byte_order = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">"}.get(binary[:4])
    if byte_order is None:
        raise ValueError("The native CLI is not a thin 64-bit Mach-O")
    cpu, _, file_type = struct.unpack(byte_order + "III", binary[4:16])
    if cpu != {"arm64": 0x0100000C, "amd64": 0x01000007}[architecture] or file_type != 2:
        raise ValueError("The actual CLI platform/architecture differs")
    if capability.encode("ascii") not in binary:
        raise ValueError("The native HTTP capability marker is missing")


def source_outputs(repository: Path, source: Path, contract, inputs: Inputs, go: Path):
    """Reconstruct reviewed hooks on a private copy using the actual pinned formatter."""
    if run(["git", "-C", str(source), "rev-parse", "HEAD"]) != contract["source_commit"]:
        raise ValueError("The upstream source checkout commit differs")
    if run(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=all"]):
        raise ValueError("The upstream source checkout is not clean")
    for name, expected in contract["upstream_preimages"].items():
        if inputs.admit(source_file(source, name)) != expected:
            raise ValueError("An upstream source preimage differs")
    inputs.admit(source_file(source, "LICENSE"))
    fingerprint = {
        name: inputs.admit(source_file(repository, name))
        for name in contract["source_fingerprint_paths"]
    }
    go = go.resolve(strict=True)
    gofmt = go.with_name("gofmt")
    inputs.admit(go)
    inputs.admit(gofmt)
    if run([str(go), "env", "GOVERSION"]) != contract["go_version"]:
        raise ValueError("The source verifier requires the pinned Go formatter")
    specification = importlib.util.spec_from_file_location(
        "managed_ollama_producer", repository / PRODUCER
    )
    producer = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(producer)
    with tempfile.TemporaryDirectory(prefix="managed-ollama-catalogue-source-") as temporary:
        candidate = Path(temporary)
        for name in contract["upstream_preimages"]:
            destination = candidate / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_file(source, name), destination)
        producer.apply_hooks(candidate, repository)
        files = [candidate / name for name in contract["request_hook_paths"]]
        capability_source = candidate / "ergopti_native_http_capability.go"
        run([str(gofmt), "-w", *map(str, files), str(capability_source)])
        hooks = {name: digest(candidate / name) for name in contract["request_hook_paths"]}
        capability_hash = digest(capability_source)
    return fingerprint, hooks, capability_hash


def admit_asset(
    repository,
    contract,
    official_identity,
    official_records,
    receipt_path,
    archive_path,
    inputs,
    fingerprint,
    hooks,
    capability_hash,
    repository_commit,
    license_hash,
):
    receipt = inputs.read_json(receipt_path)
    exact_keys(receipt, RECEIPT_FIELDS)
    if (
        type(receipt["schema_version"]) is not int
        or receipt["schema_version"] != 1
        or receipt["cgo_enabled"] is not True
    ):
        raise ValueError("A native producer receipt was refused")
    host = "macos-" + str(receipt["architecture"])
    if host not in contract["assets"]:
        raise ValueError("The receipt has an unsupported native host")
    binding = contract["assets"][host]
    for key in ("version", "source_commit", "capability", "go_version", "deployment_target"):
        if receipt[key] != contract[key]:
            raise ValueError("A native receipt/source policy field differs")
    if (
        receipt["platform"] != binding["os"]
        or receipt["filename"] != binding["filename"]
        or archive_path.name != binding["filename"]
        or receipt["cgo_ldflags"] != binding["cgo_ldflags"]
        or receipt["signing_mode"] not in contract["allowed_signing_modes"]
        or receipt["repository_commit"] != repository_commit
        or receipt["runtime_contract_sha256"] != inputs.admit(source_file(repository, CONTRACT))
        or receipt["repository_source_sha256"] != fingerprint
        or receipt["upstream_preimages"] != contract["upstream_preimages"]
        or receipt["request_hook_sha256"] != hooks
        or receipt["capability_source_sha256"] != capability_hash
    ):
        raise ValueError("The native producer provenance is stale or mismatched")
    bridge = {
        PurePosixPath(name).name: value
        for name, value in fingerprint.items()
        if name.endswith(".go")
    }
    if receipt["bridge_sha256"] != bridge:
        raise ValueError("The native request bridge source differs")
    for key in ("sdk_version", "clang_version", "native_dependencies"):
        if not isinstance(receipt[key], str) or not receipt[key].strip():
            raise ValueError("The actual native toolchain observation is missing")
    if (
        type(receipt["official_archive_bytes"]) is not int
        or receipt["official_archive_sha256"] != official_identity["sha256"]
        or receipt["official_archive_bytes"] != official_identity["bytes"]
        or type(receipt["bytes"]) is not int
        or receipt["bytes"] <= 0
        or archive_path.stat().st_size != receipt["bytes"]
        or inputs.admit(archive_path) != receipt["sha256"]
    ):
        raise ValueError("The actual native asset/official archive identity differs")
    records, binary = archive_snapshot(archive_path, binary_path=contract["binary_path"])
    expected = set(official_records) | {contract["license_path"]}
    if set(records) != expected:
        raise ValueError("The native asset contains missing or additional payload/source files")
    for name, record in official_records.items():
        if name == contract["binary_path"]:
            if records[name]["kind"] != "file" or not records[name]["mode"] & 0o111:
                raise ValueError("The native CLI is not an executable regular archive file")
        elif records[name] != record:
            raise ValueError("The verified official native runtime closure changed")
    libraries = {
        name: file_hash(official_records, name)
        for name in official_records
        if resolved_record(official_records, name)["kind"] == "file"
        and name != contract["binary_path"]
    }
    if not libraries or not any(name.endswith(".dylib") for name in libraries):
        raise ValueError("The actual official native library closure is missing")
    if receipt["runtime_libraries_sha256"] != libraries:
        raise ValueError("The producer runtime-library fingerprint differs")
    license_record = records[contract["license_path"]]
    if (
        license_record["kind"] != "file"
        or license_record["mode"] & 0o111
        or license_record["sha256"] != license_hash
    ):
        raise ValueError("The source license binding differs")
    macho(binary, binding["architecture"], contract["capability"])
    if records[contract["binary_path"]]["sha256"] != receipt["binary_sha256"]:
        raise ValueError("The actual native CLI bytes differ")
    return host, {
        "os": binding["os"],
        "architecture": binding["architecture"],
        "filename": binding["filename"],
        "url": "",
        "sha256": receipt["sha256"],
        "bytes": receipt["bytes"],
        "version": contract["version"],
        "source_commit": contract["source_commit"],
        "capability": contract["capability"],
        "native_http_capability": contract["native_http_capability"],
        "binary_sha256": receipt["binary_sha256"],
        "runtime_libraries_sha256": libraries,
        "provenance_sha256": inputs.admit(receipt_path),
    }


def catalogue_output(repository: Path, source: Path, requested: Path):
    """Resolve a build-only output without creating directories or replacing files."""
    output = requested.absolute()
    if output.name != "managed_ollama_release.json":
        raise ValueError("The catalogue output basename was refused")
    output = output.parent.resolve(strict=False) / output.name
    if output.is_relative_to(repository) and output.relative_to(repository).parts[0] != "build":
        raise ValueError("A generated catalogue cannot replace source/runtime checkout files")
    if output.is_relative_to(source):
        raise ValueError("A generated catalogue cannot modify the upstream source checkout")
    if output.exists() or output.is_symlink():
        raise ValueError("The catalogue output is already owned")
    return output


def stage(options):
    repository = physical_directory(options.repository)
    source = physical_directory(options.source)
    inputs = Inputs()
    contract, official_identity = read_contract(repository, inputs)
    plan = publication(
        repository,
        inputs,
        release=options.release,
        tag=options.release_tag,
        version=options.release_version,
        channel=options.release_channel,
        node=options.node,
    )
    official = options.official_archive.absolute()
    if (
        ordinary(official).st_size != official_identity["bytes"]
        or inputs.admit(official) != official_identity["sha256"]
    ):
        raise ValueError("The canonical official runtime archive differs")
    official_records, _ = archive_snapshot(official)
    if (
        contract["license_path"] in official_records
        or contract["binary_path"] not in official_records
    ):
        raise ValueError("The official runtime root layout changed")
    repository_commit = run(["git", "-C", str(repository), "rev-parse", "HEAD"])
    if not SOURCE_COMMIT.fullmatch(repository_commit):
        raise ValueError("The source repository commit is unavailable")
    fingerprint, hooks, capability_hash = source_outputs(
        repository, source, contract, inputs, options.go
    )
    if not options.producer_receipt or len(options.producer_receipt) != len(options.archive):
        raise ValueError("Each actual native archive requires its actual producer receipt")
    assets = {}
    for receipt, archive in zip(options.producer_receipt, options.archive, strict=True):
        host, asset = admit_asset(
            repository,
            contract,
            official_identity,
            official_records,
            receipt.absolute(),
            archive.absolute(),
            inputs,
            fingerprint,
            hooks,
            capability_hash,
            repository_commit,
            inputs.admit(source_file(source, "LICENSE")),
        )
        if host in assets:
            raise ValueError("A duplicate native host asset was refused")
        if options.release:
            asset["url"] = (
                "https://github.com/"
                + plan["repository"]
                + "/releases/download/"
                + plan["tag"]
                + "/"
                + asset["filename"]
            )
        assets[host] = asset
    catalogue = {
        "schema_version": 1,
        "version": contract["version"],
        "source_commit": contract["source_commit"],
        "capability": contract["capability"],
        "native_http_capability": contract["native_http_capability"],
        "runtime_contract_sha256": inputs.admit(source_file(repository, CONTRACT)),
        "repository_commit": repository_commit,
        "repository_source_sha256": fingerprint,
        "publication": plan,
        "assets": assets,
    }
    output = catalogue_output(repository, source, options.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(catalogue, indent="\t", sort_keys=True) + "\n").encode("utf-8")
    inputs.current()
    if (
        run(["git", "-C", str(repository), "rev-parse", "HEAD"]) != repository_commit
        or run(["git", "-C", str(source), "rev-parse", "HEAD"]) != contract["source_commit"]
        or run(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=all"])
    ):
        raise ValueError("An admitted source checkout changed during catalogue generation")
    with tempfile.NamedTemporaryFile(
        prefix=".managed-ollama-catalogue-", dir=output.parent
    ) as temporary:
        temporary.write(encoded)
        temporary.flush()
        os.fsync(temporary.fileno())
        os.chmod(temporary.name, 0o644)
        inputs.current()
        os.link(temporary.name, output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--official-archive", type=Path, required=True)
    parser.add_argument("--producer-receipt", type=Path, action="append", required=True)
    parser.add_argument("--archive", type=Path, action="append", required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--go", type=Path, required=True)
    parser.add_argument("--node", default="node")
    parser.add_argument("--release", choices=["true", "false"], required=True)
    parser.add_argument("--release-tag", default="")
    parser.add_argument("--release-version", default="")
    parser.add_argument("--release-channel", required=True)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    options.release = options.release == "true"
    print(stage(options))


if __name__ == "__main__":
    main()
