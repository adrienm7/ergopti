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
local DisplayPolicy = require("llm.display_policy")
local Preferences = require("infra.preferences")
local ConfigPaths = require("infra.config_paths")





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Builds the display submenu items and returns the full submenu table.
--- @param ctx table Context: { state, is_disabled, is_paused?, settings_mgr }.
--- @return table The Hammerspoon menu structure for the display submenu.
function M.build(ctx)
	local state        = ctx.state
	local is_disabled  = ctx.is_disabled
	local settings_mgr = ctx.settings_mgr

	local leading_rows = {}
	local rows = {}

	-- Indentation picker — only meaningful with multiple predictions (num < 2 disables)
	local num_preds_safe = tonumber(state.llm_num_predictions) or llm_mod.DEFAULT_STATE.llm_num_predictions
	table.insert(leading_rows, {
		label    = i18n.get("menu.llm.indent_label"),
		disabled = (is_disabled or num_preds_safe < 2) or nil,
		submenu  = settings_mgr.build_indent_menu(),  -- settings_mgr's tree, handed over whole
	})

	local function streaming_snapshot()
		local snapshot = llm_mod.streaming_snapshot()
		local source = settings_mgr.setting_snapshot("llm_streaming_multi")
		local canonical, canonical_source = Preferences.current_view(ConfigPaths.get("ConfigTomlPath"))
		snapshot.source = Preferences.source_snapshot(ConfigPaths.get("ConfigTomlPath"))
		if source then
			snapshot.owner = source.owner
			snapshot.generation = snapshot.generation + source.generation
		end
		snapshot.platform = "hs"
		if type(ctx.is_paused) == "function" then snapshot.paused = ctx.is_paused() end
		snapshot.progressive = state.llm_streaming_multi
		local function current_boolean(key)
			if canonical == nil then return nil end
			if canonical[key] == nil then return llm_mod.DEFAULT_STATE[key] end
			return canonical[key]
		end
		snapshot.blocked = snapshot.blocked == true or ctx.is_disabled == true
			or source == nil or source.value ~= snapshot.progressive
			or not Preferences.source_matches(snapshot.source, canonical_source)
			or canonical == nil or current_boolean("llm_enabled") ~= snapshot.enabled
			or current_boolean("llm_streaming") ~= snapshot.streaming
			or current_boolean("llm_streaming_multi") ~= snapshot.progressive
			or (canonical and canonical.llm_backend ~= nil and canonical.llm_backend ~= snapshot.backend)
			or state.llm_enabled ~= snapshot.enabled or state.llm_backend ~= snapshot.backend
			or state.llm_streaming ~= snapshot.streaming
		return snapshot
	end
	local streaming_source = streaming_snapshot()

	local function show_all_ready()
		return DisplayPolicy.ready(state.llm_num_predictions,
			ctx.is_disabled == true or (type(ctx.is_paused) == "function" and ctx.is_paused() == true)
				or state.llm_enabled ~= true)
	end

	local display_ctx = {
		commands = {
			["llm_show_all"] = function()
				if not show_all_ready() then return false end
				return settings_mgr.apply_setting_transaction({
					key = "llm_streaming_multi",
					value = not state.llm_streaming_multi,
					runtime_fn = "set_llm_streaming_multi",
					publish_setting = false,
				})
			end,
			["llm_token_streaming"] = function()
				local current = streaming_snapshot()
				if not Preferences.source_matches(streaming_source.source, current.source) then return false end
				local decision = DisplayPolicy.streaming_intent(streaming_source, current)
				if decision.admitted ~= true then return false end
				local path, expected_source = ConfigPaths.get("ConfigTomlPath"), current.source
				local before_id
				local function publication_guard(phase)
					if phase == "before" then
						local _, source = Preferences.current_view(path)
						if not Preferences.source_matches(expected_source, source) then return false end
						local receipt = Preferences.publication_receipt(path)
						if type(receipt) ~= "table" or type(receipt.id) ~= "number" or receipt.id < 0
							or receipt.id ~= math.floor(receipt.id) then return false end
						before_id = receipt.id
						return true
					end
					if phase ~= "acknowledged" then return false end
					local receipt = Preferences.publication_receipt(path)
					if not receipt or receipt.id ~= before_id + 1
						or not Preferences.source_matches(receipt.source, receipt.source) then return false end
					expected_source = receipt.source
					return true
				end
				return settings_mgr.apply_setting_transaction({
					key = "llm_streaming", value = decision.value,
					runtime_fn = "set_llm_streaming", publish_setting = false,
					publication_guard = publication_guard,
				})
			end,
			["llm_info_bar"] = function()
				return settings_mgr.apply_setting_transaction({
					key = "llm_show_info_bar",
					value = not state.llm_show_info_bar,
					runtime_fn = "set_llm_show_info_bar",
					publish_setting = false,
				})
			end,
		},
		state_getters = {
			["llm_show_all_enabled"] = function() return DisplayPolicy.show_all(state.llm_streaming_multi) end,
			["llm_show_all_ready"] = show_all_ready,
			["llm_token_streaming_enabled"] = function()
				return DisplayPolicy.streaming_capable(streaming_source.platform, streaming_source.backend)
					and streaming_source.streaming == true
			end,
			["llm_token_streaming_ready"] = function() return DisplayPolicy.streaming_ready(streaming_source) end,
			["llm_info_bar_enabled"] = function() return state.llm_show_info_bar end,
			["llm_info_bar_ready"] = function() return not is_disabled end,
		},
	}
	return ManifestMenu.build("llm_display_menu", "LLM", nil, nil, display_ctx, {
		["llm_display_leading"] = function() return leading_rows end,
		["llm_display_remaining"] = function() return rows end,
		["llm_display_trailing"] = function() return {} end,
	})
end

return M
