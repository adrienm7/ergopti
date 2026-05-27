--- ui/menu/menu_llm/streaming_panel.lua

--- ==============================================================================
--- MODULE: LLM Streaming Panel
--- DESCRIPTION:
--- Builds the display-related menu items for the LLM tray menu.
--- Covers the indent selector, info bar toggle, token-streaming toggle, and
--- the show-all-at-once (parallel display) toggle.
---
--- FEATURES & RATIONALE:
--- 1. Isolated panel: keeps init.lua focused on wiring, not on individual
---    setting UIs — each toggle lives next to its i18n key and state flag.
--- 2. Indent sub-menu is delegated to settings_manager, which already owns
---    the per-indent-value state mutation logic.
--- ==============================================================================

local M = {}

local llm_mod = require("modules.llm")
local i18n    = require("lib.i18n")




-- ==============================
-- ==============================
-- ======= 1/ Public API =======
-- ==============================
-- ==============================

--- Builds the display submenu items and returns the full submenu table.
--- @param ctx table Context: { state, keymap, is_disabled, save_prefs, update_menu, settings_mgr }.
--- @return table The Hammerspoon menu structure for the display submenu.
function M.build(ctx)
	local state        = ctx.state
	local keymap       = ctx.keymap
	local is_disabled  = ctx.is_disabled
	local save_prefs   = ctx.save_prefs
	local update_menu  = ctx.update_menu
	local settings_mgr = ctx.settings_mgr

	local display_menu = {}

	-- Indentation picker — only meaningful with multiple predictions (num < 2 disables)
	local num_preds_safe = tonumber(state.llm_num_predictions) or llm_mod.DEFAULT_STATE.llm_num_predictions
	table.insert(display_menu, {
		title    = i18n.get("menu.llm.indent_label"),
		disabled = (is_disabled or num_preds_safe < 2) or nil,
		menu     = settings_mgr.build_indent_menu(),
	})

	-- Info bar visibility toggle
	table.insert(display_menu, {
		title    = i18n.get("menu.llm.show_info_bar"),
		checked  = state.llm_show_info_bar,
		disabled = is_disabled or nil,
		fn       = function()
			state.llm_show_info_bar = not state.llm_show_info_bar
			if keymap and type(keymap.set_llm_show_info_bar) == "function" then
				pcall(keymap.set_llm_show_info_bar, state.llm_show_info_bar)
			end
			save_prefs(); update_menu()
		end,
	})

	-- Streaming flags are nil-safe: old configs without these keys default to false
	local streaming_on       = (state.llm_streaming == true)
	-- true = show predictions progressively as tokens arrive (per-prediction streaming)
	local streaming_multi_on = (state.llm_streaming_multi == true)
	local num_preds_multi    = tonumber(state.llm_num_predictions) or llm_mod.DEFAULT_STATE.llm_num_predictions

	-- Token-level streaming — only visible when multi-prediction streaming is on,
	-- since per-token updates are meaningless in show-all-at-once mode
	table.insert(display_menu, {
		title    = i18n.get("menu.llm.show_streaming"),
		checked  = streaming_on,
		disabled = (is_disabled or not streaming_multi_on) or nil,
		fn       = not is_disabled and function()
			state.llm_streaming = not streaming_on
			if keymap and type(keymap.set_llm_streaming) == "function" then
				pcall(keymap.set_llm_streaming, state.llm_streaming)
			end
			save_prefs(); update_menu()
		end or nil,
	})

	-- Show-all-at-once toggle — independent of token streaming;
	-- only irrelevant when num_predictions < 2
	table.insert(display_menu, {
		title    = i18n.get("menu.llm.show_all_at_once"),
		checked  = not streaming_multi_on,
		disabled = (is_disabled or num_preds_multi < 2) or nil,
		fn       = (not is_disabled and num_preds_multi >= 2) and function()
			state.llm_streaming_multi = not streaming_multi_on
			if keymap and type(keymap.set_llm_streaming_multi) == "function" then
				pcall(keymap.set_llm_streaming_multi, state.llm_streaming_multi)
			end
			save_prefs(); update_menu()
		end or nil,
	})

	return display_menu
end

return M
