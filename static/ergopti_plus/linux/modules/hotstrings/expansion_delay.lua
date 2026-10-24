--- modules/hotstrings/expansion_delay.lua

--- ==============================================================================
--- MODULE: Expansion Delay Gate (Linux)
--- DESCRIPTION:
--- Decides whether a completed match still expands, from the gap between the last
--- letter of the input and the expander (see the project-hotstring-expansion-
--- delay-definition entry of docs/memory/text-input-and-config.md), widened for
--- a Shift, Alt or AltGr keystroke exactly as the Windows and macOS gates are.
---
--- FEATURES & RATIONALE:
--- 1. The rule is the shared engine's (`within_expansion_delay` and
---    `complex_delay_multiplier`) and the factor and the carry are the shared
---    timing registry's `[hotstrings] complex_key_delay_multiplier` and
---    `complex_key_carry_ms`: this file owns neither a rule nor a value, only
---    the join, so the cross-driver time-gate corpus replays it unchanged.
--- 2. Kept out of the daemon's main file so the corpus can call the very code
---    the keystroke path calls.
--- ==============================================================================

local M = {}

local Engine = require("modules.hotstrings.engine")
local Timings = require("infra.timings")

--- Whether the match is still inside its expansion delay.
--- @param result table Match returned by engine:on_char() (carries expander_gap_ms).
--- @param delay_sec number Allowed last-letter-to-expander pause in seconds; zero disables it.
--- @param resolution_ms number Resolution of the clock that stamped the keys.
--- @param expander_complex boolean Shift, Alt or AltGr was held on the expander keystroke.
--- @param reference_complex boolean The same for the keystroke before it (the last letter).
--- @param group string|nil The match's category; autocorrections are never widened.
--- @return boolean allowed
function M.allows(result, delay_sec, resolution_ms, expander_complex, reference_complex, group)
	local factor = Engine.complex_delay_multiplier(
		expander_complex == true, reference_complex == true,
		type(result) == "table" and tonumber(result.expander_gap_ms) or nil,
		Timings.count("hotstrings", "complex_key_delay_multiplier"),
		Timings.ms("hotstrings", "complex_key_carry_ms"),
		group ~= "autocorrection")
	return Engine.within_expansion_delay(result, delay_sec, resolution_ms, factor)
end

return M
