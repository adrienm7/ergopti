# tools/diagnostics/hs_karabiner_config_probe_test.py
"""Reject altered native graphs, incomplete cohorts and changed private sources."""

import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import hs_karabiner_config_probe as probe
import hs_native_bootstrap_probe as bootstrap

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

    def observe_refusal(self, value):
        """Exercise the real file reader and validator before the gate's privacy owner."""
        observed = []
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            owner = probe.NativeKarabinerConfigProbe(
                Path("/Applications/ErgoptiPlus.app"), output, DOMAIN
            )
            owner.nonce = NONCE

            def execute(_source):
                observed.append(owner.runtime_owner[0])
                (output / "native-karabiner-config.json").write_text(json.dumps(value))

            with mock.patch.object(owner, "execute", side_effect=execute):
                with self.assertRaises(ValueError) as caught:
                    owner.observe(42, lambda _: [42])
            self.assertEqual(observed, [42])
            self.assertIs(type(caught.exception), ValueError)
            self.assertIsNone(caught.exception.__cause__)
            return caught.exception, bootstrap.bounded_refusal(caught.exception)

    def test_incomplete_actual_receipt_exposes_only_admitted_native_failure_evidence(self):
        value = receipt()
        value.update(
            complete=False,
            variants=[],
            errors=[
                "/private/native-source.lua:66: Native rule build refused: "
                "generated rule 3 manipulator 12 has inconsistent managed conditions\n"
                "stack traceback: private-child-argv https://host/path?signature=secret"
            ],
        )
        failure, detail = self.observe_refusal(value)
        self.assertTrue(
            str(failure).startswith("Native Karabiner identity or observation differs: complete")
        )
        self.assertIn("native_failure=", detail)
        summary = json.loads(detail.split("native_failure=", 1)[1])
        self.assertEqual(summary["variant_count"], 0)
        self.assertEqual(summary["variant_expected"], 8)
        self.assertEqual(summary["error_count"], 1)
        self.assertEqual(summary["flags"]["complete"], False)
        self.assertEqual(summary["flags"]["private_source_restored"], True)
        self.assertEqual(
            summary["errors"],
            [
                "Native rule build refused: generated rule 3 manipulator 12 has inconsistent managed conditions"
            ],
        )
        for private in (
            "/private/native-source.lua",
            "private-child-argv",
            "https://host",
            "signature=secret",
        ):
            self.assertNotIn(private, detail)

    def test_actual_merge_refusal_boundaries_expose_only_closed_public_codes(self):
        cases = (
            (
                "generated config must contain exactly one selected profile, found 0",
                "generated_profile_selection",
            ),
            (
                "generated selected profile must contain complex_modifications.rules",
                "generated_complex_rules",
            ),
            ("generated managed rules must be a dense array", "generated_rules_array"),
            ("generated rule 3 lacks an exact managed tag", "generated_rule_tag"),
            ("legacy rule fingerprints must be a dense array", "legacy_fingerprint_array"),
            (
                "generated rule 3 manipulator 12 contains a foreign managed condition",
                "generated_condition_namespace",
            ),
            (
                "generated rule 3 manipulator 12: private-runtime-reference-error",
                "generated_runtime_references",
            ),
            (
                "legacy rule fingerprint 2 manipulator 3 contains a managed condition",
                "legacy_fingerprint_condition",
            ),
            (
                "legacy rule fingerprint 2 contains managed variable 'private-var' at private-path",
                "legacy_fingerprint_variable",
            ),
            ("legacy action catalogue item 2 lacks a non-empty label", "legacy_catalogue_label"),
            ("existing karabiner.json read raised: private-provider-error", "source_read_raised"),
            (
                "existing karabiner.json could not be read: private-provider-error",
                "source_read_refused",
            ),
            ("existing karabiner.json is not valid JSON", "source_json_invalid"),
            (
                "existing config must contain exactly one selected profile, found 2",
                "existing_profile_selection",
            ),
            ("existing profile 2 complex_modifications must be a table", "existing_complex_type"),
            (
                "legacy migration context has incomplete static rule anchors",
                "legacy_context_anchors",
            ),
            ("legacy action catalogue has a missing or duplicate id", "legacy_action_identity"),
            ("multiple historical ErgoptiPlus blocks match", "legacy_graph_ambiguous"),
            (
                "1 ambiguous legacy ErgoptiPlus rule: private-user-description",
                "legacy_signature_conflict",
            ),
            (
                "legacy combo catalogue has duplicate label 'private-user-label'",
                "legacy_catalogue_duplicate",
            ),
        )
        for actual_reason, expected_code in cases:
            with self.subTest(actual_reason=actual_reason):
                value = receipt()
                value.update(
                    complete=False,
                    variants=[],
                    errors=[
                        "/private/native-probe.lua:68: Native merge refused: "
                        + actual_reason
                        + "\nstack traceback: private-child-argv https://host/private?signature=secret"
                    ],
                )
                failure, detail = self.observe_refusal(value)
                self.assertTrue(
                    str(failure).startswith(
                        "Native Karabiner identity or observation differs: complete"
                    )
                )
                summary = json.loads(detail.split("native_failure=", 1)[1])
                self.assertEqual(summary["errors"], [f"Native merge refused [{expected_code}]"])
                self.assertEqual(summary["variant_count"], 0)
                self.assertEqual(summary["variant_expected"], 8)
                self.assertEqual(summary["flags"]["complete"], False)
                self.assertEqual(summary["flags"]["lease_initialized"], False)
                self.assertEqual(summary["flags"]["private_source_restored"], True)
                self.assertLessEqual(len(detail), 2048)
                for private in (
                    "/private/",
                    "private-provider",
                    "private-user",
                    "private-child",
                    "https://",
                    "signature=secret",
                ):
                    self.assertNotIn(private, detail)

    def test_merge_reason_codes_require_exact_producer_boundaries(self):
        for text in (
            "private-user sentence generated managed rules must be a dense array",
            "existing karabiner.json is not valid JSON private-user-suffix",
            "generated rule 9999999 lacks an exact managed tag",
            "existing profile secret complex_modifications must be a table",
            "legacy migration context has incomplete static rule anchors private-suffix",
            "legacy combo catalogue has duplicate private-user-suffix",
        ):
            with self.subTest(text=text):
                value = receipt()
                value.update(complete=False, errors=["Native merge refused: " + text])
                _, detail = self.observe_refusal(value)
                summary = json.loads(detail.split("native_failure=", 1)[1])
                self.assertEqual(summary["errors"], ["Native merge refused (detail omitted)"])
                self.assertNotIn("private-user", detail)
                self.assertNotIn("secret", detail)

    def test_foreign_or_malformed_identity_never_exposes_receipt_failure_details(self):
        for field, replacement in {
            "schema_version": 2,
            "contract": "foreign",
            "nonce": "b" * 32,
            "pid": 43,
            "executable": "/private/foreign",
            "bundle_id": "foreign",
            "version": "0.0.0",
            "publication_scope": "runtime-active",
            "private_extra": "secret",
        }.items():
            with self.subTest(field=field):
                value = receipt()
                value.update(complete=False, errors=["Native merge refused: private-user-contents"])
                value[field] = replacement
                _, detail = self.observe_refusal(value)
                self.assertNotIn("native_failure=", detail)
                self.assertNotIn("Native merge refused", detail)
                self.assertNotIn("private-user-contents", detail)

    def test_failure_summary_omits_unowned_text_and_bounds_actual_error_inventory(self):
        value = receipt()
        value.update(
            complete=False,
            codec_independent="private-flag",
            variants=[{"config": "private-configuration"}],
            errors=[
                "Native publication refused: private-user-contents\r\n::error::injected"
                + " secret " * 1000
                for _ in range(200)
            ],
        )
        _, detail = self.observe_refusal(value)
        self.assertIn("native_failure=", detail)
        summary = json.loads(detail.split("native_failure=", 1)[1])
        self.assertEqual(summary["error_count"], 200)
        self.assertEqual(summary["variant_count"], 1)
        self.assertEqual(summary["flags"]["codec_independent"], "invalid")
        self.assertEqual(summary["errors"], ["Native publication refused (detail omitted)"] * 4)
        self.assertEqual(summary["errors_omitted"], 196)
        self.assertLessEqual(len(detail), 2048)
        for private in (
            "private-user-contents",
            "private-configuration",
            "private-flag",
            "::error::",
            "secret",
        ):
            self.assertNotIn(private, detail)

    def test_malformed_failure_observations_do_not_render_arbitrary_json_values(self):
        for changes in (
            {"errors": {"private-map": "secret"}},
            {"variants": "private-variants", "errors": [None, {"private-map": "secret"}, 7]},
            {"errors": ["unowned private sentence"]},
        ):
            with self.subTest(changes=changes):
                value = receipt()
                value.update(complete=False, **changes)
                _, detail = self.observe_refusal(value)
                self.assertIn("native_failure=", detail)
                self.assertNotIn("private-", detail)
                self.assertNotIn("private sentence", detail)
                self.assertNotIn("secret", detail)
                self.assertLessEqual(len(detail), 2048)

    def test_supplementary_owner_keeps_primary_evidence_after_exact_cleanup(self):
        from hs_native_bootstrap_probe_test import NativeFixture

        with tempfile.TemporaryDirectory() as folder:
            fixture = NativeFixture(Path(folder))
            fixture.feature_mutation = lambda value: value.update(
                complete=False,
                variants=[],
                errors=["Identical native rules were not confirmed unchanged"],
            )
            with self.assertRaises(ValueError) as caught:
                fixture.observe(self, "karabiner_config")
            self.assertIs(type(caught.exception), ValueError)
            self.assertIsNone(caught.exception.__cause__)
            detail = bootstrap.bounded_refusal(caught.exception)
            self.assertIn("Identical native rules were not confirmed unchanged", detail)
            self.assertEqual(fixture.owners, [])
            self.assertEqual(
                fixture.preferences[bootstrap.CONFIG_KEY], fixture.initial[bootstrap.CONFIG_KEY]
            )
            self.assertEqual(fixture.preferences["late-unrelated"], "keep")

    def test_supplementary_cleanup_debt_stays_fatal_with_original_cause(self):
        from hs_native_bootstrap_probe_test import NativeFixture

        with tempfile.TemporaryDirectory() as folder:
            fixture = NativeFixture(Path(folder))
            fixture.feature_mutation = lambda value: value.update(
                complete=False, variants=[], errors=["The actual merge source receipt differs"]
            )
            cleanup = RuntimeError("exact owner retirement refused")
            with mock.patch.object(fixture.owner, "retire", side_effect=cleanup):
                with self.assertRaises(RuntimeError) as caught:
                    fixture.observe(self, "karabiner_config")
            self.assertIs(type(caught.exception), RuntimeError)
            self.assertIs(caught.exception.__cause__, cleanup)
            detail = bootstrap.bounded_refusal(caught.exception)
            self.assertIn("The actual merge source receipt differs", detail)
            self.assertIn("cleanup refused: exact owner retirement refused", detail)
            self.assertEqual(fixture.owners, [42])
            self.assertNotEqual(
                fixture.preferences[bootstrap.CONFIG_KEY], fixture.initial[bootstrap.CONFIG_KEY]
            )

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


def owned_receipt():
    """Declare independent native NSArray-empty serialization and complete profile witnesses."""
    value = receipt()
    value = {key: item for key, item in value.items() if key in probe.IDENTITY_FIELDS}
    value.update(
        {
            "contract": probe.OWNED_CONTRACT,
            "publication_scope": "private-file-only",
            "installation": False,
            "remapping": False,
            "lease_initialized": False,
            "complete": True,
            "cleanup_settled": True,
            "stock_sentinel_preserved": True,
            "errors": [],
            "variants": [],
        }
    )
    for preset in ("default", "recommended"):
        for tap in (False, True):
            for combination in (False, True):
                rules = graph()["profiles"][1]["complex_modifications"]["rules"][1:]
                config = {
                    "profiles": [
                        {
                            "name": "Default profile",
                            "selected": True,
                            "devices": [
                                {
                                    "identifiers": {"is_keyboard": True},
                                    "simple_modifications": [],
                                }
                            ],
                            "virtual_hid_keyboard": {
                                "country_code": 0,
                                "keyboard_type_v2": "ansi",
                            },
                            "complex_modifications": {"rules": rules},
                        }
                    ]
                }
                value["variants"].append(
                    {
                        "preset": preset,
                        "tap_holds": tap,
                        "combinations": combination,
                        "config": config,
                        "exact_publication_receipt": True,
                        "cleanup_settled": True,
                    }
                )
    return value


class NativeOwnedReceiptTests(unittest.TestCase):
    """No private-file pass flag authorizes runtime installation or remapping."""

    def judge(self, value):
        return probe.validate_owned_receipt(value, NONCE, 42, EXECUTABLE, DOMAIN)

    def test_healthy_complete_document_has_actual_witnesses(self):
        summary = self.judge(owned_receipt())
        self.assertEqual(summary["variant_count"], 8)
        self.assertEqual(summary["manipulator_count"], 480)
        self.assertIs(summary["installation"], False)
        self.assertIs(summary["remapping"], False)

    def test_every_closed_identity_and_observation_is_required(self):
        original = owned_receipt()
        for key in original:
            with self.subTest(missing=key):
                value = copy.deepcopy(original)
                del value[key]
                with self.assertRaisesRegex(
                    ValueError, "Malformed complete private publication inventory"
                ):
                    self.judge(value)
        for key, changed in {
            "pid": 43,
            "nonce": "b" * 32,
            "version": "0.0.0",
            "bundle_id": "foreign",
            "executable": "/foreign",
            "installation": True,
            "remapping": True,
            "lease_initialized": True,
            "complete": False,
            "cleanup_settled": False,
            "stock_sentinel_preserved": False,
            "publication_scope": "runtime-active",
        }.items():
            with self.subTest(changed=key):
                value = copy.deepcopy(original)
                value[key] = changed
                with self.assertRaisesRegex(ValueError, "identity or observation differs"):
                    self.judge(value)

    def test_complete_document_inventory_cannot_be_a_stock_merge(self):
        for mutation in (
            "root",
            "profile",
            "devices",
            "vhd",
            "complex",
            "selected",
            "name",
        ):
            with self.subTest(mutation=mutation):
                value = owned_receipt()
                config = value["variants"][0]["config"]
                profile = config["profiles"][0]
                if mutation == "root":
                    config["global"] = {}
                elif mutation == "profile":
                    config["profiles"].append(copy.deepcopy(profile))
                elif mutation == "devices":
                    profile["devices"] = []
                elif mutation == "vhd":
                    profile["virtual_hid_keyboard"]["country_code"] = True
                elif mutation == "complex":
                    profile["complex_modifications"]["parameters"] = {}
                elif mutation == "selected":
                    profile["selected"] = 1
                else:
                    profile["name"] = "Personal"
                with self.assertRaisesRegex(ValueError, "Complete private publication"):
                    self.judge(value)

    def test_native_empty_array_expectation_is_not_the_test_encoder_object(self):
        value = owned_receipt()
        value["variants"][0]["config"]["profiles"][0]["devices"][0]["simple_modifications"] = {}
        with self.assertRaisesRegex(ValueError, "device configuration differs"):
            self.judge(value)

    def test_graph_conditions_generation_modes_and_floor_are_independent(self):
        for mutation in (
            "nonce",
            "condition",
            "duplicate",
            "foreign",
            "mode",
            "floor",
            "shape",
            "empty",
        ):
            with self.subTest(mutation=mutation):
                value = owned_receipt()
                rules = value["variants"][0]["config"]["profiles"][0]["complex_modifications"][
                    "rules"
                ]
                manipulator = rules[0]["manipulators"][0]
                if mutation == "nonce":
                    rules[0]["description"] = rules[0]["description"].replace(NONCE, "b" * 32)
                elif mutation == "condition":
                    manipulator["conditions"][0]["value"] = True
                elif mutation == "duplicate":
                    manipulator["conditions"].append(copy.deepcopy(manipulator["conditions"][0]))
                elif mutation == "foreign":
                    manipulator["conditions"].append(
                        {
                            "name": "ergopti_mode_" + "b" * 32,
                            "type": "variable_if",
                            "value": 1,
                        }
                    )
                elif mutation == "mode":
                    rules.pop()
                elif mutation == "floor":
                    for rule in rules:
                        rule["manipulators"] = rule["manipulators"][:1]
                elif mutation == "shape":
                    manipulator["type"] = "foreign"
                else:
                    rules[0]["manipulators"] = []
                with self.assertRaisesRegex(ValueError, "Complete private publication"):
                    self.judge(value)

    def test_all_eight_actual_publications_and_receipts_are_required(self):
        for mutation in (
            "missing",
            "duplicate",
            "switch",
            "receipt",
            "cleanup",
            "error",
        ):
            with self.subTest(mutation=mutation):
                value = owned_receipt()
                if mutation == "missing":
                    value["variants"].pop()
                elif mutation == "duplicate":
                    value["variants"][1] = copy.deepcopy(value["variants"][0])
                elif mutation == "switch":
                    value["variants"][0]["tap_holds"] = 1
                elif mutation == "receipt":
                    value["variants"][0]["exact_publication_receipt"] = 1
                elif mutation == "cleanup":
                    value["variants"][0]["cleanup_settled"] = False
                else:
                    value["errors"] = ["failure"]
                with self.assertRaisesRegex(ValueError, "[Cc]omplete private publication"):
                    self.judge(value)

    def test_actual_private_file_and_stock_sentinel_are_admitted(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            owner = probe.NativeKarabinerConfigProbe(
                Path("/Applications/ErgoptiPlus.app"), output, DOMAIN
            )
            owner.nonce = NONCE
            value = owned_receipt()

            def execute(source):
                self.assertIn(".run_owned(", source)
                self.assertEqual(owner.runtime_owner[0], 42)
                root = output / "ergopti-owned-private-root"
                self.assertEqual(root.stat().st_mode & 0o777, 0o700)
                self.assertEqual((root / "karabiner").stat().st_mode & 0o777, 0o700)
                (root / "karabiner/karabiner.json").write_text(
                    json.dumps(value["variants"][-1]["config"])
                )
                (output / "native-karabiner-owned-config.json").write_text(json.dumps(value))

            with mock.patch.object(owner, "execute", side_effect=execute):
                summary = owner.observe_owned(42, lambda _: [42])
            self.assertEqual(summary["manipulator_count"], 480)

    def test_changed_actual_final_file_and_stock_bytes_are_rejected(self):
        for changed in ("final", "stock"):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as folder:
                output = Path(folder)
                owner = probe.NativeKarabinerConfigProbe(
                    Path("/Applications/ErgoptiPlus.app"), output, DOMAIN
                )
                owner.nonce = NONCE
                value = owned_receipt()

                def execute(_source):
                    root = output / "ergopti-owned-private-root"
                    (root / "karabiner/karabiner.json").write_text(
                        json.dumps({} if changed == "final" else value["variants"][-1]["config"])
                    )
                    (output / "native-karabiner-owned-config.json").write_text(json.dumps(value))
                    if changed == "stock":
                        (root / "stock-personal.json").write_bytes(b"foreign")

                with mock.patch.object(owner, "execute", side_effect=execute):
                    with self.assertRaisesRegex(RuntimeError, "Complete private publication"):
                        owner.observe_owned(42, lambda _: [42])


if __name__ == "__main__":
    unittest.main()
