# _shared/python/managed_ollama_hint.py
"""Provisional catalogue selection only; no source, signing or process authority."""

import re


def budgets(policy, raw):
    """Receive the existing retry owner constants without duplicating their values."""
    if type(raw) is not bytes or len(raw) > policy.MAXIMUM_METADATA_BYTES:
        raise policy.RuntimeRefusal("metadata")
    try:
        text = raw.decode("utf-8")
    except UnicodeError:
        raise policy.RuntimeRefusal("metadata") from None
    result = {}
    for key, name in (
        ("admission", "CURL_CONNECT_TIMEOUT_SEC"),
        ("idle", "CURL_STALL_SEC"),
        ("retirement", "CURL_MAX_TIME_SEC"),
    ):
        found = re.findall(r"^" + name + r"=([^\n]*)$", text, re.MULTILINE)
        if len(found) != 1 or len(found[0]) > 16 or re.fullmatch(r"[1-9][0-9]*", found[0]) is None:
            raise policy.RuntimeRefusal("metadata")
        value = int(found[0])
        if value > 9007199254740991:
            raise policy.RuntimeRefusal("metadata")
        result[key] = value
    return result


def candidate(policy, contract_bytes, catalogue_bytes, installed_bytes, host):
    """Match exact current public metadata; native verification remains mandatory."""
    contract, asset = policy.select_asset(contract_bytes, catalogue_bytes, host)
    installed = policy.metadata_bytes(installed_bytes)
    expected = policy.receipt(contract_bytes, catalogue_bytes, host, asset)
    if installed != expected or any(
        type(installed[key]) is not type(expected[key]) for key in expected
    ):
        raise policy.RuntimeRefusal("metadata")
    binary = policy.relative_name(contract["binary_path"])
    if "/" in binary:
        raise policy.RuntimeRefusal("metadata")
    return binary


def canonical_budgets(policy, raw):
    data = policy.metadata_bytes(raw)
    if (
        set(data) != {"schema_version", "admission_seconds", "idle_seconds", "retirement_seconds"}
        or type(data["schema_version"]) is not int
        or data["schema_version"] != 1
    ):
        raise policy.RuntimeRefusal("metadata")
    result = {}
    for field, key in (
        ("admission_seconds", "admission"),
        ("idle_seconds", "idle"),
        ("retirement_seconds", "retirement"),
    ):
        value = data[field]
        if type(value) is not int or not 0 < value <= 9007199254740991:
            raise policy.RuntimeRefusal("metadata")
        result[key] = value
    return result
