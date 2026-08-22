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


--- Builds a native timer whose stop-state probe supersedes the active request.
--- The first running() call proves start; the second is TimerScheduler.cancel's
--- post-stop proof and advances the fixture fetch identity without installing a
--- successor watchdog.
--- @param fixture_ref table Mutable reference populated after load_fixture.
--- @return function timer_new hs.timer.new-compatible constructor.
local function superseding_timer_factory(fixture_ref)
	return function(_delay, callback)
		local timer = {
			callback = callback,
			live = false,
			running_calls = 0,
		}
		function timer:start()
			self.live = true
			return self
		end
		function timer:stop()
			self.live = false
			return self
		end
		function timer:running()
			self.running_calls = self.running_calls + 1
			if self.running_calls == 2 then
				fixture_ref.value.live_id = fixture_ref.value.live_id + 1
			end
			return self.live
		end
		return timer
	end
end


--- Loads the real handler and returns a controllable request fixture.
--- @param render_result any|function Result returned by show_predictions.
--- @param reset_result any|nil Result returned by reset_llm_dismiss_timer.
--- @param mark_result any|nil Result returned by mark_chain_complete.
--- @param timer_new function|nil Optional native timer.new override.
--- @return table fixture Observable fixture fields.
local function load_fixture(render_result, reset_result, mark_result, timer_new)
	package.loaded["modules.llm.parser"] = {
		strip_thinking = function(raw) return raw end,
		process_prediction = function(_buffer, _tail, raw) return prediction(" " .. raw) end,
	}
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["modules.llm.streaming_handler"] = nil
	local fixture
	local hs_overrides = {
		application = {
			frontmostApplication = function()
				fixture.frontmost_calls = fixture.frontmost_calls + 1
				if fixture.frontmost_hook then fixture.frontmost_hook(fixture) end
				return { title = function() return "FixtureApp" end }
			end,
		},
		notify = {
			new = function()
				return {
					send = function()
						fixture.notifications = fixture.notifications + 1
						if fixture.notify_hook then fixture.notify_hook(fixture) end
						return true
					end,
				}
			end,
		},
	}
	if timer_new then
		hs_overrides.timer = {
			new = timer_new,
			secondsSinceEpoch = function() return 1 end,
		}
	end
	local Handler = helpers.load_with_stubs("modules.llm.streaming_handler", hs_overrides)

	fixture = {
		live_id = 1,
		renders = 0,
		ui_failures = 0,
		suggested = 0,
		raw_logs = 0,
		frontmost_calls = 0,
		backend_calls = 0,
		notifications = 0,
		hide_calls = 0,
		surface_session = nil,
		surface_value = nil,
		reset_calls = 0,
		mark_calls = 0,
		ui_failure_details = {},
	}
	local tooltip = {
		show_predictions = function(...)
			fixture.renders = fixture.renders + 1
			local args = table.pack(...)
			local result = resolve_result(render_result, nil, fixture,
				table.unpack(args, 1, args.n))
			if result == true then
				local commit_guard = args[12]
				if type(commit_guard) == "function" and commit_guard() ~= true then
					return false
				end
				fixture.surface_session = args[11]
				fixture.surface_value = args[1]
			end
			return result
		end,
		hide = function(session_id, commit_guard)
			fixture.hide_calls = fixture.hide_calls + 1
			fixture.hide_session = session_id
			if fixture.hide_hook then
				return fixture.hide_hook(fixture, session_id, commit_guard)
			end
			if type(commit_guard) == "function" and commit_guard() ~= true then
				return false
			end
			fixture.surface_session = nil
			fixture.surface_value = nil
			return true
		end,
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
		get_backend = function()
			fixture.backend_calls = fixture.backend_calls + 1
			if fixture.backend_hook then fixture.backend_hook(fixture) end
			return fixture.backend or "ollama"
		end,
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

local function with_reentrant_facade(callback)
	helpers.with_fresh_modules({
		"ui.tooltip.init",
		"ui.tooltip.tooltip_llm",
		"ui.tooltip.tooltip_hotstring",
	}, function()
		local fixture = {
			live_id = 1,
			surface_session = nil,
			surface_value = nil,
			render_b_calls = 0,
			publish_calls = 0,
		}
		local facade
		local tooltip_llm = {}
		local tooltip_hotstring = {
			dismiss_silent = function() return true end,
			hide = function() return true end,
			hide_forced = function() return true end,
			is_visible = function() return false end,
		}
		function tooltip_llm.show_predictions(predictions, _index, _enabled, _info,
			_shortcut, _indent, _navigation, _background, _loading, _reserved,
			session_id, commit_guard)
			if session_id == 1 and fixture.pause_from_render then
				fixture.pause_from_render = false
				fixture.forced_silent_result = facade.hide_forced_silent()
				fixture.forced_result = facade.hide_forced()
				fixture.fallback_hide_result = facade.hide()
				-- Model the opaque Renderer tail repainting A after PAUSE's nested
				-- cleanup request returned to it.
				fixture.surface_session = 1
				fixture.surface_value = "stale-A-after-pause"
				return true
			end
			if session_id == 1 and fixture.reenter_render then
				fixture.reenter_render = false
				fixture.live_id = 2
				fixture.nested_result = facade.show_predictions(
					{ "successor-B" }, 1, true, nil, nil, 0, {}, nil, nil, 1, 2,
					function() return fixture.live_id == 2 end)
				fixture.surface_session = 1
				fixture.surface_value = "stale-A"
				return true
			end
			if type(commit_guard) == "function" and commit_guard() ~= true then
				return false
			end
			if session_id == 2 then fixture.render_b_calls = fixture.render_b_calls + 1 end
			fixture.surface_session = session_id
			fixture.surface_value = predictions[1]
			return true
		end
		function tooltip_llm.hide_session(_session_id, _commit_guard)
			if fixture.pause_from_hide then
				fixture.pause_from_hide = false
				fixture.forced_silent_result = facade.hide_forced_silent()
				fixture.surface_session = 1
				fixture.surface_value = "stale-hide-tail"
				return true
			end
			if fixture.reenter_hide then
				fixture.reenter_hide = false
				fixture.live_id = 2
				fixture.nested_result = facade.show_predictions(
					{ "successor-B" }, 1, true, nil, nil, 0, {}, nil, nil, 1, 2,
					function() return fixture.live_id == 2 end)
				fixture.surface_session = nil
				fixture.surface_value = nil
				return true
			end
			return true
		end
		function tooltip_llm.hide()
			fixture.surface_session = nil
			fixture.surface_value = nil
			return true
		end
		tooltip_llm.hide_silent = tooltip_llm.hide
		function tooltip_llm.is_visible() return fixture.surface_session ~= nil end

		package.loaded["ui.tooltip.tooltip_llm"] = tooltip_llm
		package.loaded["ui.tooltip.tooltip_hotstring"] = tooltip_hotstring
		facade = require("ui.tooltip.init")
		fixture.facade = facade
		facade.set_on_show_callback(function()
			fixture.publish_calls = fixture.publish_calls + 1
			return true
		end)
		callback(fixture)
	end)
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
-- ======= 2/ Reentrant Successor Surface Ownership =========
-- ==========================================================
-- ==========================================================

helpers.describe("streaming_handler: stale UI tails preserve a real successor surface", function()
	helpers.it("passes a live capability that refuses an outer render after B paints", function()
		local fixture = load_fixture(function(state, ...)
			local args = table.pack(...)
			local session_id = args[11]
			local commit_guard = args[12]
			state.live_id = 2
			state.surface_session = 2
			state.surface_value = "successor-B"
			if type(commit_guard) ~= "function" or commit_guard() == true then
				state.surface_session = session_id
				state.surface_value = "stale-A"
				return true
			end
			return false
		end)

		fixture.partial("stale partial")

		helpers.assert_eq(fixture.live_id, 2)
		helpers.assert_eq(fixture.surface_session, 2)
		helpers.assert_eq(fixture.surface_value, "successor-B")
		helpers.assert_eq(#fixture.pending.value, 0,
			"the refused A frame must not publish business state")
	end)

	local function install_reentrant_hide(fixture)
		fixture.surface_session = 1
		fixture.surface_value = "surface-A"
		fixture.hide_hook = function(state, session_id, commit_guard)
			state.live_id = 2
			state.surface_session = 2
			state.surface_value = "successor-B"
			if type(commit_guard) ~= "function" or commit_guard() == true then
				state.surface_session = nil
				state.surface_value = nil
				return true
			end
			return false
		end
	end

	helpers.it("keeps B when the empty-final hide reenters a successor", function()
		local fixture = load_fixture(true)
		install_reentrant_hide(fixture)

		fixture.success({}, 25, true, false)

		helpers.assert_eq(fixture.hide_calls, 1)
		helpers.assert_eq(fixture.hide_session, 1)
		helpers.assert_eq(fixture.surface_session, 2)
		helpers.assert_eq(fixture.surface_value, "successor-B")
	end)

	helpers.it("keeps B when the failure hide reenters a successor", function()
		local fixture = load_fixture(true)
		install_reentrant_hide(fixture)

		fixture.fail()

		helpers.assert_eq(fixture.hide_calls, 1)
		helpers.assert_eq(fixture.hide_session, 1)
		helpers.assert_eq(fixture.surface_session, 2)
		helpers.assert_eq(fixture.surface_value, "successor-B")
	end)

	helpers.it("replays B after the facade's outer render tail overwrites it", function()
		with_reentrant_facade(function(fixture)
			fixture.reenter_render = true
			local outer_result = fixture.facade.show_predictions(
				{ "surface-A" }, 1, true, nil, nil, 0, {}, nil, nil, 1, 1,
				function() return fixture.live_id == 1 end)

			helpers.assert_eq(outer_result, false)
			helpers.assert_eq(fixture.nested_result, true)
			helpers.assert_eq(fixture.surface_session, 2)
			helpers.assert_eq(fixture.surface_value, "successor-B")
			helpers.assert_eq(fixture.render_b_calls, 2,
				"B must be repainted after the stale native render tail returns")
		end)
	end)

	helpers.it("replays B after the facade's outer hide tail clears it", function()
		with_reentrant_facade(function(fixture)
			fixture.surface_session = 1
			fixture.surface_value = "surface-A"
			fixture.reenter_hide = true
			local outer_result = fixture.facade.hide(
				1, function() return fixture.live_id == 1 end)

			helpers.assert_eq(outer_result, false)
			helpers.assert_eq(fixture.nested_result, true)
			helpers.assert_eq(fixture.surface_session, 2)
			helpers.assert_eq(fixture.surface_value, "successor-B")
			helpers.assert_eq(fixture.render_b_calls, 2,
				"B must be repainted after the stale native hide tail returns")
		end)
	end)

	helpers.it("defers PAUSE cleanup until an opaque render tail unwinds", function()
		with_reentrant_facade(function(fixture)
			fixture.pause_from_render = true
			local outer_result = fixture.facade.show_predictions(
				{ "surface-A" }, 1, true, nil, nil, 0, {}, nil, nil, 1, 1,
				function() return fixture.live_id == 1 end)

			helpers.assert_eq(fixture.forced_silent_result, false)
			helpers.assert_eq(fixture.forced_result, false)
			helpers.assert_eq(fixture.fallback_hide_result, false,
				"reset's normal-hide fallback must not claim quiescence under Renderer")
			helpers.assert_eq(outer_result, false)
			helpers.assert_eq(fixture.publish_calls, 0,
				"the invalidated A surface must never publish logical visibility")
			helpers.assert_eq(fixture.surface_value, "stale-A-after-pause",
				"the negative control must model the opaque stale paint tail")
			helpers.assert_eq(fixture.facade.show_predictions(
				{ "premature-B" }, 1, true, nil, nil, 0, {}, nil, nil, 1, 2,
				function() return true end), false,
				"forced-hide debt must fence every new paint until cleanup settles")
			helpers.assert_eq(fixture.surface_value, "stale-A-after-pause")
			helpers.assert_eq(fixture.publish_calls, 0)

			helpers.assert_eq(fixture.facade.hide_forced_silent(), true)
			helpers.assert_eq(fixture.surface_session, nil)
			helpers.assert_eq(fixture.surface_value, nil)
		end)
	end)

	helpers.it("defers PAUSE cleanup until an opaque hide tail unwinds", function()
		with_reentrant_facade(function(fixture)
			fixture.surface_session = 1
			fixture.surface_value = "surface-A"
			fixture.pause_from_hide = true
			local outer_result = fixture.facade.hide(
				1, function() return fixture.live_id == 1 end)

			helpers.assert_eq(fixture.forced_silent_result, false)
			helpers.assert_eq(outer_result, false)
			helpers.assert_eq(fixture.surface_value, "stale-hide-tail",
				"the negative control must model the opaque stale hide tail")

			helpers.assert_eq(fixture.facade.hide_forced_silent(), true)
			helpers.assert_eq(fixture.surface_session, nil)
			helpers.assert_eq(fixture.surface_value, nil)
		end)
	end)
end)





-- ==========================================================
-- ==========================================================
-- ======= 3/ Existing-Surface and Watchdog Repaints ========
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
-- ======= 4/ Watchdog Construction Transaction =============
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





-- ==========================================================
-- ==========================================================
-- ======= 5/ Final Callback Watchdog Revalidation ==========
-- ==========================================================
-- ==========================================================

helpers.describe("streaming_handler: final callbacks revalidate watchdog stop", function()
	helpers.it("drops a final success superseded by the native stop proof", function()
		local fixture_ref = {}
		local fixture = load_fixture(true, true, true, superseding_timer_factory(fixture_ref))
		fixture_ref.value = fixture
		helpers.assert_true(fixture.handler.arm_watchdog(fixture.context))

		fixture.success({ prediction(" stale completion") }, 25, true, false)

		helpers.assert_eq(fixture.live_id, 2,
			"the negative control must supersede the request inside native running()")
		helpers.assert_eq(fixture.raw_logs, 0,
			"a superseded final response must not cross the logging boundary")
		helpers.assert_eq(fixture.renders, 0)
		helpers.assert_eq(fixture.suggested, 0)
		helpers.assert_eq(#fixture.pending.value, 0)
		helpers.assert_eq(fixture.visible.value, false)
	end)

	helpers.it("does not log a response superseded by the frontmost-app lookup", function()
		local fixture = load_fixture(true, true, true)
		fixture.frontmost_hook = function(state)
			state.live_id = state.live_id + 1
		end

		fixture.success({ prediction(" stale after app lookup") }, 25, true, false)

		helpers.assert_eq(fixture.frontmost_calls, 1,
			"the negative control must cross the real app lookup boundary")
		helpers.assert_eq(fixture.live_id, 2)
		helpers.assert_eq(fixture.raw_logs, 0,
			"frontmost-app supersession must fence durable keylogger output")
		helpers.assert_eq(fixture.renders, 0)
		helpers.assert_eq(fixture.suggested, 0)
	end)

	helpers.it("drops a failure superseded by the native stop proof", function()
		local fixture_ref = {}
		local fixture = load_fixture(true, nil, nil, superseding_timer_factory(fixture_ref))
		fixture_ref.value = fixture
		fixture.pending.value = { prediction(" retained successor surface") }
		fixture.visible.value = true
		helpers.assert_true(fixture.handler.arm_watchdog(fixture.context))

		fixture.fail()

		helpers.assert_eq(fixture.live_id, 2,
			"the negative control must supersede the request inside native running()")
		helpers.assert_eq(fixture.renders, 0,
			"the stale failure must not repaint the successor's retained surface")
		helpers.assert_eq(fixture.ui_failures, 0)
		helpers.assert_eq(#fixture.pending.value, 1)
		helpers.assert_eq(fixture.visible.value, true)
	end)

	helpers.it("does not notify for a failure superseded by backend lookup", function()
		local fixture = load_fixture(true)
		fixture.pending.value = { prediction(" retained successor surface") }
		fixture.visible.value = true
		fixture.fail()
		fixture.fail()
		fixture.fail()
		helpers.assert_eq(fixture.renders, 3,
			"three current failures must prime the real four-failure threshold")

		fixture.backend = "mlx"
		fixture.backend_hook = function(state)
			state.live_id = state.live_id + 1
		end
		fixture.fail()

		helpers.assert_eq(fixture.backend_calls, 1,
			"the negative control must cross the threshold backend lookup")
		helpers.assert_eq(fixture.live_id, 2)
		helpers.assert_eq(fixture.notifications, 0,
			"a superseded threshold failure must not notify for the old request")
		helpers.assert_eq(fixture.renders, 3)
	end)

	helpers.it("does not hide successor UI after notification send supersedes", function()
		local fixture = load_fixture(true)
		fixture.fail()
		fixture.fail()
		fixture.fail()
		fixture.hide_calls = 0
		fixture.backend = "mlx"
		fixture.notify_hook = function(state)
			state.live_id = state.live_id + 1
		end

		fixture.fail()

		helpers.assert_eq(fixture.backend_calls, 1)
		helpers.assert_eq(fixture.notifications, 1,
			"the negative control must cross the real notification send boundary")
		helpers.assert_eq(fixture.live_id, 2)
		helpers.assert_eq(fixture.hide_calls, 0,
			"the stale failure cannot hide UI after notification supersession")
		helpers.assert_eq(fixture.renders, 0)
	end)
end)
