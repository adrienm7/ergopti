--- tests/unit/modules/llm/test_prediction_engine_streaming_ui_failure_integration.lua

--- ==============================================================================
--- MODULE: Prediction-engine streaming UI failure integration regression
--- DESCRIPTION:
--- Drives the real prediction engine through the real streaming handler while
--- controlling only native timer, tooltip, telemetry, and backend boundaries.
--- A failed prediction-frame commit must propagate back to the engine owner so
--- the loading surface and backend request are revoked as one transaction.
--- ==============================================================================

local helpers = require("tests.helpers")


local DEFAULTS = {
	llm_enabled = true,
	llm_temperature = 0.1,
	llm_context_length = 4000,
	llm_min_words = 1,
	llm_max_words = 0,
	llm_num_predictions = 1,
	llm_pred_indent = 0,
	llm_val_modifiers = { "alt" },
	llm_nav_modifiers = { "ctrl" },
	llm_show_info_bar = false,
	llm_sequential_mode = false,
	llm_debounce = 0.2,
	llm_auto_raise_temp = false,
	llm_streaming = true,
	llm_streaming_multi = false,
	llm_instant_on_word_end = false,
	llm_disable_url_bars = false,
	llm_disable_password_fields = false,
}


--- Loads the real prediction pipeline with observable external boundaries.
--- @return table fixture Observable engine, UI, backend, and callback state.
local function load_fixture()
	local front_app = {
		title = function() return "FixtureApp" end,
		name = function() return "FixtureApp" end,
		bundleID = function() return "test.fixture" end,
		path = function() return "/Applications/Fixture.app" end,
		pid = function() return 42 end,
	}
	helpers.load_with_stubs("infra.logger", {
		application = {
			frontmostApplication = function() return front_app end,
		},
	})
	package.loaded["infra.logger"] = helpers.make_logger_stub()

	local fixture = {
		fetches = 0,
		cancels = 0,
		loading_calls = 0,
		prediction_renders = 0,
		hides = 0,
	}

	local core = {
		DEFAULT_STATE = DEFAULTS,
		get_current_model = function() return "test-model" end,
		get_backend = function() return "ollama" end,
		get_active_profile = function() return nil end,
		is_backend_ready = function() return true end,
		set_runtime_llm_enabled = function() end,
		set_llm_streaming = function() end,
		cancel_streaming = function()
			fixture.cancels = fixture.cancels + 1
			return true
		end,
		fetch_llm_prediction = function(_context, _tail, _model, _temperature, _max_tokens,
			_num_predictions, on_success, on_fail, _sequential, _force, _request_id, on_partial)
			fixture.fetches = fixture.fetches + 1
			fixture.on_success = on_success
			fixture.on_fail = on_fail
			fixture.on_partial = on_partial
			return true
		end,
	}
	package.loaded["modules.llm"] = core

	local tooltip = {
		set_navigate_callback = function() end,
		set_enter_validates = function() end,
		set_llm_timeout = function() end,
		set_chain_start = function() return true end,
		show_loading = function()
			fixture.loading_calls = fixture.loading_calls + 1
			return true
		end,
		show_predictions = function()
			fixture.prediction_renders = fixture.prediction_renders + 1
			return false
		end,
		get_current_index = function() return 1 end,
		make_diff_styled = function() return true end,
		reset_llm_timer = function() return true end,
		mark_chain_complete = function() return true end,
		tint = function() return {} end,
		hide = function() return true end,
		hide_forced_silent = function()
			fixture.hides = fixture.hides + 1
			return true
		end,
	}
	package.loaded["ui.tooltip"] = tooltip
	package.loaded["modules.keylogger"] = {
		get_live_stats = function() return { wpm_physical = 0 } end,
		log_llm = function() end,
		log_llm_suggested = function() end,
		log_llm_dismissed = function() end,
	}
	package.loaded["modules.shortcuts.script_control"] = nil

	-- These internal modules must be real: the regression guards their transitive
	-- callback contract, not a test-local reproduction of either half.
	for _, module_name in ipairs({
		"modules.llm.parser",
		"modules.llm.prompt_builder",
		"modules.llm.streaming_handler",
		"modules.llm.warmup_controller",
		"modules.llm.app_filter",
		"modules.llm.api_common",
		"modules.llm.prediction_engine",
	}) do
		package.loaded[module_name] = nil
	end

	local StreamingHandler = require("modules.llm.streaming_handler")
	local Engine = require("modules.llm.prediction_engine")
	fixture.handler = StreamingHandler
	fixture.engine = Engine
	Engine.init({
		buffer = "hello world",
		mappings = {},
		DELAYS = { llm_prediction = 1 },
		ignored_window_titles = {},
		ignored_window_patterns = {},
		suppress_rescan_keep_buffer = function() end,
	})
	return fixture
end





-- ==========================================================
-- ==========================================================
-- ======= 1/ Transitive UI-Failure Ownership Gate =========
-- ==========================================================
-- ==========================================================

helpers.describe("prediction_engine + streaming_handler: UI failure ownership", function()
	helpers.it("propagates a failed real handler render into engine cleanup", function()
		local fixture = load_fixture()
		fixture.engine.perform_check(true)

		helpers.assert_eq(fixture.fetches, 1,
			"the negative control must dispatch through the real prediction engine")
		helpers.assert_not_nil(fixture.on_success,
			"the backend boundary must receive the real engine-wrapped success callback")
		fixture.on_success({ {
			to_type = " completion",
			deletes = 0,
			chunks = { { type = "insert", text = " completion" } },
			nw = "",
		} }, 25, true, false)

		helpers.assert_eq(fixture.prediction_renders, 1,
			"the negative control must fail inside the real streaming handler render")
		helpers.assert_eq(fixture.hides, 1,
			"the handler UI failure must reach the engine owner and revoke its surface")
		helpers.assert_eq(fixture.cancels, 1,
			"engine cleanup must cancel the backend request whose UI can no longer commit")
		helpers.assert_eq(fixture.engine.is_visible(), false)
	end)
end)
