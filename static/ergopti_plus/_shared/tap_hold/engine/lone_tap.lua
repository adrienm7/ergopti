--- _shared/tap_hold/engine/lone_tap.lua

--- ==============================================================================
--- MODULE: Lone Modifier Tap Window (shared)
--- DESCRIPTION:
--- How long a tap-hold key whose hold is a modifier may stay down, pressed
--- alone, and still type its tap (tap_holds.lone_modifier_tap_max_ms).
---
--- FEATURES & RATIONALE:
--- 1. Alone means nothing else was pressed, released, clicked or scrolled under
---    the key: nothing was typed under its hold, so waiting longer for the
---    release costs nothing, while a chord is still decided at once by the hold
---    taken at key-down. A deliberate Shift tap for Copy often lasts 200 to
---    300 ms and copied nothing under the 200 ms threshold (field report
---    mac-2026-11-03).
--- 2. 0 is the strict tap-hold: the tap only under the threshold. A key whose
---    own delay is longer keeps it. The typing keys and the holds that wait for
---    their threshold (a layer, a one-shot Shift) never take the window; each
---    driver decides which of its keys are such a modifier key.
--- 3. The tap minimum (tap_hold.tap_min_duration_ms) bounds the other side on
---    the three drivers; on macOS Karabiner's to_if_alone has no minimum, so the
---    generator gates each tap on a delayed action (platform/remap/generator.lua
---    apply_tap_minimum).
--- 4. One rule for the Lua drivers; the Windows driver ports it in AHK
---    (platform/remap/constants.ahk TapHoldTapWindowSec). The bounds are the
---    shared value schema's (_shared/settings/data/value_schema).
--- ==============================================================================

local ValueCheck = require("settings.engine.value_check")

local M = {}

-- The setting's declaration in the shared value schema owns its bounds.
local KEY = require("settings.engine.keys").KEY.TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS

--- Validates the configured window against its shared declaration (0 or a
--- whole number of milliseconds up to the declared maximum), raising a
--- message that names the setting and the reason otherwise.
--- @param value any The configured milliseconds.
--- @return number window_ms 0 (strict) or a positive whole number of milliseconds.
function M.validate(value)
	return ValueCheck.require_value(nil, KEY, value)
end

--- The longest press that still types the tap.
--- @param threshold_ms number The key's tap / hold threshold.
--- @param lone_modifier boolean Whether the key is a modifier key pressed alone.
--- @param window_ms number The configured window, 0 for strict.
--- @return number tap_max_ms
function M.tap_max_ms(threshold_ms, lone_modifier, window_ms)
	if lone_modifier and window_ms > threshold_ms then return window_ms end
	return threshold_ms
end

--- The windows the menu offers, in order, 0 (Off) first: the feature's
--- preset_values in the manifest, the one list the three drivers read.
--- @param feature table The generated tap_holds.lone_modifier_tap_max_ms entry.
--- @return table choices_ms A copy of the declared windows.
function M.choices(feature)
	assert(type(feature) == "table" and type(feature.preset_values) == "table"
		and #feature.preset_values >= 2,
		"tap_holds.lone_modifier_tap_max_ms declares no preset_values in the manifest")
	local choices = {}
	for index, value in ipairs(feature.preset_values) do
		choices[index] = M.validate(value)
	end
	return choices
end

return M
