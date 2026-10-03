--- ui/menu/menu_llm/temperature_panel.lua

--- ==============================================================================
--- MODULE: LLM Temperature Panel
--- DESCRIPTION:
--- Builds the temperature-related menu items for the LLM generation submenu.
---
--- FEATURES & RATIONALE:
--- 1. Isolated panel: keeps init.lua focused on wiring rather than individual
---    setting UIs — temperature items live next to their i18n keys and flags.
--- 2. Delegates every setting transition to settings_manager: this panel only
---    builds menu items and never owns partial state or persistence updates.
--- ==============================================================================

local M = {}

local llm_mod = require("modules.llm")
local i18n    = require("infra.i18n")





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Appends the temperature rows to the generation submenu's row array.
--- Row DATA since 2026-08-07: the caller renders the whole array through the
--- shared renderer, so this panel says what its rows are and nothing more.
--- @param ctx table Context: { state, is_disabled, settings_mgr }.
--- @param out table The destination numeric ROW array to append to.
--- @return table Context for the shared generation child and its acknowledged command.
function M.build(ctx, out)
	local state        = ctx.state
	local is_disabled  = ctx.is_disabled
	local settings_mgr = ctx.settings_mgr

	-- Temperature input with reset if changed from default
	table.insert(out, {
		label    = string.format(i18n.get("menu.llm.temperature_label"), tostring(state.llm_temperature)),
		disabled = is_disabled or nil,
		action   = settings_mgr.set_temperature,
	})
	if state.llm_temperature ~= llm_mod.DEFAULT_STATE.llm_temperature then
		table.insert(out, {
			label    = string.format(i18n.get("menu.llm.reset_label"), tostring(llm_mod.DEFAULT_STATE.llm_temperature)),
			disabled = is_disabled or nil,
			action   = settings_mgr.reset_temperature,
		})
	end

	--- Reads current native facts before rendering or delivering the command.
	--- @return boolean ready
	local function ready()
		local count = tonumber(state.llm_num_predictions) or llm_mod.DEFAULT_STATE.llm_num_predictions
		return not is_disabled and count >= 2
	end
	return {
		commands = {
			["llm_auto_raise_temperature"] = function()
				if not ready() then return false end
				return settings_mgr.apply_setting_transaction({
					key = "llm_auto_raise_temp",
					value = not state.llm_auto_raise_temp,
					runtime_fn = "set_llm_auto_raise_temp",
					publish_setting = false,
				})
			end,
		},
		state_getters = {
			["llm_auto_raise_enabled"] = function() return state.llm_auto_raise_temp end,
			["llm_auto_raise_ready"] = ready,
		},
	}
end

return M
