--- tests/support/cmd_star_ports.lua

--- ==============================================================================
--- MODULE: Modifiers + Magic Key Save Ports Fixture
--- DESCRIPTION:
--- The live owners bind_cmd_star reads at each chord, as plain values: the
--- magic key replaced, the automatic physical source, ★ on keycode 28 (the US
--- Shift+8 key the event fixtures press) and no shortcut on the chord.
--- ==============================================================================

local M = {}

-- The keycode whose plain press types the magic key in these fixtures.
M.MAGIC_KEYCODE = 28

--- Builds the ports, each value overridable.
--- @param overrides table|nil { replace_on, chosen_source, magic_key, owned, plain = { [code] = text } }.
--- @return table ports
--- @return table state The mutable values the ports read.
function M.build(overrides)
	local state = { replace_on = true, chosen_source = false, magic_key = "★", owned = false,
		plain = { [M.MAGIC_KEYCODE] = "★", [1] = "s" }, owns_calls = {} }
	for key, value in pairs(overrides or {}) do state[key] = value end
	return {
		replace_on = function() return state.replace_on end,
		chosen_source = function() return state.chosen_source end,
		magic_key = function() return state.magic_key end,
		plain_text = function(keycode) return state.plain[keycode] end,
		shortcut_owns = function(mods, keycode)
			state.owns_calls[#state.owns_calls + 1] = { mods = mods, keycode = keycode }
			return state.owned
		end,
	}, state
end

return M
