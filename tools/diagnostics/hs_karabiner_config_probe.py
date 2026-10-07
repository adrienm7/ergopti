# tools/diagnostics/hs_karabiner_config_probe.py
"""Judge real packaged JSON generation and publication in one private file."""

import itertools
import json
from pathlib import Path
import re

from hs_delayed_timer_probe import (
    NativeDelayedTimerProbe,
    CONTRACT as TIMER_CONTRACT,
    unique_object,
)

CONTRACT = json.loads(Path(__file__).with_name("hs_karabiner_config_contract.json").read_text())
USER_RULE = {
    "description": "Private native qualification user rule",
    "manipulators": [{"type": "basic", "from": {"key_code": "f23"}, "to": [{"key_code": "f24"}]}],
}
INITIAL_CONFIG = {
    "global": {"show_in_menu_bar": False},
    "profiles": [
        {
            "name": name,
            "selected": selected,
            "complex_modifications": {
                "parameters": {"basic.to_if_alone_timeout_milliseconds": 913},
                "rules": [USER_RULE],
            },
        }
        for name, selected in (("Work", False), ("Default", True))
    ],
}
VARIANTS = list(itertools.product(CONTRACT["presets"], CONTRACT["switches"], CONTRACT["switches"]))
IDENTITY_FIELDS = {
    "schema_version",
    "contract",
    "nonce",
    "pid",
    "executable",
    "bundle_id",
    "version",
}
RECEIPT_FIELDS = IDENTITY_FIELDS | {
    "publication_scope",
    "complete",
    "lease_initialized",
    "private_source_restored",
    "codec_independent",
    "native_equal_values_shared",
    "variants",
    "errors",
}
SUMMARY_FIELDS = set(CONTRACT["summary_fixed"]) | {
    "version",
    "nonce",
    "pid",
    "executable",
    "variant_count",
    "manipulator_count",
}


NATIVE_FAILURE_FLAGS = (
    "complete",
    "lease_initialized",
    "private_source_restored",
    "codec_independent",
    "native_equal_values_shared",
)
NATIVE_FAILURE_ERROR_LIMIT = 4
NATIVE_FAILURE_INPUT_LIMIT = 2048


def native_merge_refusal_code(detail):
    """Project exact generator refusal boundaries into closed public diagnostic codes.

    These are observations, never admission or recovery authority. No arbitrary
    source/provider text, profile label, description, path or rule payload escapes.
    """
    constants = {
        "karabiner output path must be a non-empty string": "destination_invalid",
        "generated config must be a table": "generated_profile_shape",
        "generated config must contain profiles": "generated_profile_shape",
        "generated selected profile must contain complex_modifications.rules": "generated_complex_rules",
        "generated managed rules must be a dense array": "generated_rules_array",
        "generated managed rules must use one generation token": "generated_token_cohort",
        "legacy rule fingerprints must be a dense array": "legacy_fingerprint_array",
        "existing karabiner.json is not valid JSON": "source_json_invalid",
        "existing config must be a table": "existing_profile_shape",
        "existing config must contain profiles": "existing_profile_shape",
        "legacy migration context must be a table": "legacy_context_type",
        "legacy migration context requires a shared data directory": "legacy_context_data",
        "legacy migration context requires a non-canonical combo set": "legacy_context_combos",
        "legacy migration context requires three script-control slots": "legacy_context_slots",
        "legacy migration context requires the historical physical-key log path": "legacy_context_log",
        "legacy migration context requires static rule anchors": "legacy_context_anchors",
        "legacy migration context has incomplete static rule anchors": "legacy_context_anchors",
        "legacy action catalogue has a missing or duplicate id": "legacy_action_identity",
        "legacy combo catalogue has a missing or duplicate id": "legacy_combo_identity",
        "multiple historical ErgoptiPlus blocks match": "legacy_graph_ambiguous",
    }
    if detail in constants:
        return constants[detail]
    # Only these exact producer prefixes have an opaque native/provider suffix.
    # Retain the boundary, not any byte of that suffix.
    for prefix, code in (
        ("existing karabiner.json read raised: ", "source_read_raised"),
        ("existing karabiner.json could not be read: ", "source_read_refused"),
    ):
        if detail.startswith(prefix):
            return code
    number = r"[1-9][0-9]{0,5}"
    count = r"(?:0|[1-9][0-9]{0,5})"
    patterns = (
        (rf"generated profile {number} must be a table", "generated_profile_shape"),
        (
            rf"generated config must contain exactly one selected profile, found {count}",
            "generated_profile_selection",
        ),
        (rf"existing profile {number} must be a table", "existing_profile_shape"),
        (
            rf"existing config must contain exactly one selected profile, found {count}",
            "existing_profile_selection",
        ),
        (rf"generated rule {number} must be a table", "generated_rule_type"),
        (rf"generated rule {number} lacks an exact managed tag", "generated_rule_tag"),
        (rf"generated rule {number} must contain manipulators", "generated_rule_manipulators"),
        (
            rf"generated rule {number} manipulator {number} lacks managed conditions",
            "generated_conditions_missing",
        ),
        (
            rf"generated rule {number} manipulator {number} contains an invalid condition",
            "generated_condition_type",
        ),
        (
            rf"generated rule {number} manipulator {number} contains a foreign runtime condition",
            "generated_condition_cohort",
        ),
        (
            rf"generated rule {number} manipulator {number} contains a foreign managed condition",
            "generated_condition_namespace",
        ),
        (
            rf"existing profile {number} complex_modifications must be a table",
            "existing_complex_type",
        ),
        (
            rf"existing profile {number} complex_modifications.rules must be a table",
            "existing_rules_array",
        ),
        (
            rf"legacy rule fingerprint {number} must have a non-empty description",
            "legacy_fingerprint_description",
        ),
        (rf"legacy rule fingerprint {number} must be untagged", "legacy_fingerprint_tag"),
        (
            rf"legacy rule fingerprint {number} must contain manipulators",
            "legacy_fingerprint_manipulators",
        ),
        (
            rf"legacy rule fingerprint {number} manipulator {number} is malformed",
            "legacy_fingerprint_graph",
        ),
        (
            rf"legacy rule fingerprint {number} manipulator {number} contains a managed condition",
            "legacy_fingerprint_condition",
        ),
        (
            r"legacy (?:action|tap/hold|combo) catalogue must be a dense array",
            "legacy_catalogue_array",
        ),
        (
            rf"legacy (?:action|tap/hold|combo) catalogue item {number} lacks a non-empty label",
            "legacy_catalogue_label",
        ),
    )
    for pattern, code in patterns:
        if re.fullmatch(pattern, detail):
            return code
    # These producer envelopes wrap private runtime references and variables.
    # Report the public refusal boundary without projecting any wrapped bytes.
    if re.match(rf"generated rule {number} manipulator {number}: ", detail):
        return "generated_runtime_references"
    if re.fullmatch(
        rf"legacy rule fingerprint {number} contains managed variable '[^\r\n]+' at [^\r\n]+",
        detail,
    ):
        return "legacy_fingerprint_variable"
    # A description/key is intentionally opaque, including quotes and colons.
    # Its producer envelope is all the diagnostic is allowed to acknowledge.
    if re.match(rf"{number} ambiguous legacy ErgoptiPlus rules?: ", detail):
        return "legacy_signature_conflict"
    if re.fullmatch(
        r"legacy (?:action|tap/hold|combo) catalogue has duplicate label '[^\r\n]*'", detail
    ):
        return "legacy_catalogue_duplicate"
    return None


def native_failure_error(value):
    """Expose only public probe stages or fixed messages, never arbitrary Lua text."""
    if type(value) is not str:
        return "unclassified native error omitted"
    # The native xpcall traceback starts with a source location and its primary
    # assertion. Do not retain that location, subsequent frames or unowned data.
    first = value[:NATIVE_FAILURE_INPUT_LIMIT].splitlines()[0] if value else ""
    first = re.sub(r"^.*:[0-9]+: ", "", first, count=1)
    for message in (
        "Equal native JSON values did not become independent trees",
        "The actual merge source receipt differs",
        "Identical native rules were not confirmed unchanged",
    ):
        if first == message:
            return message
    for stage in (
        "Native rule build refused",
        "Native merge refused",
        "Native publication refused",
        "Owned source restoration refused",
    ):
        prefix = stage + ": "
        if first.startswith(prefix):
            detail = first[len(prefix) :]
            if re.fullmatch(
                r"generated rule [1-9][0-9]{0,5} manipulator [1-9][0-9]{0,5} "
                r"has inconsistent managed conditions",
                detail,
            ):
                return prefix + detail
            if stage == "Native merge refused":
                code = native_merge_refusal_code(detail)
                if code is not None:
                    return stage + " [" + code + "]"
            return stage + " (detail omitted)"
    return "unclassified native error omitted"


def native_failure_summary(result):
    """Describe an identity-admitted refusal without walking any configuration."""
    errors = result["errors"]
    variants = result["variants"]
    error_count = len(errors) if type(errors) is list else "invalid"
    return json.dumps(
        {
            "variant_count": len(variants) if type(variants) is list else "invalid",
            "variant_expected": len(VARIANTS),
            "error_count": error_count,
            "flags": {
                key: result[key] if type(result[key]) is bool else "invalid"
                for key in NATIVE_FAILURE_FLAGS
            },
            "errors": [native_failure_error(value) for value in errors[:NATIVE_FAILURE_ERROR_LIMIT]]
            if type(errors) is list
            else [],
            "errors_omitted": max(0, error_count - NATIVE_FAILURE_ERROR_LIMIT)
            if type(error_count) is int
            else "invalid",
        },
        separators=(",", ":"),
    )


def typed_equal(left, right):
    """Keep JSON Boolean, number, array and object identities distinct."""
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return set(left) == set(right) and all(
            typed_equal(value, right[key]) for key, value in left.items()
        )
    if isinstance(left, list):
        return len(left) == len(right) and all(typed_equal(a, b) for a, b in zip(left, right))
    return left == right


def validate_receipt(result, nonce, pid, executable, bundle_id):
    """Inspect every actually published rule instead of trusting a pass flag."""
    if not isinstance(result, dict) or set(result) != RECEIPT_FIELDS:
        raise ValueError("Malformed native Karabiner receipt inventory")
    identity = {
        "schema_version": 1,
        "contract": CONTRACT["contract"],
        "nonce": nonce,
        "pid": pid,
        "executable": str(executable),
        "bundle_id": bundle_id,
        "version": TIMER_CONTRACT["runtime_version"],
    }
    fixed = {
        **identity,
        "publication_scope": "private-file-only",
        "complete": True,
        "lease_initialized": False,
        "private_source_restored": True,
        "codec_independent": True,
        "native_equal_values_shared": True,
    }
    for key, expected in fixed.items():
        if type(result[key]) is not type(expected) or result[key] != expected:
            detail = f"Native Karabiner identity or observation differs: {key}"
            # Inventory, every runtime identity and private-only publication are
            # admitted first. Foreign receipts must reveal no observed details.
            if key in NATIVE_FAILURE_FLAGS:
                detail += "; native_failure=" + native_failure_summary(result)
            raise ValueError(detail)
    if result["errors"] != [] or not isinstance(result["variants"], list):
        raise ValueError(
            "Native Karabiner generation or restoration failed; native_failure="
            + native_failure_summary(result)
        )
    seen = []
    manipulator_count = 0
    for variant in result["variants"]:
        if not isinstance(variant, dict) or set(variant) != {
            "preset",
            "tap_holds",
            "combinations",
            "config",
            "exact_source_snapshot",
            "repeated_unchanged",
        }:
            raise ValueError("Malformed native Karabiner variant inventory")
        if type(variant["tap_holds"]) is not bool or type(variant["combinations"]) is not bool:
            raise ValueError("Native Karabiner variant switches are not Boolean")
        seen.append((variant["preset"], variant["tap_holds"], variant["combinations"]))
        if (
            variant["exact_source_snapshot"] is not True
            or variant["repeated_unchanged"] is not True
        ):
            raise ValueError("Native Karabiner publication did not confirm its source or no-op")
        config = variant["config"]
        if not isinstance(config, dict) or set(config) != set(INITIAL_CONFIG):
            raise ValueError("Foreign Karabiner root settings changed")
        profiles = config["profiles"]
        if not isinstance(profiles, list) or len(profiles) != 2:
            raise ValueError("Foreign Karabiner profiles changed")
        if not typed_equal(config["global"], INITIAL_CONFIG["global"]) or not typed_equal(
            profiles[0], INITIAL_CONFIG["profiles"][0]
        ):
            raise ValueError("Unselected profile or global preferences changed")
        selected = profiles[1]
        if not isinstance(selected, dict) or set(selected) != set(INITIAL_CONFIG["profiles"][1]):
            raise ValueError("Selected profile metadata changed")
        if selected["name"] != "Default" or selected["selected"] is not True:
            raise ValueError("Selected profile identity changed")
        complex_modifications = selected["complex_modifications"]
        if not isinstance(complex_modifications, dict) or set(complex_modifications) != {
            "parameters",
            "rules",
        }:
            raise ValueError("Foreign complex modification settings changed")
        if not typed_equal(
            complex_modifications["parameters"],
            INITIAL_CONFIG["profiles"][1]["complex_modifications"]["parameters"],
        ):
            raise ValueError("Personal timing settings changed")
        rules = complex_modifications["rules"]
        if not isinstance(rules, list) or rules.count(USER_RULE) != 1:
            raise ValueError("The exact personal rule was lost or duplicated")
        count = 0
        modes = set()
        for rule in rules:
            if rule == USER_RULE:
                continue
            if not isinstance(rule, dict):
                raise ValueError("Published native managed rule is not an object")
            tag = re.match(
                r"^\[ErgoptiPlus managed:([0-9a-f]{32}):(normal|pause)\] ",
                rule.get("description", ""),
            )
            if not tag or tag[1] != nonce:
                raise ValueError("Native managed rule lost its exact private token tag")
            mode = tag[2]
            modes.add(mode)
            manipulators = rule.get("manipulators")
            if not isinstance(manipulators, list) or not manipulators:
                raise ValueError("Native managed rule has no actual manipulators")
            for manipulator in manipulators:
                conditions = (
                    manipulator.get("conditions") if isinstance(manipulator, dict) else None
                )
                if not isinstance(conditions, list) or not all(
                    isinstance(row, dict) for row in conditions
                ):
                    raise ValueError("Native manipulator lacks actual condition objects")
                expected = {
                    "ergopti_mode_" + nonce: CONTRACT["mode_values"][mode],
                    "ergopti_revoked_" + nonce: CONTRACT["revoked_value"],
                }
                for name, value in expected.items():
                    found = [row for row in conditions if row.get("name") == name]
                    if (
                        len(found) != 1
                        or found[0].get("type") != "variable_if"
                        or type(found[0].get("value")) is not int
                        or found[0]["value"] != value
                    ):
                        raise ValueError(
                            "Native managed conditions are duplicated, missing or inconsistent"
                        )
                foreign = [
                    row
                    for row in conditions
                    if str(row.get("name", "")).startswith(("ergopti_mode_", "ergopti_revoked_"))
                    and row.get("name") not in expected
                ]
                if foreign:
                    raise ValueError("Native managed conditions include a foreign generation")
                count += 1
        if modes != set(CONTRACT["mode_values"]) or count < CONTRACT["minimum_manipulators"]:
            raise ValueError("Native generated rule graph is vacuous or missing a mode")
        manipulator_count += count
    if sorted(seen) != sorted(VARIANTS):
        raise ValueError("Native preset and switch coverage is incomplete or duplicated")
    return {
        **CONTRACT["summary_fixed"],
        "version": TIMER_CONTRACT["runtime_version"],
        "nonce": nonce,
        "pid": pid,
        "executable": str(executable),
        "variant_count": len(VARIANTS),
        "manipulator_count": manipulator_count,
        "preference_restored": False,
    }


def validate_summary(summary):
    """Require the complete native contract and its preference restoration."""
    if not isinstance(summary, dict) or set(summary) != SUMMARY_FIELDS | {"preference_restored"}:
        raise ValueError("Malformed native Karabiner summary")
    for key, expected in {
        **CONTRACT["summary_fixed"],
        "version": TIMER_CONTRACT["runtime_version"],
        "variant_count": len(VARIANTS),
        "preference_restored": True,
    }.items():
        if type(summary[key]) is not type(expected) or summary[key] != expected:
            raise ValueError(f"Incomplete native Karabiner summary: {key}")
    if (
        not isinstance(summary["nonce"], str)
        or re.fullmatch(r"[0-9a-f]{32}", summary["nonce"]) is None
    ):
        raise ValueError("Invalid native Karabiner nonce")
    if type(summary["pid"]) is not int or summary["pid"] <= 0:
        raise ValueError("Invalid native Karabiner PID")
    if (
        type(summary["manipulator_count"]) is not int
        or summary["manipulator_count"] < len(VARIANTS) * CONTRACT["minimum_manipulators"]
    ):
        raise ValueError("Missing measured native Karabiner manipulators")
    if summary["executable"] != str(
        NativeDelayedTimerProbe.executable_path(Path("/Applications/ErgoptiPlus.app"))
    ):
        raise ValueError("Foreign packaged Karabiner qualification executable")


OWNED_CONTRACT = "karabiner.owned-private-publication"
OWNED_RECEIPT_FIELDS = IDENTITY_FIELDS | {
    "publication_scope",
    "installation",
    "remapping",
    "lease_initialized",
    "complete",
    "cleanup_settled",
    "stock_sentinel_preserved",
    "variants",
    "errors",
}


def validate_owned_receipt(result, nonce, pid, executable, bundle_id):
    """Judge complete private documents without deriving expectations from their generator."""
    if type(result) is not dict or set(result) != OWNED_RECEIPT_FIELDS:
        raise ValueError("Malformed complete private publication inventory")
    fixed = {
        "schema_version": 1,
        "contract": OWNED_CONTRACT,
        "nonce": nonce,
        "pid": pid,
        "executable": str(executable),
        "bundle_id": bundle_id,
        "version": TIMER_CONTRACT["runtime_version"],
        "publication_scope": "private-file-only",
        "installation": False,
        "remapping": False,
        "lease_initialized": False,
        "complete": True,
        "cleanup_settled": True,
        "stock_sentinel_preserved": True,
    }
    for key, expected in fixed.items():
        if type(result[key]) is not type(expected) or result[key] != expected:
            raise ValueError(f"Complete private publication identity or observation differs: {key}")
    if result["errors"] != [] or type(result["variants"]) is not list:
        raise ValueError("Complete private publication failed")
    seen, total = [], 0
    for variant in result["variants"]:
        if type(variant) is not dict or set(variant) != {
            "preset",
            "tap_holds",
            "combinations",
            "config",
            "exact_publication_receipt",
            "cleanup_settled",
        }:
            raise ValueError("Malformed complete private publication variant")
        if type(variant["tap_holds"]) is not bool or type(variant["combinations"]) is not bool:
            raise ValueError("Complete private publication switches are not Boolean")
        seen.append((variant["preset"], variant["tap_holds"], variant["combinations"]))
        if (
            variant["exact_publication_receipt"] is not True
            or variant["cleanup_settled"] is not True
        ):
            raise ValueError("Complete private publication lacks actual receipt settlement")
        config = variant["config"]
        if type(config) is not dict or set(config) != {"profiles"}:
            raise ValueError("Complete private publication is not the complete owned document")
        profiles = config["profiles"]
        if type(profiles) is not list or len(profiles) != 1 or type(profiles[0]) is not dict:
            raise ValueError("Complete private publication has foreign or missing profiles")
        profile = profiles[0]
        if set(profile) != {
            "name",
            "selected",
            "devices",
            "virtual_hid_keyboard",
            "complex_modifications",
        }:
            raise ValueError("Complete private publication profile inventory differs")
        if profile["name"] != "Default profile" or profile["selected"] is not True:
            raise ValueError("Complete private publication profile identity differs")
        if not typed_equal(
            profile["devices"],
            [{"simple_modifications": [], "identifiers": {"is_keyboard": True}}],
        ):
            raise ValueError("Complete private publication device configuration differs")
        if not typed_equal(
            profile["virtual_hid_keyboard"],
            {"country_code": 0, "keyboard_type_v2": "ansi"},
        ):
            raise ValueError("Complete private publication virtual keyboard configuration differs")
        complex_modifications = profile["complex_modifications"]
        if type(complex_modifications) is not dict or set(complex_modifications) != {"rules"}:
            raise ValueError("Complete private publication complex configuration differs")
        rules = complex_modifications["rules"]
        if type(rules) is not list or not rules:
            raise ValueError("Complete private publication has no rules")
        modes, count = set(), 0
        for rule in rules:
            if type(rule) is not dict or type(rule.get("description")) is not str:
                raise ValueError("Complete private publication rule shape differs")
            tag = re.match(
                r"^\[ErgoptiPlus managed:([0-9a-f]{32}):(normal|pause)\] ",
                rule["description"],
            )
            if tag is None or tag[1] != nonce:
                raise ValueError("Complete private publication generation differs")
            modes.add(tag[2])
            manipulators = rule.get("manipulators")
            if type(manipulators) is not list or not manipulators:
                raise ValueError("Complete private publication manipulator cohort is empty")
            for manipulator in manipulators:
                if type(manipulator) is not dict or manipulator.get("type") != "basic":
                    raise ValueError("Complete private publication manipulator shape differs")
                conditions = manipulator.get("conditions")
                if type(conditions) is not list or not all(type(row) is dict for row in conditions):
                    raise ValueError("Complete private publication has no actual condition cohort")
                expected_conditions = {
                    "ergopti_mode_" + nonce: CONTRACT["mode_values"][tag[2]],
                    "ergopti_revoked_" + nonce: CONTRACT["revoked_value"],
                }
                for name, value in expected_conditions.items():
                    found = [row for row in conditions if row.get("name") == name]
                    if (
                        len(found) != 1
                        or found[0].get("type") != "variable_if"
                        or type(found[0].get("value")) is not int
                        or found[0]["value"] != value
                    ):
                        raise ValueError("Complete private publication condition cohort differs")
                if any(
                    str(row.get("name", "")).startswith(("ergopti_mode_", "ergopti_revoked_"))
                    and row.get("name") not in expected_conditions
                    for row in conditions
                ):
                    raise ValueError("Complete private publication contains a foreign generation")
                count += 1
        if modes != set(CONTRACT["mode_values"]) or count < CONTRACT["minimum_manipulators"]:
            raise ValueError(
                "Complete private publication graph lacks its actual modes or witnesses"
            )
        total += count
    if sorted(seen) != sorted(VARIANTS):
        raise ValueError("Complete private publication preset and switch cohort differs")
    return {**fixed, "variant_count": len(VARIANTS), "manipulator_count": total}


class NativeKarabinerConfigProbe(NativeDelayedTimerProbe):
    """Reuse the existing owned scripting transport; never acquire a runtime lease."""

    def observe(self, pid, processes):
        receipt = self.output / "native-karabiner-config.json"
        private_home = self.output / "karabiner-private-home"
        private_home.mkdir(mode=0o700)
        destination = private_home / ".config/karabiner/karabiner.json"
        destination.parent.mkdir(parents=True, mode=0o700)
        original = (json.dumps(INITIAL_CONFIG, indent=2) + "\n").encode()
        with destination.open("xb") as handle:
            handle.write(original)
        if receipt.exists() or processes(self.executable) != [pid]:
            raise RuntimeError("Native Karabiner probe lacks its fresh exact runtime or receipt")
        self.bind_runtime(pid, processes)
        fixture = Path(__file__).with_name("hs_karabiner_config_native.lua")
        source = "return dofile({}).run({}, {}, {})".format(
            *(json.dumps(str(value)) for value in (fixture, receipt, destination, self.nonce))
        )
        self.execute(source)
        if processes(self.executable) != [pid]:
            raise RuntimeError("Native Karabiner runtime changed before receipt admission")
        result = json.loads(receipt.read_text(), object_pairs_hook=unique_object)
        if destination.read_bytes() != original:
            raise RuntimeError(
                "Native Karabiner probe did not restore its exact private source bytes"
            )
        return validate_receipt(result, self.nonce, pid, self.executable, self.domain)

    def observe_owned(self, pid, processes):
        """Qualify explicit private whole-document publication without installing a runtime."""
        import os

        receipt = self.output / "native-karabiner-owned-config.json"
        private_root = self.output / "ergopti-owned-private-root"
        if receipt.exists() or processes(self.executable) != [pid]:
            raise RuntimeError("Complete private publication lacks its fresh exact runtime")
        private_root.mkdir(mode=0o700)
        (private_root / "karabiner").mkdir(mode=0o700)
        stock = private_root / "stock-personal.json"
        original = (json.dumps(INITIAL_CONFIG, indent=2) + "\n").encode()
        with stock.open("xb") as handle:
            handle.write(original)
        self.bind_runtime(pid, processes)
        fixture = Path(__file__).with_name("hs_karabiner_config_native.lua")
        source = "return dofile({}).run_owned({}, {}, {}, {}, {})".format(
            *(json.dumps(str(value)) for value in (fixture, receipt, private_root, self.nonce)),
            os.getuid(),
            pid,
        )
        self.execute(source)
        if processes(self.executable) != [pid]:
            raise RuntimeError(
                "Complete private publication runtime changed before receipt admission"
            )
        result = json.loads(receipt.read_text(), object_pairs_hook=unique_object)
        summary = validate_owned_receipt(result, self.nonce, pid, self.executable, self.domain)
        destination = private_root / "karabiner/karabiner.json"
        published = json.loads(destination.read_bytes(), object_pairs_hook=unique_object)
        if not typed_equal(published, result["variants"][-1]["config"]):
            raise RuntimeError("Complete private publication does not match its actual final file")
        if stock.read_bytes() != original:
            raise RuntimeError("Complete private publication changed its separate stock sentinel")
        return summary
