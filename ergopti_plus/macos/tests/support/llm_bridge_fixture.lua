--- tests/support/llm_bridge_fixture.lua

--- ==============================================================================
--- MODULE: LLM Bridge Fixture
--- DESCRIPTION:
--- Loads the real modules/keymap/llm_bridge.lua over strict tooltip and
--- prediction-engine doubles and restores package.loaded and the hs global
--- exactly afterwards, so a scenario can never inherit another test's partial
--- double.
--- ==============================================================================

local helpers = require("tests.helpers")

local M = {}

local function noop() end
local function return_true() return true end
local function return_false() return false end
local function return_empty_table() return {} end

--- Copies every populated package cache slot by identity.
--- @return table snapshot Exact package.loaded snapshot.
local function snapshot_package_loaded()
	local snapshot = {}
	for name, module in pairs(package.loaded) do snapshot[name] = module end
	return snapshot
end

--- Restores package.loaded exactly, removing modules created by the fixture.
--- @param snapshot table Snapshot returned by snapshot_package_loaded().
local function restore_package_loaded(snapshot)
	for name in pairs(package.loaded) do
		if snapshot[name] == nil then package.loaded[name] = nil end
	end
	for name, module in pairs(snapshot) do package.loaded[name] = module end
end

--- Builds the complete tooltip surface consumed by the bridge and its engine.
--- @param fixture table Mutable callback capture owned by one scenario.
--- @return table tooltip Strict tooltip double.
local function make_tooltip(fixture)
	return {
		setup = return_true,
		set_timeout = return_true,
		set_llm_timeout = return_true,
		set_colorization_enabled = return_true,
		hide = return_true,
		hide_forced = return_true,
		hide_forced_silent = return_true,
		is_visible = return_false,
		set_on_show_callback = function(callback)
			fixture.show_callback = callback
			return true
		end,
		set_runtime_guard = return_true,
		show = return_true,
		show_stacked = return_true,
		show_loading = return_true,
		show_predictions = return_true,
		navigate = return_false,
		set_navigate_callback = function(callback)
			fixture.navigate_callback = callback
			return true
		end,
		set_accept_callback = function(callback)
			fixture.accept_callback = callback
			return true
		end,
		set_cancel_callback = function(callback)
			fixture.cancel_callback = callback
			return true
		end,
		set_enter_validates = return_true,
		get_current_index = function() return 1 end,
		is_llm_visible = return_false,
		is_hotstring_visible = return_false,
		has_visible_hotstring_lease = return_false,
		make_diff_styled = function(text) return text end,
		reset_llm_timer = return_true,
		set_chain_start = return_true,
		mark_chain_complete = return_true,
		tint = return_empty_table,
		set_accent_color = return_true,
	}
end

--- Builds the prediction-engine surface consumed by the bridge.
--- @param fixture table Mutable scenario state.
--- @return table engine Strict prediction-engine double.
local function make_prediction_engine(fixture)
	local enabled = false
	return {
		set_preview_ai_enabled = noop,
		set_preview_ai_color = noop,
		set_llm_enabled = function(value) enabled = value == true end,
		get_llm_enabled = function() return enabled end,
		set_llm_model = noop,
		set_llm_display_model_name = noop,
		set_llm_backend_name = noop,
		set_llm_context_length = noop,
		set_llm_temperature = noop,
		set_llm_num_predictions = noop,
		set_llm_pred_indent = noop,
		set_llm_show_info_bar = noop,
		set_llm_sequential_mode = noop,
		set_llm_auto_raise_temp = noop,
		set_llm_streaming = noop,
		set_llm_streaming_multi = noop,
		set_llm_instant_on_word_end = noop,
		set_llm_disabled_apps = noop,
		set_llm_url_bar_filter_enabled = noop,
		set_llm_secure_field_filter_enabled = noop,
		set_llm_val_modifiers = noop,
		set_llm_nav_modifiers = noop,
		set_llm_min_words = noop,
		set_llm_max_words = noop,
		set_llm_debounce = noop,
		perform_check = noop,
		reset = return_true,
		consume = function() return nil, {} end,
		arm_chain = noop,
		set_runtime_guard = noop,
		init = return_true,
		start_timer = return_true,
		start_timer_word_end = return_true,
		stop_timer = return_true,
		handle_chain_signal = return_false,
		is_visible = function() return fixture.engine_visible == true end,
		is_chain_pending = return_false,
		get_predictions = function() return fixture.predictions or {} end,
		get_current_index = function() return fixture.current_index end,
		navigate = return_false,
		normalize_mods = return_empty_table,
		get_navigation_mods = function() return fixture.navigation_mods or {} end,
		get_validation_mods = function() return fixture.validation_mods or {} end,
	}
end

--- Runs one bridge scenario with exact dependency and global restoration.
--- @param callback function Scenario receiving the isolated fixture.
--- @param options table|nil Optional preloaded tooltip or provenance double.
--- @return ... Scenario results.
local function with_bridge_fixture(callback, options)
	options = options or {}
	local baseline_loaded = snapshot_package_loaded()
	local baseline_hs = rawget(_G, "hs")

	if options.preloaded_tooltip ~= nil then
		package.loaded["ui.tooltip"] = options.preloaded_tooltip
	end
	local pre_fixture_loaded = snapshot_package_loaded()
	local pre_fixture_hs = rawget(_G, "hs")

	local outcome = table.pack(xpcall(function()
		local fixture = {}
		fixture.tooltip = make_tooltip(fixture)
		fixture.engine = make_prediction_engine(fixture)
		package.loaded["ui.tooltip"] = fixture.tooltip
		package.loaded["modules.llm.prediction_engine"] = fixture.engine
		package.loaded["infra.logger"] = nil
		package.loaded["adapters.event_provenance"] = options.event_provenance
		fixture.bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
		fixture.hs = rawget(_G, "hs")
		fixture.logger = package.loaded["infra.logger"]
		return callback(fixture)
	end, debug.traceback))

	restore_package_loaded(pre_fixture_loaded)
	_G.hs = pre_fixture_hs
	local preloaded_restored = options.preloaded_tooltip == nil
		or package.loaded["ui.tooltip"] == options.preloaded_tooltip
	restore_package_loaded(baseline_loaded)
	_G.hs = baseline_hs

	if not preloaded_restored then
		error("bridge fixture did not restore the preloaded tooltip identity", 0)
	end
	if not outcome[1] then error(outcome[2], 0) end
	return (table.unpack or unpack)(outcome, 2, outcome.n)
end

M.with_bridge_fixture = with_bridge_fixture

return M
