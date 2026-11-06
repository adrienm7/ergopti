"""Authenticate the four closed worker archives without claiming semantic parity."""

import argparse
from decimal import Decimal
import gzip
import hashlib
import json
from pathlib import Path
import re

AUDITED_SHA = "f2c3ea43542c985fb20e5f0887976f1c02525341"
ROLES = ("windows", "macos", "linux", "shared")
REQUIRED = {"report.md", "findings.json", "coverage.json", "source-receipts.json"}


def require(condition, message):
    """Keep custody checks enabled even under optimized Python."""
    if not condition:
        raise ValueError(message)


def member(directory, relative):
    """Resolve a canonical relative file without symlink or traversal hops."""
    require(
        isinstance(relative, str) and relative and "\\" not in relative and ":" not in relative,
        "artifact path",
    )
    path = Path(relative)
    require(
        not path.is_absolute() and ".." not in path.parts and path.as_posix() == relative,
        "noncanonical artifact path",
    )
    current = directory
    for part in path.parts:
        current = current / part
        require(not current.is_symlink(), "symlink artifact")
    require(current.is_file(), "missing artifact: " + relative)
    return current


def typed_json(raw):
    """Compare JSON values without confusing booleans and numeric values."""

    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate JSON key in format alias")
            result[key] = value
        return result

    def nonfinite(value):
        raise ValueError("nonfinite JSON constant in format alias: " + value)

    def typed(value):
        if value is None:
            return ("null",)
        if type(value) is bool:
            return ("boolean", value)
        if isinstance(value, Decimal):
            return ("number", value, value.is_zero() and value.is_signed())
        if isinstance(value, str):
            return ("string", value)
        if isinstance(value, list):
            return ("array", tuple(typed(item) for item in value))
        return ("object", tuple((key, typed(item)) for key, item in sorted(value.items())))

    return typed(
        json.loads(
            raw,
            object_pairs_hook=pairs,
            parse_int=Decimal,
            parse_float=Decimal,
            parse_constant=nonfinite,
        )
    )


def format_aliases(directory):
    """Read only explicit lossless JSON-format mappings outside worker archives."""
    relative = "validation/worker-format-provenance.json"
    if not (directory / relative).exists():
        return {}, None
    path = member(directory, relative)
    document = json.loads(path.read_bytes())
    require(document.get("audited_sha") == AUDITED_SHA, "wrong format provenance pin")
    transforms = document.get("transforms")
    require(isinstance(transforms, list), "format transforms shape")
    result = {}
    for item in transforms:
        require(isinstance(item, dict), "format transform shape")
        role, artifact = item.get("role"), item.get("path")
        require(
            role in ROLES and isinstance(artifact, str) and artifact.endswith(".json"),
            "format transform target",
        )
        require(item.get("kind") == "json-format", "unsupported archive transform")
        key = (role, artifact)
        require(key not in result, "duplicate format transform")
        original = item.get("original_copy")
        require(
            isinstance(original, str) and original.startswith("validation/worker-originals/"),
            "format original location",
        )
        original_raw = member(directory, original).read_bytes()
        current_raw = member(directory / role, artifact).read_bytes()
        require(
            hashlib.sha256(original_raw).hexdigest() == item.get("original_sha256"),
            "format original hash mismatch",
        )
        require(
            hashlib.sha256(current_raw).hexdigest() == item.get("current_sha256"),
            "formatted artifact hash mismatch",
        )
        require(
            typed_json(original_raw) == typed_json(current_raw),
            "JSON values/types changed by archive transform",
        )
        result[key] = item
    return result, {"path": relative, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def encoding_aliases(directory):
    """Decode only explicitly declared lossless gzip custody members."""
    relative = "validation/worker-encoding-provenance.json"
    if not (directory / relative).exists():
        return {}, None
    path = member(directory, relative)
    document = json.loads(path.read_bytes())
    require(document.get("audited_sha") == AUDITED_SHA, "wrong encoding provenance pin")
    require(isinstance(document.get("encodings"), list), "encoding list shape")
    result = {}
    storage_paths = set()
    for item in document["encodings"]:
        role, artifact = item.get("role"), item.get("path")
        require(role in ROLES and isinstance(artifact, str), "encoding target")
        target = Path(artifact)
        require(
            not target.is_absolute()
            and ".." not in target.parts
            and target.as_posix() == artifact
            and "\\" not in artifact
            and ":" not in artifact,
            "encoding artifact path",
        )
        require(item.get("codec") == "gzip", "unsupported archive codec")
        key = (role, artifact)
        require(key not in result, "duplicate encoding target")
        storage = item.get("storage")
        require(
            isinstance(storage, str)
            and storage.startswith("validation/worker-originals/")
            and storage not in storage_paths,
            "encoding storage collision/location",
        )
        raw = member(directory, storage).read_bytes()
        require(
            hashlib.sha256(raw).hexdigest() == item.get("storage_sha256"),
            "encoded storage hash mismatch",
        )
        decoded = gzip.decompress(raw)
        require(
            hashlib.sha256(decoded).hexdigest() == item.get("decoded_sha256"),
            "decoded artifact hash mismatch",
        )
        require(not (directory / role / artifact).exists(), "encoded artifact physical collision")
        result[key] = item
        storage_paths.add(storage)
    return result, {"path": relative, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def authenticate(directory):
    """Require every archived byte to be listed in its pinned worker envelope."""
    roles = []
    aliases, provenance = format_aliases(directory)
    encodings, encoding_provenance = encoding_aliases(directory)
    require(not (set(aliases) & set(encodings)), "archive alias collision")
    used_encodings = set()
    used_aliases = set()
    for role in ROLES:
        archive = directory / role
        require(not archive.is_symlink(), "symlink role archive")
        handoff = member(archive, "handoff.json")
        raw = handoff.read_bytes()
        manifest = json.loads(raw)
        require(manifest.get("audited_sha") == AUDITED_SHA, "wrong handoff source pin")
        files = manifest.get("files")
        require(isinstance(files, list) and files, "empty handoff")
        seen = set()
        checked = []
        for item in files:
            require(isinstance(item, dict), "handoff artifact shape")
            relative, expected = item.get("path"), item.get("sha256")
            require(isinstance(relative, str), "artifact path")
            require(
                relative != "handoff.json" and relative not in seen,
                "duplicate/self handoff artifact",
            )
            require(
                isinstance(expected, str) and re.fullmatch(r"[0-9a-f]{64}", expected),
                "artifact digest",
            )
            encoded = encodings.get((role, relative))
            if encoded is not None:
                require(
                    encoded["decoded_sha256"] == expected,
                    "worker hash differs from decoded artifact",
                )
                used_encodings.add((role, relative))
                seen.add(relative)
                checked.append(
                    {
                        "path": relative,
                        "sha256": expected,
                        "resolution": encoded["storage"],
                        "codec": encoded["codec"],
                    }
                )
                continue
            file = member(archive, relative)
            current = hashlib.sha256(file.read_bytes()).hexdigest()
            alias = aliases.get((role, relative))
            if alias is None:
                require(current == expected, "artifact hash mismatch: " + relative)
                checked.append({"path": relative, "sha256": expected, "resolution": "current"})
            else:
                require(
                    alias["original_sha256"] == expected,
                    "worker hash differs from original format alias",
                )
                used_aliases.add((role, relative))
                checked.append(
                    {
                        "path": relative,
                        "sha256": expected,
                        "current_sha256": current,
                        "resolution": alias["original_copy"],
                    }
                )
            seen.add(relative)
        require(REQUIRED <= seen, "missing required role artifacts")
        actual = set()
        for path in archive.rglob("*"):
            require(not path.is_symlink(), "unlisted symlink artifact")
            if path.is_file():
                actual.add(path.relative_to(archive).as_posix())
        encoded_paths = {path for encoded_role, path in encodings if encoded_role == role}
        require(
            actual == (seen - encoded_paths) | {"handoff.json"},
            "unlisted/missing archived artifact",
        )
        roles.append(
            {"role": role, "handoff_sha256": hashlib.sha256(raw).hexdigest(), "artifacts": checked}
        )
    require(used_aliases == set(aliases), "unused archive format alias")
    require(used_encodings == set(encodings), "unused archive encoding alias")
    return {
        "encoding_provenance": encoding_provenance,
        "format_provenance": provenance,
        "audited_sha": AUDITED_SHA,
        "qualification": "Four closed worker archives only. Artifact identity is not source authentication, assertion adequacy, semantic parity or native receiving.",
        "roles": roles,
    }


def main():
    """Write an external custody receipt, preserving each worker archive."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    directory = args.directory.resolve()
    output = args.output.resolve()
    require(not args.output.is_symlink(), "output symlink")
    require(
        not any(output.is_relative_to(directory / role) for role in ROLES),
        "output inside frozen role archive",
    )
    require(output != Path(__file__).resolve(), "output overwrites program")
    receipt = authenticate(directory)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(receipt, indent="\t") + "\n", encoding="utf-8")
    print(
        "Authenticated 4 worker archives and "
        + str(sum(len(r["artifacts"]) for r in receipt["roles"]))
        + " listed artifact hashes."
    )


if __name__ == "__main__":
    main()
