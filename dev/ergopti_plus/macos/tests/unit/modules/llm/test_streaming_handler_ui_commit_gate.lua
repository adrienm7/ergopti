--- tests/unit/modules/llm/test_streaming_handler_ui_commit_gate.lua

--- ==============================================================================
--- MODULE: Streaming-handler UI commit gate regressions
--- DESCRIPTION:
--- Exercises the real streaming callbacks with controllable tooltip outcomes.
--- Prediction refs, visibility, suggestion telemetry, dismiss timers, and stale
--- cleanup must remain transactional with the exact surface render that makes
--- those predictions visible.
--- ==============================================================================

local helpers = require("tests.helpers")

local NIL_RESULT = {}

--- Resolves a configured dependency outcome while preserving an explicit nil.
--- @param configured any Configured value, function, or NIL_RESULT sentinel.
--- @param default any Default when no value was configured.
--- @param ... any Arguments forwarded to configured functions.
--- @return any result Resolved outcome.
local function resolve_result(configured, default, ...)
	if configured == NIL_RESULT then return nil end
	if configured == nil then return default end
	if type(configured) == "function" then return configured(...) end
	return configured
end


--- Builds one valid prediction accepted by every handler filter.
--- @param text string Prediction text.
--- @return table prediction A valid raw prediction.
local function prediction(text)
	return {
		to_type = text,
		deletes = 0,
		chunks = { { type = "insert", text = text } },
		nw = "",
	}
end


--- Loads the real handler and returns a controllable request fixture.
--- @param render_result any|function Result returned by show_predictions.
--- @param reset_result any|nil Result returned by reset_llm_dismiss_timer.
--- @param mark_result any|nil Result returned by mark_chain_complete.
--- @param timer_do_after function|nil Optional watchdog constructor override.
--- @return table fixture Observable fixture fields.
local function load_fixture(render_result, reset_result, mark_result, timer_do_after)
	package.loaded["modules.llm.parser"] = {
		strip_thinking = function(raw) return raw end,
		process_prediction = function(_buffer, _tail, raw) return prediction(" " .. raw) end,
	}
	package.loaded["modules.llm.streaming_handler"] = nil
	local hs_overrides = {
		application = {
			frontmostApplication = function()
				return { title = function() return "FixtureApp" end }
			end,
		},
	}
	if timer_do_after then
		hs_overrides.timer = {
			doAfter = timer_do_after,
			secondsSinceEpoch = function() return 1 end,
		}
	end
	local Handler = helpers.load_with_stubs("modules.llm.streaming_handler", hs_overrides)

	local fixture = {
		live_id = 1,
		renders = 0,
		ui_failures = 0,
		suggested = 0,
		raw_logs = 0,
		reset_calls = 0,
		mark_calls = 0,
		ui_failure_details = {},
	}
	local tooltip = {
		show_predictions = function(...)
			fixture.renders = fixture.renders + 1
			return resolve_result(render_result, nil, fixture, ...)
		end,
		hide = function() return true end,
		get_current_index = function() return 1 end,
		make_diff_styled = function() return true end,
		tint = function() return {} end,
		mark_chain_complete = function()
			fixture.mark_calls = fixture.mark_calls + 1
			return resolve_result(mark_result, true)
		end,
	}
	local core = {
		get_active_profile = function() return nil end,
		get_current_model = function() return "test-model" end,
		get_backend = function() return "ollama" end,
	}
	local keylogger = {
		log_llm = function() fixture.raw_logs = fixture.raw_logs + 1 end,
		log_llm_suggested = function() fixture.suggested = fixture.suggested + 1 end,
	}
	Handler.init({ core_llm = core, tooltip = tooltip, keylogger = keylogger })
	fixture.tooltip = tooltip

	fixture.pending = { value = {} }
	fixture.visible = { value = false }
	fixture.context = {
		buffer = "hello",
		tail = "",
		my_fetch_id = 1,
		get_fetch_id = function() return fixture.live_id end,
		is_streaming_enabled = true,
		is_streaming_multi_enabled = true,
		num_predictions = 2,
		show_info_bar = false,
		streaming_info_bar = nil,
		prediction_indent = 0,
		validation_mods = { "none" },
		navigation_mods = {},
		model_to_use = "test-model",
		llm_display_name = "Test Model",
		profile_name = nil,
		build_info_bar_text = function() return nil end,
		resolve_backend_label = function() return "" end,
		is_noise_pred = function() return false end,
		reset_llm_dismiss_timer = function()
			fixture.reset_calls = fixture.reset_calls + 1
			return resolve_result(reset_result, true)
		end,
		pending_predictions_ref = fixture.pending,
		predictions_visible_ref = fixture.visible,
		is_ai_preview_enabled = true,
		runtime_available = function() return true end,
		on_ui_unavailable = function(stage, detail)
			fixture.ui_failures = fixture.ui_failures + 1
			fixture.ui_failure_details[#fixture.ui_failure_details + 1] = {
				stage = stage,
				detail = detail,
			}
			return true
		end,
	}
	fixture.handler = Handler
	fixture.partial, fixture.success, fixture.fail = Handler.build_callbacks(fixture.context)
	return fixture
end





-- ==========================================================
-- ==========================================================
-- ======= 1/ Partial and Final Render Transactions =========
-- ==========================================================
-- ==========================================================

helpers.describe("streaming_handler: UI render commits prediction state", function()
	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "nil", value = nil },
		{ name = "throw", value = function() error("render failed") end },
	}) do
		helpers.it("keeps partial refs closed on a " .. case.name .. " render result", function()
			local fixture = load_fixture(case.value)
			fixture.partial("partial")
			helpers.assert_eq(fixture.renders, 1,
				"the negative control must reach the production render call")
			helpers.assert_eq(#fixture.pending.value, 0)
			helpers.assert_eq(fixture.visible.value, false)
			helpers.assert_eq(fixture.ui_failures, 1,
				"a still-current failed surface must request fail-closed cleanup")
			if case.name == "throw" then
				helpers.assert_contains(
					tostring(fixture.ui_failure_details[1].detail),
					"render failed",
					"the fail-closed owner must receive the original render error"
				)
			end
		end)
	end

	helpers.it("does not mutate the old pool or log a suggestion before final paint", function()
		local fixture = load_fixture(false)
		local placeholder = prediction(" old")
		placeholder._is_stream_placeholder = true
		fixture.pending.value = { placeholder }
		fixture.success({ prediction(" new") }, 25, true, false)

		helpers.assert_eq(#fixture.pending.value, 1,
			"failed final paint must leave the pre-commit pool byte-for-byte owned by the caller")
		helpers.assert_true(fixture.pending.value[1] == placeholder,
			"placeholder eviction must happen only after the new surface commits")
		helpers.assert_eq(fixture.visible.value, false)
		helpers.assert_eq(fixture.suggested, 0,
			"suggestion telemetry must describe only a physically committed suggestion")
		helpers.assert_eq(fixture.ui_failures, 1)
	end)


	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "nil", value = NIL_RESULT },
		{ name = "throw", value = function() error("dismiss timer failed") end },
	}) do
		helpers.it("requires a strict " .. case.name .. "-aware final dismiss-timer reset", function()
			local fixture = load_fixture(true, case.value)
			fixture.success({ prediction(" completion") }, 25, true, false)

			helpers.assert_eq(fixture.renders, 1)
			helpers.assert_eq(fixture.reset_calls, 1,
				"the negative control must reach the real post-render timer reset")
			helpers.assert_eq(#fixture.pending.value, 0)
			helpers.assert_eq(fixture.visible.value, false)
			helpers.assert_eq(fixture.suggested, 0)
			helpers.assert_eq(fixture.ui_failures, 1)
		end)
	end

	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "nil", value = NIL_RESULT },
		{ name = "throw", value = function() error("timing paint failed") end },
	}) do
		helpers.it("requires a strict " .. case.name .. "-aware chain-timing update", function()
			local fixture = load_fixture(true, true, case.value)
			fixture.success({ prediction(" completion") }, 25, true, false)

			helpers.assert_eq(fixture.renders, 1)
			helpers.assert_eq(fixture.reset_calls, 1)
			helpers.assert_eq(fixture.mark_calls, 1,
				"the negative control must reach the real timing update")
			helpers.assert_eq(#fixture.pending.value, 0)
			helpers.assert_eq(fixture.visible.value, false)
			helpers.assert_eq(fixture.suggested, 0)
			helpers.assert_eq(fixture.ui_failures, 1)
		end)
	end

	helpers.it("publishes and logs only after every final UI step succeeds", function()
		local fixture = load_fixture(true, true)
		fixture.success({ prediction(" completion") }, 25, true, false)

		helpers.assert_eq(#fixture.pending.value, 1)
		helpers.assert_eq(fixture.visible.value, true)
		helpers.assert_eq(fixture.suggested, 1)
		helpers.assert_eq(fixture.reset_calls, 1)
		helpers.assert_eq(fixture.mark_calls, 1)
		helpers.assert_eq(fixture.ui_failures, 0)
	end)

	helpers.it("does not reset a request superseded inside a failing render", function()
		local fixture = load_fixture(function(state)
			state.live_id = 2
			return false
		end)
		fixture.partial("partial")
		helpers.assert_eq(fixture.ui_failures, 0,
			"a stale surface failure must not tear down the newer request that now owns the UI")
		helpers.assert_eq(#fixture.pending.value, 0)
		helpers.assert_eq(fixture.visible.value, false)
	end)
end)





-- ==========================================================
-- ==========================================================
-- ======= 2/ Existing-Surface and Watchdog Repaints ========
-- ==========================================================
-- ==========================================================

helpers.describe("streaming_handler: every repaint propagates UI failure", function()
	helpers.it("fails closed when the failure fallback cannot repaint retained predictions", function()
		local fixture = load_fixture(false)
		fixture.pending.value = { prediction(" retained") }
		fixture.visible.value = true
		fixture.fail()
		helpers.assert_eq(fixture.renders, 1)
		helpers.assert_eq(fixture.ui_failures, 1)
		helpers.assert_eq(fixture.reset_calls, 0,
			"the dismiss timer must not arm after a failed fallback repaint")
	end)

	helpers.it("fails closed when the stream watchdog cannot repaint", function()
		local fixture = load_fixture(false)
		fixture.pending.value = { prediction(" retained") }
		fixture.visible.value = true
		fixture.handler.arm_watchdog(fixture.context)
		local watchdog = hs.timer.__timers[#hs.timer.__timers]
		helpers.assert_not_nil(watchdog)
		watchdog:fire()
		helpers.assert_eq(fixture.renders, 1)
		helpers.assert_eq(fixture.ui_failures, 1)
	end)

	helpers.it("closes a loading surface when no partial result arrived before the watchdog", function()
		local fixture = load_fixture(true)
		fixture.handler.arm_watchdog(fixture.context)
		local watchdog = hs.timer.__timers[#hs.timer.__timers]
		helpers.assert_not_nil(watchdog)
		watchdog:fire()

		helpers.assert_eq(fixture.renders, 0,
			"an empty stream has no prediction frame it can truthfully paint")
		helpers.assert_eq(fixture.ui_failures, 1,
			"the loading owner must close instead of leaving a permanent spinner")
		helpers.assert_eq(fixture.ui_failure_details[1].stage, "watchdog render")
		helpers.assert_eq(fixture.ui_failure_details[1].detail, "no committed partial prediction")
	end)

	helpers.it("contains a tint throw inside the partial-render transaction", function()
		local fixture = load_fixture(true)
		fixture.tooltip.tint = function() error("native tint failed") end
		fixture.partial("partial")

		helpers.assert_eq(fixture.renders, 0,
			"show_predictions cannot run after its tint argument failed")
		helpers.assert_eq(#fixture.pending.value, 0)
		helpers.assert_eq(fixture.visible.value, false)
		helpers.assert_eq(fixture.ui_failures, 1)
		helpers.assert_contains(
			tostring(fixture.ui_failure_details[1].detail),
			"native tint failed",
			"the protected render boundary must preserve the original dependency error"
		)
	end)
end)





-- ==========================================================
-- ==========================================================
-- ======= 3/ Watchdog Construction Transaction =============
-- ==========================================================
-- ==========================================================

helpers.describe("streaming_handler: watchdog construction is proven", function()
	for _, case in ipairs({
		{
			name = "throwing constructor",
			create = function() error("native timer failed") end,
		},
		{
			name = "nil constructor result",
			create = function() return nil end,
		},
		{
			name = "stopped constructor result",
			create = function()
				return {
					running = false,
					stop = function(self) self.running = false end,
				}
			end,
		},
	}) do
		helpers.it("rejects a " .. case.name, function()
			local fixture = load_fixture(true, nil, nil, case.create)
			local armed = fixture.handler.arm_watchdog(fixture.context)

			helpers.assert_eq(armed, false,
				"arm_watchdog must report only a verified live timer")
			helpers.assert_eq(fixture.renders, 0)
			helpers.assert_eq(fixture.ui_failures, 0,
				"construction failure is returned to the dispatch owner, not misreported as a repaint")
		end)
	end
end)
