# tools/diagnostics/hs_script_scope_probe.py
"""Judge isolated actual SDK and Script participant receipts, never desktop input."""

import math
import re

from hs_delayed_timer_probe import CONTRACT as TIMER_CONTRACT

CONTRACT = "script.scope-native"
CLAIM_CONTRACT = "script.scope-claim"
IDENTITY_FIELDS = {
    "schema_version",
    "contract",
    "nonce",
    "pid",
    "executable",
    "bundle_id",
    "version",
}
FLAGS = {
    "sdk_void_set",
    "sdk_readback",
    "sdk_clear",
    "participant_applied",
    "participant_reverted",
    "source_restored",
    "native_aliases_restored",
    "runtime_restored",
    "complete",
}
VIEW_FIELDS = {"locale", "locale_backend", "log_level", "error_dialog"}


def identity(result, contract, nonce, pid, executable, bundle_id):
    expected = {
        "schema_version": 1,
        "contract": contract,
        "nonce": nonce,
        "pid": pid,
        "executable": str(executable),
        "bundle_id": bundle_id,
        "version": TIMER_CONTRACT["runtime_version"],
    }
    if not isinstance(result, dict):
        raise ValueError("The native script receipt is not an object")
    for key, value in expected.items():
        if type(result.get(key)) is not type(value) or result.get(key) != value:
            raise ValueError("The native script identity differs: " + key)
    if (
        type(nonce) is not str
        or not re.fullmatch(r"[0-9a-f]{32}", nonce)
        or type(pid) is not int
        or pid <= 0
    ):
        raise ValueError("The native script admission identity is invalid")


def scalar(value):
    return type(value) is bool or type(value) is str and 0 < len(value) <= 128 and "\0" not in value


def view(value):
    if not isinstance(value, dict) or set(value) != VIEW_FIELDS:
        raise ValueError("The native script runtime view is incomplete")
    if (
        not all(
            type(value[key]) is str and scalar(value[key]) for key in ("locale", "locale_backend")
        )
        or value["locale"] != value["locale_backend"]
    ):
        raise ValueError("The actual locale consumer differs from its backend")
    if (
        type(value["log_level"]) not in (int, float)
        or not math.isfinite(value["log_level"])
        or type(value["error_dialog"]) is not bool
    ):
        raise ValueError("The actual native scalar consumer view is invalid")


def validate_receipt(result, nonce, pid, executable, bundle_id):
    identity(result, CONTRACT, nonce, pid, executable, bundle_id)
    if set(result) != IDENTITY_FIELDS | FLAGS | {"errors", "aliases", "runtime_views"}:
        raise ValueError("The native script measurement has unknown or missing fields")
    if any(result[key] is not True for key in FLAGS) or result["errors"] != []:
        raise ValueError("The native script SDK or participant did not settle")
    aliases = result["aliases"]
    if type(aliases) is not list or not 0 < len(aliases) <= 16:
        raise ValueError("The native script alias cohort is not bounded and nonempty")
    paths, keys = set(), set()
    for index, row in enumerate(aliases, 1):
        expected_alias = f"scope_probe.{nonce}.alias_{index}"
        if (
            not isinstance(row, dict)
            or set(row) != {"path", "alias", "key", "publication"}
            or row["alias"] != expected_alias
            or row["key"] != "ergopti." + expected_alias
        ):
            raise ValueError("The native script alias is not its exact private declaration")
        if (
            type(row["path"]) is not str
            or not re.fullmatch(r"script\.[a-z][a-z0-9_]*", row["path"])
            or row["path"] in paths
            or row["key"] in keys
        ):
            raise ValueError("The native script alias repeats or changes its declared path")
        cell = row["publication"]
        if (
            not isinstance(cell, dict)
            or set(cell) != {"present", "value"}
            or cell["present"] is not True
            or not scalar(cell["value"])
        ):
            raise ValueError("The native script planned scalar is invalid")
        paths.add(row["path"])
        keys.add(row["key"])
    views = result["runtime_views"]
    if not isinstance(views, dict) or set(views) != {"before", "applied", "restored"}:
        raise ValueError("The native script inverse has no complete runtime witnesses")
    for observed in views.values():
        view(observed)
    if views["before"] != views["restored"] or any(
        type(views["before"][key]) is not type(views["restored"][key]) for key in VIEW_FIELDS
    ):
        raise ValueError("The native script participant did not restore its exact consumers")
    return {
        "contract": CONTRACT,
        "runtime": "native Hammerspoon",
        "publication_scope": "private-file-and-nonce-settings-only",
        "alias_count": len(aliases),
        "sdk_void_set": True,
        "sdk_clear": True,
        "participant_inverse": True,
        "nonce": nonce,
        "pid": pid,
        "executable": str(executable),
    }


def validate_claim(result, nonce, pid, executable, bundle_id):
    identity(result, CLAIM_CONTRACT, nonce, pid, executable, bundle_id)
    if (
        set(result) != IDENTITY_FIELDS | {"entries"}
        or type(result["entries"]) is not list
        or not 2 <= len(result["entries"]) <= 17
    ):
        raise ValueError("The private native settings claim is incomplete")
    entries, seen = [], set()
    prefix = f"ergopti.scope_probe.{nonce}."
    for row in result["entries"]:
        if (
            not isinstance(row, dict)
            or set(row) != {"key", "before", "allowed_values"}
            or type(row["key"]) is not str
            or not row["key"].startswith(prefix)
        ):
            raise ValueError("The private native settings claim contains a foreign key")
        suffix = row["key"][len(prefix) :]
        if (
            suffix != "sdk_primitive"
            and not re.fullmatch(r"alias_[1-9][0-9]*", suffix)
            or row["key"] in seen
        ):
            raise ValueError("The private native settings claim repeats or changes a key")
        if row["before"] != {"present": False} or type(row["before"].get("present")) is not bool:
            raise ValueError("The private native settings claim was not initially absent")
        values = row["allowed_values"]
        if type(values) is not list or len(values) != 1 or not scalar(values[0]):
            raise ValueError("The private native settings claim has no exact offered scalar")
        if suffix == "sdk_primitive" and values != [nonce]:
            raise ValueError("The private SDK primitive has a foreign offered value")
        seen.add(row["key"])
        entries.append(row)
    expected = {prefix + "sdk_primitive"} | {
        prefix + f"alias_{index}" for index in range(1, len(entries))
    }
    if seen != expected:
        raise ValueError("The private native settings claim is not its dense exact cohort")
    return entries


def recover_claim(entries, domain, reader, runner, timeout):
    """Clear only exact offered unique keys after the native process has retired.

    This uses the existing cooperating native-preference boundary; defaults has
    no atomic multi-key cross-process compare-and-swap. Foreign values refuse.
    """
    for row in entries:
        current = reader.read_domain()
        key = row["key"]
        if key not in current:
            continue
        if not any(
            type(current[key]) is type(value) and current[key] == value
            for value in row["allowed_values"]
        ):
            raise RuntimeError("A foreign private settings value refuses conditional cleanup")
        removed = runner(
            ["/usr/bin/defaults", "delete", domain, key], capture_output=True, timeout=timeout
        )
        if removed.returncode or key in reader.read_domain():
            raise RuntimeError("The exact private settings cleanup was not acknowledged")
    if any(row["key"] in reader.read_domain() for row in entries):
        raise RuntimeError("The private settings cohort did not settle")


def require_summary(result, executable, bundle_id, bootstrap_contract, qualification):
    """Require the closed native measurement and both physical cleanup receipts."""
    fields = {
        "schema_version",
        "contract",
        "feature",
        "qualification",
        "admission",
        "identity",
        "measurement",
        "cleanup_acknowledged",
        "process_retired",
        "preference_restored",
    }
    if type(result) is not dict or set(result) != fields:
        raise ValueError("The required native Script summary is incomplete")
    if (
        type(result["schema_version"]) is not int
        or result["schema_version"] != 1
        or result["contract"] != bootstrap_contract
        or result["feature"] != "script_scope"
        or result["qualification"] != qualification
        or result["admission"] != "owned startup file"
    ):
        raise ValueError("The required native Script summary has a foreign contract")
    if any(
        result[key] is not True
        for key in ("cleanup_acknowledged", "process_retired", "preference_restored")
    ):
        raise ValueError("The required native Script summary has cleanup debt")
    observed = result["identity"]
    if (
        type(observed) is not dict
        or set(observed) != IDENTITY_FIELDS | {"phase"}
        or observed["phase"] != "ready"
    ):
        raise ValueError("The required native Script process identity is incomplete")
    identity(
        observed, bootstrap_contract, observed["nonce"], observed["pid"], executable, bundle_id
    )
    measured = result["measurement"]
    fields = {
        "contract",
        "runtime",
        "publication_scope",
        "alias_count",
        "sdk_void_set",
        "sdk_clear",
        "participant_inverse",
        "nonce",
        "pid",
        "executable",
    }
    if type(measured) is not dict or set(measured) != fields:
        raise ValueError("The required native Script measurement is incomplete")
    expected = {
        "contract": CONTRACT,
        "runtime": "native Hammerspoon",
        "publication_scope": "private-file-and-nonce-settings-only",
        "nonce": observed["nonce"],
        "pid": observed["pid"],
        "executable": str(executable),
    }
    if any(
        type(measured.get(key)) is not type(value) or measured.get(key) != value
        for key, value in expected.items()
    ):
        raise ValueError("The required native Script measurement identity differs")
    if (
        type(measured["alias_count"]) is not int
        or not 0 < measured["alias_count"] <= 16
        or any(
            measured[key] is not True
            for key in ("sdk_void_set", "sdk_clear", "participant_inverse")
        )
    ):
        raise ValueError("The required native Script SDK or inverse did not qualify")
    return result
