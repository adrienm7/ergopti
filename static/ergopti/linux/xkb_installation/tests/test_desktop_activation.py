"""Tests for the shared desktop-activation contract.

Issue #84 was a silent failure: the files were installed, the installer
reported success, and the session kept the previous layout. Every test here
pins one of the reasons that could happen again.
"""

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import desktop_activation as activation  # noqa: E402
import xkb_files_installer_clean as clean_installer  # noqa: E402
import xkb_files_installer_legacy as legacy_installer  # noqa: E402


def gsettings_session(initial: str, writes: list[list[str]], accept: bool = True):
    """Return a fake ``subprocess.run`` backed by one in-memory dconf value."""
    state = {"value": initial}

    def fake_run(command, **kwargs):
        if command[:1] == ["gsettings"] and command[1] == "get":
            return SimpleNamespace(returncode=0, stdout=state["value"])
        if command[:1] == ["gsettings"] and command[1] == "set":
            writes.append(command)
            if accept:
                state["value"] = command[-1]
            return SimpleNamespace(returncode=0, stdout="")
        return SimpleNamespace(returncode=1, stdout="")

    return fake_run


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
        lines = activation.manual_instructions(
            "ergopti", {"hyprland"}, "wayland"
        )
        joined = "\n".join(lines)
        self.assertIn("hyprland.conf", joined)
        self.assertIn("kb_layout = ergopti", joined)

    def test_sway_snippet_quotes_the_layout(self):
        joined = "\n".join(activation.manual_instructions("ergopti", {"sway"}, "wayland"))
        self.assertIn('xkb_layout "ergopti"', joined)

    def test_unknown_wayland_compositor_gets_the_environment_fallback(self):
        joined = "\n".join(activation.manual_instructions("ergopti", {"weston"}, "wayland"))
        self.assertIn("environment.d", joined)
        self.assertIn("XKB_DEFAULT_LAYOUT=ergopti", joined)

    def test_every_compositor_snippet_renders_without_stray_braces(self):
        for name in activation.COMPOSITOR_INSTRUCTIONS:
            joined = "\n".join(activation.manual_instructions("ergopti", {name}, "wayland"))
            self.assertIn("ergopti", joined, name)
            self.assertNotIn("{layout}", joined, name)
            self.assertNotIn("{{", joined, name)

    def test_x11_without_a_known_compositor_gets_no_manual_block(self):
        self.assertEqual(activation.manual_instructions("ergopti", {"xfce"}, "x11"), [])


class PrivilegeDropTests(unittest.TestCase):
    def test_root_never_writes_to_the_session(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append(command)
            return SimpleNamespace(returncode=0, stdout="@a(ss) []")

        with mock.patch("builtins.print"), mock.patch.object(
            activation, "running_as_root", return_value=True
        ), mock.patch.object(activation.subprocess, "run", side_effect=fake_run):
            applied = activation.activate_layout(["ergopti"])

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


class GnomeApplyTests(unittest.TestCase):
    def test_layout_is_written_first_and_read_back(self):
        writes: list[list[str]] = []
        with mock.patch("builtins.print"), mock.patch.object(
            activation.subprocess, "run", side_effect=gsettings_session("[('xkb', 'us')]", writes)
        ):
            applied = activation.apply_gnome(["ergopti"], {"gnome"})

        self.assertTrue(applied)
        self.assertEqual(writes[-1][-1], "[('xkb', 'ergopti'), ('xkb', 'us')]")

    def test_a_write_that_does_not_stick_is_reported_as_a_failure(self):
        writes: list[list[str]] = []
        with mock.patch("builtins.print"), mock.patch.object(
            activation.subprocess,
            "run",
            side_effect=gsettings_session("[('xkb', 'us')]", writes, accept=False),
        ):
            applied = activation.apply_gnome(["ergopti"], {"gnome"})

        self.assertEqual(len(writes), 1)
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
            self.assertFalse(activation.apply_gnome(["ergopti"], {"gnome"}))
        self.assertEqual(writes, [])


class OwningDesktopTests(unittest.TestCase):
    """A write only counts when the desktop that reads it is the one running.

    gsettings-desktop-schemas is pulled in by many unrelated packages, so
    ``gsettings set`` succeeds under Sway or Hyprland and changes nothing those
    compositors read. Reporting that as success is issue #84 in a new disguise.
    """

    def run_activation(self, environ):
        writes: list[list[str]] = []
        printed: list[str] = []
        with mock.patch("builtins.print", side_effect=lambda *a, **k: printed.append(
            " ".join(str(part) for part in a)
        )), mock.patch.object(
            activation,
            "subprocess",
            SimpleNamespace(
                run=gsettings_session("[('xkb', 'us')]", writes),
                PIPE=-1,
                STDOUT=-2,
                DEVNULL=-3,
                TimeoutExpired=Exception,
            ),
        ), mock.patch.object(
            activation.shutil, "which", return_value=None
        ), mock.patch.object(activation, "running_as_root", return_value=False):
            applied = activation.activate_layout(["ergopti"], environ)
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

    def test_gnome_does_not_get_a_manual_block_when_the_write_sticks(self):
        environ = {"XDG_CURRENT_DESKTOP": "ubuntu:GNOME", "XDG_SESSION_TYPE": "wayland"}
        applied, output, writes = self.run_activation(environ)
        self.assertTrue(applied)
        self.assertEqual(len(writes), 1)
        self.assertNotIn("environment.d", output)
        self.assertNotIn("hyprland", output.lower())

    def test_an_unknown_wayland_session_falls_back_to_environment_d(self):
        environ = {"XDG_SESSION_TYPE": "wayland"}
        _, output, _ = self.run_activation(environ)
        self.assertIn("XKB_DEFAULT_LAYOUT=ergopti", output)

    def test_a_failed_gnome_write_offers_the_command_to_retry(self):
        writes: list[list[str]] = []
        printed: list[str] = []
        with mock.patch("builtins.print", side_effect=lambda *a, **k: printed.append(
            " ".join(str(part) for part in a)
        )), mock.patch.object(
            activation,
            "subprocess",
            SimpleNamespace(
                run=gsettings_session("[('xkb', 'us')]", writes, accept=False),
                PIPE=-1,
                STDOUT=-2,
                DEVNULL=-3,
                TimeoutExpired=Exception,
            ),
        ), mock.patch.object(
            activation.shutil, "which", return_value=None
        ), mock.patch.object(activation, "running_as_root", return_value=False):
            applied = activation.activate_layout(
                ["ergopti"], {"XDG_CURRENT_DESKTOP": "GNOME", "XDG_SESSION_TYPE": "wayland"}
            )
        output = "\n".join(printed)
        self.assertFalse(applied)
        self.assertIn("gsettings set org.gnome.desktop.input-sources sources", output)

    def test_kde_gets_a_plasma_instruction_rather_than_a_gsettings_one(self):
        lines = activation.manual_instructions("ergopti", {"kde", "plasma"}, "wayland")
        joined = "\n".join(lines)
        self.assertIn("kxkbrc", joined)
        self.assertNotIn("gsettings", joined)


class KeymapVerificationTests(unittest.TestCase):
    def test_a_missing_custom_type_fails_the_check(self):
        with mock.patch("builtins.print"), mock.patch.object(
            activation.shutil, "which", return_value="/usr/bin/xkbcli"
        ), mock.patch.object(activation, "run_capture", return_value="xkb_keymap {}"):
            self.assertFalse(activation.verify_keymap("ergopti", "ERGOPTI_SEVEN_LEVEL"))

    def test_a_layout_that_does_not_compile_fails_the_check(self):
        with mock.patch("builtins.print"), mock.patch.object(
            activation.shutil, "which", return_value="/usr/bin/xkbcli"
        ), mock.patch.object(activation, "run_capture", return_value=None):
            self.assertFalse(activation.verify_keymap("ergopti", "ERGOPTI_SEVEN_LEVEL"))

    def test_a_complete_keymap_passes(self):
        with mock.patch("builtins.print"), mock.patch.object(
            activation.shutil, "which", return_value="/usr/bin/xkbcli"
        ), mock.patch.object(
            activation, "run_capture", return_value="type ERGOPTI_SEVEN_LEVEL {"
        ):
            self.assertTrue(activation.verify_keymap("ergopti", "ERGOPTI_SEVEN_LEVEL"))


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
        ), mock.patch.object(
            clean_installer, "rerun_unprivileged", return_value=0
        ) as rerun:
            code = clean_installer.main(["--activate-only", "--variant", "ergopti"])
        self.assertEqual(code, clean_installer.EXIT_OK)
        argv = rerun.call_args[0][0]
        self.assertIn("--activate-only", argv)
        self.assertIn("ergopti", argv)

    def test_clean_activate_only_verifies_the_keymap_before_activating(self):
        order = []
        with mock.patch("builtins.print"), mock.patch.object(
            clean_installer, "running_as_root", return_value=False
        ), mock.patch.object(
            clean_installer, "verify_keymap", side_effect=lambda *a: order.append("verify")
        ), mock.patch.object(
            clean_installer, "activate_layout", side_effect=lambda *a: order.append("activate")
        ):
            code = clean_installer.main(["--activate-only", "--variant", "ergopti"])
        self.assertEqual(code, clean_installer.EXIT_OK)
        self.assertEqual(order, ["verify", "activate"])

    def test_a_real_install_verifies_through_the_distribution_search_path(self):
        """Overriding the search path would prove the files exist, not that the
        session can find them: only a sandboxed run may pass an explicit root."""
        seen = {}
        with mock.patch("builtins.print"), mock.patch.object(
            clean_installer, "running_as_root", return_value=False
        ), mock.patch.object(
            clean_installer,
            "verify_keymap",
            side_effect=lambda *args: seen.setdefault("root", args[2] if len(args) > 2 else None),
        ), mock.patch.object(clean_installer, "activate_layout"), mock.patch.dict(
            clean_installer.os.environ,
            {"ERGOPTI_XKB_EXTENSIONS_ROOT": "", "ERGOPTI_XKB_SYSTEM_ROOT": "", "ERGOPTI_XKB_CACHE_DIR": ""},
            clear=False,
        ):
            clean_installer.main(["--activate-only", "--variant", "ergopti"])
        self.assertIsNone(seen["root"])

    def test_a_sandboxed_run_verifies_against_its_own_root(self):
        seen = {}
        with mock.patch("builtins.print"), mock.patch.object(
            clean_installer, "running_as_root", return_value=False
        ), mock.patch.object(
            clean_installer,
            "verify_keymap",
            side_effect=lambda *args: seen.setdefault("root", args[2] if len(args) > 2 else None),
        ), mock.patch.object(clean_installer, "activate_layout"), mock.patch.dict(
            clean_installer.os.environ,
            {"ERGOPTI_XKB_EXTENSIONS_ROOT": "/tmp/sandbox-extensions"},
            clear=False,
        ):
            clean_installer.main(["--activate-only", "--variant", "ergopti"])
        self.assertEqual(str(seen["root"]).replace("\\", "/"), "/tmp/sandbox-extensions")

    def test_clean_activate_only_rejects_contradictory_flags(self):
        for argv in (
            ["--activate-only", "--deactivate-only"],
            ["--activate-only", "--uninstall"],
            ["--deactivate-only", "--uninstall"],
        ):
            with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
                clean_installer.parse_args(argv)

    def test_legacy_layout_id_targets_the_fr_variant(self):
        self.assertEqual(legacy_installer.legacy_layout_id("Ergopti_v2_2_1"), "fr+Ergopti_v2_2_1")
        self.assertEqual(
            legacy_installer.legacy_layout_id("fr+Ergopti_v2_2_1"), "fr+Ergopti_v2_2_1"
        )

    def test_legacy_activation_requires_an_identifier(self):
        with mock.patch.object(legacy_installer.logging, "error"):
            self.assertEqual(legacy_installer.run_activation_phase(None), 1)

    def test_legacy_activation_uses_the_shared_module(self):
        with mock.patch.object(
            legacy_installer, "running_as_root", return_value=False
        ), mock.patch.object(legacy_installer, "activate_layout") as activate:
            self.assertEqual(legacy_installer.run_activation_phase("Ergopti_v2_2_1"), 0)
        activate.assert_called_once_with(["fr+Ergopti_v2_2_1"])


class EntrypointWiringTests(unittest.TestCase):
    """The shell entry point owns the privileged/unprivileged split."""

    def setUp(self):
        self.script = (
            Path(__file__).resolve().parents[1] / "install.sh"
        ).read_text(encoding="utf-8")

    def test_the_privileged_run_never_activates(self):
        self.assertIn('INSTALLER_ARGS+=(--variant "$VARIANT_ID" --skip-activation)', self.script)
        self.assertIn("INSTALLER_ARGS+=(--skip-activation)", self.script)

    def test_activation_runs_outside_sudo_for_both_methods(self):
        activation_lines = [
            line.strip()
            for line in self.script.splitlines()
            if "--activate-only" in line
        ]
        self.assertEqual(len(activation_lines), 2, activation_lines)
        for line in activation_lines:
            self.assertFalse(line.startswith("sudo"), line)
            self.assertIn("python3", line)

    def test_uninstall_leaves_the_session_before_removing_the_files(self):
        deactivate_index = self.script.index("--deactivate-only")
        uninstall_index = self.script.index("--uninstall --skip-activation")
        self.assertLess(deactivate_index, uninstall_index)

    def test_the_copy_paste_command_is_fish_compatible(self):
        self.assertNotIn('branch="$branch"', self.script)


if __name__ == "__main__":
    unittest.main()
