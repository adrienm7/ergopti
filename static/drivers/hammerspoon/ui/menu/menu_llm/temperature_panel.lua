--- ui/menu/menu_llm/temperature_panel.lua

--- ==============================================================================
--- MODULE: LLM Temperature Panel
--- DESCRIPTION:
--- Builds the temperature-related menu items for the LLM generation submenu.
---
--- FEATURES & RATIONALE:
--- 1. Isolated panel: keeps init.lua focused on wiring rather than individual
---    setting UIs — temperature items live next to their i18n keys and flags.
--- 2. Delegates setters to settings_manager: this panel only builds menu items
---    and never owns the set/reset callbacks, which already live in the manager.
--- ==============================================================================

local M = {}

local llm_mod = require("modules.llm")
local i18n    = require("lib.i18n")




-- ==============================
-- ==============================
-- ======= 1/ Public API =======
-- ==============================
-- ==============================

--- Builds temperature-related menu items and appends them to the target table.
--- @param ctx table Context: { state, keymap, is_disabled, save_prefs, update_menu, settings_mgr, llm_mod }.
--- @param out table The destination menu table to append items into.
function M.build(ctx, out)
	local state        = ctx.state
	local keymap       = ctx.keymap
	local is_disabled  = ctx.is_disabled
	local save_prefs   = ctx.save_prefs
	local update_menu  = ctx.update_menu
	local settings_mgr = ctx.settings_mgr

	-- Temperature input with reset if changed from default
	table.insert(out, {
		title    = string.format(i18n.get("menu.llm.temperature_label"), tostring(state.llm_temperature)),
		disabled = is_disabled or nil,
		fn       = settings_mgr.set_temperature,
	})
	if state.llm_temperature ~= llm_mod.DEFAULT_STATE.llm_temperature then
		table.insert(out, {
			title    = string.format(i18n.get("menu.llm.reset_label"), tostring(llm_mod.DEFAULT_STATE.llm_temperature)),
			disabled = is_disabled or nil,
			fn       = settings_mgr.reset_temperature,
		})
	end

	-- Auto-raise temperature across parallel predictions — only useful when
	-- multiple predictions are requested so the variants explore different
	-- temperature regions (disabled badge when num_predictions < 2)
	table.insert(out, {
		title    = i18n.get("menu.llm.auto_raise_temp"),
		checked  = state.llm_auto_raise_temp,
		disabled = (is_disabled or (tonumber(state.llm_num_predictions) or llm_mod.DEFAULT_STATE.llm_num_predictions) < 2) or nil,
		fn       = function()
			state.llm_auto_raise_temp = not state.llm_auto_raise_temp
			if keymap and type(keymap.set_llm_auto_raise_temp) == "function" then
				pcall(keymap.set_llm_auto_raise_temp, state.llm_auto_raise_temp)
			end
			save_prefs(); update_menu()
		end,
	})
end

return M
