"""Project canonical role IDs into signed fixed service policy; grants no authority."""

import argparse
import ast
import hashlib
import json
from pathlib import Path
import sys

_ROOT = Path(__file__).resolve().parents[2]
_DATA = _ROOT / "static/ergopti_plus/_shared/data"
_ROLES = ("core", "console", "cli")
_SERVICE_KEYS = {
    "role",
    "label",
    "plist",
    "bundle",
    "executable_relative",
    "run_at_load",
    "keep_alive",
    "user_name",
}


class ReferenceRefusal(ValueError):
    """A malformed projection never supplies code, service or consent authority."""


def _require(condition):
    if not condition:
        raise ReferenceRefusal("Owned runtime service reference refused")


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result)
        result[key] = value
    return result


def _path(value, *, absolute):
    _require(isinstance(value, str) and value and "\0" not in value)
    _require(value.startswith("/") == absolute)
    parts = value[1:].split("/") if absolute else value.split("/")
    _require(all(part and part not in (".", "..") for part in parts))


def build_reference(policy_bytes, identities_source):
    """Read literal IDs without executing the existing namespace provider."""
    _require(isinstance(policy_bytes, bytes) and isinstance(identities_source, bytes))
    _require(len(policy_bytes) <= 65_536 and len(identities_source) <= 8_388_608)
    try:
        policy = json.loads(policy_bytes, object_pairs_hook=_unique_object)
        module = ast.parse(identities_source)
        definitions = [
            node.value
            for node in module.body
            if isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name) and target.id == "OWNED_PRODUCT_IDENTIFIERS"
                for target in node.targets
            )
        ]
        _require(len(definitions) == 1)
        identifiers = ast.literal_eval(definitions[0])
    except (SyntaxError, ValueError, TypeError, UnicodeDecodeError, RecursionError) as error:
        raise ReferenceRefusal("Owned runtime service reference refused") from error
    _require(isinstance(policy, dict) and set(policy) == {"schema", "roles", "service"})
    _require(type(policy["schema"]) is int and policy["schema"] == 1)
    _require(policy["roles"] == list(_ROLES))
    _require(isinstance(identifiers, tuple) and len(identifiers) == len(_ROLES))
    _require(all(isinstance(pair, tuple) and len(pair) == 2 for pair in identifiers))
    _require(tuple(pair[0] for pair in identifiers) == _ROLES)
    _require(
        all(
            isinstance(value, str) and value and "\0" not in value
            for pair in identifiers
            for value in pair
        )
    )
    _require(len({pair[1] for pair in identifiers}) == len(_ROLES))
    service = policy["service"]
    _require(isinstance(service, dict) and set(service) == _SERVICE_KEYS)
    _require(service["role"] == "core" and service["user_name"] == "root")
    _require(
        isinstance(service["label"], str)
        and service["label"]
        and all(
            character.isascii() and (character.isalnum() or character in ".-_")
            for character in service["label"]
        )
    )
    _require(
        service["label"].startswith("com.ergoptiplus.")
        and service["label"] not in dict(identifiers).values()
    )
    for key in ("plist", "bundle"):
        _path(service[key], absolute=True)
    _path(service["executable_relative"], absolute=False)
    _require(
        service["plist"].startswith("/Library/LaunchDaemons/")
        and service["plist"].endswith(".plist")
    )
    _require(
        service["bundle"].startswith("/Library/Application Support/ErgoptiPlus/Runtime/")
        and service["bundle"].endswith(".app")
    )
    _require(
        service["executable_relative"].startswith("Contents/MacOS/")
        and service["executable_relative"].count("/") == 2
    )
    _require(service["run_at_load"] is False and service["keep_alive"] is False)
    return {
        "schema": 1,
        "roles": policy["roles"],
        "service": service,
        "runtime_identifiers": dict(identifiers),
        "policy_sha256": hashlib.sha256(policy_bytes).hexdigest(),
        "identities_source_sha256": hashlib.sha256(identities_source).hexdigest(),
    }


def _reference_bytes(reference):
    """Match repository JSON tabs and the compact, fixed three-role array."""
    rendered = json.dumps(reference, indent="\t", ensure_ascii=True)
    expanded_roles = json.dumps(list(_ROLES), indent="\t").replace("\n", "\n\t")
    _require(rendered.count(expanded_roles) == 1)
    return (rendered.replace(expanded_roles, json.dumps(list(_ROLES)), 1) + "\n").encode()


def main(arguments=None):
    """Generate only the separate reference, or refuse a stale artifact without edits."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, default=_DATA / "owned_runtime_service_policy.json")
    parser.add_argument(
        "--identities-source", type=Path, default=_ROOT / "tools/build/remap_runtime_patch.py"
    )
    parser.add_argument(
        "--output", type=Path, default=_DATA / "owned_runtime_service_reference.generated.json"
    )
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args(arguments)
    try:
        reference = build_reference(
            options.policy.read_bytes(), options.identities_source.read_bytes()
        )
        expected = _reference_bytes(reference)
        if options.check:
            _require(options.output.read_bytes() == expected)
        else:
            options.output.write_bytes(expected)
    except (OSError, ReferenceRefusal):
        print("Owned runtime service reference refused", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
