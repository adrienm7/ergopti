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
