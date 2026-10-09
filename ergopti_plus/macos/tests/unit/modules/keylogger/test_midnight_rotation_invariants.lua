--- tests/unit/modules/keylogger/test_midnight_rotation_invariants.lua

--- Behavioural midnight-rotation coverage. The real watcher must flush before
--- rollover, reset only day-local aggregates after an accepted drain, retry a
--- rejected drain, and leave event-local input provenance untouched.

local helpers = require("tests.helpers")
local provenance_fixture = require("tests.support.keylogger_provenance_fixture")

local OLD_DAY = "2026-08-07"
local NEW_DAY = "2026-08-08"

local function with_date(day, fn)
	local original_date = os.date
	os.date = function(format, time)
		if format == "%Y-%m-%d" then return day end
		return original_date(format, time)
	end
	local ok, result = xpcall(fn, debug.traceback)
	os.date = original_date
	if not ok then error(result, 0) end
	return result
end

local function drive_rotation(rollover_results, paused, ticks, split_results)
	local calls = {}
	local errors = {}
	local rollover_count = 0
	local split_count = 0
	local previous_index = { sentinel = "index" }
	local previous_ngram = { sentinel = "ngram" }

	local logger = helpers.make_logger_stub()
	logger.error = function(_log, format, ...)
		errors[#errors + 1] = string.format(format, ...)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["modules.keylogger.log_manager"] = {
		flush_buffer = function()
			calls[#calls + 1] = "flush"
			return true
		end,
		day_rollover = function()
			rollover_count = rollover_count + 1
			calls[#calls + 1] = "rollover"
			return rollover_results[rollover_count]
		end,
	}
	package.loaded["modules.keylogger.context_tracker"] = {
		split_active_app_at_midnight = function(day)
			split_count = split_count + 1
			calls[#calls + 1] = "split:" .. tostring(day)
			local outcome = split_results and split_results[split_count]
			if outcome == "throw" then error("injected split failure") end
			return outcome ~= false
		end,
	}

	local watchers = with_date(OLD_DAY, function()
		return helpers.load_with_stubs("modules.keylogger.watchers")
	end)
	local state = {
		today_idx = previous_index,
		ngram_context = previous_ngram,
		is_enabled = true,
		buffer_events = {},
		mouse_distance_px = 0,
		last_mouse_pos = nil,
	}
	watchers.init(state, function() return paused end)

	local synthetic_input = require("adapters.synthetic_input")
	local provenance = require("adapters.event_provenance")
	local tagged = provenance_fixture.tagged_key(
		synthetic_input, "test.midnight", "replacement", "m")
	local stats_before = synthetic_input.stats()
	local tap_count_before = #_G.hs.eventtap.__taps

	with_date(NEW_DAY, function()
		for _ = 1, ticks or 1 do watchers.perform_maintenance() end
	end)

	local stats_after = synthetic_input.stats()
	return {
		calls = calls,
		errors = errors,
		state = state,
		previous_index = previous_index,
		previous_ngram = previous_ngram,
		rollover_count = rollover_count,
		split_count = split_count,
		provenance = provenance,
		tagged = tagged,
		stats_before = stats_before,
		stats_after = stats_after,
		tap_count_before = tap_count_before,
		tap_count_after = #_G.hs.eventtap.__taps,
	}
end

local function assert_provenance_unchanged(run, consumer)
	helpers.assert_eq(run.stats_after.records, run.stats_before.records,
		"calendar rotation must not mutate the centralized ownership ledger")
	helpers.assert_eq(run.stats_after.generation, run.stats_before.generation)
	helpers.assert_eq(run.stats_after.action_handoffs, run.stats_before.action_handoffs)
	local metadata = run.provenance.classify(run.tagged, consumer)
	helpers.assert_not_nil(metadata, "the event's exact ownership tag must survive rotation")
	helpers.assert_eq(metadata.owner, "test.midnight")
	helpers.assert_eq(metadata.effect, "replacement")
	helpers.assert_eq(run.tap_count_after, run.tap_count_before,
		"maintenance must not stop or rebuild an input tap")
end

helpers.describe("keylogger: behavioural midnight rotation invariants", function()
	helpers.it("flushes before rollover and resets only day-local aggregates on success", function()
		local run = drive_rotation({ true }, false, 1)

		helpers.assert_eq(table.concat(run.calls, ","),
			"split:" .. OLD_DAY .. ",flush,rollover")
		helpers.assert_true(run.state.today_idx ~= run.previous_index,
			"an accepted rollover must start a fresh daily index")
		helpers.assert_eq(next(run.state.today_idx), nil)
		helpers.assert_nil(run.state.ngram_context)
		helpers.assert_true(run.state.is_enabled,
			"background maintenance must not change enablement")
		assert_provenance_unchanged(run, "test.midnight.success")
	end)

	helpers.it("retains bookmarks and retries a rejected rollover", function()
		local run = drive_rotation({ false, false }, false, 2)

		helpers.assert_eq(run.rollover_count, 2,
			"a rejected drain must be retried on the next maintenance tick")
		helpers.assert_eq(table.concat(run.calls, ","),
			"split:" .. OLD_DAY .. ",flush,rollover,split:" .. OLD_DAY .. ",flush,rollover")
		helpers.assert_true(run.state.today_idx == run.previous_index,
			"the old index is a rollover bookmark until persistence accepts the drain")
		helpers.assert_true(run.state.ngram_context == run.previous_ngram)
		helpers.assert_true(run.state.is_enabled)
		assert_provenance_unchanged(run, "test.midnight.retry")
	end)

	helpers.it("does not archive until a failed app interval split can be retried", function()
		local run = drive_rotation({ true }, false, 2, { "throw", true })

		helpers.assert_eq(run.split_count, 2,
			"the next maintenance tick must retry a failed midnight split")
		helpers.assert_eq(run.rollover_count, 1,
			"rollover must not run until the app interval split succeeds")
		helpers.assert_eq(#run.errors, 1,
			"the failed split must remain visible without hiding the successful retry")
		helpers.assert_contains(run.errors[1], "Midnight app-interval split failed")
		helpers.assert_eq(table.concat(run.calls, ","),
			"split:" .. OLD_DAY .. ",split:" .. OLD_DAY .. ",flush,rollover")
		assert_provenance_unchanged(run, "test.midnight.split_retry")
	end)

	helpers.it("does no rotation or input-state work while paused", function()
		local run = drive_rotation({ true }, true, 1)

		helpers.assert_eq(#run.calls, 0)
		helpers.assert_true(run.state.today_idx == run.previous_index)
		helpers.assert_true(run.state.ngram_context == run.previous_ngram)
		helpers.assert_true(run.state.last_mouse_pos == nil,
			"the pause gate must precede the hardware poll too")
		assert_provenance_unchanged(run, "test.midnight.paused")
	end)
end)
