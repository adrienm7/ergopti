--- ui/menu/menu_caps_word.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off Menu
--- DESCRIPTION:
--- Draws « CapsWord : désactivation automatique », declared by
--- caps_word_auto_off_group as on every driver: the delay choice, one checkbox
--- per hotstring delimiter (the shared catalogue's order, labels and
--- separators) and one per pointer kind of the manifest section. A change
--- applies to the CapsWord watcher at once, then is saved; a refused save
--- restores the state.
--- ==============================================================================

local M = {}

local i18n            = require("infra.i18n")
local ManifestMenu    = require("infra.manifest_menu")
local CapsWordAutoOff = require("infra.capsword_auto_off")
local CapsWordPolicy  = require("caps_word.auto_off")
local Manifest        = require("infra.manifest_reader")

--- Builds the group's rows.
--- @param ctx table Menu context (state, save_prefs, updateMenu, state_getters, applyTriggerChar).
--- @return table|nil rows Rendered rows for the group.
function M.build(ctx)
	local state = ctx.state
	local function commit(key, value)
		local previous = state[key]
		state[key] = value
		if CapsWordAutoOff.apply_state(state) ~= true then
			state[key] = previous
			return false
		end
		if ctx.save_prefs() ~= true then
			state[key] = previous
			CapsWordAutoOff.apply_state(state)
			return false
		end
		ctx.updateMenu()
		return true
	end
	local render_ctx = {}
	for key, value in pairs(ctx) do render_ctx[key] = value end
	render_ctx.commands = {
		["caps_word_idle_timeout"] = function(seconds) return commit(CapsWordAutoOff.IDLE_KEY, seconds) end,
	}
	render_ctx.state_getters = {}
	for key, value in pairs(ctx.state_getters or {}) do render_ctx.state_getters[key] = value end
	render_ctx.state_getters["shortcuts.caps_word.idle_timeout_seconds"] = function()
		return state[CapsWordAutoOff.IDLE_KEY]
	end
	local providers = {
		["caps_word_terminators"] = function()
			local rows, checked = {}, {}
			for _, key in ipairs(state[CapsWordAutoOff.TERMINATORS_KEY] or {}) do checked[key] = true end
			for _, row in ipairs(CapsWordPolicy.terminator_rows()) do
				if row.separator then
					local boundary = ManifestMenu.template_rows("hotstrings_parameter_boundary", {}, {}, {})
					if not boundary then return {} end
					for _, separator in ipairs(boundary) do rows[#rows + 1] = separator end
				else
					rows[#rows + 1] = {
						label = ctx.applyTriggerChar(i18n.get(row.label_key)),
						checked = checked[row.key] or nil,
						action = function()
							local list = CapsWordPolicy.with_terminator(
								state[CapsWordAutoOff.TERMINATORS_KEY], row.key, not checked[row.key])
							if not list then return false end
							return commit(CapsWordAutoOff.TERMINATORS_KEY, list)
						end,
					}
				end
			end
			return rows
		end,
		-- One row per kind of the manifest section, in its order. A kind another
		-- platform declares alone is drawn greyed with its reason.
		["caps_word_pointer_kinds"] = function()
			local rows, POINTER = {}, CapsWordAutoOff.POINTER_KEY
			local here = {}
			for _, kind in ipairs(CapsWordAutoOff.pointer_kinds()) do here[kind] = true end
			for _, entry in ipairs(Manifest.declared_section_entries("shortcuts.caps_word.pointer")) do
				local kind = entry.id
				if here[kind] then
					rows[#rows + 1] = {
						label = i18n.get(entry.description_key),
						checked = state[POINTER][kind] == true or nil,
						action = function()
							local pointer = {}
							for id, enabled in pairs(state[POINTER]) do pointer[id] = enabled end
							pointer[kind] = not pointer[kind]
							return commit(POINTER, pointer)
						end,
					}
				else
					rows[#rows + 1] = { label = i18n.get(entry.description_key), disabled = true,
						disabled_reason_key = entry.reason_key }
				end
			end
			return rows
		end,
	}
	return ManifestMenu.build("caps_word_auto_off_group", "Shortcuts", nil, nil, render_ctx, providers)
end

return M
