--- tests/unit/modules/keymap/test_llm_bridge_preview_commit_gate.lua

--- ==============================================================================
--- MODULE: Hotstring-preview UI commit gate regressions
--- DESCRIPTION:
--- Drives the real keymap LLM bridge through its deferred preview render. A
--- failed or throwing tooltip must not publish last-shown state, suggestion
--- telemetry, or LLM timers. Deliberately hidden rows remain a supported state
--- and retain their short LLM-chain behaviour without pretending a suggestion
--- was visible.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Loads one real bridge with a provider match and controllable preview render.
--- @param render_result any|function Result returned by tooltip.show_stacked.
--- @param previews_enabled boolean Whether the provider row may be displayed.
--- @param options table|nil Optional injected post-render failures.
--- @return table fixture Observable fixture fields and the loaded bridge.
local function load_fixture(render_result, previews_enabled, options)
	options = options or {}
	helpers.load_with_stubs("infra.logger")
	local fixture = {
		scheduled = {},
		drained = 0,
		renders = 0,
		resets = 0,
		stops = 0,
		starts = {},
		suggested = 0,
		dismissed = 0,
	}
	local action_epoch = {}
	fixture.schedule_calls = 0

	package.loaded["adapters.synthetic_input"] = {
		current_action_epoch = function() return action_epoch end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, callback)
			fixture.schedule_calls = fixture.schedule_calls + 1
			if options.schedule_error_on == fixture.schedule_calls then
				error("preview telemetry scheduling failed")
			end
			if options.schedule_failure_on == fixture.schedule_calls then
				return { fired = true }, false
			end
			local handle = { timer = {}, delay = delay, callback = callback }
			fixture.scheduled[#fixture.scheduled + 1] = handle
			return handle, true
		end,
	}
	package.loaded["modules.keymap.utils"] = {
		tokens_from_repl = function(value) return value end,
		plain_text = function(value) return value end,
	}
	local mapping = {
		auto = false,
		group = nil,
		section = "fixture",
		is_private = false,
	}
	package.loaded["modules.keymap.registry"] = {
		mappings_for_star_tail = function() return nil end,
		mappings_for_tail = function()
			-- Do not use `condition and nil or fallback` here: nil deliberately
			-- represents an empty bucket, so that Lua idiom would select the fallback
			-- and turn every negative control into a hidden positive match.
			if options.no_match then return nil end
			return { mapping }
		end,
	}
	package.loaded["modules.keymap.expander"] = {
		would_fire = function() return "replacement", "abc" end,
		resolve_magic_action = function()
			if options.no_match then return nil end
			local action = {
				mapping = mapping,
				kind = "autocorrect",
				eff_plain = "replacement",
				eff_repl = "replacement",
				typed = "abc",
			}
			return { winner = action, candidates = { action }, attempts = { action } }
		end,
		perform_text_replacement = function() return true end,
	}
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = { llm_after_hotstring = true, llm_reset_on_nav = true },
	}
	package.loaded["modules.llm.prediction_engine"] = {
		set_runtime_guard = function() end,
		init = function() return true end,
		get_llm_enabled = function() return true end,
		stop_timer = function()
			fixture.stops = fixture.stops + 1
			if type(options.stop_result) == "function" then return options.stop_result() end
			if options.stop_result ~= nil then return options.stop_result end
			return true
		end,
		start_timer = function(delay)
			-- Array assignment of nil removes a slot; retain the no-override call as
			-- an explicit sentinel so the ordinary inactivity path is observable.
			fixture.starts[#fixture.starts + 1] = delay == nil and "idle" or delay
			if options.timer_error then error("preview timer arm failed") end
			if type(options.timer_result) == "function" then return options.timer_result() end
			if options.timer_result ~= nil then return options.timer_result end
			return true
		end,
		start_timer_word_end = function()
			fixture.starts[#fixture.starts + 1] = "word"
			if options.timer_error then error("preview timer arm failed") end
			if type(options.timer_result) == "function" then return options.timer_result() end
			if options.timer_result ~= nil then return options.timer_result end
			return true
		end,
		reset = function() fixture.resets = fixture.resets + 1; return true end,
	}
	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = function() fixture.suggested = fixture.suggested + 1 end,
		log_hotstring_dismissed = function() fixture.dismissed = fixture.dismissed + 1 end,
	}
	package.loaded["ui.tooltip"] = {
		set_runtime_guard = function() end,
		set_accept_callback = function() end,
		set_cancel_callback = function() end,
		set_on_show_callback = function() end,
		set_timeout = function() end,
		tint = function() return {} end,
		hide_forced_silent = function() return true end,
		has_visible_hotstring_lease = function(token)
			if not fixture.tooltip_committed then return false end
			for _, row in ipairs(fixture.visible_rows or {}) do
				if row.lease_token == token then return true end
			end
			return false
		end,
		show_stacked = function(rows, ...)
			fixture.renders = fixture.renders + 1
			local result = type(render_result) == "function"
				and render_result(fixture, rows, ...) or render_result
			fixture.tooltip_committed = result == true
			fixture.visible_rows = result == true and rows or nil
			return result
		end,
	}

	package.loaded["modules.keymap.llm_bridge"] = nil
	local Bridge = require("modules.keymap.llm_bridge")
	fixture.bridge = Bridge
	fixture.state = {
		buffer = "abc",
		mappings = {},
		groups = {},
		magic_key = "★",
		no_rescan_until = 0,
		DELAYS = { dynamichotstrings = 1 },
		preview_providers = {},
		is_repeat_feature_enabled = function() return false end,
	}
	Bridge.init(fixture.state, {
		preview_star_enabled = previews_enabled,
		preview_autocorrect_enabled = previews_enabled,
	})
	return fixture
end


--- Runs every currently queued zero-delay callback exactly once.
--- @param fixture table Fixture returned by load_fixture.
local function drain(fixture)
	local limit = #fixture.scheduled
	for index = fixture.drained + 1, limit do fixture.scheduled[index].callback() end
	fixture.drained = limit
end





-- ==========================================================
-- ==========================================================
-- ======= 1/ Deferred Preview Commit Gate ==================
-- ==========================================================
-- ==========================================================

helpers.describe("llm_bridge: deferred preview render owns downstream state", function()
	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "nil", value = nil },
		{ name = "throw", value = function() error("preview paint failed") end },
	}) do
			helpers.it("rejects a " .. case.name .. " render before timers and telemetry", function()
				local fixture = load_fixture(case.value, true)
				fixture.bridge.update_preview(fixture.state.buffer)
				local resets_before_render = fixture.resets
				helpers.assert_eq(#fixture.starts, 0,
					"the keyboard callback must not arm a timer before deferred paint")
				drain(fixture)
			helpers.assert_eq(fixture.renders, 1,
				"the negative control must reach the production render call")
				helpers.assert_eq(#fixture.starts, 0,
					"no chain or inactivity timer may outlive a failed visible preview")
				helpers.assert_eq(fixture.suggested, 0)
				helpers.assert_eq(fixture.resets, resets_before_render + 1,
					"a current failed render must close its engine state exactly once")

			fixture.bridge.reset_predictions(false)
			drain(fixture)
			helpers.assert_eq(fixture.dismissed, 0,
				"a preview that never committed must never become last_shown_hotstring")
		end)
	end

	helpers.it("publishes timers and telemetry after strict render success", function()
		local fixture = load_fixture(true, true)
		fixture.bridge.update_preview(fixture.state.buffer)
		local resets_before_render = fixture.resets
		helpers.assert_eq(#fixture.starts, 0)
		drain(fixture)
		helpers.assert_eq(#fixture.starts, 1)
		helpers.assert_eq(fixture.starts[1], 0.05,
			"an explicit magic action stays visible until context changes, so chained LLM work "
				.. "uses only its short no-finite-surface offset")
		helpers.assert_eq(fixture.suggested, 0,
			"persistence remains deferred even after the visual commit")
		drain(fixture)
		helpers.assert_eq(fixture.suggested, 1)
		helpers.assert_eq(fixture.resets, resets_before_render,
			"a committed preview must not enter the fail-closed reset path")

		fixture.bridge.reset_predictions(false)
		drain(fixture)
		helpers.assert_eq(fixture.dismissed, 1,
			"the committed row must become the one dismissible suggestion record")
	end)

	helpers.it("publishes an opaque provider snapshot only after its exact row commits", function()
		local fixture = load_fixture(true, true, { no_match = true })
		local token = {}
		fixture.state.preview_providers = {
			function() return "snapshot-value", token end,
		}
		fixture.bridge.update_preview(fixture.state.buffer)
		helpers.assert_eq(fixture.bridge.owns_visible_magic_action(token, fixture.state.buffer), false,
			"provider evaluation alone must not publish an action lease")
		drain(fixture)
		helpers.assert_eq(fixture.visible_rows[1].text, "snapshot-value")
		helpers.assert_eq(fixture.visible_rows[1].trigger_label, "★",
			"the provider row must advertise the key its interceptor consumes")
		helpers.assert_eq(fixture.visible_rows[1].lease_token, token,
			"the committed row must carry the provider's exact opaque identity")
		helpers.assert_eq(fixture.bridge.owns_visible_magic_action(token, fixture.state.buffer), true)
		helpers.assert_eq(fixture.bridge.owns_visible_magic_action({}, fixture.state.buffer), false,
			"canvas visibility must not grant ownership to a sibling action")
	end)

	helpers.it("never publishes a provider snapshot when the tooltip rejects paint", function()
		local fixture = load_fixture(false, true, { no_match = true })
		local token = {}
		fixture.state.preview_providers = {
			function() return "uncommitted-value", token end,
		}
		fixture.bridge.update_preview(fixture.state.buffer)
		drain(fixture)
		helpers.assert_eq(fixture.bridge.owns_visible_magic_action(token, fixture.state.buffer), false,
			"a provider cache is not an action promise until native pixels commit")
	end)

	helpers.it("does not reset a newer generation created during a failing render", function()
		local fixture
		fixture = load_fixture(function(state)
			state.bridge.update_preview(state.state.buffer)
			return false
		end, true)
		fixture.bridge.update_preview(fixture.state.buffer)
		local resets_before = fixture.resets
		fixture.scheduled[1].callback()
		helpers.assert_eq(fixture.resets, resets_before + 1,
			"only the re-entrant newer preview may perform its normal pre-render reset")
		fixture.scheduled[2].callback()
		helpers.assert_eq(#fixture.starts, 0,
			"both deliberately failing renders remain uncommitted")
	end)

	helpers.it("keeps independent hotstring pixels when the LLM timer arm raises", function()
		local fixture = load_fixture(true, true, { timer_error = true })
		fixture.bridge.update_preview(fixture.state.buffer)
		local resets_before = fixture.resets
		local ok, err = pcall(drain, fixture)
		helpers.assert_true(ok, "the deferred timer callback must contain the throw: " .. tostring(err))
		helpers.assert_eq(fixture.renders, 1,
			"the negative control must paint before downstream publication fails")
		helpers.assert_eq(fixture.resets, resets_before,
			"LLM scheduling failure must not revoke a truthful hotstring preview")
		helpers.assert_eq(fixture.suggested, 0)
		drain(fixture)
		helpers.assert_eq(fixture.suggested, 1)
	end)

	helpers.it("fails closed when the initial render deferral cannot be armed", function()
		local fixture = load_fixture(true, true, { schedule_failure_on = 1 })
		local resets_before = fixture.resets
		fixture.bridge.update_preview(fixture.state.buffer)
		helpers.assert_eq(fixture.renders, 0,
			"the real adapter failure shape must prove that no render callback ran")
		helpers.assert_eq(#fixture.starts, 0)
		helpers.assert_eq(fixture.suggested, 0)
		helpers.assert_eq(fixture.resets, resets_before + 2,
			"the ordinary match reset plus schedule-failure cleanup must close the engine")
	end)

	helpers.it("keeps published ownership when best-effort suggestion telemetry raises", function()
		local fixture = load_fixture(true, true, { schedule_error_on = 2 })
		fixture.bridge.update_preview(fixture.state.buffer)
		local resets_before = fixture.resets
		local ok, err = pcall(drain, fixture)
		helpers.assert_true(ok, "the deferred publication callback must contain the throw: " .. tostring(err))
		helpers.assert_eq(fixture.resets, resets_before)

		fixture.bridge.reset_predictions(false)
		drain(fixture)
		helpers.assert_eq(fixture.dismissed, 1,
			"visible ownership remains dismissible even when suggestion logging failed")
	end)

	helpers.it("keeps visible ownership across a non-throwing telemetry schedule failure", function()
		local fixture = load_fixture(true, true, { schedule_failure_on = 2 })
		fixture.bridge.update_preview(fixture.state.buffer)
		local resets_before = fixture.resets
		local ok, err = pcall(drain, fixture)
		helpers.assert_true(ok, "the real adapter failure shape must be contained: " .. tostring(err))
		helpers.assert_eq(fixture.renders, 1)
		helpers.assert_eq(fixture.suggested, 0)
		helpers.assert_eq(fixture.resets, resets_before)
		fixture.bridge.reset_predictions(false)
		drain(fixture)
		helpers.assert_eq(fixture.dismissed, 1)
	end)

	helpers.it("keeps engine reset authoritative when dismissal telemetry scheduling raises", function()
		local fixture = load_fixture(true, true, { schedule_error_on = 3 })
		fixture.bridge.update_preview(fixture.state.buffer)
		drain(fixture)
		drain(fixture)
		local resets_before = fixture.resets

		local ok, result = pcall(fixture.bridge.reset_predictions, false)
		helpers.assert_true(ok,
			"a best-effort telemetry scheduler must not abort reset: " .. tostring(result))
		helpers.assert_eq(result, true)
		helpers.assert_eq(fixture.resets, resets_before + 1,
			"engine teardown must still run after telemetry scheduling fails")
		helpers.assert_eq(fixture.schedule_calls, 3,
			"the negative control must fault at the dismissal scheduler")
		helpers.assert_eq(fixture.dismissed, 0)

		fixture.bridge.reset_predictions(false)
		helpers.assert_eq(fixture.schedule_calls, 3,
			"cleared ownership must not re-emit the stale dismiss on a later reset")
	end)

	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "throw", value = function() error("stream cancellation failed") end },
	}) do
		helpers.it("keeps hotstring output but suppresses new LLM work when stop returns " .. case.name, function()
			local fixture = load_fixture(true, true, { stop_result = case.value })
			local ok, err = pcall(fixture.bridge.update_preview, fixture.state.buffer)
			helpers.assert_true(ok, "the keyboard callback must contain stop failure: " .. tostring(err))
			helpers.assert_eq(fixture.stops, 1)
			drain(fixture)
			helpers.assert_eq(fixture.renders, 1,
				"LLM teardown failure must not suppress the independent hotstring feature")
			helpers.assert_eq(#fixture.starts, 0,
				"no replacement LLM timer may queue behind an unterminated stream")
		end)
	end
end)


helpers.describe("llm_bridge: ordinary timer starts are strict and contained", function()
	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "nil", value = function() return nil end },
		{ name = "throw", error = true },
	}) do
		helpers.it("contains a " .. case.name .. " no-match timer result", function()
			local fixture = load_fixture(true, true, {
				no_match = true,
				timer_result = case.value,
				timer_error = case.error,
			})
			helpers.assert_true(fixture.bridge.is_runtime_available(),
				"the negative control must reach the live LLM path")
			local ok, err = pcall(fixture.bridge.update_preview, fixture.state.buffer)
			helpers.assert_true(ok, "timer failure must not escape the keyboard callback: " .. tostring(err))
			helpers.assert_eq(fixture.resets, 1,
				"the no-match path must commit its reset before attempting the timer")
			helpers.assert_eq(#fixture.starts, 1)
			helpers.assert_eq(fixture.renders, 0)
			helpers.assert_eq(fixture.suggested, 0)
		end)

		helpers.it("contains a " .. case.name .. " word-end timer result", function()
			local fixture = load_fixture(true, true, {
				no_match = true,
				timer_result = case.value,
				timer_error = case.error,
			})
			fixture.state.buffer = "abc "
			local ok, err = pcall(fixture.bridge.update_preview, fixture.state.buffer)
			helpers.assert_true(ok, "word-end failure must not escape the keyboard callback: " .. tostring(err))
			helpers.assert_eq(fixture.starts[1], "word")
			helpers.assert_eq(fixture.renders, 0)
		end)
	end

	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "nil", value = function() return nil end },
		{ name = "throw", error = true },
	}) do
		helpers.it("propagates a " .. case.name .. " public timer result", function()
			local fixture = load_fixture(true, true, {
				timer_result = case.value,
				timer_error = case.error,
			})
			local ok, result = pcall(fixture.bridge.start_timer)
			helpers.assert_true(ok, "an expander-triggered timer failure must be contained")
			helpers.assert_eq(result, false)
			helpers.assert_eq(fixture.starts[1], "idle")
		end)
	end
end)





-- ==========================================================
-- ==========================================================
-- ======= 2/ Deliberately Hidden Match =====================
-- ==========================================================
-- ==========================================================

helpers.describe("llm_bridge: a no-row match stays intentionally invisible", function()
	helpers.it("keeps the short chain without publishing visible suggestion state", function()
		local fixture = load_fixture(true, false)
		fixture.bridge.update_preview(fixture.state.buffer)
		helpers.assert_eq(#fixture.scheduled, 0,
			"a disabled row must not schedule a fake render")
		helpers.assert_eq(fixture.renders, 0)
		helpers.assert_eq(#fixture.starts, 1)
		helpers.assert_eq(fixture.starts[1], 0.05,
			"the no-row path must preserve the intentional short LLM chain")
		helpers.assert_eq(fixture.suggested, 0)

		fixture.bridge.reset_predictions(false)
		drain(fixture)
		helpers.assert_eq(fixture.dismissed, 0,
			"an intentionally hidden match must never be reported as dismissed UI")
	end)

	helpers.it("contains a hidden-row timer throw on the keyboard path", function()
		local fixture = load_fixture(true, false, { timer_error = true })
		local resets_before = fixture.resets
		local ok, err = pcall(fixture.bridge.update_preview, fixture.state.buffer)
		helpers.assert_true(ok, "the hidden-row branch must not throw into the eventtap: " .. tostring(err))
		helpers.assert_eq(fixture.renders, 0)
		helpers.assert_eq(fixture.resets, resets_before + 2,
			"the ordinary match reset plus failure cleanup must leave the prediction engine closed")
	end)
end)
