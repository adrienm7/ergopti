--- modules/keymap/emulation_admission.lua

--- ==============================================================================
--- MODULE: Layout Emulation Admission (Linux)
--- DESCRIPTION:
--- Decides which consumers a physical key-down reaches while one of Ergopti's
--- own windows holds the input capture gate (platform/input/capture_gate.lua):
--- the hotstring editor's text field acquires it so its triggers do not expand
--- inside the editor.
---
--- FEATURES & RATIONALE:
--- 1. The layout is the user's way of typing, so it types everywhere: in a
---    password manager, and in Ergopti's own text fields. The gate withholds
---    the consumers that act on text (hotstrings, shortcuts, tap keys, the AI,
---    wrap-on-type), never the layout emulation. Before, the whole consumption
---    callback sat behind the gate and the emulation stopped inside Ergopti's
---    windows (Arch Linux field report, 2026-11-25).
--- 2. A field that records a physical key or shortcut still reads the raw key:
---    it observes the evdev key position through the keyboard hook's
---    capture_position (ui/physical_shortcuts/bridge.lua) before any consumer
---    runs, so the emulation never changes what it records.
--- 3. An emulated key pressed while the gate is held keeps its repeats and its
---    release, as outside it: a lost release would leave the key held.
--- ==============================================================================

local M = {}

--- Builds the consumption callback the keyboard hook calls on a key-down.
--- @param gate table The daemon's input capture gate ({ blocks_text }).
--- @param emulate function (detail) -> consumed, repeat_callback, release_callback:
---   modules/keymap/layout_emulation.on_key.
--- @param ordinary function (detail) -> verdict: every other consumer, emulation
---   included, as the daemon runs them while no Ergopti window holds the gate.
--- @return function consume (detail) -> verdict for keyboard_hook.on_consume.
function M.consumer(gate, emulate, ordinary)
	if type(gate) ~= "table" or type(gate.blocks_text) ~= "function" then
		error("emulation_admission: the capture gate is required")
	end
	if type(emulate) ~= "function" or type(ordinary) ~= "function" then
		error("emulation_admission: the emulation and the ordinary consumers are required")
	end
	return function(detail)
		if gate.blocks_text() ~= true then return ordinary(detail) end
		local emulated, repeat_callback, release_callback = emulate(detail)
		if not emulated then return nil, "input capture blocked" end
		if repeat_callback == nil then return true end
		return { consume = true, repeat_callback = repeat_callback, release_callback = release_callback }
	end
end

return M
