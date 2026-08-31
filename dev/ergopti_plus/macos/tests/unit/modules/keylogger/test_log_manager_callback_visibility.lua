--- tests/unit/modules/keylogger/test_log_manager_callback_visibility.lua

--- ==============================================================================
--- MODULE: Keylogger Log Manager Callback Visibility Regression Tests
--- DESCRIPTION:
--- Proves that post-ingest listeners and retained compatibility completions stay
--- exception-contained while failures reach the central, deduplicating logger.
--- One broken dashboard listener must never prevent its siblings from refreshing.
--- ==============================================================================

local helpers = require("tests.helpers")

local Logger = helpers.load_with_stubs("infra.logger")

local function matching_errors(needle_a, needle_b)
	local count = 0
	for _, line in ipairs(Logger.ring_buffer_snapshot()) do
		if line:find("[ERROR]", 1, true)
			and line:find(needle_a, 1, true)
			and line:find(needle_b, 1, true) then
			count = count + 1
		end
	end
	return count
end

local function reset_logger()
	Logger.set_level("WARNING")
	Logger.ring_buffer_clear()
	Logger.reset_dedup()
end

local function fresh_manager()
	local db = {
		nrows = function()
			return function() return nil end
		end,
		errmsg = function() return "" end,
	}

	package.loaded["infra.logger"] = Logger
	package.loaded["infra.timings"] = {
		ms = function() return 1000 end,
		sec = function() return 1 end,
	}
	package.loaded["infra.i18n"] = {}
	package.loaded["adapters.file_system"] = {}
	package.loaded["adapters.timer_scheduler"] = {}
	package.loaded["modules.keylogger.sqlite_writer"] = {
		get_db = function() return db end,
		close_db = function() return true end,
	}
	package.loaded["modules.keylogger.aggregator"] = {}
	package.loaded["modules.keylogger.rotation"] = {
		read_new_entries = function() return {}, 0 end,
	}
	package.loaded["modules.keylogger.export"] = {
		sync_foreign_data_sql = function()
			return { "peer-device" }
		end,
	}
	package.loaded["keylogger.metrics"] = {}
	package.loaded["modules.keylogger.log_manager"] = nil
	return helpers.load_with_stubs("modules.keylogger.log_manager")
end

helpers.describe("keylogger.log_manager: callback failure visibility", function()
	helpers.it("logs, throttles, and isolates repeated ingest-listener failures", function()
		reset_logger()
		local manager = fresh_manager()
		local throwing_calls = 0
		local sibling_calls = 0

		manager.on_ingest_done(function()
			throwing_calls = throwing_calls + 1
			error("dashboard listener exploded")
		end)
		manager.on_ingest_done(function()
			sibling_calls = sibling_calls + 1
		end)

		for _ = 1, 3 do manager.ingest_once() end

		helpers.assert_eq(throwing_calls, 3,
			"diagnostic throttling must not disable the failing dashboard listener")
		helpers.assert_eq(sibling_calls, 3,
			"one broken dashboard must not prevent later listeners from refreshing")
		helpers.assert_eq(matching_errors("Ingest listener #1", "dashboard listener exploded"), 1,
			"the first listener failure must be searchable without a per-tick log storm")
		helpers.assert_eq(Logger.dedup_suppressed_count(), 2,
			"the central logger must suppress identical ingest-listener failures")

		reset_logger()
	end)

	helpers.it("logs retained compatibility completion failures with stable context", function()
		reset_logger()
		local manager = fresh_manager()
		local calls = 0
		local function throwing_completion(expected)
			return function(result)
				calls = calls + 1
				helpers.assert_eq(result, expected)
				error("legacy completion exploded")
			end
		end

		manager.merge_day_to_db_async(nil, nil, nil, throwing_completion(true))
		manager.rebuild_today_from_raw_log_async(throwing_completion(false))
		manager.rebuild_index_if_needed_async(throwing_completion(false))

		helpers.assert_eq(calls, 3, "every retained completion must still be delivered")
		helpers.assert_eq(matching_errors("Merge-day completion", "legacy completion exploded"), 1)
		helpers.assert_eq(matching_errors("Rebuild-today completion", "legacy completion exploded"), 1)
		helpers.assert_eq(matching_errors("Rebuild-index completion", "legacy completion exploded"), 1)

		reset_logger()
	end)

	helpers.it("rejects shutdown when the final ingest raises", function()
		reset_logger()
		local manager = fresh_manager()
		manager.ingest_once = function()
			error("final ingest exploded")
		end

		helpers.assert_eq(manager.stop(), false,
			"shutdown must remain incomplete when its final ingest raises")
		helpers.assert_eq(matching_errors("Final ingest cleanup", "final ingest exploded"), 1,
			"the rejected shutdown must expose the final-ingest traceback")

		reset_logger()
	end)
end)
