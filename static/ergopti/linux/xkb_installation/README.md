# Installing Ergopti XKB files

This document describes the Ergopti keyboard layout installation methods on Linux.

## Comparison

Two installation methods are available:

- Clean (recommended): installs into an XKB extensions directory.
- Legacy: modifies system XKB files for older distributions and X11 sessions.

| Aspect                        | Clean method                             | Legacy method                             |
| ----------------------------- | ---------------------------------------- | ----------------------------------------- |
| Python script                 | `xkb_files_installer_clean.py`            | `xkb_files_installer_legacy.py`            |
| Installation command          | `install.sh --installation-method clean`  | `install.sh --installation-method legacy`  |
| Requirements                  | libxkbcommon >= 1.13.0, Wayland session    | X11 or Wayland                            |
| Location                      | `/usr/share/xkeyboard-config.d/ergopti/`  | `/usr/share/X11/xkb/`                      |
| Patches system files          | No                                       | Yes                                       |
| Conflicts with system updates | No                                       | Possible                                  |
| Uninstallation                | Removes the extension package            | Restores managed backups                  |
| Composes with other packages  | Yes                                      | No                                        |

## Installation methods

### Clean method

Only libxkbcommon reads extensions directories. Xorg compiles layouts with its own `xkbcomp`
from the legacy tree and cannot see them. The detector therefore selects Legacy for X11
and unknown session types, including SSH and consoles. The package's `rules/evdev.post`
declares both unindexed and indexed `layout = types` rules (`layout[1]` through `layout[4]`).
An unindexed rule applies only to single-layout configurations, while GNOME and KDE compile
all configured sources into one keymap.

The clean package also exposes Ergopti under the existing French layout for input-method
pickers that require a French variant: use `fr` + `ergopti` (or `ergopti_plus` when that
variant is installed). On Hyprland, this means `kb_layout = fr` and `kb_variant = ergopti`.
The standalone `ergopti` layout and its existing named variant remain available and use
the same symbols. This configures the keyboard layout; Japanese conversion still depends
on the user's input method and its settings.

The package owns only its extension files. Its `symbols/fr` delegates the default to
`%S/fr`, adds the selected Ergopti section, and leaves other named French variants to the
system search path. Variant-specific rules attach the custom types in all four groups.

### Legacy method

The legacy script creates backups such as `file.ext.1` and `file.ext.2`. The command
`install.sh --uninstall` restores the first backup, representing the state before Ergopti,
for each modified file. The custom type goes inside the `xkb_types` section of `types/extra`.
A block appended outside that section is a syntax error rejected by `xkbcomp` and silently
ignored by libxkbcommon. Installation is transactional: if the resulting keymap does not
compile with the custom type present, every modified file is restored.

## Installer modes and options

```bash
# Interactive: choose the version and variant with fzf
bash install.sh

# Non-interactive: CI and scripts
bash install.sh --yes --version v2_2_1 --variant ergopti_plus

# Non-interactive uninstall: infer the method from installed files
bash install.sh --uninstall --yes

# Diagnostic report for bug reports; no root privileges required
bash install.sh --diagnose

# Alternate interpreter: the installer requires Python >= 3.8
PYTHON=python3.11 bash install.sh
```

The diagnostic report (`xkb_diagnose.py`) describes the system, graphical session, detected
desktop, XKB tools and versions, installed files for both methods, and GNOME/KDE settings.
It then compiles the detected Ergopti layouts with the system compilers. Every `install.sh`
run is also recorded in a log whose path appears first: `/tmp/ergopti-install.log` by default,
overridden by `ERGOPTI_INSTALL_LOG`.

Implementation contracts:

- Always install the complete types file, which defines Shift, CapsLock, AltGr and shortcut
  layers. The former choice without Ctrl broke shortcuts on accented keys (issue #84).
- `_ansi` variants are distinct from ISO layouts: ê, j and several symbols move between
  physical keys. Use `--ansi` for an ANSI keyboard.
- GNOME/KDE activation puts Ergopti first while retaining every other input source.
- Activation runs as the desktop user. Root writes to its own dconf database and cannot
  change the user's session. `install.sh` copies files with `sudo`, then runs the installer
  unprivileged with `--activate-only`. If invoked as root, activation drops privileges with
  `runuser` and reconstructs `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`.
- Read settings back after writing: dconf can report success without changing the intended
  user's configuration.
- Only the desktop owning a setting counts as activated. Hyprland, Sway and niri do not
  read GNOME settings, so the installer prints their configuration snippets. Unknown Wayland
  compositors receive an `~/.config/environment.d/` example. Sessions without `XDG_*`
  identification attempt all settings.
- `xkbcli compile-keymap` checks distribution search-path resolution and the presence of
  `ERGOPTI_SEVEN_LEVEL`, both alone and beside `us` in either order. This separates an
  undiscoverable package from a session that has not selected it.
- Successful compilation alone is insufficient: an unknown key type silently becomes
  `ONE_LEVEL`, causing the dead Shift layer reported in issue #84. The probe requires
  `<AD01>` (è) to bind the custom type in Ergopti's group and map and preserve Ctrl at level
  5, producing Ctrl+Z. Failure prints the exact command and compiler diagnostics and exits
  nonzero instead of claiming success.
- Xorg's `xkbcomp` checks clean symbols through `-I<package>` and legacy symbols through
  `pc+fr(variant)`. Without any compiler, the installation is marked unverified and
  `install.sh` offers to install the package providing `xkbcli`.
- A forced clean installation on libxkbcommon < 1.13 is rejected before writing files,
  because that library cannot load extensions directories.
- Clean packages use directory/file modes 0755/0644 regardless of the privileged process's
  umask. Read-only filesystems produce errors naming the path and cause. NixOS and Guix
  are rejected with platform-specific guidance.
- Legacy uninstallation preserves system files already replaced by a package manager,
  identified by the absence of Ergopti content; it removes only their obsolete backups.
- GNOME's `mru-sources` is aligned with `sources`: gnome-shell activates the first recent
  source at login, rather than the first entry of `sources`.
- KDE Plasma requires index-aligned `LayoutList` and `VariantList` values and `Use=true`.
  The legacy selection is `fr` plus `Ergopti_vX_Y_Z`, without GNOME's `+` separator. A D-Bus
  `org.kde.keyboard.reloadConfig` signal requests a reload.
- Generated `.XCompose` strings escape backslashes and quotes. An unescaped backslash
  previously caused libxkbcommon to ignore subsequent sequences.
- Uninstallation refuses to guess when clean and legacy artifacts coexist or when neither
  method is detected. For a mixed installation, inspect it and explicitly select
  `--installation-method clean|legacy`.
- Installation writes to system XKB directories and requires `sudo`. The former `--user`
  mode was removed because libxkbcommon did not load its path and its isolation from system
  files was not guaranteed.

### Directory overrides for sandbox tests

Environment overrides take precedence over default paths. Tests use them to run the real CLI
inside temporary directories without root privileges:

| Variable                      | Default                         | Purpose                                         |
| ----------------------------- | ------------------------------- | ----------------------------------------------- |
| `ERGOPTI_XKB_EXTENSIONS_ROOT` | `/usr/share/xkeyboard-config.d` | XKB extensions root                            |
| `ERGOPTI_XKB_SYSTEM_ROOT`     | `/usr/share/X11/xkb`            | Legacy X11 tree, including cleanup targets      |
| `ERGOPTI_XKB_CACHE_DIR`       | `/var/lib/xkb`                  | XKB cache cleared after installation           |
| `ERGOPTI_XKB_USER_HOME`       | Calling user's home            | Isolated home for XCompose tests               |

Clean Python installer exit codes: `0` success, `2` invalid arguments, `3` inconsistent
package or invalid keymap, `4` installation aborted.

## Files in this directory

- `install.sh`: installation entry point for downloading, selection and installation.
- `layout_package.py`: shared logic for canonical content, symbols/types validation and
  GNOME/KDE list merging.
- `desktop_activation.py`: session detection, privilege dropping, settings readback,
  compositor instructions, keymap verification and removal of input sources on uninstall.

Scripts called by `install.sh`:

- `detect_installation_method.sh`: automatic installation-method detection.
- `xkb_files_installer_clean.py`: extensions-directory installer.
- `xkb_files_installer_legacy.py`: legacy installer that modifies system files.
- `xkb_diagnose.py`: diagnostic report (`install.sh --diagnose`).

Run `python tests/run_all_tests.py` for unit tests, generated-layout consistency, sandbox
installation and uninstallation, diagnostics, and real compilation with `xkbcli` (>= 1.13
for Clean) and `xkbcomp` when installed. Regression cases cover unindexed rules, misplaced
type sections and French variant discovery. `tests/test_install_entrypoint.sh` runs the real
`install.sh` with test doubles for `sudo`, `fzf`, `gsettings`, `xkbcli` and `xkbcomp`.

The `linux-layout.yml` workflow runs `tests/e2e_distro.sh` in distribution containers:
Arch, Ubuntu 20.04 through 26.04, Debian 13 and sid, Fedora, Rocky 9, openSUSE Tumbleweed
and Leap 15.6, and Alpine edge. Each entry tests with the distribution's Python, installs
through the documented command from an unprivileged user using `sudo` or `doas`, verifies
the keymap independently with system compilers, checks `xkbcli list`, and uninstalls before
comparing the system tree byte for byte. Selected entries also exercise GNOME on a private
D-Bus bus with real dconf. Arch reproduces the issue #84 environment: fish, a wlroots
compositor and generation-2 installation leftovers.

## References

- [libxkbcommon: Packaging keyboard layouts](https://xkbcommon.org/doc/current/packaging-keyboard-layouts.html).
