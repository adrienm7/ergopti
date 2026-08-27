"""Tests for the shared desktop-activation contract.

Issue #84 was a silent failure: the files were installed, the installer
reported success, and the session kept the previous layout. Every test here
pins one of the reasons that could happen again.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import desktop_activation as activation  # noqa: E402
import xkb_files_installer_clean as clean_installer  # noqa: E402
import xkb_files_installer_legacy as legacy_installer  # noqa: E402
from layout_package import LayoutSpec  # noqa: E402

ERGOPTI = LayoutSpec("ergopti")
LEGACY = LayoutSpec("fr", "Ergopti_v2_2_1")
TYPE = "ERGOPTI_SEVEN_LEVEL"

# A compiled keymap as libxkbcommon dumps it (numeric groups and levels): the
# probe key bound to the custom type with its seven levels, and the type
# mapping Ctrl to level 5 while preserving it.
GOOD_KEYMAP = """xkb_keymap {
xkb_types "complete" {
	type "ERGOPTI_SEVEN_LEVEL" {
		modifiers= Shift+Lock+Control+Mod4+Alt+LevelThree;
		map[Lock]= 2;
		map[Shift]= 3;
		map[Control]= 5;
		preserve[Control]= Control;
		map[LevelThree]= 6;
	};
};
xkb_symbols "pc+ergopti+inet(evdev)" {
	key <AD01>               {
		type= "ERGOPTI_SEVEN_LEVEL",
		symbols[1]= [ egrave, Egrave, Egrave, egrave, z, grave, doublelowquotemark ]
	};
};
};
"""
# The same key when the type is unknown to the compiler: the silent fallback
# of issue #84, a keymap that compiles and types nothing but lowercase.
DEAD_KEYMAP = """xkb_keymap {
xkb_types "complete" { };
xkb_symbols "pc+ergopti+inet(evdev)" {
	key <AD01>               {
		type= "ONE_LEVEL",
		symbols[1]= [ egrave ]
	};
};
};
"""


def compiled(keymap, command=("xkbcli", "compile-keymap"), diagnostics=""):
    return activation.CompileResult(list(command), keymap, diagnostics, {})


def failed(diagnostics="xkbcommon: ERROR: Couldn't look up rules", command=("xkbcli", "compile-keymap")):
    return activation.CompileResult(list(command), None, diagnostics, {})


def gsettings_session(initial: dict[str, str], writes: list[list[str]], accept: bool = True):
    """Return a fake ``subprocess.run`` backed by an in-memory dconf keyed by name."""
    state = dict(initial)

    def fake_run(command, **kwargs):
        if command[:1] == ["gsettings"] and command[1] == "get":
            return SimpleNamespace(returncode=0, stdout=state.get(command[3], "@a(ss) []"))
        if command[:1] == ["gsettings"] and command[1] == "set":
            writes.append(command)
            if accept:
                state[command[3]] = command[-1]
            return SimpleNamespace(returncode=0, stdout="")
        return SimpleNamespace(returncode=1, stdout="")

    return fake_run


def fake_subprocess(run):
    """A stand-in for the subprocess module with only what the code touches."""
    return SimpleNamespace(
        run=run, PIPE=-1, STDOUT=-2, DEVNULL=-3, TimeoutExpired=activation.subprocess.TimeoutExpired
    )


class SessionDetectionTests(unittest.TestCase):
    def test_desktop_tokens_split_every_advertised_name(self):
        tokens = activation.desktop_tokens({"XDG_CURRENT_DESKTOP": "ubuntu:GNOME"})
        self.assertEqual(tokens, {"ubuntu", "gnome"})

    def test_desktop_tokens_fall_back_to_the_other_variables(self):
        tokens = activation.desktop_tokens({"DESKTOP_SESSION": "Hyprland"})
        self.assertEqual(tokens, {"hyprland"})

    def test_session_type_prefers_the_declared_value(self):
        self.assertEqual(
            activation.session_type({"XDG_SESSION_TYPE": "wayland", "DISPLAY": ":0"}),
            "wayland",
        )

    def test_session_type_infers_wayland_from_the_socket(self):
        self.assertEqual(activation.session_type({"WAYLAND_DISPLAY": "wayland-0"}), "wayland")

    def test_session_type_is_unknown_without_any_hint(self):
        self.assertEqual(activation.session_type({}), "unknown")

    def test_gnome_derivatives_are_recognised(self):
        for name in ("ubuntu:GNOME", "Budgie:GNOME", "pop:GNOME"):
            tokens = activation.desktop_tokens({"XDG_CURRENT_DESKTOP": name})
            self.assertTrue(activation.is_gnome_session(tokens), name)

    def test_wlroots_compositors_are_not_mistaken_for_gnome(self):
        tokens = activation.desktop_tokens({"XDG_CURRENT_DESKTOP": "Hyprland"})
        self.assertFalse(activation.is_gnome_session(tokens))
        self.assertFalse(activation.is_kde_session(tokens))


class ManualInstructionTests(unittest.TestCase):
    def test_known_compositor_gets_its_own_configuration_file(self):
        joined = "\n".join(activation.manual_instructions(ERGOPTI, {"hyprland"}, "wayland"))
        self.assertIn("hyprland.conf", joined)
        self.assertIn("kb_layout = ergopti", joined)
        self.assertNotIn("kb_variant", joined)

    def test_legacy_layout_is_split_into_layout_and_variant_for_every_compositor(self):
        expectations = {
            "hyprland": ("kb_layout = fr", "kb_variant = Ergopti_v2_2_1"),
            "sway": ('xkb_layout "fr"', 'xkb_variant "Ergopti_v2_2_1"'),
            "niri": ('layout "fr"', 'variant "Ergopti_v2_2_1"'),
            "river": ("riverctl keyboard-layout -variant Ergopti_v2_2_1 fr",),
            "wayfire": ("xkb_layout = fr", "xkb_variant = Ergopti_v2_2_1"),
            "labwc": ("XKB_DEFAULT_LAYOUT=fr", "XKB_DEFAULT_VARIANT=Ergopti_v2_2_1"),
        }
        self.assertEqual(set(expectations), set(activation.COMPOSITOR_INSTRUCTIONS))
        for name, fragments in expectations.items():
            joined = "\n".join(activation.manual_instructions(LEGACY, {name}, "wayland"))
            for fragment in fragments:
                self.assertIn(fragment, joined, name)
            # The joined GNOME spelling is never valid for a compositor.
            self.assertNotIn("fr+Ergopti", joined, name)

    def test_unknown_wayland_compositor_gets_the_environment_fallback(self):
        joined = "\n".join(activation.manual_instructions(LEGACY, {"weston"}, "wayland"))
        self.assertIn("environment.d", joined)
        self.assertIn("XKB_DEFAULT_LAYOUT=fr", joined)
        self.assertIn("XKB_DEFAULT_VARIANT=Ergopti_v2_2_1", joined)

    def test_x11_without_a_known_compositor_gets_no_manual_block(self):
        self.assertEqual(activation.manual_instructions(ERGOPTI, {"xfce"}, "x11"), [])

    def test_kde_gets_plasma_instructions_with_the_use_key(self):
        joined = "\n".join(activation.manual_instructions(LEGACY, {"kde", "plasma"}, "wayland"))
        self.assertIn("--key LayoutList fr", joined)
        self.assertIn("--key VariantList Ergopti_v2_2_1", joined)
        self.assertIn("--key Use true", joined)
        self.assertNotIn("gsettings", joined)

    def test_gnome_retry_uses_the_joined_spelling(self):
        joined = "\n".join(activation.manual_instructions(LEGACY, {"gnome"}, "wayland"))
        self.assertIn("('xkb', 'fr+Ergopti_v2_2_1')", joined)

    def test_persistence_instruction_prefers_localectl(self):
        with mock.patch.object(activation.shutil, "which", return_value="/usr/bin/localectl"):
            joined = "\n".join(activation.persistence_instructions(LEGACY))
        self.assertIn("sudo localectl set-x11-keymap fr pc105 Ergopti_v2_2_1", joined)

    def test_persistence_instruction_falls_back_to_xorg_conf(self):
        with mock.patch.object(activation.shutil, "which", return_value=None):
            joined = "\n".join(activation.persistence_instructions(LEGACY))
        self.assertIn('Option "XkbLayout" "fr"', joined)
        self.assertIn('Option "XkbVariant" "Ergopti_v2_2_1"', joined)


class PrivilegeDropTests(unittest.TestCase):
    def test_root_never_writes_to_the_session(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append(command)
            return SimpleNamespace(returncode=0, stdout="@a(ss) []")

        with mock.patch("builtins.print"), mock.patch.object(
            activation, "running_as_root", return_value=True
        ), mock.patch.object(activation.subprocess, "run", side_effect=fake_run):
            applied = activation.activate_layout([ERGOPTI])

        self.assertFalse(applied)
        self.assertEqual(calls, [])

    def test_session_bus_is_rebuilt_from_the_target_uid(self):
        fake_pwd = SimpleNamespace(getpwnam=lambda name: SimpleNamespace(pw_uid=1000))
        with mock.patch.dict(sys.modules, {"pwd": fake_pwd}), mock.patch.object(
            activation.Path, "is_dir", return_value=True
        ):
            env = activation.session_bus_env("someone")
        self.assertEqual(env["XDG_RUNTIME_DIR"], "/run/user/1000")
        self.assertEqual(env["DBUS_SESSION_BUS_ADDRESS"], "unix:path=/run/user/1000/bus")

    def test_missing_runtime_directory_yields_no_bus_override(self):
        fake_pwd = SimpleNamespace(getpwnam=lambda name: SimpleNamespace(pw_uid=1000))
        with mock.patch.dict(sys.modules, {"pwd": fake_pwd}), mock.patch.object(
            activation.Path, "is_dir", return_value=False
        ):
            self.assertEqual(activation.session_bus_env("someone"), {})

    def test_drop_command_carries_the_bus_into_the_child(self):
        environment = {"DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"}
        command = activation.build_drop_command(
            "runuser", "someone", environment, ["python3", "installer.py", "--activate-only"]
        )
        self.assertEqual(command[:4], ["runuser", "-u", "someone", "--"])
        self.assertIn("env", command)
        self.assertIn("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus", command)
        self.assertIn("--activate-only", command)

    def test_su_command_quotes_every_argument(self):
        command = activation.build_drop_command(
            "su", "someone", {}, ["python3", "a file.py", "--activate-only"]
        )
        self.assertEqual(command[:3], ["su", "someone", "-c"])
        self.assertIn("'a file.py'", command[3])

    def test_root_is_not_reported_as_the_desktop_user(self):
        with mock.patch.dict(activation.os.environ, {"SUDO_USER": "root"}, clear=True):
            self.assertIsNone(activation.desktop_user())

    def test_doas_user_is_recognised(self):
        with mock.patch.dict(activation.os.environ, {"DOAS_USER": "someone"}, clear=True):
            self.assertEqual(activation.desktop_user(), "someone")

    def test_user_identity_prefers_the_sandbox_home(self):
        with mock.patch.dict(
            activation.os.environ, {activation.ENV_USER_HOME: "/sandbox/home", "SUDO_USER": "x"}
        ):
            home, uid, gid = activation.resolve_user_identity()
        self.assertEqual(str(home).replace("\\", "/"), "/sandbox/home")
        self.assertIsNone(uid)
        self.assertIsNone(gid)


class GnomeApplyTests(unittest.TestCase):
    def run_apply(self, initial, accept=True, specs=(ERGOPTI,)):
        writes: list[list[str]] = []
        with mock.patch("builtins.print"), mock.patch.object(
            activation.time, "sleep"
        ), mock.patch.object(
            activation.subprocess, "run", side_effect=gsettings_session(initial, writes, accept)
        ):
            applied = activation.apply_gnome(list(specs), {"gnome"})
        return applied, writes

    def test_layout_is_written_first_and_read_back(self):
        applied, writes = self.run_apply({"sources": "[('xkb', 'us')]"})
        self.assertTrue(applied)
        by_key = {write[3]: write[-1] for write in writes}
        self.assertEqual(by_key["sources"], "[('xkb', 'ergopti'), ('xkb', 'us')]")

    def test_layout_becomes_the_most_recently_used_source(self):
        """gnome-shell activates mru-sources[0] at login, not sources[0]."""
        applied, writes = self.run_apply(
            {"sources": "[('xkb', 'us')]", "mru-sources": "[('xkb', 'us')]"}
        )
        self.assertTrue(applied)
        keys = [write[3] for write in writes]
        self.assertEqual(keys, ["sources", "mru-sources"], "sources must be written before the MRU list")
        self.assertEqual(writes[-1][-1], "[('xkb', 'ergopti'), ('xkb', 'us')]")

    def test_mru_is_reconciled_even_when_sources_are_already_first(self):
        applied, writes = self.run_apply(
            {"sources": "[('xkb', 'ergopti'), ('xkb', 'us')]", "mru-sources": "[('xkb', 'us'), ('xkb', 'ergopti')]"}
        )
        self.assertTrue(applied)
        self.assertEqual([write[3] for write in writes], ["mru-sources"])
        self.assertEqual(writes[0][-1], "[('xkb', 'ergopti'), ('xkb', 'us')]")

    def test_legacy_layout_uses_the_joined_gnome_spelling(self):
        applied, writes = self.run_apply({"sources": "[('xkb', 'us')]"}, specs=(LEGACY,))
        self.assertTrue(applied)
        self.assertEqual(writes[0][-1], "[('xkb', 'fr+Ergopti_v2_2_1'), ('xkb', 'us')]")

    def test_a_write_that_does_not_stick_is_reported_as_a_failure(self):
        applied, writes = self.run_apply({"sources": "[('xkb', 'us')]"}, accept=False)
        self.assertEqual([write[3] for write in writes], ["sources"])
        self.assertFalse(applied, "a silent dconf no-op must never be reported as success")

    def test_an_unreadable_value_is_left_untouched(self):
        writes: list[list[str]] = []

        def fake_run(command, **kwargs):
            if command[1] == "get":
                return SimpleNamespace(returncode=0, stdout="garbage")
            writes.append(command)
            return SimpleNamespace(returncode=0, stdout="")

        with mock.patch("builtins.print"), mock.patch.object(
            activation.subprocess, "run", side_effect=fake_run
        ):
            self.assertFalse(activation.apply_gnome([ERGOPTI], {"gnome"}))
        self.assertEqual(writes, [])


class KdeApplyTests(unittest.TestCase):
    """Plasma keeps aligned LayoutList/VariantList lists and needs Use=true."""

    def run_apply(self, values, specs=(LEGACY,), which=("kreadconfig6", "kwriteconfig6", "dbus-send")):
        writes: list[list[str]] = []
        signals: list[list[str]] = []

        def fake_run(command, **kwargs):
            if command[0] == "kreadconfig6":
                key = command[command.index("--key") + 1]
                return SimpleNamespace(returncode=0, stdout=values.get(key, "") + "\n")
            if command[0] == "kwriteconfig6":
                writes.append(command)
                return SimpleNamespace(returncode=0, stdout="")
            if command[0] == "dbus-send":
                signals.append(command)
                return SimpleNamespace(returncode=0, stdout="")
            raise FileNotFoundError(command[0])

        with mock.patch("builtins.print"), mock.patch.object(
            activation.subprocess, "run", side_effect=fake_run
        ), mock.patch.object(
            activation.shutil, "which", side_effect=lambda name: name if name in which else None
        ):
            applied = activation.apply_kde(list(specs), {"kde"})
        by_key = {write[write.index("--key") + 1]: write[-1] for write in writes}
        return applied, by_key, signals

    def test_layout_and_variant_are_written_to_aligned_lists(self):
        applied, by_key, signals = self.run_apply(
            {"LayoutList": "us,fr", "VariantList": ",oss", "Use": "false"}
        )
        self.assertTrue(applied)
        self.assertEqual(by_key["LayoutList"], "fr,us,fr")
        self.assertEqual(by_key["VariantList"], "Ergopti_v2_2_1,,oss")
        self.assertEqual(by_key["Use"], "true")
        self.assertNotIn("DisplayNames", by_key)
        self.assertTrue(signals, "Plasma must be told to reread kxkbrc")
        self.assertIn("org.kde.keyboard.reloadConfig", signals[0])

    def test_the_gnome_spelling_never_reaches_plasma(self):
        _, by_key, _ = self.run_apply({"LayoutList": "us", "VariantList": ""})
        self.assertNotIn("fr+Ergopti", by_key["LayoutList"])
        self.assertEqual(by_key["LayoutList"], "fr,us")

    def test_display_names_stay_aligned_when_present(self):
        _, by_key, _ = self.run_apply(
            {"LayoutList": "us,fr", "VariantList": ",oss", "DisplayNames": "US,FR", "Use": "true"}
        )
        self.assertEqual(by_key["DisplayNames"], ",US,FR")
        self.assertNotIn("Use", by_key, "Use=true must not be rewritten needlessly")

    def test_already_first_still_enables_the_list(self):
        applied, by_key, _ = self.run_apply(
            {"LayoutList": "fr,us", "VariantList": "Ergopti_v2_2_1,", "Use": ""}
        )
        self.assertTrue(applied)
        self.assertEqual(list(by_key), ["Use"])

    def test_missing_writer_is_a_failure_not_a_success(self):
        applied, by_key, _ = self.run_apply(
            {"LayoutList": "us", "VariantList": ""}, which=("kreadconfig6",)
        )
        self.assertFalse(applied)
        self.assertEqual(by_key, {})


class OwningDesktopTests(unittest.TestCase):
    """A write only counts when the desktop that reads it is the one running.

    gsettings-desktop-schemas is pulled in by many unrelated packages, so
    ``gsettings set`` succeeds under Sway or Hyprland and changes nothing those
    compositors read. Reporting that as success is issue #84 in a new disguise.
    """

    def run_activation(self, environ, accept=True, spec=ERGOPTI):
        writes: list[list[str]] = []
        printed: list[str] = []
        with mock.patch(
            "builtins.print",
            side_effect=lambda *a, **k: printed.append(" ".join(str(part) for part in a)),
        ), mock.patch.object(activation.time, "sleep"), mock.patch.object(
            activation, "subprocess", fake_subprocess(gsettings_session({"sources": "[('xkb', 'us')]"}, writes, accept))
        ), mock.patch.object(activation.shutil, "which", return_value=None), mock.patch.object(
            activation, "running_as_root", return_value=False
        ):
            applied = activation.activate_layout([spec], environ)
        return applied, "\n".join(printed), writes

    def test_hyprland_still_gets_its_own_instructions(self):
        environ = {"XDG_CURRENT_DESKTOP": "Hyprland", "XDG_SESSION_TYPE": "wayland"}
        _, output, _ = self.run_activation(environ)
        self.assertIn("hyprland.conf", output)
        self.assertIn("kb_layout = ergopti", output)

    def test_sway_still_gets_its_own_instructions(self):
        environ = {"XDG_CURRENT_DESKTOP": "sway", "XDG_SESSION_TYPE": "wayland"}
        _, output, _ = self.run_activation(environ)
        self.assertIn("sway/config", output)

    def test_a_compositor_session_never_writes_the_gnome_setting(self):
        """gsettings exists on the reporter's Arch box and accepted the write,
        while Hyprland never reads it; a success line about GNOME on a
        Hyprland session is noise that hides the real instruction."""
        environ = {"XDG_CURRENT_DESKTOP": "Hyprland", "XDG_SESSION_TYPE": "wayland"}
        applied, output, writes = self.run_activation(environ)
        self.assertFalse(applied)
        self.assertEqual(writes, [])
        self.assertIn("Réglage GNOME ignoré", output)
        self.assertIn("non activée automatiquement", output)

    def test_an_unidentified_session_still_tries_every_setting(self):
        _, _, writes = self.run_activation({"XDG_SESSION_TYPE": "wayland"})
        self.assertTrue(any(write[3] == "sources" for write in writes))

    def test_gnome_does_not_get_a_manual_block_when_the_write_sticks(self):
        environ = {"XDG_CURRENT_DESKTOP": "ubuntu:GNOME", "XDG_SESSION_TYPE": "wayland"}
        applied, output, writes = self.run_activation(environ)
        self.assertTrue(applied)
        self.assertEqual([write[3] for write in writes if write[3] == "sources"], ["sources"])
        self.assertNotIn("environment.d", output)
        self.assertNotIn("hyprland", output.lower())
        self.assertIn("Disposition activée", output)

    def test_an_unknown_wayland_session_falls_back_to_environment_d(self):
        _, output, _ = self.run_activation({"XDG_SESSION_TYPE": "wayland"})
        self.assertIn("XKB_DEFAULT_LAYOUT=ergopti", output)

    def test_a_failed_gnome_write_offers_the_command_to_retry(self):
        applied, output, _ = self.run_activation(
            {"XDG_CURRENT_DESKTOP": "GNOME", "XDG_SESSION_TYPE": "wayland"}, accept=False
        )
        self.assertFalse(applied)
        self.assertIn("gsettings set org.gnome.desktop.input-sources sources", output)

    def test_x11_without_a_layout_manager_is_told_how_to_persist(self):
        printed: list[str] = []
        with mock.patch(
            "builtins.print",
            side_effect=lambda *a, **k: printed.append(" ".join(str(part) for part in a)),
        ), mock.patch.object(
            activation.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="")
        ), mock.patch.object(
            activation.shutil, "which", side_effect=lambda name: name if name in ("setxkbmap", "localectl") else None
        ), mock.patch.object(activation, "running_as_root", return_value=False):
            applied = activation.activate_layout(
                [LEGACY], {"XDG_CURRENT_DESKTOP": "XFCE", "XDG_SESSION_TYPE": "x11"}
            )
        output = "\n".join(printed)
        self.assertTrue(applied)
        self.assertIn("localectl set-x11-keymap fr pc105 Ergopti_v2_2_1", output)


class SetxkbmapTests(unittest.TestCase):
    def test_variant_is_a_separate_argument(self):
        self.assertEqual(
            activation.setxkbmap_arguments(LEGACY),
            ["-layout", "fr", "-variant", "Ergopti_v2_2_1"],
        )
        self.assertEqual(activation.setxkbmap_arguments(ERGOPTI), ["-layout", "ergopti"])


class KeymapInspectionTests(unittest.TestCase):
    """A keymap that compiles is not a keymap that works (issue #84)."""

    def test_a_good_keymap_has_no_problem_and_a_readable_summary(self):
        self.assertEqual(activation.inspect_keymap(GOOD_KEYMAP, TYPE), [])
        summary = activation.describe_probe(GOOD_KEYMAP, TYPE)
        self.assertIn("7 niveaux", summary)
        self.assertIn("Ctrl → niveau 5 (z)", summary)

    def test_the_one_level_fallback_is_named_as_the_cause(self):
        problems = activation.inspect_keymap(DEAD_KEYMAP, TYPE)
        joined = "\n".join(problems)
        self.assertIn("n'est pas défini", joined)
        self.assertIn("ONE_LEVEL", joined)

    def test_a_missing_probe_key_means_the_symbols_never_loaded(self):
        problems = activation.inspect_keymap("xkb_keymap { xkb_symbols { }; };", TYPE)
        self.assertTrue(any("absente" in problem for problem in problems))

    def test_a_type_without_a_ctrl_level_is_rejected(self):
        keymap = GOOD_KEYMAP.replace("\t\tmap[Control]= 5;\n", "").replace("\t\tpreserve[Control]= Control;\n", "")
        problems = activation.inspect_keymap(keymap, TYPE)
        self.assertTrue(any("Ctrl" in problem for problem in problems), problems)

    def test_a_type_that_drops_ctrl_is_rejected(self):
        keymap = GOOD_KEYMAP.replace("\t\tpreserve[Control]= Control;\n", "")
        problems = activation.inspect_keymap(keymap, TYPE)
        self.assertTrue(any("preserve" in problem for problem in problems), problems)

    def test_the_group_carrying_ergopti_is_the_one_inspected(self):
        multi = GOOD_KEYMAP.replace(
            '\t\ttype= "ERGOPTI_SEVEN_LEVEL",',
            '\t\ttype[1]= "ALPHABETIC",\n\t\ttype[2]= "ERGOPTI_SEVEN_LEVEL",',
        ).replace("symbols[1]=", "symbols[2]=")
        self.assertEqual(activation.inspect_keymap(multi, TYPE, group=2), [])
        self.assertTrue(activation.inspect_keymap(multi, TYPE, group=1))

    def test_xkbcomp_spelling_is_understood_too(self):
        keymap = GOOD_KEYMAP.replace("symbols[1]=", "symbols[Group1]=").replace("map[Control]= 5", "map[Control]= Level5")
        self.assertEqual(activation.inspect_keymap(keymap, TYPE), [])

    def test_relevant_diagnostics_keep_the_cause_and_drop_the_chatter(self):
        diagnostics = (
            "xkbcommon: WARNING: [XKB-407] Multiple definitions of the ONE_LEVEL key type; Earlier definition ignored\n"
            "xkbcommon: WARNING: [XKB-302] ergopti:24:75: deprecated keysym name \"masculine\"\n"
            "xkbcommon: ERROR: [XKB-822] Couldn't find file \"symbols/ergopti\" for symbols include\n"
            "xkbcommon: WARNING: something about ERGOPTI_SEVEN_LEVEL not defined\n"
        )
        kept = activation.relevant_diagnostics(diagnostics, (TYPE, "ergopti"))
        self.assertEqual(len(kept), 3, kept)
        self.assertTrue(any("Couldn't find file" in line for line in kept))
        self.assertTrue(any("not defined" in line for line in kept))
        self.assertFalse(any("Multiple definitions" in line for line in kept))

    def test_relevant_diagnostics_fall_back_to_the_last_lines(self):
        kept = activation.relevant_diagnostics("line one\nline two\n", ("ergopti",), limit=1)
        self.assertEqual(kept, ["line two"])


class KeymapVerificationTests(unittest.TestCase):
    def run_verify(self, keymaps_by_layouts, spec=ERGOPTI, xkbcomp_probe=None, tools=("xkbcli",)):
        seen: list[str] = []
        printed: list[str] = []

        def fake_compiler(command, environment=None, timeout=60):
            if "compile-keymap" in command:
                layouts = command[command.index("--layout") + 1]
                seen.append(layouts)
                keymap = keymaps_by_layouts.get(layouts)
            else:
                seen.append("xkbcomp")
                keymap = keymaps_by_layouts.get("xkbcomp")
            if keymap is None:
                return activation.CompileResult(command, None, "xkbcommon: ERROR: Couldn't look up rules", dict(environment or {}))
            return activation.CompileResult(command, keymap, "", dict(environment or {}))

        with mock.patch(
            "builtins.print",
            side_effect=lambda *a, **k: printed.append(" ".join(str(part) for part in a)),
        ), mock.patch.object(
            activation.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}" if name in tools else None
        ), mock.patch.object(activation, "run_compiler", side_effect=fake_compiler):
            verdict = activation.verify_keymap(spec, TYPE, xkbcomp_probe=xkbcomp_probe)
        return verdict, seen, "\n".join(printed)

    def test_the_type_must_survive_a_companion_layout_in_both_orders(self):
        verdict, seen, output = self.run_verify(
            {"ergopti": GOOD_KEYMAP, "ergopti,us": GOOD_KEYMAP, "us,ergopti": GOOD_KEYMAP.replace("symbols[1]=", "symbols[2]=").replace('type= "ERGOPTI_SEVEN_LEVEL"', 'type[2]= "ERGOPTI_SEVEN_LEVEL"')}
        )
        self.assertTrue(verdict)
        self.assertEqual(seen, ["ergopti", "ergopti,us", "us,ergopti"])
        self.assertIn("Keymap vérifiée", output)

    def test_a_type_lost_in_multi_layout_configurations_fails(self):
        """The exact failure of an unindexed ``! layout = types`` rule."""
        verdict, _, output = self.run_verify(
            {"ergopti": GOOD_KEYMAP, "ergopti,us": DEAD_KEYMAP, "us,ergopti": GOOD_KEYMAP}
        )
        self.assertFalse(verdict)
        self.assertIn("ergopti,us", output)
        self.assertIn("ONE_LEVEL", output)

    def test_a_layout_that_does_not_compile_fails_with_the_compiler_output(self):
        verdict, _, output = self.run_verify({})
        self.assertFalse(verdict)
        self.assertIn("Couldn't look up rules", output)
        self.assertIn("Commande :", output)

    def test_missing_compilers_are_unverified_not_broken(self):
        verdict, seen, output = self.run_verify({}, tools=())
        self.assertIsNone(verdict)
        self.assertEqual(seen, [])
        self.assertIn("xkbcli absent", output)

    def test_xkbcomp_alone_can_verify_when_a_probe_is_given(self):
        probe = activation.XkbcompProbe("pc+ergopti+inet(evdev)", "complete+ergopti", (Path("/pkg"),))
        verdict, seen, output = self.run_verify({"xkbcomp": GOOD_KEYMAP}, xkbcomp_probe=probe, tools=("xkbcomp",))
        self.assertTrue(verdict)
        self.assertEqual(seen, ["xkbcomp"])
        self.assertIn("xkbcomp", output)

    def test_xkbcomp_rejecting_the_layout_fails_even_when_libxkbcommon_passes(self):
        probe = activation.XkbcompProbe("pc+fr(Ergopti_v2_2_1)+inet(evdev)", "complete")
        verdict, seen, _ = self.run_verify(
            {"ergopti": GOOD_KEYMAP, "ergopti,us": GOOD_KEYMAP, "us,ergopti": GOOD_KEYMAP.replace("symbols[1]=", "symbols[2]=").replace('type= "ERGOPTI_SEVEN_LEVEL"', 'type[2]= "ERGOPTI_SEVEN_LEVEL"')},
            xkbcomp_probe=probe,
            tools=("xkbcli", "xkbcomp"),
        )
        self.assertFalse(verdict)
        self.assertEqual(seen[-1], "xkbcomp")

    def test_legacy_spec_compiles_with_its_variant(self):
        captured: list[list[str]] = []

        def fake_compiler(command, environment=None, timeout=60):
            captured.append(command)
            keymap = GOOD_KEYMAP
            if command[command.index("--layout") + 1].startswith("us"):
                keymap = GOOD_KEYMAP.replace("symbols[1]=", "symbols[2]=").replace('type= "ERGOPTI_SEVEN_LEVEL"', 'type[2]= "ERGOPTI_SEVEN_LEVEL"')
            return activation.CompileResult(command, keymap, "", dict(environment or {}))

        with mock.patch("builtins.print"), mock.patch.object(
            activation.shutil, "which", side_effect=lambda name: "/usr/bin/xkbcli" if name == "xkbcli" else None
        ), mock.patch.object(activation, "run_compiler", side_effect=fake_compiler):
            self.assertTrue(activation.verify_keymap(LEGACY, TYPE, include_roots=[Path("/sandbox")]))
        first = captured[0]
        self.assertEqual(first[first.index("--layout") + 1], "fr")
        self.assertEqual(first[first.index("--variant") + 1], "Ergopti_v2_2_1")
        self.assertIn("--include-defaults", first)
        second = captured[1]
        self.assertEqual(second[second.index("--variant") + 1], "Ergopti_v2_2_1,")

    def test_the_staging_environment_makes_the_compiler_talkative(self):
        captured: list[dict[str, str]] = []

        def fake_compiler(command, environment=None, timeout=60):
            captured.append(dict(environment or {}))
            return activation.CompileResult(command, GOOD_KEYMAP.replace("symbols[1]=", "symbols[2]=").replace('type= "ERGOPTI_SEVEN_LEVEL"', 'type[2]= "ERGOPTI_SEVEN_LEVEL"') if command[command.index("--layout") + 1].startswith("us") else GOOD_KEYMAP, "", dict(environment or {}))

        with mock.patch("builtins.print"), mock.patch.object(
            activation.shutil, "which", side_effect=lambda name: "/usr/bin/xkbcli" if name == "xkbcli" else None
        ), mock.patch.object(activation, "run_compiler", side_effect=fake_compiler):
            activation.verify_keymap(ERGOPTI, TYPE, extensions_root=Path("/staging"))
        environment = captured[0]
        self.assertEqual(environment["XKB_LOG_LEVEL"], "warning")
        self.assertEqual(environment["XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH"].replace("\\", "/"), "/staging")
        self.assertEqual(environment["XKB_CONFIG_VERSIONED_EXTENSIONS_PATH"], "")


class CompilerRunnerTests(unittest.TestCase):
    def test_a_missing_binary_is_a_readable_failure(self):
        result = activation.run_compiler(["/nonexistent/xkbcli-for-tests", "compile-keymap"])
        self.assertFalse(result.succeeded)
        self.assertIn("introuvable", result.diagnostics)
        self.assertIn("xkbcli-for-tests", result.command_line())

    def test_stderr_is_kept_for_the_report(self):
        result = activation.run_compiler(
            [sys.executable, "-c", "import sys; sys.stderr.write('boom\\n'); sys.exit(1)"]
        )
        self.assertFalse(result.succeeded)
        self.assertIn("boom", result.diagnostics)

    def test_an_empty_keymap_is_a_failure(self):
        result = activation.run_compiler([sys.executable, "-c", "pass"])
        self.assertFalse(result.succeeded)
        self.assertIn("aucune keymap", result.diagnostics)


class CliGuardTests(unittest.TestCase):
    def test_a_crash_becomes_a_report_and_an_exit_code(self):
        def crash(argv):
            raise RuntimeError("unexpected condition")

        with mock.patch("sys.stderr") as stderr:
            code = activation.run_cli(crash, [])
        self.assertEqual(code, activation.EXIT_INSTALL_ABORTED)
        written = "".join(str(call.args[0]) for call in stderr.write.call_args_list if call.args)
        self.assertIn("unexpected condition", written)
        self.assertIn("Erreur interne", written)

    def test_system_exit_passes_through(self):
        def leave(argv):
            raise SystemExit(3)

        with self.assertRaises(SystemExit):
            activation.run_cli(leave, [])

    def test_the_return_value_is_forwarded(self):
        self.assertEqual(activation.run_cli(lambda argv: 7, []), 7)


class DeactivationTests(unittest.TestCase):
    def run_deactivate(self, gnome_sources, kde_values=None, kde_write_ok=True, which=("kreadconfig6", "kwriteconfig6", "dbus-send")):
        calls: list[list[str]] = []

        def fake_run(command, **kwargs):
            calls.append(command)
            if command[0] == "gsettings":
                if gnome_sources is None:
                    raise FileNotFoundError("gsettings")
                if gnome_sources == "FAIL":
                    return SimpleNamespace(returncode=1, stdout="")
                if command[1] == "get":
                    value = gnome_sources if command[3] == "sources" else "@a(ss) []"
                    return SimpleNamespace(returncode=0, stdout=value)
                return SimpleNamespace(returncode=0, stdout="")
            if command[0] == "kreadconfig6":
                if kde_values is None:
                    raise FileNotFoundError(command[0])
                if kde_values == "FAIL":
                    return SimpleNamespace(returncode=1, stdout="")
                key = command[command.index("--key") + 1]
                return SimpleNamespace(returncode=0, stdout=kde_values.get(key, ""))
            if command[0] == "kwriteconfig6":
                return SimpleNamespace(returncode=0 if kde_write_ok else 1, stdout="")
            if command[0] == "dbus-send":
                return SimpleNamespace(returncode=0, stdout="")
            raise FileNotFoundError(command[0])

        with mock.patch("builtins.print"), mock.patch.object(
            activation.subprocess, "run", side_effect=fake_run
        ), mock.patch.object(
            activation.shutil, "which", side_effect=lambda name: name if name in which else None
        ):
            status = activation.deactivate_layouts()
        return status, calls

    def test_every_ergopti_entry_is_removed_and_nothing_else(self):
        status, calls = self.run_deactivate(
            "[('xkb', 'fr'), ('xkb', 'ergopti'), ('ibus', 'mozc-jp'), ('xkb', 'ergopti+plus'), ('xkb', 'fr+Ergopti_v2_2_1')]",
            {"LayoutList": "us,ergopti,fr,fr", "VariantList": ",,Ergopti_v2_2_1,oss"},
        )
        self.assertIs(status, activation.CleanupStatus.CHANGED)
        gnome_writes = [call for call in calls if call[0] == "gsettings" and call[1] == "set" and call[3] == "sources"]
        self.assertEqual(gnome_writes[0][-1], "[('xkb', 'fr'), ('ibus', 'mozc-jp')]")
        kde_writes = {call[call.index("--key") + 1]: call[-1] for call in calls if call[0] == "kwriteconfig6"}
        self.assertEqual(kde_writes["LayoutList"], "us,fr")
        self.assertEqual(kde_writes["VariantList"], ",oss")

    def test_gnome_read_failure_is_a_failure(self):
        status, _ = self.run_deactivate("FAIL", None)
        self.assertIs(status, activation.CleanupStatus.FAILED)

    def test_kde_read_failure_is_a_failure(self):
        status, _ = self.run_deactivate(None, "FAIL")
        self.assertIs(status, activation.CleanupStatus.FAILED)

    def test_kde_write_failure_is_a_failure(self):
        status, _ = self.run_deactivate(None, {"LayoutList": "us,ergopti", "VariantList": ","}, kde_write_ok=False)
        self.assertIs(status, activation.CleanupStatus.FAILED)

    def test_missing_desktop_commands_mean_absent(self):
        status, _ = self.run_deactivate(None, None, which=())
        self.assertIs(status, activation.CleanupStatus.ABSENT)


class InstallerWiringTests(unittest.TestCase):
    def test_clean_activate_only_refuses_to_run_as_root_without_a_user(self):
        with mock.patch("builtins.print"), mock.patch.object(
            clean_installer, "running_as_root", return_value=True
        ), mock.patch.object(clean_installer, "rerun_unprivileged", return_value=None):
            code = clean_installer.main(["--activate-only", "--variant", "ergopti"])
        self.assertNotEqual(code, clean_installer.EXIT_OK)

    def test_clean_activate_only_reruns_unprivileged_when_root(self):
        with mock.patch("builtins.print"), mock.patch.object(
            clean_installer, "running_as_root", return_value=True
        ), mock.patch.object(clean_installer, "rerun_unprivileged", return_value=0) as rerun:
            code = clean_installer.main(["--activate-only", "--variant", "ergopti"])
        self.assertEqual(code, clean_installer.EXIT_OK)
        argv = rerun.call_args[0][0]
        self.assertIn("--activate-only", argv)
        self.assertIn("ergopti", argv)

    def test_clean_activate_only_verifies_the_keymap_before_activating(self):
        order = []

        def verify(*args, **kwargs):
            order.append("verify")
            return True

        with mock.patch("builtins.print"), mock.patch.object(
            clean_installer, "running_as_root", return_value=False
        ), mock.patch.object(
            clean_installer, "verify_keymap", side_effect=verify
        ), mock.patch.object(
            clean_installer, "activate_layout", side_effect=lambda *a, **k: order.append("activate")
        ):
            code = clean_installer.main(["--activate-only", "--variant", "ergopti"])
        self.assertEqual(code, clean_installer.EXIT_OK)
        self.assertEqual(order, ["verify", "activate"])

    def test_clean_activation_aborts_when_the_installed_package_is_unusable(self):
        """Activating a package whose layers are dead is issue #84 with a
        success message on top; the failure must reach the exit code."""
        printed: list[str] = []
        with mock.patch(
            "builtins.print", side_effect=lambda *a, **k: printed.append(" ".join(str(p) for p in a))
        ), mock.patch.object(
            clean_installer, "running_as_root", return_value=False
        ), mock.patch.object(
            clean_installer, "verify_keymap", return_value=False
        ), mock.patch.object(clean_installer, "activate_layout") as activate:
            code = clean_installer.main(["--activate-only", "--variant", "ergopti"])
        self.assertEqual(code, clean_installer.EXIT_INSTALL_ABORTED)
        activate.assert_not_called()
        self.assertIn("--diagnose", "\n".join(printed))

    def test_clean_activation_without_a_compiler_warns_and_continues(self):
        printed: list[str] = []
        with mock.patch(
            "builtins.print", side_effect=lambda *a, **k: printed.append(" ".join(str(p) for p in a))
        ), mock.patch.object(
            clean_installer, "running_as_root", return_value=False
        ), mock.patch.object(
            clean_installer, "verify_keymap", return_value=None
        ), mock.patch.object(clean_installer, "activate_layout") as activate:
            code = clean_installer.main(["--activate-only", "--variant", "ergopti"])
        self.assertEqual(code, clean_installer.EXIT_OK)
        activate.assert_called_once()
        self.assertIn("sans vérification", "\n".join(printed))

    def test_clean_activation_gives_xorg_a_probe_into_the_package(self):
        seen = {}
        with mock.patch("builtins.print"), mock.patch.object(
            clean_installer, "running_as_root", return_value=False
        ), mock.patch.object(
            clean_installer, "verify_keymap", side_effect=lambda *a, **k: seen.update(k) or True
        ), mock.patch.object(clean_installer, "activate_layout"):
            clean_installer.main(["--activate-only", "--variant", "ergopti"])
        probe = seen["xkbcomp_probe"]
        self.assertEqual(probe.symbols, "pc+ergopti+inet(evdev)")
        self.assertEqual(probe.types, "complete+ergopti")
        self.assertTrue(str(probe.include_dirs[0]).endswith("ergopti"))

    def test_a_message_raised_as_system_exit_is_printed_not_swallowed(self):
        """``read_text`` raises SystemExit with the message: the CLI used to
        return code 4 without ever printing it."""
        with mock.patch("sys.stderr") as stderr, mock.patch.dict(
            clean_installer.os.environ, {"ERGOPTI_XKB_EXTENSIONS_ROOT": "/tmp/sandbox-extensions"}
        ):
            code = clean_installer.main(
                ["--xkb", "/nonexistent/layout.xkb", "--types", "/nonexistent/types.txt", "--skip-activation"]
            )
        self.assertEqual(code, clean_installer.EXIT_INSTALL_ABORTED)
        written = "".join(str(call.args[0]) for call in stderr.write.call_args_list if call.args)
        self.assertIn("lecture impossible", written)
        self.assertIn("layout.xkb", written)

    def test_a_real_install_verifies_through_the_distribution_search_path(self):
        """Overriding the search path would prove the files exist, not that the
        session can find them: only a sandboxed run may pass an explicit root."""
        seen = {}
        with mock.patch("builtins.print"), mock.patch.object(
            clean_installer, "running_as_root", return_value=False
        ), mock.patch.object(
            clean_installer, "verify_keymap", side_effect=lambda *a, **k: seen.update(k)
        ), mock.patch.object(clean_installer, "activate_layout"), mock.patch.dict(
            clean_installer.os.environ,
            {"ERGOPTI_XKB_EXTENSIONS_ROOT": "", "ERGOPTI_XKB_SYSTEM_ROOT": "", "ERGOPTI_XKB_CACHE_DIR": ""},
        ):
            clean_installer.main(["--activate-only", "--variant", "ergopti"])
        self.assertIsNone(seen["extensions_root"])

    def test_a_sandboxed_run_verifies_against_its_own_root(self):
        seen = {}
        with mock.patch("builtins.print"), mock.patch.object(
            clean_installer, "running_as_root", return_value=False
        ), mock.patch.object(
            clean_installer, "verify_keymap", side_effect=lambda *a, **k: seen.update(k)
        ), mock.patch.object(clean_installer, "activate_layout"), mock.patch.dict(
            clean_installer.os.environ, {"ERGOPTI_XKB_EXTENSIONS_ROOT": "/tmp/sandbox-extensions"}
        ):
            clean_installer.main(["--activate-only", "--variant", "ergopti"])
        self.assertEqual(str(seen["extensions_root"]).replace("\\", "/"), "/tmp/sandbox-extensions")

    def test_clean_activate_only_rejects_contradictory_flags(self):
        for argv in (
            ["--activate-only", "--deactivate-only"],
            ["--activate-only", "--uninstall"],
            ["--deactivate-only", "--uninstall"],
        ):
            with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
                clean_installer.parse_args(argv)

    def test_clean_installer_no_longer_offers_a_half_working_x11_bridge(self):
        """Symlinks into the legacy tree never carried the types rule, so an
        Xorg session got the layout with dead layers; X11 is the legacy method's job."""
        with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
            clean_installer.parse_args(["--xkb", "a", "--types", "b", "--support-x11"])

    def test_legacy_spec_targets_the_fr_variant(self):
        self.assertEqual(legacy_installer.legacy_spec("Ergopti_v2_2_1"), LEGACY)
        self.assertEqual(legacy_installer.legacy_spec("fr+Ergopti_v2_2_1"), LEGACY)
        self.assertEqual(legacy_installer.legacy_layout_id("Ergopti_v2_2_1"), "fr+Ergopti_v2_2_1")

    def test_legacy_activation_requires_an_identifier(self):
        roots = legacy_installer.resolve_roots()
        with mock.patch.object(legacy_installer.logging, "error"):
            self.assertEqual(
                legacy_installer.run_activation_phase(None, roots), legacy_installer.EXIT_INSTALL_ABORTED
            )

    def test_legacy_activation_uses_the_shared_module_with_the_split_spec(self):
        roots = legacy_installer.resolve_roots()
        with mock.patch("builtins.print"), mock.patch.object(
            legacy_installer, "running_as_root", return_value=False
        ), mock.patch.object(legacy_installer, "compile_check", return_value=True), mock.patch.object(
            legacy_installer, "activate_layout"
        ) as activate:
            self.assertEqual(
                legacy_installer.run_activation_phase("Ergopti_v2_2_1", roots), legacy_installer.EXIT_OK
            )
        activate.assert_called_once_with([LEGACY])

    def test_legacy_activation_aborts_when_the_tree_is_unusable(self):
        roots = legacy_installer.resolve_roots()
        with mock.patch("builtins.print"), mock.patch.object(
            legacy_installer, "running_as_root", return_value=False
        ), mock.patch.object(legacy_installer, "compile_check", return_value=False), mock.patch.object(
            legacy_installer, "activate_layout"
        ) as activate:
            self.assertEqual(
                legacy_installer.run_activation_phase("Ergopti_v2_2_1", roots),
                legacy_installer.EXIT_INSTALL_ABORTED,
            )
        activate.assert_not_called()

    def test_legacy_compile_check_gives_xorg_the_variant_probe(self):
        seen = {}
        roots = legacy_installer.InstallerRoots(Path("/ext"), Path("/sys"), Path("/cache"), sandboxed=True)
        with mock.patch.object(
            legacy_installer, "verify_keymap", side_effect=lambda *a, **k: seen.update(k) or True
        ):
            self.assertTrue(legacy_installer.compile_check(roots, LEGACY))
        self.assertEqual(seen["xkbcomp_probe"].symbols, "pc+fr(Ergopti_v2_2_1)+inet(evdev)")
        self.assertEqual(seen["xkbcomp_probe"].types, "complete")
        self.assertEqual([str(p) for p in seen["include_roots"]], [str(Path("/sys"))])

    def test_legacy_activation_reruns_unprivileged_when_root(self):
        roots = legacy_installer.resolve_roots()
        with mock.patch("builtins.print"), mock.patch.object(
            legacy_installer, "running_as_root", return_value=True
        ), mock.patch.object(legacy_installer, "rerun_unprivileged", return_value=0) as rerun:
            self.assertEqual(
                legacy_installer.run_activation_phase("Ergopti_v2_2_1", roots), legacy_installer.EXIT_OK
            )
        self.assertIn("fr+Ergopti_v2_2_1", rerun.call_args[0][0])


class EntrypointWiringTests(unittest.TestCase):
    """The shell entry point owns the privileged/unprivileged split."""

    def setUp(self):
        self.script = (Path(__file__).resolve().parents[1] / "install.sh").read_text(encoding="utf-8")

    def test_the_privileged_run_never_activates(self):
        self.assertIn('INSTALLER_ARGS+=(--variant "$VARIANT_ID" --skip-activation)', self.script)
        self.assertIn("INSTALLER_ARGS+=(--skip-activation)", self.script)

    def test_privileged_calls_go_through_the_helper(self):
        self.assertNotIn("sudo python3", self.script)
        self.assertNotIn("sudo \"$PYTHON_BIN\"", self.script)
        self.assertEqual(self.script.count('as_root "$PYTHON_BIN"'), 3)

    def test_activation_runs_outside_privileges_for_both_methods(self):
        activation_lines = [line.strip() for line in self.script.splitlines() if "--activate-only" in line]
        self.assertEqual(len(activation_lines), 2, activation_lines)
        for line in activation_lines:
            self.assertTrue(line.startswith('ACTIVATION_COMMAND=("$PYTHON_BIN"'), line)
            self.assertNotIn("as_root", line)

    def test_a_failed_activation_stops_the_script_with_the_diagnostic_hint(self):
        index = self.script.index('"${ACTIVATION_COMMAND[@]}"')
        self.assertIn("--diagnose", self.script[index : index + 600])

    def test_the_interpreter_floor_is_checked_before_any_installer_runs(self):
        self.assertLess(self.script.index("check_python"), self.script.index('as_root "$PYTHON_BIN"'))
        self.assertIn("MIN_PYTHON_MINOR=8", self.script)

    def test_no_installer_run_writes_bytecode_into_the_users_checkout(self):
        """Root-owned __pycache__ left in the temporary checkout made the
        cleanup fail, and the failure became the exit code of a successful
        installation."""
        invocations = [line for line in self.script.splitlines() if '"$PYTHON_BIN" "' in line or '"$PYTHON_BIN" -B' in line]
        self.assertEqual(len(invocations), 8, invocations)
        for line in invocations:
            self.assertIn('"$PYTHON_BIN" -B', line)

    def test_the_exit_trap_cannot_turn_a_success_into_a_failure(self):
        cleanup = self.script[self.script.index("cleanup() {") : self.script.index("trap cleanup EXIT")]
        self.assertIn("set +e", cleanup)
        self.assertIn("trap - ERR", cleanup)
        self.assertIn('rm -rf "$TEMP_DIR" 2>/dev/null || true', cleanup)

    def test_uninstall_leaves_the_session_before_removing_the_files(self):
        for script in ("xkb_files_installer_legacy.py", "xkb_files_installer_clean.py"):
            deactivate_index = self.script.index(f"{script}\" --deactivate-only")
            uninstall_index = self.script.index(f"{script}\" \\\n                --uninstall --skip-activation")
            self.assertLess(deactivate_index, uninstall_index, script)

    def test_the_copy_paste_command_is_fish_compatible(self):
        self.assertNotIn('branch="$branch"', self.script)


class DetectorWiringTests(unittest.TestCase):
    def setUp(self):
        self.script = (
            Path(__file__).resolve().parents[1] / "detect_installation_method.sh"
        ).read_text(encoding="utf-8")

    def test_an_x11_session_is_routed_to_the_legacy_method(self):
        """Xorg compiles with its own xkbcomp and never sees extension directories."""
        x11_branch = self.script.index("    x11)")
        self.assertIn("METHOD=legacy", self.script[x11_branch : x11_branch + 400])
        self.assertLess(x11_branch, self.script.index("version_ge \"$LIB_VER\""))

    def test_the_library_tool_is_probed_before_package_managers(self):
        self.assertLess(self.script.index("xkbcli --version"), self.script.index("pkg-config --modversion xkbcommon"))


if __name__ == "__main__":
    unittest.main()
