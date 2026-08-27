"""Unit tests for the shared installer core (layout_package)."""

import os
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from layout_package import (  # noqa: E402
    LayoutSpec,
    build_evdev_post,
    build_registry_xml,
    extract_defined_types,
    extract_referenced_types,
    find_stale_bridge_links,
    insert_type_sections,
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

    def test_evdev_post_matches_every_layout_position(self):
        """An unindexed rule only matches single-layout configurations, and
        GNOME/KDE compile every configured source into one keymap: without
        the indexed rules the custom types vanish as soon as ``us`` is kept
        next to Ergopti (issue #84)."""
        text = build_evdev_post("ergopti")
        for index in range(1, 5):
            self.assertIn(f"! layout[{index}]\t=\ttypes", text)
        self.assertEqual(text.count("ergopti\t=\t+ergopti"), 5)

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


EXTRA_SAMPLE = """default partial xkb_types "default" {
    virtual_modifiers LevelThree;

    type "FOUR_LEVEL_X" {
        modifiers = Shift + LevelThree;
        map[Shift] = Level2;
    };
};
"""


def assert_type_inside_section(case: unittest.TestCase, content: str) -> None:
    """The type block must be followed by the section's own closing brace.

    Checking ``rindex("};")`` is not enough: an appended block ends with a
    ``};`` of its own, so only a column-zero ``};`` *after* the block proves
    the block sits inside the section.
    """
    import re

    start = content.index('type "ERGOPTI_SEVEN_LEVEL"')
    block_end = content.index("};", start) + 2
    case.assertRegex(
        content[block_end:],
        r"(?m)^\};\s*$",
        "the xkb_types section must close after the inserted type block",
    )


class InsertTypeSectionsTests(unittest.TestCase):
    """The legacy method must place the type inside the xkb_types section.

    A block appended after the closing ``};`` is a syntax error: Xorg's
    xkbcomp rejects the whole ``complete`` types file and libxkbcommon drops
    the type without a diagnostic, which is how Shift and AltGr died.
    """

    def test_new_type_lands_inside_the_last_section(self):
        merged, handled = insert_type_sections(EXTRA_SAMPLE, TYPES_SAMPLE)
        self.assertEqual(handled, ["ERGOPTI_SEVEN_LEVEL"])
        assert_type_inside_section(self, merged)
        self.assertEqual(merged.count("xkb_types"), 1)
        self.assertIn('type "FOUR_LEVEL_X"', merged)

    def test_existing_type_is_replaced_in_place(self):
        once, _ = insert_type_sections(EXTRA_SAMPLE, TYPES_SAMPLE)
        updated_source = TYPES_SAMPLE.replace("map[LevelThree] = Level3;", "map[LevelThree] = Level3;\n        map[Lock] = Level2;")
        twice, _ = insert_type_sections(once, updated_source)
        self.assertEqual(twice.count('type "ERGOPTI_SEVEN_LEVEL"'), 1)
        self.assertIn("map[Lock] = Level2;", twice)
        self.assertEqual(twice.count("xkb_types"), 1)

    def test_rejects_a_destination_without_section(self):
        with self.assertRaises(ValueError):
            insert_type_sections("// nothing here\n", TYPES_SAMPLE)

    def test_rejects_a_source_without_type(self):
        with self.assertRaises(ValueError):
            insert_type_sections(EXTRA_SAMPLE, "xkb_types { include \"complete\" };")


class LayoutSpecTests(unittest.TestCase):
    def test_parse_splits_the_gnome_spelling(self):
        self.assertEqual(LayoutSpec.parse("fr+Ergopti_v2_2_1"), LayoutSpec("fr", "Ergopti_v2_2_1"))
        self.assertEqual(LayoutSpec.parse("ergopti"), LayoutSpec("ergopti"))
        self.assertEqual(LayoutSpec("fr", "Ergopti_v2_2_1").gnome_id, "fr+Ergopti_v2_2_1")

    def test_parse_rejects_unsafe_identifiers(self):
        for unsafe in ("", "../x", "fr+../x", "a b"):
            with self.assertRaises(ValueError):
                LayoutSpec.parse(unsafe)


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

    def test_strip_removes_the_assignments_and_the_section_they_emptied(self):
        cleaned, removed = strip_ergopti_rule_lines(self.OLD_RULES)
        self.assertEqual(removed, 3)
        self.assertNotIn("! layout = types", cleaned, "an emptied section header is litter")
        self.assertIn("! model = types\n  * = complete\n", cleaned)
        self.assertNotIn("Ergopti_v2_2_1_plus", cleaned)
        self.assertNotIn("ergopti =", cleaned)

    def test_strip_keeps_a_section_that_still_holds_foreign_entries(self):
        rules = "! layout = types\n  foreign = +foreign\n  ergopti = +ergopti\n"
        cleaned, removed = strip_ergopti_rule_lines(rules)
        self.assertEqual(removed, 1)
        self.assertEqual(cleaned, "! layout = types\n  foreign = +foreign\n")

    def test_strip_restores_a_file_the_old_installer_appended_to_byte_for_byte(self):
        """The generation-2 installer appended a blank line, a header and the
        rule; the reporter of issue #84 still carried it at line 750."""
        stock = "! model = types\n  * = complete\n\n! option = types\n  caps:internal = +caps(internal)\n"
        patched = stock + "\n! layout = types\n  Ergopti_v2_2_1 = +Ergopti_v2_2_1\n"
        cleaned, removed = strip_ergopti_rule_lines(patched)
        self.assertEqual(removed, 2)
        self.assertEqual(cleaned, stock)

    def test_strip_without_matches_is_noop(self):
        cleaned, removed = strip_ergopti_rule_lines("! model = types\n")
        self.assertEqual(removed, 0)
        self.assertEqual(cleaned, "! model = types\n")
        untouched = "! layout = types\n\n! model = types\n  * = complete\n"
        self.assertEqual(strip_ergopti_rule_lines(untouched), (untouched, 0))

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
            self.assertEqual(removed, 3)
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
