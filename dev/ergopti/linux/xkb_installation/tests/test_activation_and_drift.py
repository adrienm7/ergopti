"""Tests for desktop activation merge helpers and repository-level drift."""

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from layout_package import (  # noqa: E402
    ERGOPTI_TYPE_NAME,
    LayoutSpec,
    format_gsettings_sources,
    format_kde_layouts,
    is_ergopti_spec,
    merge_gsettings_source,
    merge_kde_layout_list,
    merge_layout_specs,
    parse_gsettings_sources,
    parse_kde_layout_list,
    parse_kde_layouts,
    remove_layout_specs,
)
import xkb_files_installer_clean as clean_installer  # noqa: E402

LAYOUT_DIR = Path(__file__).resolve().parents[2]


class GSettingsMergeTests(unittest.TestCase):
    def test_parse_empty_forms(self):
        for raw in ("@a(ss) []", "[]", "", "   "):
            self.assertEqual(parse_gsettings_sources(raw), [])

    def test_parse_populated_list(self):
        pairs = parse_gsettings_sources("[('xkb', 'fr'), ('xkb', 'us')]")
        self.assertEqual(pairs, [("xkb", "fr"), ("xkb", "us")])

    def test_unparsable_text_is_distinct_from_an_empty_list(self):
        self.assertIsNone(parse_gsettings_sources("garbage without brackets"))
        self.assertIsNone(parse_gsettings_sources("[not a tuple]"))

    def test_merge_appends_only_missing_and_preserves_order(self):
        current = [("xkb", "fr"), ("xkb", "ergopti")]
        merged, added = merge_gsettings_source(
            current, [("xkb", "ergopti+plus"), ("xkb", "ergopti")]
        )
        self.assertTrue(added)
        self.assertEqual(merged, [("xkb", "fr"), ("xkb", "ergopti"), ("xkb", "ergopti+plus")])

    def test_make_primary_moves_the_layout_first_without_dropping_any(self):
        current = [("xkb", "fr"), ("xkb", "us"), ("xkb", "ergopti")]
        merged, changed = merge_gsettings_source(
            current, [("xkb", "ergopti")], make_primary=True
        )
        self.assertTrue(changed)
        self.assertEqual(merged[0], ("xkb", "ergopti"))
        self.assertEqual(set(merged), set(current))

    def test_make_primary_is_a_noop_when_already_first(self):
        current = [("xkb", "ergopti"), ("xkb", "fr")]
        merged, changed = merge_gsettings_source(
            current, [("xkb", "ergopti")], make_primary=True
        )
        self.assertFalse(changed)
        self.assertEqual(merged, current)

    def test_merge_noop_when_present(self):
        current = [("xkb", "fr"), ("xkb", "ergopti+plus")]
        merged, added = merge_gsettings_source(current, [("xkb", "ergopti+plus")])
        self.assertFalse(added)
        self.assertEqual(merged, current)

    def test_format_round_trip(self):
        pairs = [("xkb", "fr"), ("xkb", "ergopti+plus")]
        formatted = format_gsettings_sources(pairs)
        self.assertEqual(parse_gsettings_sources(formatted), pairs)


class KDEMergeTests(unittest.TestCase):
    def test_parse_handles_empty_and_spaces(self):
        self.assertEqual(parse_kde_layout_list(None), [])
        self.assertEqual(parse_kde_layout_list(""), [])
        self.assertEqual(parse_kde_layout_list(" us , fr "), ["us", "fr"])

    def test_merge_appends_missing_only(self):
        merged, added = merge_kde_layout_list(["us"], ["ergopti", "us"])
        self.assertTrue(added)
        self.assertEqual(merged, ["us", "ergopti"])

    def test_aligned_lists_round_trip(self):
        specs = parse_kde_layouts("us,fr,de", ",Ergopti_v2_2_1")
        self.assertEqual(
            specs, [LayoutSpec("us"), LayoutSpec("fr", "Ergopti_v2_2_1"), LayoutSpec("de")]
        )
        self.assertEqual(format_kde_layouts(specs), ("us,fr,de", ",Ergopti_v2_2_1,"))

    def test_spec_merge_puts_the_new_layout_first_and_keeps_the_rest(self):
        merged, changed = merge_layout_specs(
            [LayoutSpec("us"), LayoutSpec("fr", "oss")], [LayoutSpec("fr", "Ergopti_v2_2_1")]
        )
        self.assertTrue(changed)
        self.assertEqual(
            merged, [LayoutSpec("fr", "Ergopti_v2_2_1"), LayoutSpec("us"), LayoutSpec("fr", "oss")]
        )

    def test_spec_removal_targets_layout_or_variant(self):
        current = [LayoutSpec("us"), LayoutSpec("fr", "Ergopti_v2_2_1"), LayoutSpec("ergopti")]
        kept, removed = remove_layout_specs(current, is_ergopti_spec)
        self.assertTrue(removed)
        self.assertEqual(kept, [LayoutSpec("us")])


class OwnedXComposeTests(unittest.TestCase):
    def test_xcompose_include_is_idempotent_and_external_edits_survive_uninstall(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "user home"
            home.mkdir()
            destination = home / ".XCompose"
            destination.write_text('include "%L"\n<Multi_key> <a> : "alpha"\n', encoding="utf-8")
            managed = root / "package with spaces" / "compose" / "ergopti.XCompose"
            managed.parent.mkdir(parents=True)
            managed.write_text('<Multi_key> <e> : "ergopti"\n', encoding="utf-8")

            with mock.patch("builtins.print"):
                self.assertTrue(clean_installer.install_user_xcompose(managed, home=home))
                self.assertFalse(clean_installer.install_user_xcompose(managed, home=home))
            installed = destination.read_text(encoding="utf-8")
            self.assertIn('include "%L"', installed)
            self.assertIn('"alpha"', installed)
            self.assertEqual(installed.count("# Ergopti managed XCompose"), 1)
            self.assertFalse((home / ".XCompose.bak").exists())

            with destination.open("a", encoding="utf-8") as stream:
                stream.write('<Multi_key> <z> : "external-after-install"\n')
            with mock.patch("builtins.print"):
                self.assertEqual(
                    clean_installer.remove_user_xcompose_include(home=home),
                    clean_installer.CleanupStatus.CHANGED,
                )
            restored = destination.read_text(encoding="utf-8")
            self.assertIn('include "%L"', restored)
            self.assertIn('"alpha"', restored)
            self.assertIn('"external-after-install"', restored)
            self.assertNotIn("Ergopti managed XCompose", restored)


class TypesFileDriftGuard(unittest.TestCase):
    """data/xkb_types.txt is the generator source for every shipped copy."""

    DATA_TYPES = LAYOUT_DIR / "xkb_generation" / "data" / "xkb_types.txt"

    def test_data_template_exists_and_is_namespaced(self):
        content = self.DATA_TYPES.read_text(encoding="utf-8")
        self.assertIn(f'type "{ERGOPTI_TYPE_NAME}"', content)

    def test_shipped_copies_match_the_generator_template(self):
        data_bytes = self.DATA_TYPES.read_bytes()
        for version_dir in sorted(LAYOUT_DIR.glob("v*")):
            shipped = version_dir / "xkb_types.txt"
            self.assertTrue(shipped.is_file(), f"missing {shipped}")
            self.assertEqual(
                shipped.read_bytes(),
                data_bytes,
                f"{version_dir.name}/xkb_types.txt drifted from "
                "xkb_generation/data/xkb_types.txt; regenerate instead of "
                "hand-editing.",
            )
            stale = version_dir / "xkb_types_without_ctrl.txt"
            self.assertFalse(stale.exists(), f"removed variant still shipped: {stale}")


if __name__ == "__main__":
    unittest.main()
