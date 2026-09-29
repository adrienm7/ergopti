"""Golden test: the generic converter reproduces the shipped Ergopti files.

static/ergopti/linux/vX_Y_Z/ holds the XKB symbols and XCompose files users
install. They were produced by an Ergopti-only generator; the generic converter
replaced it, so every installable file must come out byte-for-byte identical,
or the replacement changed what Ergopti users type.
"""

from __future__ import annotations

import unittest

from support import LINUX_DIR, generate_xkb_files

# 2 versions x 4 installable variants (ISO/ANSI, Ergopti/Ergopti+) x 2 files.
MINIMUM_COMPARED_FILES = 16


class ErgoptiGoldenTests(unittest.TestCase):
    def test_every_installable_file_is_reproduced_byte_for_byte(self):
        compared = 0
        differences = []
        for bundle in generate_xkb_files.list_bundles():
            out_dir = generate_xkb_files.output_dir(bundle)
            if not out_dir.is_dir():
                continue
            for layout_id, result in generate_xkb_files.convert_bundle(bundle).items():
                for suffix, generated in (
                    (".xkb", result.symbols_text),
                    (".XCompose", result.compose_text),
                ):
                    shipped = out_dir / (layout_id + suffix)
                    compared += 1
                    if shipped.read_bytes() != generated.encode("utf-8"):
                        differences.append(str(shipped.relative_to(LINUX_DIR)))
        self.assertEqual(differences, [], "the generic converter changed shipped Ergopti files")
        self.assertGreaterEqual(compared, MINIMUM_COMPARED_FILES)

    def test_the_frozen_ergopti_plus_plus_files_are_not_regenerated(self):
        bundles = generate_xkb_files.list_bundles()
        self.assertTrue(bundles, "no Ergopti bundle found")
        for bundle in bundles:
            converted = generate_xkb_files.convert_bundle(bundle)
            self.assertTrue(converted, bundle.name)
            self.assertFalse([name for name in converted if "_plus_plus" in name], bundle.name)

    def test_display_names_keep_the_historical_form(self):
        self.assertEqual(
            generate_xkb_files.display_name("Ergopti_v2_2_1", (2, 2, 1)),
            "Français — Ergopti v2.2.1",
        )
        self.assertEqual(
            generate_xkb_files.display_name("Ergopti_v2_2_1_plus_ansi", (2, 2, 1)),
            "Français — Ergopti+ v2.2.1",
        )


if __name__ == "__main__":
    unittest.main()
