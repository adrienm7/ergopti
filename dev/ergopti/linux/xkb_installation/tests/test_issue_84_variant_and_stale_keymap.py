"""Regression tests for the issue #84 follow-up.

Two distinct reports came back on the issue after the Shift/AltGr fix landed.

1. "your keyboard is a layout and not a variant, which makes me unable to use it
   to type in japanese". The clean method registers one standalone layout with an
   empty variant list, so every picker that enumerates ``layout(variant)`` PAIRS
   has nothing to offer. The legacy method never had the problem because it
   registers under ``fr`` as a real variant.

2. ``localectl status`` still reporting ``X11 Layout: fr`` /
   ``X11 Variant: Ergopti_v2_2_1`` from an older release, and the reporter noting
   that selecting it "cause the Maj thing again". That file is the persistent
   SYSTEM keyboard configuration; nothing in the installer wrote it and nothing
   in the session-level cleanup looked at it, so the original bug survived the
   fix in a place we never mentioned.

Both are covered here at the level where the logic is pure, so they run on any
host with no XKB toolchain at all.
"""

import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from layout_package import (  # noqa: E402
    LayoutSpec,
    PACKAGE_NAME,
    add_variant_alias,
    build_registry_xml,
    parse_localectl_x11,
    stale_x11_keymap,
)

# The reporter's own output, pasted verbatim from the issue.
REPORTER_LOCALECTL = """System Locale: LANG=en_US.UTF-8
    VC Keymap: fr
    X11 Layout: fr
    X11 Variant: Ergopti_v2_2_1
"""

MINIMAL_SYMBOLS = (
    "default partial alphanumeric_keys\n"
    'xkb_symbols "default" {\n'
    '    name[Group1] = "Ergopti";\n'
    "};\n"
)


class VariantAliasTests(unittest.TestCase):
    """The layout must also be reachable as a layout(variant) pair."""

    def test_appends_a_section_that_includes_the_default_one(self):
        aliased = add_variant_alias(MINIMAL_SYMBOLS, "ergopti_plus", "ergopti")
        self.assertIn('xkb_symbols "ergopti_plus"', aliased)
        self.assertIn('include "ergopti(default)"', aliased)
        # The original section must survive: the alias is an extra door onto the
        # same room, not a replacement.
        self.assertIn('xkb_symbols "default"', aliased)
        self.assertIn('name[Group1] = "Ergopti"', aliased)

    def test_alias_is_a_partial_section_so_it_never_becomes_the_default(self):
        aliased = add_variant_alias(MINIMAL_SYMBOLS, "ergopti_plus", "ergopti")
        alias_at = aliased.index('xkb_symbols "ergopti_plus"')
        preceding = aliased[:alias_at].rsplit("\n", 2)[-2]
        self.assertEqual(preceding, "partial alphanumeric_keys")
        self.assertNotIn(
            "default partial alphanumeric_keys\nxkb_symbols \"ergopti_plus\"",
            aliased,
            "a second default section would make the resolved layout ambiguous",
        )

    def test_is_idempotent(self):
        once = add_variant_alias(MINIMAL_SYMBOLS, "ergopti", "ergopti")
        twice = add_variant_alias(once, "ergopti", "ergopti")
        self.assertEqual(once, twice)
        self.assertEqual(twice.count('xkb_symbols "ergopti"'), 1)

    def test_tolerates_a_symbols_file_without_a_trailing_newline(self):
        aliased = add_variant_alias(MINIMAL_SYMBOLS.rstrip("\n"), "ergopti", "ergopti")
        self.assertIn('xkb_symbols "ergopti"', aliased)
        self.assertNotIn("};partial", aliased, "sections must stay separated")

    def test_refuses_a_file_with_no_default_section(self):
        with self.assertRaises(ValueError):
            add_variant_alias('xkb_symbols "other" {};\n', "ergopti", "ergopti")

    def test_rejects_unsafe_identifiers(self):
        for variant in ("../escape", "with space", "", "a" * 81):
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                add_variant_alias(MINIMAL_SYMBOLS, variant, "ergopti")
        with self.assertRaises(ValueError):
            add_variant_alias(MINIMAL_SYMBOLS, "ergopti", "../escape")


class RegistryVariantTests(unittest.TestCase):
    """The registry must advertise the variant the symbols file provides."""

    def test_registers_the_variant_so_pickers_can_offer_a_pair(self):
        xml = build_registry_xml(
            "ergopti", "Français — Ergopti+", [("ergopti_plus", "Français — Ergopti+")]
        )
        root = ET.fromstring(xml)
        names = [node.text for node in root.iter("name")]
        self.assertEqual(names, ["ergopti", "ergopti_plus"])
        variants = root.findall(".//variantList/variant")
        self.assertEqual(len(variants), 1)

    def test_the_old_empty_shape_still_parses(self):
        # Guard the contract, not the current call: an empty list must stay
        # legal so the legacy method and any future caller keep working.
        root = ET.fromstring(build_registry_xml("ergopti", "Ergopti", []))
        self.assertEqual([n.text for n in root.iter("name")], ["ergopti"])
        self.assertIsNone(root.find(".//variantList"))


class ParseLocalectlTests(unittest.TestCase):
    """Reading the persistent system keymap out of `localectl status`."""

    def test_parses_the_reporters_exact_output(self):
        spec = parse_localectl_x11(REPORTER_LOCALECTL)
        self.assertEqual(spec, LayoutSpec("fr", "Ergopti_v2_2_1"))

    def test_reads_a_layout_with_no_variant(self):
        self.assertEqual(
            parse_localectl_x11("X11 Layout: us\n"), LayoutSpec("us", "")
        )

    def test_returns_none_without_an_x11_layout(self):
        self.assertIsNone(parse_localectl_x11("System Locale: LANG=C\n"))
        self.assertIsNone(parse_localectl_x11(""))
        self.assertIsNone(parse_localectl_x11(None))

    def test_rejects_values_that_could_escape_a_rules_slot(self):
        self.assertIsNone(parse_localectl_x11("X11 Layout: ../../etc\n"))
        self.assertIsNone(
            parse_localectl_x11("X11 Layout: fr\nX11 Variant: ../escape\n")
        )

    def test_ignores_the_console_keymap(self):
        # VC Keymap is the console, not X11; confusing the two would report a
        # stale desktop layout for a machine whose desktop is fine.
        self.assertIsNone(parse_localectl_x11("VC Keymap: Ergopti_v2_2_1\n"))


class StaleSystemKeymapTests(unittest.TestCase):
    """Only an OLD Ergopti pair is worth warning about."""

    def setUp(self):
        self.installed = LayoutSpec(PACKAGE_NAME, PACKAGE_NAME)

    def test_reports_the_reporters_leftover(self):
        stale = stale_x11_keymap(REPORTER_LOCALECTL, self.installed)
        self.assertEqual(stale, LayoutSpec("fr", "Ergopti_v2_2_1"))

    def test_reports_an_ergopti_layout_even_without_a_variant(self):
        stale = stale_x11_keymap("X11 Layout: Ergopti_v2_0_0\n", self.installed)
        self.assertEqual(stale, LayoutSpec("Ergopti_v2_0_0", ""))

    def test_stays_quiet_when_the_system_already_points_at_this_install(self):
        current = f"X11 Layout: {PACKAGE_NAME}\nX11 Variant: {PACKAGE_NAME}\n"
        self.assertIsNone(stale_x11_keymap(current, self.installed))

    def test_stays_quiet_for_a_keymap_that_is_none_of_our_business(self):
        self.assertIsNone(
            stale_x11_keymap("X11 Layout: fr\nX11 Variant: bepo\n", self.installed)
        )
        self.assertIsNone(stale_x11_keymap("X11 Layout: us\n", self.installed))

    def test_stays_quiet_when_localectl_is_absent(self):
        # run_capture returns None when the tool is missing; a machine with no
        # localectl must not produce a warning about a file it does not have.
        self.assertIsNone(stale_x11_keymap(None, self.installed))
        self.assertIsNone(stale_x11_keymap("", self.installed))

    def test_matches_the_plus_variant_spelling_too(self):
        stale = stale_x11_keymap(
            "X11 Layout: fr\nX11 Variant: Ergopti_v2_2_1_plus\n", self.installed
        )
        self.assertEqual(stale, LayoutSpec("fr", "Ergopti_v2_2_1_plus"))


class InstallerWarningTests(unittest.TestCase):
    """The installer must surface the leftover without rewriting it."""

    def _installer(self):
        import xkb_files_installer_clean as clean

        return clean

    def test_warns_and_names_the_exact_fix_command(self):
        clean = self._installer()
        printed: list[str] = []
        with mock.patch.object(clean, "run_capture", return_value=REPORTER_LOCALECTL), \
                mock.patch("builtins.print", side_effect=lambda *a, **k: printed.append(" ".join(str(x) for x in a))):
            clean.warn_stale_system_keymap("ergopti_plus")
        joined = "\n".join(printed)
        self.assertIn("fr + Ergopti_v2_2_1", joined)
        self.assertIn("localectl set-x11-keymap ergopti pc105 ergopti_plus", joined)

    def test_says_nothing_when_there_is_no_leftover(self):
        clean = self._installer()
        printed: list[str] = []
        with mock.patch.object(clean, "run_capture", return_value="X11 Layout: us\n"), \
                mock.patch("builtins.print", side_effect=lambda *a, **k: printed.append(" ".join(str(x) for x in a))):
            clean.warn_stale_system_keymap("ergopti_plus")
        self.assertEqual(printed, [])

    def test_never_runs_a_command_that_changes_the_system(self):
        # The system keyboard configuration is shared with the console and the
        # display manager. Reporting it is this installer's job; repointing it
        # silently is not.
        clean = self._installer()
        with mock.patch.object(clean, "run_capture", return_value=REPORTER_LOCALECTL) as capture, \
                mock.patch("builtins.print"):
            clean.warn_stale_system_keymap("ergopti_plus")
        for call in capture.call_args_list:
            command = call.args[0]
            self.assertEqual(
                command,
                ["localectl", "status"],
                "only the read-only status query may be run",
            )


class CompileFenceCoversTheVariantTests(unittest.TestCase):
    """An advertised spelling that does not compile is worse than none."""

    def _installer(self):
        import xkb_files_installer_clean as clean

        return clean

    def test_both_addressing_forms_reach_the_compiler(self):
        clean = self._installer()
        seen: list[LayoutSpec] = []

        def record(spec, *args, **kwargs):
            seen.append(spec)
            return True

        with mock.patch.object(clean, "verify_keymap", side_effect=record), \
                mock.patch("builtins.print"):
            self.assertTrue(
                clean.compile_validation(Path("/tmp/staging"), "ergopti", "ergopti_plus")
            )
        self.assertEqual(
            seen, [LayoutSpec("ergopti", ""), LayoutSpec("ergopti", "ergopti_plus")]
        )

    def test_a_variant_that_fails_the_fence_aborts_the_install(self):
        clean = self._installer()

        def reject_the_variant(spec, *args, **kwargs):
            return spec.variant == ""

        with mock.patch.object(clean, "verify_keymap", side_effect=reject_the_variant), \
                mock.patch("builtins.print"):
            self.assertFalse(
                clean.compile_validation(Path("/tmp/staging"), "ergopti", "ergopti_plus")
            )

    def test_a_host_with_no_compiler_still_installs(self):
        clean = self._installer()
        with mock.patch.object(clean, "verify_keymap", return_value=None), \
                mock.patch("builtins.print"):
            self.assertTrue(
                clean.compile_validation(Path("/tmp/staging"), "ergopti", "ergopti_plus")
            )

    def test_the_layout_alone_is_still_checked_without_a_variant(self):
        clean = self._installer()
        seen: list[LayoutSpec] = []
        with mock.patch.object(
            clean, "verify_keymap", side_effect=lambda spec, *a, **k: seen.append(spec) or True
        ), mock.patch("builtins.print"):
            self.assertTrue(clean.compile_validation(Path("/tmp/staging"), "ergopti"))
        self.assertEqual(seen, [LayoutSpec("ergopti", "")])


if __name__ == "__main__":
    unittest.main()
