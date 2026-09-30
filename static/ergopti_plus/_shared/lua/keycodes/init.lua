--- _shared/lua/keycodes/init.lua

--- ==============================================================================
--- MODULE: Keycode Registry (Shared)
--- DESCRIPTION:
--- Hammerspoon-specific registry of every macOS HID keycode used as a sentinel,
--- signal, or hotkey across the Ergopti+ codebase.  These are macOS HID numeric
--- codes (F13–F17 sentinels, etc.) and are NOT meaningful on Linux (which uses
--- evdev codes — see _shared/data/keycodes/evdev.json).
--- Any module that needs to compare against a literal keycode MUST require this
--- module instead of redeclaring the value locally.
---
--- FEATURES & RATIONALE:
--- 1. Eliminates magic numbers scattered across script_control, prediction_engine,
---    llm_bridge, watchers, system, generator, keymap, and the tooltip modules.
--- 2. Documents the role of each F-key so a new contributor immediately knows
---    why the codebase reserves F13–F17 for sentinels and signals. F-keys are
---    allocated contiguously starting at F13; future features should consume
---    F18, F19, F20… in order.
--- 3. Stateless and side-effect-free: pure constants, safe to require anywhere
---    without any init pattern.
--- 4. Platform-neutral: depends only on numeric literals — no hs.* API here.
---    The HS-specific to_name() helper (which needs hs.keycodes.map) lives in
---    the Hammerspoon-local infra/keycodes.lua shim instead.
--- ==============================================================================

local M = {}





-- =====================================
-- =====================================
-- ======= 1/ Function Key Codes =======
-- =====================================
-- =====================================

--- F13 (keycode 105) — Karabiner sentinel for the "right-command + Return"
--- script-control slot. Emitted by Karabiner when the user fires the chord
--- while KE is active; consumed by modules/shortcuts/script_control.lua.
M.F13_KARABINER_RETURN = 105

--- F14 (keycode 107) — Karabiner sentinel for the "right-command + Backspace"
--- script-control slot. Also reused by modules/shortcuts/actions/system.lua as
--- a benign keystroke to wake the OS without touching the user's text.
M.F14_KARABINER_BACKSPACE = 107

--- F15 (keycode 113) — Karabiner sentinel for the "right-command + Escape"
--- script-control slot. Reserved as the Hammerspoon kill-switch path — DO NOT
--- reuse it for any internal signalling, otherwise pressing it manually would
--- tear down HS.
M.F15_KARABINER_ESCAPE = 113

--- F16 (keycode 106) — synthetic "typing complete" / chain-trigger signal sent
--- by the LLM bridge after applying a prediction. The prediction engine listens
--- for this keycode in handle_chain_signal() to fire the next chained request
--- as soon as the HID queue drains. Distinct from the kill-switch sentinel
--- (F15) so it cannot be confused with a user-driven script-control event.
M.F16_LLM_CHAIN_SIGNAL = 106

--- F17 (keycode 64) — Karabiner-emitted "cycle windows in app" hotkey.
--- Bound by platform/remap/watchers.lua so the shortcut is layout-independent.
M.F17_CYCLE_WINDOWS = 64

--- F18 (keycode 79) — two roles that never meet. modules/shortcuts/actions/
--- system.lua posts it itself as the keep-awake jiggler's OS-wake keystroke,
--- with Ergopti's provenance, which every sentinel reader refuses; Karabiner
--- emits it, tagged left_control + left_shift, as the sentinel of the right
--- Option + Delete script-control slot, the fourth slot every driver shares
--- since 2026-09-30, when F13–F17, F19 and F20 were all taken.
M.F18_WAKE_OS = 79
M.F18_KARABINER_DELETE = 79

--- F19 (keycode 80) — Karabiner-emitted "nav layer left" sentinel, the pair of
--- F20: tapped by every action that turns the navigation layer off (the hold's
--- release, an explicit layer off). Between F20 and F19 the macOS driver runs
--- the layer's wheel bindings, which Karabiner cannot take
--- (modules/shortcuts/actions/system.lua bind_layer_wheel). Deleted like F20
--- by modules/keymap/control_sentinels.lua.
M.F19_LAYER_NAV_EXITED = 80

--- F20 (keycode 90) — Karabiner-emitted "nav layer entered" sentinel. Fired
--- as the first action of any tap-hold that activates the navigation layer
--- (regardless of which physical key the user binds — space, left_command,
--- caps_lock, etc.) so Hammerspoon can distinguish "user is entering the nav
--- layer" from "user pressed a real key that should dismiss the tooltip".
--- On macOS the keymap eventtaps delete both phases through
--- modules/keymap/control_sentinels.lua so no application ever receives it,
--- then publish the signal in-process (the LLM tooltip renews its deadline).
M.F20_LAYER_NAV_ENTERED = 90

--- The constant naming the sentinel Karabiner emits for each script chord slot
--- (_shared/modules/actions/script_chords.json): written by the rules of
--- platform/remap/script_chord_rules.lua and read by
--- modules/shortcuts/script_control.lua, each through its keycode registry.
M.SCRIPT_CHORD_SENTINELS = {
	script_altgr_enter     = "F13_KARABINER_RETURN",
	script_altgr_backspace = "F14_KARABINER_BACKSPACE",
	script_altgr_delete    = "F18_KARABINER_DELETE",
	script_altgr_escape    = "F15_KARABINER_ESCAPE",
}

-- NOTE: M.to_name() is Hammerspoon-specific (requires hs.keycodes.map) and
-- lives in the HS-local infra/keycodes.lua shim, not here.





-- =================================================
-- =================================================
-- ======= 2/ Other Hardcoded Physical Codes =======
-- =================================================
-- =================================================

--- Backspace (keycode 51) — used as the KE-paused fallback path in
--- modules/shortcuts/script_control.lua.
M.BACKSPACE = 51

--- Forward Delete (keycode 117) — consumes one-shot Shift without shifting.
M.FORWARD_DELETE = 117

--- Return / Enter (keycode 36) — KE-paused fallback path counterpart.
M.RETURN = 36

--- Escape (keycode 53) — KE-paused fallback path counterpart, and also
--- consumed by modules/keymap/init.lua to dismiss predictions.
M.ESCAPE = 53

--- Tab (keycode 48) — used by the LLM tooltip eventtap to accept the currently
--- highlighted prediction (mirrors the on_accept path).
M.TAB = 48

--- Numpad Enter (keycode 76) — paired with RETURN in submit-key checks; some
--- keyboards send 76 instead of 36 for the numeric-keypad Enter key.
M.ENTER = 76

--- fn / globe (keycode 63, kVK_Function) — the key macOS reports in flagsChanged
--- for fn. The physical-key stream resolves the Apple vendor fn/globe usage to
--- this keycode (modules/keylogger/physical_key_identity.lua), so both sources
--- give the key one identity, the one the heatmap draws at the fn position.
M.FUNCTION = 63

--- Arrow keys (keycodes 123/124/125/126 — left/right/down/up) — consumed by
--- the LLM tooltip eventtap for prediction navigation. Each press also resets
--- the auto-dismiss timer so a user actively navigating never loses the
--- tooltip mid-decision.
M.LEFT_ARROW  = 123
M.RIGHT_ARROW = 124
M.DOWN_ARROW  = 125
M.UP_ARROW    = 126

--- Karabiner synthetic layer keys (relocated to F21/F22/F23 — keycodes 131,
--- 134, 135) — emitted by the active layer when no real action is bound;
--- ignored by keymap/tooltip dispatchers. Previously sat on 107/113/106
--- (physical F14/F15/F16) and clashed with the new sentinel block, so they
--- were moved into the high F-key range that no Apple keyboard exposes
--- physically.
M.LAYER_SYN_1 = 131
M.LAYER_SYN_2 = 134
M.LAYER_SYN_3 = 135

return M
