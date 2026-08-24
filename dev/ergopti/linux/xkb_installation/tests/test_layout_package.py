"""Unit tests for the shared installer core (layout_package)."""

import os
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from layout_package import (  # noqa: E402
    build_evdev_post,
    build_registry_xml,
    extract_defined_types,
    extract_referenced_types,
    find_stale_bridge_links,
    patch_symbols_default,
    remove_generation_two_links,
    strip_ergopti_rule_lines,
    strip_legacy_evdev_patch,
    validate_component_identifier,
    validate_layout_files,
    variant_for_filename,
)

SYMBOLS_SAMPLE = """default partial alphanumeric_keys
xkb_symbols "ergopti" {
    name[Group1] = "Français — Ergopti";
    include "latin"
    key <AD01> { type[group1] = "ERGOPTI_SEVEN_LEVEL", [egrave, Egrave, z] };
};
"""

TYPES_SAMPLE = """xkb_types {
    include "complete"
    type "ERGOPTI_SEVEN_LEVEL" {
        modifiers = Shift + Lock + LevelThree;
        map[None] = Level1;
        map[Shift] = Level2;
        map[LevelThree] = Level3;
    };
};
"""


class PatchSymbolsDefaultTests(unittest.TestCase):
    def test_renames_section_and_adds_default_marker(self):
        content = 'partial alphanumeric_keys\nxkb_symbols "Ergopti_v9_plus"\n{\n};\n'
        patched = patch_symbols_default(content)
        self.assertIn('xkb_symbols "default"', patched)
        self.assertNotIn("Ergopti_v9_plus", patched)
        self.assertIn(
            "default partial alphanumeric_keys",
            patched.splitlines(),
        )
        # The bare marker must not be duplicated.
        self.assertEqual(patched.count("partial alphanumeric_keys"), 1)

    def test_is_idempotent(self):
        once = patch_symbols_default(SYMBOLS_SAMPLE)
        twice = patch_symbols_default(once)
        self.assertEqual(once, twice)

    def test_rejects_file_without_section(self):
        with self.assertRaises(ValueError):
            patch_symbols_default("no section here")


class RegistryAndRulesTests(unittest.TestCase):
    def test_evdev_post_maps_layout_to_types(self):
        text = build_evdev_post("ergopti")
        self.assertIn("! layout\t=\ttypes", text)
        self.assertIn("ergopti\t=\t+ergopti", text)

    def test_registry_xml_lists_variants_and_parses(self):
        xml_text = build_registry_xml(
            "ergopti", "Français — Ergopti", [("plus", "Ergopti+")]
        )
        root = ET.fromstring(xml_text)
        names = [node.text for node in root.iter("name")]
        self.assertIn("ergopti", names)
        self.assertIn("plus", names)

    def test_component_identifier_rejects_traversal(self):
        for unsafe in ["../evil", "", "a b", "x" * 81, "semi;tool"]:
            with self.assertRaises(ValueError):
                validate_component_identifier(unsafe)
        self.assertEqual(validate_component_identifier("ergopti"), "ergopti")


class CoherenceValidationTests(unittest.TestCase):
    """The regression fence for issue #84: symbols referencing unknown types."""

    def test_coherent_package_passes(self):
        self.assertEqual(validate_layout_files(SYMBOLS_SAMPLE, TYPES_SAMPLE), [])

    def test_unknown_referenced_type_fails(self):
        broken = symbols_sample_with("GHOST_TYPE")
        problems = validate_layout_files(broken, TYPES_SAMPLE)
        self.assertTrue(any("GHOST_TYPE" in problem for problem in problems))

    def test_empty_types_file_fails(self):
        problems = validate_layout_files(SYMBOLS_SAMPLE, "")
        self.assertTrue(any("types file is empty" in problem for problem in problems))

    def test_extraction_helpers(self):
        self.assertEqual(extract_referenced_types(SYMBOLS_SAMPLE), {"ERGOPTI_SEVEN_LEVEL"})
        self.assertEqual(extract_defined_types(TYPES_SAMPLE), {"ERGOPTI_SEVEN_LEVEL"})


def symbols_sample_with(type_name: str) -> str:
    return SYMBOLS_SAMPLE.replace("ERGOPTI_SEVEN_LEVEL", type_name)


class LegacyCleanupTests(unittest.TestCase):
    OLD_RULES = (
        "! model = types\n"
        "  * = complete\n"
        "! layout = types\n"
        "  Ergopti_v2_2_1_plus = +Ergopti_v2_2_1_plus\n"
        "  ergopti = +ergopti\n"
    )

    def test_strip_removes_only_assignment_lines(self):
        cleaned, removed = strip_ergopti_rule_lines(self.OLD_RULES)
        self.assertEqual(removed, 2)
        self.assertIn("! layout = types", cleaned)
        self.assertNotIn("Ergopti_v2_2_1_plus", cleaned)
        self.assertNotIn("ergopti =", cleaned)

    def test_strip_without_matches_is_noop(self):
        cleaned, removed = strip_ergopti_rule_lines("! model = types\n")
        self.assertEqual(removed, 0)
        self.assertEqual(cleaned, "! model = types\n")

    def test_stale_link_detection_and_removal(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            system_root = Path(tmp)
            symbols_dir = system_root / "symbols"
            symbols_dir.mkdir()
            stale_file = symbols_dir / "Ergopti_v2_2_0_plus"
            stale_file.write_text("stale", encoding="utf-8")
            self.assertEqual(find_stale_bridge_links(system_root), [stale_file])
            removed = remove_generation_two_links(system_root)
            self.assertEqual(removed, 1)
            self.assertFalse(stale_file.exists())
            self.assertEqual(find_stale_bridge_links(system_root), [])

    def test_strip_legacy_evdev_patch_on_real_file(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            rules_dir = Path(tmp) / "rules"
            rules_dir.mkdir()
            rules_path = rules_dir / "evdev"
            rules_path.write_text(self.OLD_RULES, encoding="utf-8")
            removed = strip_legacy_evdev_patch(Path(tmp))
            self.assertEqual(removed, 2)
            content = rules_path.read_text(encoding="utf-8")
            self.assertNotIn("+Ergopti_v2_2_1_plus", content)


class VariantPolicyTests(unittest.TestCase):
    def test_plus_plus_is_not_installable(self):
        self.assertIsNone(variant_for_filename("Ergopti_v2_2_1_plus_plus.xkb"))

    def test_standard_and_plus_are_recognised(self):
        self.assertEqual(variant_for_filename("Ergopti_v2_2_1.xkb"), "ergopti")
        self.assertEqual(variant_for_filename("Ergopti_v2_2_1_plus.xkb"), "ergopti_plus")


if __name__ == "__main__":
    unittest.main()
