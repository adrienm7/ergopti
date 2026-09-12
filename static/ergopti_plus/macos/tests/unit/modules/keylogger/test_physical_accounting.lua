--- tests/unit/modules/keylogger/test_physical_accounting.lua

--- Verifies the physical-stream aggregation boundary independently of logical text.
local helpers = require("tests.helpers")

local function with_events(callback)
	helpers.with_stub_scope({
		"hs", "tests.stubs.hs", "infra.logger", "modules.keylogger.aggregator.events",
		"modules.keylogger.aggregator.core", "modules.keylogger.aggregator.state",
		"modules.keylogger.aggregator.physical",
	}, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local events = helpers.load_with_stubs("modules.keylogger.aggregator.events")
		local state = require("modules.keylogger.aggregator.state")
		local core = require("modules.keylogger.aggregator.core")
		state.initialized = true
		state.device_id = "physical-accounting-test"
		core.reset_batch()
		core.reset_ngram_ctx()
		local function press(kc, capture, device)
			events.walk_system_event({ action = "physical_press", keycode = kc,
				capture = capture or "lease-a", device = device or "41",
				timestamp = "2026-09-12 10:00:00.000", app = "TestApp" })
		end
		callback(events, state, core, press)
	end)
end

helpers.describe("physical accounting (hs274)", function()
	helpers.it("preserves physical streaks across logical text with no physical credit", function()
		with_events(function(events, state, _, press)
			for _ = 1, 2 do
				press(0)
				events.walk_typing({ timestamp = "2026-09-12 10:00:00.000", app = "TestApp",
					events = { { "a", 100, { s = false, st = "none" } } } })
			end
			local key = "2026-09-12\1TestApp"
			helpers.assert_eq(state.agg_batch.kc_ngram[key .. "\1" .. "0"].count, 2)
			helpers.assert_eq(state.agg_batch.ergo[key].same_finger_streak_max, 2)
			helpers.assert_eq(state.agg_batch.ergo[key].same_hand_streak_max, 2)
			helpers.assert_eq(state.agg_batch.chars_class[key].letter, 2)
		end)
	end)

	helpers.it("counts original Escape and physical Space independently of two logical Spaces", function()
		with_events(function(events, state, _, press)
			press(53)
			press(49)
			events.walk_typing({ timestamp = "2026-09-12 10:00:00.000", app = "TestApp",
				events = { { " ", 100, { s = false } }, { " ", 100, { s = false } } } })
			local counts = {}
			for _, row in pairs(state.agg_batch.kc_ngram) do counts[row.keycode] = row.count end
			helpers.assert_eq(counts, { [53] = 1, [49] = 1 })
			helpers.assert_eq(state.agg_batch.chars_class["2026-09-12\1TestApp"].space, 2)
		end)
	end)

	helpers.it("breaks physical streaks when capture ownership or keyboard changes", function()
		with_events(function(_, state, _, press)
			press(0, "lease-a", "41")
			press(0, "lease-b", "41")
			press(0, "lease-b", "42")
			local row = state.agg_batch.ergo["2026-09-12\1TestApp"]
			helpers.assert_eq(row.same_finger_streak_max, 1)
			helpers.assert_eq(row.same_hand_streak_max, 1)
		end)
	end)

	helpers.it("rejects a physical press without capture ownership before adding credit", function()
		with_events(function(_, state, _, press)
			local ok, err = pcall(press, 0, "", "41")
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("Physical press requires capture ownership", 1, true) ~= nil)
			helpers.assert_eq(next(state.agg_batch.kc_ngram), nil)
			helpers.assert_eq(next(state.agg_batch.ergo), nil)
		end)
	end)

	helpers.it("retains physical continuity across batches and clears it with context reset", function()
		with_events(function(_, state, core, press)
			press(0)
			core.reset_batch()
			press(0)
			helpers.assert_eq(state.agg_batch.ergo["2026-09-12\1TestApp"].same_finger_streak_max, 2)
			core.reset_batch()
			core.reset_ngram_ctx()
			press(0)
			helpers.assert_eq(state.agg_batch.ergo["2026-09-12\1TestApp"].same_finger_streak_max, 1)
		end)
	end)

	helpers.it("breaks continuity on noncontent keys without losing their counts", function()
		with_events(function(_, state, _, press)
			press(0)
			press(49)
			press(0)
			local key = "2026-09-12\1TestApp"
			helpers.assert_eq(state.agg_batch.ergo[key].same_finger_streak_max, 1)
			helpers.assert_eq(state.agg_batch.kc_ngram[key .. "\1" .. "49"].count, 1)
		end)
	end)

	helpers.it("preserves legacy typing streaks and focus metrics in either ingest order", function()
		for _, focus_first in ipairs({ false, true }) do
			with_events(function(events, state)
				local function focus()
					events.walk_system_event({ timestamp = "2026-09-12 10:00:00.000",
						app = "TestApp", action = "focus_first_key", latency_ms = 123 })
				end
				if focus_first then focus() end
				events.walk_typing({ timestamp = "2026-09-12 10:00:00.000", app = "TestApp",
					events = { { "a", 100, { kc = 0 } }, { "a", 100, { kc = 0 } } } })
				if not focus_first then focus() end
				local row = state.agg_batch.ergo["2026-09-12\1TestApp"]
				helpers.assert_eq(row.same_finger_streak_max, 2)
				helpers.assert_eq(row.same_hand_streak_max, 2)
				helpers.assert_eq(row.focus_to_first_key_sum_ms, 123)
				helpers.assert_eq(row.focus_to_first_key_count, 1)
			end)
		end
	end)

	helpers.it("does not ingest physical events before aggregator initialization", function()
		with_events(function(_, state, _, press)
			state.initialized = false
			press(0)
			helpers.assert_eq(next(state.agg_batch.kc_ngram), nil)
			helpers.assert_eq(next(state.agg_batch.ergo), nil)
		end)
	end)
end)
