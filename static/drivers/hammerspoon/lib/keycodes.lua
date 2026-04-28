--- lib/keycodes.lua

--- ==============================================================================
--- MODULE: Keycode Registry
--- DESCRIPTION:
--- Central, single-source-of-truth registry of every macOS HID keycode used as
--- a sentinel, signal, or hotkey across the Ergopti+ Hammerspoon codebase.
--- Any module that needs to compare against a literal keycode MUST require this
--- module instead of redeclaring the value locally — that way the meaning of
--- each keycode lives in exactly one place and a future remap is a one-liner.
---
--- FEATURES & RATIONALE:
--- 1. Eliminates magic numbers scattered across script_control, prediction_engine,
---    llm_bridge, watchers, system, generator, keymap, and the tooltip modules.
--- 2. Documents the role of each F-key so a new contributor immediately knows
---    why the codebase reserves F13–F17 for sentinels and signals. F-keys are
---    allocated contiguously starting at F13; future features should consume
---    F18, F19, F20… in order. The legacy "layer syn" no-op channel — formerly
---    overlapping F14/F15/F16 — has been relocated to F21/F22/F23 to free the
---    F13–F17 block for real signal use.
--- 3. Stateless and side-effect-free: pure constants, safe to require anywhere
---    without any init pattern.
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
--- Bound by modules/karabiner/watchers.lua so the shortcut is layout-independent.
M.F17_CYCLE_WINDOWS = 64

--- F18 (keycode 79) — currently used by modules/shortcuts/actions/system.lua as
--- the OS-wake keystroke for the keep-awake jiggler. Free for reassignment.
M.F18_WAKE_OS = 79

--- F19 (keycode 80) — physical "layer" key whose hold-and-scroll combination is
--- mapped to system volume up/down by modules/shortcuts/actions/system.lua.
M.F19_VOLUME_SCROLL_MODIFIER = 80

--- F20 (keycode 90) — Karabiner-emitted "nav layer entered" sentinel. Fired
--- as the first action of any tap-hold that activates the navigation layer
--- (regardless of which physical key the user binds — space, left_command,
--- caps_lock, etc.) so Hammerspoon can distinguish "user is entering the nav
--- layer" from "user pressed a real key that should dismiss the tooltip".
--- The keymap dispatcher and the tooltip eventtaps ignore this keycode AND
--- reset the tooltip auto-dismiss timer when they see it.
M.F20_LAYER_NAV_ENTERED = 90




-- ========================
-- ===== 1.1) Helpers =====
-- ========================

--- Returns the lowercase macOS key name (e.g. "f13", "f20", "spacebar") for a
--- numeric keycode, by reverse-mapping hs.keycodes.map. Used by callers that
--- emit JSON destined for Karabiner Elements (which expects textual key names),
--- so the source of truth stays the numeric registry above and no magic
--- "f13"/"f20" string ever appears in Lua code.
--- @param numeric_code integer The macOS HID keycode to translate.
--- @return string The lowercase key name. Errors if the code is unknown.
function M.to_name(numeric_code)
	for name, code in pairs(hs.keycodes.map) do
		if code == numeric_code then return name end
	end
	error(string.format("Keycodes.to_name: unknown keycode %d", numeric_code))
end




-- =================================================
-- =================================================
-- ======= 2/ Other Hardcoded Physical Codes =======
-- =================================================
-- =================================================

--- Backspace (keycode 51) — used as the KE-paused fallback path in
--- modules/shortcuts/script_control.lua.
M.BACKSPACE = 51

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
