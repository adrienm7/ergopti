# _shared/python/managed_ollama_runtime.py
"""Source-qualified optional runtime catalogue and installed-byte admission.

Native signing, architecture, downloading and process checks are injected ports.
No runtime or model is bundled or moved by this shared policy.
"""

import hashlib
import hmac
import json
from pathlib import Path, PurePosixPath
import re
import secrets
from urllib.parse import urlsplit

MAXIMUM_METADATA_BYTES = 1048576
SHA256 = re.compile(r"[a-f0-9]{64}\Z")
CATALOGUE_FIELDS = {
    "schema_version",
    "version",
    "source_commit",
    "capability",
    "native_http_capability",
    "runtime_contract_sha256",
    "repository_commit",
    "repository_source_sha256",
    "publication",
    "assets",
}
ASSET_FIELDS = {
    "os",
    "architecture",
    "filename",
    "url",
    "sha256",
    "bytes",
    "version",
    "source_commit",
    "capability",
    "native_http_capability",
    "binary_sha256",
    "runtime_libraries_sha256",
    "provenance_sha256",
}
RECEIPT_BASENAME = ".ergopti-managed-runtime.json"


class RuntimeRefusal(Exception):
    """Fixed lexical reason only; paths, URLs and credentials are never printed."""


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise RuntimeRefusal("metadata")
        result[name] = value
    return result


def metadata_bytes(data):
    if not isinstance(data, bytes) or len(data) > MAXIMUM_METADATA_BYTES:
        raise RuntimeRefusal("metadata")
    try:
        result = json.loads(
            data,
            object_pairs_hook=unique_object,
            parse_constant=lambda value: (_ for _ in ()).throw(RuntimeRefusal("metadata")),
        )
    except (ValueError, UnicodeError) as error:
        raise RuntimeRefusal("metadata") from error
    if not isinstance(result, dict):
        raise RuntimeRefusal("metadata")
    return result


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def relative_name(name):
    if (
        not isinstance(name, str)
        or not name
        or "\\" in name
        or "\0" in name
        or PurePosixPath(name).is_absolute()
        or str(PurePosixPath(name)) != name
        or any(part in (".", "..") for part in PurePosixPath(name).parts)
    ):
        raise RuntimeRefusal("metadata")
    return name


def select_asset(contract_bytes, catalogue_bytes, host):
    contract, catalogue = (
        metadata_bytes(contract_bytes),
        metadata_bytes(catalogue_bytes),
    )
    if (
        set(catalogue) != CATALOGUE_FIELDS
        or type(catalogue["schema_version"]) is not int
        or catalogue["schema_version"] != 1
        or type(contract.get("schema_version")) is not int
        or contract.get("schema_version") != 1
        or catalogue["runtime_contract_sha256"] != sha256(contract_bytes)
        or not isinstance(catalogue["assets"], dict)
        or host not in contract.get("assets", {})
        or host not in catalogue["assets"]
    ):
        raise RuntimeRefusal("unavailable")
    if (
        not isinstance(catalogue["publication"], dict)
        or catalogue["publication"].get("mode") not in ("planned-release", "unpublished-ci")
        or not isinstance(catalogue["repository_commit"], str)
        or re.fullmatch(r"[a-f0-9]{40}", catalogue["repository_commit"]) is None
        or not isinstance(catalogue["repository_source_sha256"], dict)
        or set(catalogue["repository_source_sha256"])
        != set(contract.get("source_fingerprint_paths", []))
    ):
        raise RuntimeRefusal("metadata")
    for digest in catalogue["repository_source_sha256"].values():
        if not isinstance(digest, str) or SHA256.fullmatch(digest) is None:
            raise RuntimeRefusal("metadata")
    for name in ("version", "source_commit", "capability", "native_http_capability"):
        if catalogue[name] != contract.get(name) or type(catalogue[name]) is not type(
            contract.get(name)
        ):
            raise RuntimeRefusal("metadata")
    asset, binding = catalogue["assets"][host], contract["assets"][host]
    if not isinstance(binding, dict) or any(
        name not in binding for name in ("os", "architecture", "filename")
    ):
        raise RuntimeRefusal("metadata")
    if not isinstance(asset, dict) or set(asset) != ASSET_FIELDS:
        raise RuntimeRefusal("metadata")
    for name in ("os", "architecture", "filename"):
        if asset[name] != binding[name]:
            raise RuntimeRefusal("metadata")
    for name in ("version", "source_commit", "capability", "native_http_capability"):
        if asset[name] != contract[name] or type(asset[name]) is not type(contract[name]):
            raise RuntimeRefusal("metadata")
    for name in ("sha256", "binary_sha256", "provenance_sha256"):
        if not isinstance(asset[name], str) or SHA256.fullmatch(asset[name]) is None:
            raise RuntimeRefusal("metadata")
    if type(asset["bytes"]) is not int or asset["bytes"] <= 0 or not isinstance(asset["url"], str):
        raise RuntimeRefusal("metadata")
    if asset["url"]:
        if len(asset["url"].encode("utf-8")) > 65536 or any(
            ord(value) < 33 or ord(value) == 127 for value in asset["url"]
        ):
            raise RuntimeRefusal("metadata")
        try:
            url = urlsplit(asset["url"])
            valid = (
                url.scheme == "https"
                and url.hostname
                and not url.username
                and not url.password
                and not url.fragment
                and url.path.rsplit("/", 1)[-1] == asset["filename"]
            )
        except ValueError as error:
            raise RuntimeRefusal("metadata") from error
        if not valid:
            raise RuntimeRefusal("metadata")
    libraries = asset["runtime_libraries_sha256"]
    if not isinstance(libraries, dict) or not libraries:
        raise RuntimeRefusal("metadata")
    for name, digest in libraries.items():
        relative_name(name)
        if name in (
            contract["binary_path"],
            contract["license_path"],
            RECEIPT_BASENAME,
        ):
            raise RuntimeRefusal("metadata")
        if not isinstance(digest, str) or SHA256.fullmatch(digest) is None:
            raise RuntimeRefusal("metadata")
    return contract, asset


def receipt(contract_bytes, catalogue_bytes, host, asset):
    return {
        "schema_version": 1,
        "host": host,
        "runtime_contract_sha256": sha256(contract_bytes),
        "catalogue_sha256": sha256(catalogue_bytes),
        "asset_sha256": asset["sha256"],
        "binary_sha256": asset["binary_sha256"],
        "source_commit": asset["source_commit"],
        "capability": asset["capability"],
        "native_http_capability": asset["native_http_capability"],
    }


def verify_directory(root, contract, asset, expected_receipt=None, *, alias_context=None):
    """Require every native runtime file and in-tree link, never a capability probe alone."""
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise RuntimeRefusal("runtime")
    resolved = root.resolve(strict=True)
    expected = dict(asset["runtime_libraries_sha256"])
    expected[relative_name(contract["binary_path"])] = asset["binary_sha256"]
    allowed = set(expected) | {relative_name(contract["license_path"])}
    if expected_receipt is not None:
        allowed.add(RECEIPT_BASENAME)
    additional = set()
    if alias_context is not None:
        alias_context.validate()
        if alias_context.root != root:
            raise RuntimeRefusal("runtime")
        additional = set(alias_context.additional_files)
        if allowed.intersection(additional):
            raise RuntimeRefusal("runtime")
        allowed.update(additional)
    found = set()
    for path in root.rglob("*"):
        if path.relative_to(root).as_posix() in additional:
            found.add(path.relative_to(root).as_posix())
            continue
        try:
            actual = path.resolve(strict=True)
            actual.relative_to(resolved)
        except (ValueError, OSError) as error:
            raise RuntimeRefusal("runtime") from error
        if path.is_dir():
            continue
        if not path.is_file():
            raise RuntimeRefusal("runtime")
        name = path.relative_to(root).as_posix()
        found.add(name)
        if name not in allowed:
            raise RuntimeRefusal("runtime")
        if name in expected and sha256(path.read_bytes()) != expected[name]:
            raise RuntimeRefusal("runtime")
    if found != allowed or (root / contract["binary_path"]).is_symlink():
        raise RuntimeRefusal("runtime")
    if expected_receipt is not None:
        if metadata_bytes((root / RECEIPT_BASENAME).read_bytes()) != expected_receipt:
            raise RuntimeRefusal("runtime")
    if alias_context is not None:
        alias_context.validate()
    return root / contract["binary_path"]


def private_session(data):
    fields = {
        "version",
        "token",
        "source_commit",
        "binary_sha256",
        "asset_sha256",
        "device",
        "inode",
        "port",
    }
    if (
        not isinstance(data, dict)
        or set(data) != fields
        or type(data["version"]) is not int
        or data["version"] != 1
    ):
        raise RuntimeRefusal("session")
    for name, length in (
        ("token", 64),
        ("source_commit", 40),
        ("binary_sha256", 64),
        ("asset_sha256", 64),
    ):
        if (
            not isinstance(data[name], str)
            or re.fullmatch(r"[a-f0-9]{" + str(length) + "}", data[name]) is None
        ):
            raise RuntimeRefusal("session")
    for name in ("device", "inode", "port"):
        if (
            not isinstance(data[name], str)
            or re.fullmatch(r"0|[1-9][0-9]*", data[name]) is None
            or int(data[name]) >= 1 << 64
        ):
            raise RuntimeRefusal("session")
    if not 1024 <= int(data["port"]) <= 65535:
        raise RuntimeRefusal("session")
    return data


def authenticated_headers(session, method, path, body=b"", operation=None, challenge=None):
    session = private_session(session)
    if (method, path) not in (
        ("GET", "/api/ergopti-native-http-admission"),
        ("POST", "/api/pull"),
    ) or not isinstance(body, bytes):
        raise RuntimeRefusal("protocol")
    if operation is not None and (
        not isinstance(operation, str) or re.fullmatch(r"[a-f0-9]{32}", operation) is None
    ):
        raise RuntimeRefusal("protocol")
    if method == "POST" and operation is None:
        raise RuntimeRefusal("protocol")
    challenge = secrets.token_hex(32) if challenge is None else challenge
    if not isinstance(challenge, str) or SHA256.fullmatch(challenge) is None:
        raise RuntimeRefusal("protocol")
    digest = sha256(body)
    payload = "\n".join(
        (
            "ERGOPTI_NATIVE_AUTH_V1",
            method,
            "127.0.0.1:" + session["port"],
            path,
            digest,
            operation or "",
            challenge,
        )
    ).encode("ascii")
    proof = hmac.new(session["token"].encode("ascii"), payload, hashlib.sha256).hexdigest()
    result = [
        ("Accept-Encoding", "identity"),
        ("X-Ergopti-Native-Session", proof),
        ("X-Ergopti-Native-Challenge", challenge),
        ("X-Ergopti-Native-Body-SHA256", digest),
    ]
    if method == "POST":
        result.append(("Content-Type", "application/json"))
    if operation is not None:
        result.append(("X-Ergopti-Native-Operation", operation))
    return result, challenge


def authenticated_receipt(session, headers, payload, challenge, listener, operation=None):
    """Receive an authenticated response and actual native socket provenance."""
    session = private_session(session)
    proofs = [value for name, value in headers if name.lower() == "x-ergopti-native-proof"]
    signed = b"ERGOPTI_NATIVE_RESPONSE_V1\n" + challenge.encode("ascii") + b"\n" + payload
    expected = hmac.new(session["token"].encode("ascii"), signed, hashlib.sha256).hexdigest()
    if (
        len(proofs) != 1
        or not isinstance(proofs[0], str)
        or not hmac.compare_digest(proofs[0], expected)
    ):
        raise RuntimeRefusal("session")
    data = metadata_bytes(payload)
    fields = {
        "version",
        "capability",
        "pid",
        "source_commit",
        "binary_sha256",
        "asset_sha256",
        "device",
        "inode",
        "lease_id",
        "port",
    }
    if operation is not None:
        fields |= {
            "operation_id",
            "operation_state",
            "native_helpers",
            "background_downloads",
        }
    if (
        set(data) != fields
        or type(data["version"]) is not int
        or data["version"] != 1
        or data["capability"] != "ERGOPTI_OLLAMA_NATIVE_HTTP_V1"
        or type(data["pid"]) is not int
        or not 0 < data["pid"] < 1 << 31
        or data["pid"] != listener.get("pid")
    ):
        raise RuntimeRefusal("session")
    for name in (
        "source_commit",
        "binary_sha256",
        "asset_sha256",
        "device",
        "inode",
        "port",
    ):
        if data[name] != session[name]:
            raise RuntimeRefusal("session")
    if data["lease_id"] != sha256(session["token"].encode("ascii")):
        raise RuntimeRefusal("session")
    if data["device"] != listener.get("device") or data["inode"] != listener.get("inode"):
        raise RuntimeRefusal("session")
    if operation is not None:
        if data["operation_id"] != operation or data["operation_state"] not in (
            "active",
            "retired",
            "unknown",
        ):
            raise RuntimeRefusal("session")
        for name in ("native_helpers", "background_downloads"):
            if type(data[name]) is not int or data[name] < 0:
                raise RuntimeRefusal("session")
        if data["operation_state"] == "retired" and (
            data["native_helpers"] != 0 or data["background_downloads"] != 0
        ):
            raise RuntimeRefusal("session")
    return data
