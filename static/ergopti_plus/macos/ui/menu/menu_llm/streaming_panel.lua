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
--- 2. Transactional delegation: every display setting routes through the shared
---    settings manager so runtime, persistence, and menu publication settle once.
--- ==============================================================================

local M = {}

local llm_mod = require("modules.llm")
local i18n    = require("infra.i18n")
local ManifestMenu  = require("infra.manifest_menu")





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Builds the display submenu items and returns the full submenu table.
--- @param ctx table Context: { state, is_disabled, settings_mgr }.
--- @return table The Hammerspoon menu structure for the display submenu.
function M.build(ctx)
	local state        = ctx.state
	local is_disabled  = ctx.is_disabled
	local settings_mgr = ctx.settings_mgr

	local rows = {}

	-- Indentation picker — only meaningful with multiple predictions (num < 2 disables)
	local num_preds_safe = tonumber(state.llm_num_predictions) or llm_mod.DEFAULT_STATE.llm_num_predictions
	table.insert(rows, {
		label    = i18n.get("menu.llm.indent_label"),
		disabled = (is_disabled or num_preds_safe < 2) or nil,
		submenu  = settings_mgr.build_indent_menu(),  -- settings_mgr's tree, handed over whole
	})

	-- Info bar visibility toggle
	table.insert(rows, {
		label    = i18n.get("menu.llm.show_info_bar"),
		checked  = state.llm_show_info_bar,
		disabled = is_disabled or nil,
		action   = function()
			return settings_mgr.apply_setting_transaction({
				key = "llm_show_info_bar",
				value = not state.llm_show_info_bar,
				runtime_fn = "set_llm_show_info_bar",
				publish_setting = false,
			})
		end,
	})

	-- Streaming flags are nil-safe: old configs without these keys default to false
	local streaming_on       = (state.llm_streaming == true)
	-- true = show predictions progressively as tokens arrive (per-prediction streaming)
	local streaming_multi_on = (state.llm_streaming_multi == true)
	local num_preds_multi    = tonumber(state.llm_num_predictions) or llm_mod.DEFAULT_STATE.llm_num_predictions

	-- Token-level streaming — only visible when multi-prediction streaming is on,
	-- since per-token updates are meaningless in show-all-at-once mode
	table.insert(rows, {
		label    = i18n.get("menu.llm.show_streaming"),
		checked  = streaming_on,
		disabled = (is_disabled or not streaming_multi_on) or nil,
		action   = not is_disabled and function()
			return settings_mgr.apply_setting_transaction({
				key = "llm_streaming",
				value = not streaming_on,
				runtime_fn = "set_llm_streaming",
				publish_setting = false,
			})
		end or nil,
	})

	-- Show-all-at-once toggle — independent of token streaming;
	-- only irrelevant when num_predictions < 2
	table.insert(rows, {
		label    = i18n.get("menu.llm.show_all_at_once"),
		checked  = not streaming_multi_on,
		disabled = (is_disabled or num_preds_multi < 2) or nil,
		action   = (not is_disabled and num_preds_multi >= 2) and function()
			return settings_mgr.apply_setting_transaction({
				key = "llm_streaming_multi",
				value = not streaming_multi_on,
				runtime_fn = "set_llm_streaming_multi",
				publish_setting = false,
			})
		end or nil,
	})

	return ManifestMenu.render_rows(rows, "llm_display")
end

return M
