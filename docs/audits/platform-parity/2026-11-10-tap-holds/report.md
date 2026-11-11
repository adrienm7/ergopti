# Tap-holds, chords and the navigation layer: Windows, macOS, Linux and shared

Audited source: `637c017a` (`dev`). Date: November 10, 2026.

The register's next module. Windows (`windows/platform/remap/*.ahk`,
`windows/infra/key_combinations.ahk`) is the read-only reference; the Linux
engine (`linux/platform/remap/`), the macOS Karabiner generator
(`macos/platform/remap/`) and the shared policy (`_shared/lua/tap_hold/`,
`_shared/tap_hold/defaults.toml`) were compared with it, sequence by
sequence. Linux candidates were replayed through the pure engine and pair
policy under LuaJIT; macOS candidates through the generator on the shipped
preset and `macos/tests/support/karabiner_model.lua`. No native receiving
(evdev/uinput, Karabiner, AHK) was executed: these are source and model
counterexamples.

## Source census reconciliation

`tools/audit/source-areas.py --ref HEAD` gives 375 areas against the 363 of
the last pinned census (`2026-11-05-native-ui/source-areas.json`, source
`3aaaae7d`): 12 new areas (Linux `apps`, `keep_awake`, `take_note`,
`bundled_apps`, desktop application resolution, reload refusal; shared
`lua/color`, `ui/key_names.js`, `ui/metrics_manifest_keys.js`; Windows `apps`,
`native/keyboard_layout`), none removed, 206 with changed members, 157
unchanged. The new and changed areas need review before a register row can
claim them; this campaign covers only the tap-hold ones (`platform` on each
OS, `lua/tap_hold`, the keymap areas it reads).

## Fixed (Linux and shared)

| Id      | Sequence                                                                             | Windows                                                                                    | Linux before                                  | Regression                                  |
| ------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ | --------------------------------------------- | ------------------------------------------- |
| THL-001 | LAlt with `tap_action = "tab"` and no hold: press, repeats, J under it               | Generic tap-only block 4.9: Tab at key-down and each repeat (block 4.2 needs a hold layer) | Held the navigation layer; J gave Ctrl+Left   | `lalt-tab-no-hold-is-tap-only`              |
| THL-002 | LAlt or Tab set to `alt_tab_monitor`, RCtrl set to `tab`, no hold, lone 600 ms press | Strict `KS_WaitReleased(.., TapHoldDuration)`: no tap                                      | Lone tap window (1000 ms): switcher / Tab     | `strict-tap-no-lone-window` (AltGr control) |
| THL-003 | Pairs `left_shift_then_space` and `caps_lock_then_space`; LShift, CapsLock, Space    | `KeyCombinationHeldFirstKey`: the earliest pressed first key, LShift                       | Catalogue order: CapsLock                     | `pair-first-key-press-order`                |
| THL-004 | Pair with a hold, second key released after 20 ms                                    | Minimum tap checked (`constants.ahk` `TapHoldOwnImmediateModifier`)                        | The pair's tap ran                            | `pair-tap-minimum`                          |
| THS-001 | Chord delay and symmetry defaults                                                    | Manifest `mod_combos` (100, false)                                                         | macOS reads `[hs_timeouts]`, an unpinned copy | `chord-defaults-single-source`              |

Continued on November 11, 2026 (source `adfc5569`), from the remaining rows below:

| Id      | Sequence                                                                                          | Windows                                                                                       | Linux before                                         | Regression                      |
| ------- | ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ---------------------------------------------------- | ------------------------------- |
| THL-005 | RCtrl tapping the one-shot Shift held, LAlt tapping Tab with no hold modifier struck under it     | `SC11D & SC038` (`lalt.ahk` 4.2): Shift+Tab at key-down, `OneShotShiftFix`, any hold layer    | A plain Tab (no hold), or LAlt held the layer        | `rctrl-one-shot-lalt-shift-tab` |
| THL-006 | A user `layers.toml` binds LAlt; LAlt taps Backspace with the layer on hold; another key holds it | The static `*SC038` swallower (`nav_layer.ahk` 1) predates the `Hotkey()` bindings: swallowed | LAlt took the layer's binding (plain and per-source) | `layer-swallow-beats-binding`   |

## Decisions pending (behaviour left unchanged)

- **THD-1, a pair tap under the navigation layer.** Windows `_KeyCombinationRunTap`
  calls `DisableLayer()` and the layer stays off until the layer key is pressed
  again; Linux lifts the first key's layer around the action and restores it;
  macOS (`lcmd_caps` and the other combination rules) leaves `layer_active`
  set. Three behaviours, no recorded contract.
- **THD-2, timing of a pair's own tap (minimum decided 2026-11-10).** The
  minimum tap now bounds a pair's release-judged tap on Linux (THL-004,
  regression `pair-tap-minimum`), as it does on Windows. Still open: Windows
  also gives such a pair the lone tap window, the shared policy the strict
  threshold.
- **THD-3, activity under a pair whose hold is the layer.** Windows
  `TapHoldOwnImmediateLayer` does not cancel the tap when a layer key was struck
  under it (probably a Windows defect); the shared policy cancels it.
- **THD-4, the thumb Backspace under a held modifier on macOS.** Windows
  `BackSpaceLogic` turns LAlt's tap into Delete under Shift, Ctrl+Backspace
  under LCtrl and a forward delete under the RCtrl one-shot; the macOS rules
  send a bare `delete_or_backspace`. The macOS per-key actions are part of the
  pending PAR-17 preset decision (`defaults.toml` header).

## Remaining work

- **macOS, minimum tap (decided 2026-11-10, implemented 2026-11-11):** every
  tap that waits for its release respects `tap_hold.tap_min_duration_ms`.
  `to_if_alone` has only a maximum and Karabiner does not re-process its own
  output, but v16 evaluates a to-event's own `conditions` when it posts it
  (`event_sender.hpp` `filter_and_replace_events`): the generator
  (`apply_tap_minimum`) clears a lease-scoped `ke_held_<key>_tap_min` at
  key-down, a `to_delayed_action` raises it after the minimum, and every tap
  event requires it. Rollover keys keep no minimum, as the Linux roll keys.
  Proven on the model (`test_generator_tap_minimum.lua`, the corpus vectors
  lost their macOS divergence); native timing stays on the Mac checklist.
- **Windows (maintainer's change):** extend the minimum tap beyond LShift,
  LCtrl, RShift, CapsLock holding the layer and LAlt with a non-Backspace tap.

- **Linux:** done on November 11 (THL-005, THL-006 above).
- **macOS:** RCtrl's (right_option's) one-shot Shift with no hold armed at
  key-down even on a long press; since November 11 it arms on a quick release
  and holds Shift past the threshold (regression `one-shot-no-hold-macos`;
  Karabiner drops that Shift when another key comes within the threshold,
  where Windows and Linux press it at the threshold anyway). LAlt's
  one-shot Shift holds no Shift while down and fires under every modifier
  (Windows `lalt.ahk` 4.1 holds LShift and stands down under RCtrl, CapsLock,
  LShift or LCtrl). Both are non-default configurations of the Karabiner
  generator. The pair first-key choice follows Karabiner rule order, not press
  order (not probed). Whether a wheel scroll cancels a Karabiner tap is not
  modelled.
- **Windows (report only):** with LAlt tapping Tab and RCtrl as the one-shot
  Shift, `SC11D & SC038` makes SC11D a prefix key, which probably delays
  RCtrl's own `*SC11D` hotkey to its release (unverified, no AHK runner).
  THD-3 above is likely a Windows defect.
- **Docs:** done on November 11: the comments above the `rcmd_*` rows and the
  `lcmd_rcmd` row of `defaults.toml` now describe the slots the rows carry.
