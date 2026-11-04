<!-- docs/platform-parity-audit.md -->

# Ergopti+ platform parity audit

This audit describes the source tree at the time of the change. The generated
[entry-by-entry review queue](feature-inventory.md) is updated from the actual
catalogues, and includes every missing configuration path, bindable action and
platform-restricted interactive menu entry, with action alternatives and menu reasons. An
entry is not the same thing as a user-facing capability: an OS can provide the
same capability through a different path. A declaration is not a runtime or
hardware test.

## Sources and checks

- Configuration and settings: `_shared/modules/features/manifest.toml`, resolved
  with the same platform inheritance as the driver generator. The existing
  Linux evidence gate checks registration, calls, application and proof tiers.
- Bindable actions and gesture axes: `_shared/modules/actions/actions.toml`.
  Its generator requires a reason for each missing platform and validates named
  equivalents; driver suites compare generated catalogues to executable actions.
- User-visible unavailable controls: `_shared/modules/menu/menu.toml` and its
  generated `menu_manifest.json`. Restricted interactive rows and rows with `unavailable = "grey"` supply the
  platform-specific reason where declared. The menu's own drift and dispatch gates remain the
  authority for its projection and handlers.
- Additional capabilities: compared the three driver module and UI trees,
  runtime entry points, platform-specific action reasons, and the bundled macOS
  app descriptions. Files with matching names are leads, not proof of parity.

## Findings beyond individual configuration paths

| Capability                                                  | Windows                                    | macOS                                                          | Linux                                                                                      | Evidence and qualification                                                                                                                                    |
| ----------------------------------------------------------- | ------------------------------------------ | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Physical shortcut editor                                    | Unavailable                                | Declared                                                       | Declared                                                                                   | `physical_shortcuts_editor` menu row and `physical_shortcuts.windows_unavailable`                                                                             |
| Token-by-token prediction display                           | Unvalidated and disabled                   | Declared                                                       | Declared                                                                                   | `llm_token_streaming` menu row; distinct from typing predictions directly into a document                                                                     |
| Insert prediction directly as it arrives                    | Declared                                   | Bubble then accept                                             | Bubble then accept                                                                         | `platform_reason.inline_autotype_is_windows`                                                                                                                  |
| Prompt profile automatically follows model                  | Declared                                   | Applied on request                                             | Declared                                                                                   | `platform_reason.llm_profile_follows_model_is_not_on_macos`                                                                                                   |
| Tap-hold word-reset option                                  | Declared                                   | No equivalent option                                           | Declared                                                                                   | `platform_reason.tap_hold_word_reset_not_on_macos`; macOS Karabiner input follows the shortcut option                                                         |
| Shortcut-only restore/clear                                 | Declared                                   | Configuration restore combines shortcut and Karabiner settings | Declared                                                                                   | `scope_restore` and `scope_clear` in `shortcuts_menu`                                                                                                         |
| Continuous gesture axes and step sizes                      | Discrete system gestures                   | Continuous                                                     | Discrete                                                                                   | `ax_actions` and `platform_reason.gesture_modes_and_steps_are_macos`; catalogue records discrete equivalents                                                  |
| Extra touchpad slots                                        | Three/four finger system slots             | Two to five fingers, including diagonals                       | Shared gesture slot set, subject to device/session                                         | `actions.toml` slots and Windows touchpad reason; actual device support requires testing                                                                      |
| Floating WPM widget                                         | Implemented                                | Implemented                                                    | Implemented                                                                                | Windows `ui/wpm/wpm_widget.ahk`, macOS `ui/wpm/wpm_widget.lua`, Linux `ui/wpm/widget.lua` and runtime registration. Linux availability is not hardware proof. |
| WPM in system bar                                           | Floating widget instead                    | Menu bar                                                       | Notification area                                                                          | `platform_reason.wpm_readout_needs_a_menubar`                                                                                                                 |
| Wrap-symbol pair management                                 | Custom add/delete and bulk controls        | Custom add/delete and bulk controls                            | Fixed-pair invocation; no custom/bulk menu controls                                        | Linux `ui/menu/menu_shortcuts.lua`; shared `wrap_symbols_*` control rows filter Linux                                                                         |
| Focused-application identity                                | Native API                                 | Native API                                                     | X11 and selected Wayland compositors; unavailable on GNOME, KDE, COSMIC and Weston Wayland | `linux/adapters/window_info.lua`; unknown identity constrains per-application rules and is not equivalent to an empty application                             |
| Tap-hold copy confirmation                                  | Check supported by platform implementation | Check supported by platform implementation                     | Unchecked on Wayland or X11 without xclip                                                  | `linux/platform/remap/tap_copy.lua`: copy is sent, but the counter-dependent retry and warning cannot run                                                     |
| Pointer center, teleport, spotlight                         | Declared                                   | Declared                                                       | No implementation                                                                          | `sg_actions` reasons: Wayland restricts pointer moves/overlays; X11-only implementations remain potential work                                                |
| Open terminal or create file in current file-manager folder | Declared                                   | Declared                                                       | No implementation                                                                          | Action catalogue records lack of a common Linux file-manager interface; per-file-manager support remains potential work                                       |
| Accented-key shortcut remapping                             | Declared                                   | Native layout control/command layer                            | No equivalent                                                                              | `platform_reason.accented_shortcuts_are_windows`                                                                                                              |
| MLX local inference                                         | Not applicable                             | Apple Silicon                                                  | Not applicable                                                                             | `platform_reason.llm_mlx_is_apple_silicon`; Ollama is separate                                                                                                |
| Keyboard layout emulation                                   | Declared                                   | Installed system input source                                  | Installed XKB layout                                                                       | `platform_reason.layout_emulation_is_windows_only`; these are different installation models                                                                   |
| App Cloner bundled application                              | No bundled counterpart found               | Bundled                                                        | No bundled counterpart found                                                               | `macos/apps/App Cloner.app/Contents/Info.plist`; separate app clones and profiles                                                                             |
| Encryptor bundled application                               | No bundled counterpart found               | Bundled                                                        | No bundled counterpart found                                                               | `macos/apps/Encryptor.app/Contents/Info.plist`; file encryption/decryption is distinct from text and metrics encryption                                       |

The English catalogue also contains stale Linux claims. The reason
`platform_reason.llm_configuration_surface_is_not_on_linux` says Linux has no
backend, profile, trigger or display surfaces, while `linux/ui/menu/menu_llm.lua`
provides them and `menu.toml` explicitly selects Linux's inline generation
provider. `platform_reason.metrics_extras_are_not_on_linux` says there is no
per-application exclusion, while `linux/ui/menu/menu_metrics.lua` and
`modules/keystats/keystats.lua` implement it. These strings are not reliable
proof of absence; correcting and propagating their translations is tracked in
TODO. The Linux action `open_personal_shortcuts` additionally resolves
`personal_shortcuts.toml`, but the declared editable shortcut owner uses
`config.toml`; no production reader of that file was found in this tree. Its
actual behavior requires verification and is tracked separately.

The complete action-level list also includes OS-specific system commands,
keyboard shortcuts, sticky modifiers and equivalents. For example, a missing
macOS `copy` action is provided as a modifier/key combination, and a missing
Windows executable-permission action reflects the OS permission model. The
queue deliberately retains these entries with reasons instead of counting all of
them as missing product features.

The comparison does not establish that every unregistered feature has been
identified, nor that all declared features behave identically. New capabilities
must be registered in the appropriate shared catalogue; code review and runtime
or hardware tests remain necessary to establish behavior. Linux evidence tracks
hardware proof independently of software registration.
