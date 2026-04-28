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
---  2. Documents the role of each F-key so a new contributor immediately knows
---     why the codebase reserves F13/F17/F18/F19/F20 for synthetic events.
---  3. Stateless and side-effect-free: pure constants, safe to require anywhere
---     without any init pattern.
--- ==============================================================================

local M = {}




-- =====================================
-- =====================================
-- ======= 1/ Function Key Codes =======
-- =====================================
-- =====================================

--- F13 (keycode 105) — Karabiner-emitted "cycle windows in app" hotkey.
--- Bound by modules/karabiner/watchers.lua so the shortcut is layout-independent.
M.F13_CYCLE_WINDOWS = 105

--- F17 (keycode 64) — synthetic "typing complete" / chain-trigger signal sent
--- by the LLM bridge after applying a prediction. The prediction engine listens
--- for this keycode in handle_chain_signal() to fire the next chained request
--- as soon as the HID queue drains. Distinct from F20 so it cannot be confused
--- with the script-control kill-switch.
M.F17_LLM_CHAIN_SIGNAL = 64

--- F18 (keycode 79) — Karabiner sentinel for the right-command + Backspace
--- script-control slot. Also reused by modules/shortcuts/actions/system.lua as
--- a benign keystroke to wake the OS without touching the user's text.
M.F18_KARABINER_BACKSPACE = 79

--- F19 (keycode 80) — Karabiner sentinel for the right-command + Return slot,
--- and the physical "layer" key whose hold-and-scroll combination is mapped to
--- system volume up/down by modules/shortcuts/actions/system.lua.
M.F19_KARABINER_RETURN = 80

--- F20 (keycode 90) — Karabiner sentinel for the right-command + Escape slot.
--- Reserved as the Hammerspoon kill-switch path — DO NOT reuse it for any
--- internal "typing complete" signalling, or pressing F20 manually would
--- accidentally fire LLM chains. Use F17 for chain signalling instead.
M.F20_KARABINER_ESCAPE = 90




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

--- Karabiner synthetic layer keys (107/113/106) — emitted by the active layer
--- when no real action is bound; ignored by keymap/tooltip dispatchers.
M.LAYER_SYN_1 = 107
M.LAYER_SYN_2 = 113
M.LAYER_SYN_3 = 106

return M
