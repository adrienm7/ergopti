# tools/diagnostics/hs_karabiner_config_probe_test.py
"""Reject altered native graphs, incomplete cohorts and changed private sources."""

import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import hs_karabiner_config_probe as probe

NONCE = "a" * 32
EXECUTABLE = probe.NativeDelayedTimerProbe.executable_path(Path("/Applications/ErgoptiPlus.app"))
DOMAIN = "com.ergoptiplus.app.hammerspoon"


def graph():
    """Declare an independent published graph, including every condition witness."""
    config = copy.deepcopy(probe.INITIAL_CONFIG)
    rules = config["profiles"][1]["complex_modifications"]["rules"]
    for mode, value in (("normal", 1), ("pause", 2)):
        rules.append(
            {
                "description": f"[ErgoptiPlus managed:{NONCE}:{mode}] fixture",
                "manipulators": [
                    {
                        "type": "basic",
                        "from": {"key_code": "a"},
                        "to": [{"key_code": "b"}],
                        "conditions": [
                            {
                                "type": "variable_if",
                                "name": "ergopti_mode_" + NONCE,
                                "value": value,
                            },
                            {"type": "variable_if", "name": "ergopti_revoked_" + NONCE, "value": 0},
                        ],
                    }
                    for _ in range(30)
                ],
            }
        )
    return config


def receipt():
    """Provide all eight independently declared preset and switch observations."""
    variants = []
    for preset in ("default", "recommended"):
        for tap_holds in (False, True):
            for combinations in (False, True):
                variants.append(
                    {
                        "preset": preset,
                        "tap_holds": tap_holds,
                        "combinations": combinations,
                        "config": graph(),
                        "exact_source_snapshot": True,
                        "repeated_unchanged": True,
                    }
                )
    return {
        "schema_version": 1,
        "contract": "karabiner.build-merge",
        "nonce": NONCE,
        "pid": 42,
        "executable": str(EXECUTABLE),
        "bundle_id": DOMAIN,
        "version": "1.1.1",
        "publication_scope": "private-file-only",
        "complete": True,
        "lease_initialized": False,
        "private_source_restored": True,
        "codec_independent": True,
        "native_equal_values_shared": True,
        "variants": variants,
        "errors": [],
    }


class NativeReceiptTests(unittest.TestCase):
    """A native pass flag cannot replace measured conditions or preserved profiles."""

    def judge(self, value):
        return probe.validate_receipt(value, NONCE, 42, EXECUTABLE, DOMAIN)

    def test_full_graph_still_needs_preference_restoration(self):
        summary = self.judge(receipt())
        self.assertEqual(summary["manipulator_count"], 480)
        with self.assertRaises(ValueError):
            probe.validate_summary(summary)
        summary["preference_restored"] = True
        probe.validate_summary(summary)

    def test_each_identity_and_measured_observation_is_required(self):
        source = receipt()
        for field in source:
            with self.subTest(missing=field):
                changed = copy.deepcopy(source)
                del changed[field]
                with self.assertRaises(ValueError):
                    self.judge(changed)
        for field, replacement in {
            "pid": 43,
            "nonce": "b" * 32,
            "bundle_id": "foreign",
            "version": "0.0.0",
            "publication_scope": "runtime-active",
            "complete": False,
            "lease_initialized": True,
            "private_source_restored": False,
            "codec_independent": False,
            "native_equal_values_shared": False,
            "errors": ["native callback error"],
        }.items():
            with self.subTest(field=field):
                changed = receipt()
                changed[field] = replacement
                with self.assertRaises(ValueError):
                    self.judge(changed)

    def test_duplicate_or_missing_variant_never_counts_as_full_coverage(self):
        for change in (lambda v: v.pop(), lambda v: v.__setitem__(0, copy.deepcopy(v[1]))):
            value = receipt()
            change(value["variants"])
            with self.assertRaisesRegex(ValueError, "coverage"):
                self.judge(value)

    def test_all_condition_rows_are_judged_including_last_variant_last_manipulator(self):
        for change in (
            lambda rows: rows.append(copy.deepcopy(rows[0])),
            lambda rows: rows[0].__setitem__("value", 2),
            lambda rows: rows[0].__setitem__("value", True),
            lambda rows: rows[1].__setitem__("value", 1),
            lambda rows: rows[1].__setitem__("name", "ergopti_revoked_" + "b" * 32),
            lambda rows: rows.pop(),
        ):
            value = receipt()
            # The final pause rule expects 2; change the earlier normal rule's
            # final manipulator so value=2 is always an actual disagreement.
            rows = value["variants"][-1]["config"]["profiles"][1]["complex_modifications"]["rules"][
                1
            ]["manipulators"][-1]["conditions"]
            change(rows)
            with self.assertRaisesRegex(ValueError, "conditions"):
                self.judge(value)

    def test_personal_rule_profiles_and_json_types_are_preserved(self):
        for change in (
            lambda config: config["profiles"][0]["complex_modifications"]["rules"].clear(),
            lambda config: config["profiles"][0].__setitem__("selected", 0),
            lambda config: config["global"].__setitem__("show_in_menu_bar", 0),
            lambda config: config["profiles"][1]["complex_modifications"]["parameters"].__setitem__(
                "basic.to_if_alone_timeout_milliseconds", 914
            ),
            lambda config: config["profiles"][1]["complex_modifications"]["rules"].pop(0),
        ):
            value = receipt()
            change(value["variants"][3]["config"])
            with self.assertRaises(ValueError):
                self.judge(value)

    def test_vacuous_graph_and_unacknowledged_publication_are_rejected(self):
        for field in ("exact_source_snapshot", "repeated_unchanged"):
            value = receipt()
            value["variants"][0][field] = False
            with self.assertRaises(ValueError):
                self.judge(value)
        value = receipt()
        value["variants"][0]["config"]["profiles"][1]["complex_modifications"]["rules"] = [
            copy.deepcopy(probe.USER_RULE)
        ]
        with self.assertRaisesRegex(ValueError, "vacuous"):
            self.judge(value)

    def test_private_physical_source_readback_cannot_be_replaced_by_receipt_flag(self):
        for changed_source in (False, True):
            with (
                self.subTest(changed_source=changed_source),
                tempfile.TemporaryDirectory() as folder,
            ):
                output = Path(folder)
                owner = probe.NativeKarabinerConfigProbe(
                    Path("/Applications/ErgoptiPlus.app"), output, DOMAIN
                )
                owner.nonce = NONCE
                sampled_owners = []

                def execute(source):
                    sampled_owners.append(owner.runtime_owner)
                    (output / "native-karabiner-config.json").write_text(json.dumps(receipt()))
                    if changed_source:
                        (
                            output / "karabiner-private-home/.config/karabiner/karabiner.json"
                        ).write_text("foreign bytes")

                with mock.patch.object(owner, "execute", side_effect=execute):
                    if changed_source:
                        with self.assertRaisesRegex(RuntimeError, "source bytes"):
                            owner.observe(42, lambda _: [42])
                    else:
                        self.assertEqual(owner.observe(42, lambda _: [42])["variant_count"], 8)
                self.assertEqual(len(sampled_owners), 1)
                self.assertEqual(sampled_owners[0][0], 42)
                self.assertEqual(sampled_owners[0][1](EXECUTABLE), [42])

    def test_changed_runtime_before_binding_never_enters_native_transport(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeKarabinerConfigProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            processes = mock.Mock(side_effect=[[42], [43]])
            with mock.patch.object(owner, "execute") as execute:
                with self.assertRaisesRegex(RuntimeError, "changed runtime owner"):
                    owner.observe(42, processes)
            self.assertIsNone(owner.runtime_owner)
            execute.assert_not_called()
            self.assertFalse((Path(folder) / "native-karabiner-config.json").exists())


if __name__ == "__main__":
    unittest.main()
