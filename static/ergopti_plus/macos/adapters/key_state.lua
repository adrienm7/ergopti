--- adapters/key_state.lua

--- ==============================================================================
--- MODULE: KeyState Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the KeyState port contract defined in
--- static/ergopti_plus/_shared/core/ports/KeyState.spec.js. Wraps hs.eventtap to query
--- the physical state of keyboard keys without coupling domain modules to hs APIs.
---
--- FEATURES & RATIONALE:
--- 1. Fail-safe returns: isDown() returns false and isUp() returns true on
---    any error, matching the port contract error_behavior ("absent key = up").
--- 2. Defensive pcall: hs.eventtap calls are wrapped to prevent propagation.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

local LOG = "adapters.key_state"




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

-- Normalisation map: platform-specific sided key names → canonical modifier name
-- used by hs.eventtap.checkKeyboardModifiers(). checkKeyboardModifiers() only
-- returns modifier flags (shift/ctrl/alt/cmd/fn); it cannot distinguish sides,
-- so we collapse left/right variants to the canonical name (H4 audit fix).
local KEY_NORMALISATION = {
	LShift = "shift",  RShift = "shift",
	LCtrl  = "ctrl",   RCtrl  = "ctrl",
	LAlt   = "alt",    RAlt   = "alt",
	LCmd   = "cmd",    RCmd   = "cmd",
}

--- Normalises a platform key name to the canonical modifier name expected by
--- hs.eventtap.checkKeyboardModifiers(). Unknown names are returned unchanged.
--- @param key_name string The raw key name to normalise.
--- @return string The normalised name.
local function normalize_key(key_name)
	return KEY_NORMALISATION[key_name] or key_name
end

--- Returns true when the key is physically held down.
--- @param key_name string Platform key identifier (e.g. "shift", "ctrl", "LShift").
--- @return boolean
function M.isDown(key_name)
	local ok, result = pcall(function()
		local flags = hs.eventtap and hs.eventtap.checkKeyboardModifiers
			and hs.eventtap.checkKeyboardModifiers()
		if type(flags) == "table" then
			return flags[normalize_key(key_name)] == true
		end
		return false
	end)
	if not ok then
		Logger.error(LOG, "isDown(): error checking %q — %s", tostring(key_name), tostring(result))
		return false
	end
	return result == true
end

--- Returns true when the key is not physically held down.
--- @param key_name string Platform key identifier.
--- @return boolean
function M.isUp(key_name)
	return not M.isDown(key_name)
end

--- Returns true when a right-hand AltGr modifier (right command OR right option)
--- is physically held at this instant. Unlike isDown(), this uses the
--- device-specific raw flag masks so a LEFT command/option is correctly excluded
--- — required by the script-control sentinel guard, which must accept a genuine
--- AltGr + key chord but reject a bare function key (no modifier held at all).
---
--- STRICTLY right-hand-only (right command OR right option — device bits only).
--- A prior widening (accepting deviceLeftAlternate, then a side-agnostic
--- `mods.alt == true` fallback with no device bit at all) was meant to support
--- Karabiner remaps that surface a remapped right_command as a generic left/plain
--- option, but it regressed a CRITICAL invariant: holding plain LEFT Option (no
--- right-hand modifier at all) while pressing a physical F13/F14/F15 key would
--- also read as "genuine", dispatching script_pause/reload/quit from an
--- unintentional chord (F-HIGH-22). sentinel_is_tagged() in script_control.lua is
--- now the primary discriminator for the KE-active path — every genuine KE-emitted
--- sentinel carries the ctrl+shift SCRIPT_CONTROL_SENTINEL_TAGS output modifiers
--- (karabiner/generator.lua build_script_control_sentinel_rules /
--- build_paused_script_control_rules), which a bare physical F-key press or a
--- left-Option chord can never carry. That tag check makes this narrower mask safe
--- again: genuine Karabiner remaps of right_command → option are still covered
--- because sentinel_is_genuine() accepts EITHER this live-modifier check OR the tag.
--- Falls back to the side-agnostic cmd flag only (never alt) when the raw masks are
--- unavailable (never on real macOS), so a bare key still cannot pass via alt alone.
--- @return boolean True if right command or right option is currently down.
function M.is_right_altgr_held()
	local ok, result = pcall(function()
		if not (hs.eventtap and hs.eventtap.checkKeyboardModifiers) then return false end
		local mods = hs.eventtap.checkKeyboardModifiers(true)
		if type(mods) ~= "table" then return false end

		local raw   = mods._raw
		local masks = hs.eventtap.event and hs.eventtap.event.rawFlagMasks
		if type(raw) == "number" and type(masks) == "table" then
			-- AltGr family: right command OR right option — device bits ONLY. Left
			-- command/option are excluded so a stray ⌘/⌥ + physical-F-key (or a plain
			-- left-Option hold) can never be mistaken for a genuine sentinel.
			local altgr = (masks.deviceRightCommand   or 0)
				| (masks.deviceRightAlternate or 0)
			return (raw & altgr) ~= 0
		end
		return mods.cmd == true
	end)
	if not ok then
		Logger.error(LOG, "is_right_altgr_held(): %s", tostring(result))
		return false
	end
	return result == true
end

--- Returns a human-readable list of the command/option/control/shift modifiers
--- currently held, by physical side, e.g. "rcmd lopt" or "(none)". Diagnostic
--- only — used by the script-control sentinel logs so that, if a chord is still
--- rejected, the exact held-modifier state appears in the log without a debugger.
--- @return string Space-separated side-tagged modifier names, or "(none)".
function M.describe_held_modifiers()
	local ok, result = pcall(function()
		if not (hs.eventtap and hs.eventtap.checkKeyboardModifiers) then return "(unavailable)" end
		local mods = hs.eventtap.checkKeyboardModifiers(true)
		if type(mods) ~= "table" then return "(unavailable)" end
		local raw   = mods._raw
		local masks = hs.eventtap.event and hs.eventtap.event.rawFlagMasks
		if type(raw) ~= "number" or type(masks) ~= "table" then
			-- Side-agnostic fallback: report whatever flags checkKeyboardModifiers gave.
			local flags = {}
			for _, name in ipairs({ "cmd", "alt", "ctrl", "shift", "fn" }) do
				if mods[name] == true then flags[#flags + 1] = name end
			end
			return #flags > 0 and table.concat(flags, " ") or "(none)"
		end
		local sided = {
			{ "rcmd",  masks.deviceRightCommand   }, { "lcmd",  masks.deviceLeftCommand   },
			{ "ropt",  masks.deviceRightAlternate }, { "lopt",  masks.deviceLeftAlternate  },
			{ "rctrl", masks.deviceRightControl   }, { "lctrl", masks.deviceLeftControl   },
			{ "rshift", masks.deviceRightShift    }, { "lshift", masks.deviceLeftShift     },
		}
		local held = {}
		for _, pair in ipairs(sided) do
			local mask = pair[2] or 0
			if mask ~= 0 and (raw & mask) ~= 0 then held[#held + 1] = pair[1] end
		end
		-- Append a side-agnostic flag ONLY when its family set no device bit (e.g. a
		-- KE remap that surfaces option as a generic `alt` with no deviceLeftAlternate).
		-- Tagged "(generic)" so the log distinguishes that from a genuine sided bit.
		local family_bits = {
			cmd = (masks.deviceRightCommand or 0)   | (masks.deviceLeftCommand or 0),
			alt = (masks.deviceRightAlternate or 0) | (masks.deviceLeftAlternate or 0),
			ctrl = (masks.deviceRightControl or 0)  | (masks.deviceLeftControl or 0),
			shift = (masks.deviceRightShift or 0)   | (masks.deviceLeftShift or 0),
		}
		for _, name in ipairs({ "cmd", "alt", "ctrl", "shift", "fn" }) do
			if mods[name] == true then
				local fam = family_bits[name] or 0
				if fam == 0 or (raw & fam) == 0 then held[#held + 1] = name .. "(generic)" end
			end
		end
		return #held > 0 and table.concat(held, " ") or "(none)"
	end)
	return ok and result or "(error)"
end

return M
