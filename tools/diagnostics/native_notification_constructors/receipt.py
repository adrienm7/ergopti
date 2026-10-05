# tools/diagnostics/native_notification_constructors/receipt.py
"""Closed constructor-only observations; no delivery or click qualification."""

import json
import re

CONTRACT = "macos-native-application-notification-constructors"
CASES = (
    "authenticated_native_notify_runtime",
    "exact_source_pins_before",
    "native_callback_caption_body_options",
    "native_nil_callback_empty_label",
    "native_default_label_and_payload",
    "callback_registry_preserves_exact_function",
    "owned_callback_unregister_readback",
    "constructor_only_no_delivery",
    "exact_source_pins_after",
)
SCOPE = {
    "constructor_only": True,
    "notification_delivery": False,
    "callback_invocation": False,
    "gc_native_destruction_verified": False,
    "user_configuration_modified": False,
}
LIMIT = 32768


def require(condition, category):
    if condition is not True:
        raise ValueError(category)


def decode(raw):
    require(type(raw) is bytes and 0 < len(raw) <= LIMIT, "receipt_size_refused")

    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, "duplicate_receipt_key")
            value[key] = item
        return value

    return json.loads(raw.decode("utf-8"), object_pairs_hook=unique)


def validate(value, sha, nonce, pid, hashes):
    require(
        type(value) is dict
        and set(value)
        == {
            "schema",
            "contract",
            "source_sha",
            "nonce",
            "pid",
            "source_hashes",
            "cases",
            "counts",
            "scope",
            "forbidden_attempts",
            "callback_invocations",
            "owned_tags_remaining",
            "input_properties_unchanged",
        },
        "receipt_fields_refused",
    )
    require(type(value["schema"]) is int and value["schema"] == 1, "receipt_schema_refused")
    require(value["contract"] == CONTRACT, "receipt_contract_refused")
    require(
        re.fullmatch(r"[0-9a-f]{40}", sha) is not None
        and re.fullmatch(r"[0-9a-f]{32}", nonce) is not None,
        "expected_identity_refused",
    )
    require(value["source_sha"] == sha and value["nonce"] == nonce, "receipt_stale")
    require(type(value["pid"]) is int and value["pid"] == pid and pid > 0, "receipt_owner_refused")
    require(
        type(hashes) is dict
        and bool(hashes)
        and all(
            type(key) is str and type(digest) is str and re.fullmatch(r"[0-9a-f]{64}", digest)
            for key, digest in hashes.items()
        )
        and value["source_hashes"] == hashes,
        "receipt_sources_refused",
    )
    require(
        type(value["scope"]) is dict and set(value["scope"]) == set(SCOPE), "receipt_scope_refused"
    )
    for key, expected in SCOPE.items():
        require(
            type(value["scope"][key]) is bool and value["scope"][key] is expected,
            "receipt_scope_refused",
        )
    require(
        type(value["cases"]) is list and len(value["cases"]) == len(CASES), "receipt_census_refused"
    )
    for actual, expected in zip(value["cases"], CASES):
        require(
            type(actual) is dict
            and set(actual) == {"id", "status"}
            and actual["id"] == expected
            and actual["status"] == "passed",
            "native_case_failed",
        )
    require(
        type(value["counts"]) is dict
        and set(value["counts"]) == {"passed", "failed", "skipped"}
        and all(type(count) is int for count in value["counts"].values())
        and value["counts"] == {"passed": 9, "failed": 0, "skipped": 0},
        "receipt_counts_refused",
    )
    for key in ("forbidden_attempts", "callback_invocations", "owned_tags_remaining"):
        require(type(value[key]) is int and value[key] == 0, "constructor_scope_refused")
    require(value["input_properties_unchanged"] is True, "constructor_payload_refused")
    return 9
