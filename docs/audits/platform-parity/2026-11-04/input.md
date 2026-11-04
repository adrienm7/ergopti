# Input, remapping and gesture parity review

Reviewed `/workspace/ergopti` at `c2fa6197b2be521df5bd0bfa71ee2a3805e9838d` on 2026-11-04. Audit only; no repository files edited. Read `.agents/skills/cross-driver-parity/SKILL.md`, routed memory index and text-input memory, existing parity audit and TODO. Existing gap declarations were treated as hypotheses and compared to runtime owners.

## New finding: typing-key tap-hold rollover is behaviorally different on macOS

This is an intentional implementation constraint/alternative policy, not complete runtime parity. With native Space tap and Shift hold, press Space, press `a` before the threshold, release `a` while Space remains down. Windows/Linux can classify that as a hold and emit Shift+a; macOS emits Space then `a` on the next key-down and never later introduces the hold. A slow isolated Space hold still works on macOS. Relevant keys are the shared rollover catalogue, intersected with the OS's key catalogue.

Evidence:

- `_shared/tap_hold/defaults.toml:103-121` explicitly documents release-order classification on Windows/Linux versus Karabiner's next-key-down typing priority and declares `tap_hold.rollover.keys = [escape, tab, enter, space, backspace, delete]`.
- `macos/platform/remap/generator.lua:1083-1096` sets `to_delayed_action.to_if_canceled` to the native tap and only raises the hold at the hold threshold. This branch requires a native-equivalent tap and a different hold.
- `windows/platform/remap/tap_hold_roll.ahk:360-379` resolves tap when a second subsequent key appears or the original comes up; resolves hold when the first intervening key comes up or threshold elapses.
- `linux/platform/remap/tap_hold_engine.lua:1009-1011` resolves the pending key as a tap if that key comes up first; its pending rollover branch and timer resolve intervening-key release/threshold as hold. The file reads the shared rollover list rather than an independent key list.
- `macos/tests/unit/platform/remap/generator/test_generator_typing_rollover.lua:48-110` tests the actual generated graph through its Karabiner model: next press emits native tap without hold, slow hold activates exactly at threshold, and cancellation never later raises a hold. Native suites were not run here.

Recommended TODO wording: “Document and evaluate macOS typing-key tap-hold rollover behavior: unlike Windows/Linux release-order classification, Karabiner emits the native tap at the next key-down before the threshold. Retain the current safe typing policy unless a verified alternative can preserve typing and immediate chords.” Do not promise exact release-order parity merely because all three consume the same catalogue.

## New finding: macOS onboarding still excludes a capability available in its menu

`_shared/modules/features/manifest.toml:4841-4852` declares onboarding control `number_row_order` for `ahk,linux` only and states macOS keeps the system row. However `macos/ui/menu/menu_keyboard_layout.lua:294-340` presents writable order and edge controls, persists them and invokes `modules.keymap.number_row_live.apply`. `macos/modules/keymap/number_row_live.lua:1-18,76-112` rebuilds a selected driver-owned .keylayout live. Availability requires a selected installed/composed driver-owned layout, rather than arbitrary system layouts. The macOS onboarding bridge (`macos/ui/onboarding/init.lua:398`) supplies only `gesture_registration=false`, no `number_row_live` capability.

This is a missing onboarding surface, not a missing macOS number-row feature. TODO: expose the macOS live number-row control in onboarding with the same availability and source-layout reason as the menu, or document why its onboarding exposure remains intentionally different. Also correct stale manifest comments at `4223-4224` and `4265-4266` claiming macOS/Linux never write number-row ordering. Linux does write it through `linux/modules/keymap/number_row_live.lua:72-98` and menu `linux/ui/menu/menu_layouts.lua:180-202`.

Linux live application is intentionally narrower than all Linux sessions: `linux/modules/keymap/layout_registry.lua:1010-1025` accepts X11 and GNOME/KDE Wayland, otherwise refuses. `linux/modules/keymap/number_row_live.lua:50-56` also requires an installed source layout. The menu already explains unavailable sessions/source layouts; classify this as a runtime environment condition, not a globally missing Linux feature.

## Correction: the hold picker parity test does not prove one picker on all three OSes

`node tools/test/test-tap-hold-hold-options-parity.cjs` passes and prints “same order on every driver”. Its inspected runtime files are Windows and the shared Lua module/Linux menu. It does not read the macOS menu or macOS actions.json. Therefore that success text cannot substantiate a macOS hold-picker equivalence claim.

Actual sources:

- `_shared/tap_hold/defaults.toml:98-102`: `tap_hold.hold_picker.modifiers = [ctrl,shift,alt,alt_gr,win]`, `layers=[nav]`, plus modifier aliases and left-side aliases.
- `_shared/lua/tap_hold/hold_options.lua:56-92` enumerates nonempty modifier combinations depth-first in the declared order; sentinel none + 31 combinations + nav = 33 Windows/Linux options. Windows uses its corresponding enumerator, tested by the JS gate.
- `macos/ui/menu/menu_tap_holds.lua:348-355,487-494` opens an action picker and accepts `action.holdable == true` for holds.
- `macos/platform/remap/init.lua:133,7033` loads `platform/remap/data/actions.json` through `Config.load_available_actions`.
- `macos/platform/remap/config.lua:435-451` reads and names local actions, then appends shared modifier chords; appended actions are explicitly nonholdable at `config.lua:350`.

The macOS JSON has 19 holdable entries: none; nav (`id=layer`); the 15 nonempty combinations of four ordinary modifiers Ctrl, Shift, Option and Command (the four-modifier combination is `id=hyper`); Fn; Fn+Shift. This is alternative native modifier vocabulary, not evidence that macOS lacks 14 useful hold features. Windows/Linux expose AltGr separately; macOS has Option and Command and native Fn. Fn is not separately injectable by ordinary PC drivers. Mac IDs `cmd`, `alt`, `hyper`, `layer` must be normalized to actual semantics before comparison.

Reproduce the native macOS set:

```sh
node -e 'const a=require("./static/ergopti_plus/macos/platform/remap/data/actions.json"); console.log(a.filter(x=>x.holdable===true).map(x=>({id:x.id,modifiers:x.modifiers,hold_layer:x.hold_layer,karabiner_to:x.karabiner_to})))'
```

## Canonical inventory schema and omitted vocabularies

At audited HEAD the generator reads feature model, actions.toml, menu_manifest.json and layer_actions.toml (`tools/codegen/codegen-feature-inventory.cjs:257-296`). It does not read the input catalogue or onboarding control declarations separately. Recommended additional source-driven projections:

1. `defaults.tap_hold.catalog.keys`: array of `{id,hand,ahk?,hs?,linux?}` at `_shared/tap_hold/defaults.toml:246-266`. Project presence of each OS column, preserve IDs per platform and hand/order. It has 19 identity rows, 14 per OS. These are physical native key identities, not a missing-feature checklist: Fn/Command/Option versus Win/Alt/AltGr are natural vocabulary differences. No hand-maintained copy needed. `test-tap-hold-key-catalog-single-source.cjs` already verifies source correspondence and tray consumption.
2. Hold picker: read `defaults.tap_hold.hold_picker.{modifiers,layers,modifier_aliases,left_modifier_aliases}` for Windows/Linux; enumerate 31 nonempty combos plus sentinel and layers. Read `macos/.../actions.json` holdable entries for macOS and preserve actual modifier vectors/hold_layer. Do not assign macOS availability to every shared hold option. Add a gate that compares actual Mac filtered rows if claiming parity in prose.
3. `actions.toml [slots].single` and `[slots].axis` at `93-109`: 36 discrete slots and 3 axis slots. The source supplies names, not full per-OS availability. Windows supported touchpad slots must be derived from its actual input owner, not assigned to every declared slot; existing action metadata already describes axis action restriction but is not a slot-level matrix.
4. `defaults.tap_hold.rollover.keys` should be described as behavioral policy with per-OS mechanism above, rather than universal release-order support.
5. `manifest.onboarding.pages.*.controls` deserves a surface-level projection if the matrix claims all onboarding controls (the number-row issue above otherwise remains invisible).

Other shared files checked: `_shared/modules/actions/tap_keys.json` has three number-row edge tap keys already covered individually by feature-manifest `shortcuts.tap_keys`; avoid duplicating them as new product features. `_shared/modules/features/shortcuts.toml` explicitly says STATUS UNREAD; its generator and outputs were deleted, so do not treat it as runtime truth. `_shared/data/keycodes/physical_keys.json` is the complete physical registry, with 114 positions (105 keys, 5 buttons, 4 wheels), but presence in that registry alone does not prove native input availability.

## Existing gaps independently corroborated / false gaps rejected

- Windows physical editor genuinely unavailable: `windows/ui/physical_shortcuts/README.md:3-15` explicitly states no host/bridge/runtime and keeps the canonical menu disabled. Shared form existence does not establish support.
- macOS and Linux physical editors are real native bridges, not shared assets alone: `macos/ui/physical_shortcuts/init.lua:182-256` joins the running native physical-capture observer and scope source; `linux/ui/physical_shortcuts/bridge.lua:39-61,109-135` requires actual scope/native availability and joins `keyboard_hook.capture_position`. Linux capture implementation is at `linux/adapters/keyboard_hook.lua:1975-2035`; macOS at `macos/modules/keystats/physical_capture.lua:43`. Availability remains session/runtime dependent. Per-device bindings are a known deferred design in TODO item 108, not an OS-level feature proven from observer facts.
- Bulk copy tap assignments to simultaneous chord slots: menu declaration `menu.toml:1693-1695` includes only hs/linux; Linux production caller `linux/ui/menu/key_combinations.lua:178`, macOS `macos/ui/menu/menu_tap_holds.lua:1365`. Existing Windows gap remains credible; no Windows caller found by recursive search.
- Layer input/action differences are explicitly encoded in `layer_actions.toml`: mouse button source excludes Linux (`95-96`); Fn modifier macOS only (`78-80`); repeat_count Windows only (`120-124`); layer Spotlight macOS only. Wheel remapping is supported in every OS via different native mechanisms; do not infer no macOS wheel layer solely from Karabiner not capturing wheels (`layer_actions.toml:85-91`).

## Checks run

All these commands passed at audited HEAD:

- `node tools/test/test-layer-actions-vocabulary.cjs`: 47 layer actions, 75 catalogue keystrokes agree, four reason keys in 21 locales.
- `node tools/test/test-tap-hold-hold-options-parity.cjs`: 33 Windows/shared-Lua picker options. Scope caveat above.
- `node tools/test/test-tap-hold-key-catalog-single-source.cjs`: 19 identities, 14 per driver, engine/menu agreement.
- `node tools/test/test-tap-hold-threshold-parity.cjs`: common 200ms global default, no shipped per-key override.
- `node tools/test/test-key-combination-defaults-parity.cjs`: three recommended pairs agree by physical position; 182 macOS matrix rows have no unexpected shipped chord/hold defaults.
- `node tools/test/test-gesture-slots-single-source.cjs`: generated Linux and macOS slot names agree with shared slot-space.
- `node tools/test/test-physical-keys-registry.cjs`: 114 physical positions agree with tracked hand copies.
- `node tools/test/test-keymap-layers-corpus.cjs`: 51 JS loader vectors, 12 error codes, all three OS projections.
- `node tools/test/test-layer-editor-model.cjs`: 51 files, 656 isolated single-OS edits, 168 availability probes.

These are meaningful static/model/registry checks, not actual desktop/hardware execution. No Lua/LuaJIT interpreter was available. No Windows AHK or macOS Hammerspoon/Karabiner native runtime was exercised. The review covers the named module families and source owners above, not a proof of zero remaining gaps in every runtime path.
