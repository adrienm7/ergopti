--- tests/unit/modules/keylogger/test_rotation_read_failure_preserves_journal.lua

--- ==============================================================================
--- MODULE: Keylogger Journal Read-Failure Rollover Tests
--- DESCRIPTION:
--- Wires the real rotation and log-manager modules to a non-empty virtual
--- today.log. A read failure must remain distinguishable from committed EOF so
--- day rollover cannot delete the only durable copy of un-ingested events.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ======================================
-- ======================================
-- ======= 1/ End-to-End Harness ========
-- ======================================
-- ======================================

local JOURNAL_PATH = "/virtual/keylogger/today.log"
local JOURNAL_SIZE = 128

local STUBBED_MODULES = {
	"modules.keylogger.sqlite_writer",
	"modules.keylogger.aggregator",
	"modules.keylogger.rotation",
	"modules.keylogger.export",
	"keylogger.metrics",
	"adapters.file_system",
}

local function fake_writer(on_write, on_close)
	return {
		setvbuf = function(_, mode) return mode == "no" end,
		write = function(self, text)
			if on_write then on_write(text) end
			return self
		end,
		flush = function() return true end,
		close = function()
			if on_close then on_close() end
			return true
		end,
	}
end

local function make_reader(failure_mode)
	local position = 0
	return {
		seek = function(_, whence, offset)
			if whence == "end" then
				position = JOURNAL_SIZE
			elseif whence == "set" then
				position = offset or 0
			end
			return position
		end,
		read = function()
			if failure_mode == "read" then return nil, "input/output error", 5 end
			return nil
		end,
		close = function()
			if failure_mode == "close" then return nil, "close failed", 5 end
			return true
		end,
	}
end

local function make_state()
	return {
		LOG_DIR               = "/virtual/keylogger/metrics",
		buffer_events         = {},
		buffer_text           = "",
		rich_chunks           = {},
		session_mouse_clicks  = 0,
		session_mouse_scrolls = 0,
		mouse_distance_px     = 0,
		last_flush_time       = 0,
		last_time             = 0,
		pending_keyup         = {},
		today_idx             = {},
		manifest              = {},
	}
end

local function run_rollover_case(failure_mode)
	local saved_modules = {}
	for _, name in ipairs(STUBBED_MODULES) do
		saved_modules[name] = package.loaded[name]
	end

	local observed = {
		journal_removes = 0,
		journal_opens = 0,
		journal_closes = 0,
		marker_writes = 0,
		reset_calls = 0,
		read_calls = 0,
	}
	local journal_present = true
	local real_open = io.open
	local real_remove = os.remove
	local ok, result_or_error = xpcall(function()
		io.open = function(path, mode)
			if path == JOURNAL_PATH and mode == "a" then
				observed.journal_opens = observed.journal_opens + 1
				return fake_writer(nil, function()
					observed.journal_closes = observed.journal_closes + 1
				end)
			end
			if path == JOURNAL_PATH and mode == "r" then
				if not journal_present then return nil, "no such file", 2 end
				observed.read_calls = observed.read_calls + 1
				return make_reader(failure_mode)
			end
			if mode == "a" or mode == "w" then
				return fake_writer(function(text)
					if tostring(text):find("day rollover", 1, true) then
						observed.marker_writes = observed.marker_writes + 1
					end
				end)
			end
			return real_open(path, mode)
		end
		os.remove = function(path)
			if path == JOURNAL_PATH then
				observed.journal_removes = observed.journal_removes + 1
				if failure_mode == "remove_throw" then
					error("injected remove failure")
				end
				if failure_mode == "remove" then
					return nil, "permission denied", 13
				end
				journal_present = false
				return true
			end
			return real_remove(path)
		end

		package.loaded["modules.keylogger.rotation"] = nil
		local rotation = helpers.load_with_stubs("modules.keylogger.rotation", {
			fs = {
				attributes = function(path)
					if path == JOURNAL_PATH then return { size = JOURNAL_SIZE } end
					return nil
				end,
			},
		})
		rotation.init({
			paths = { today_log_path = JOURNAL_PATH },
			state = {},
			today_log_offset = failure_mode == "read" and 0 or JOURNAL_SIZE,
			today_log_date = "2099-06-30",
		})

		package.loaded["modules.keylogger.sqlite_writer"] = {
			init = function() end,
			open_db = function() return false end,
			close_db = function() end,
			get_db = function() return nil end,
		}
		package.loaded["modules.keylogger.aggregator"] = {
			init = function() end,
			reset_ngram_ctx = function() observed.reset_calls = observed.reset_calls + 1 end,
		}
		package.loaded["modules.keylogger.export"] = {
			init = function() end,
			get_native_app_category = function() return "other" end,
			get_device_short_id = function() return "abcd" end,
			get_sqlite_path = function() return "/virtual/cache.sqlite" end,
			get_db_rev = function() return 0 end,
			sync_foreign_data_sql = function() end,
		}
		package.loaded["keylogger.metrics"] = {}
		package.loaded["adapters.file_system"] = {
			write = function() return true end,
			create_if_absent = function() return true, "created" end,
			read = function() return nil end,
		}

		local log_manager = helpers.load_with_stubs("modules.keylogger.log_manager", {
			execute = function(command)
				if command:find("ioreg", 1, true) then return "TEST-HOST-ROLLOVER" end
				return ""
			end,
			fs = {
				attributes = function() return nil end,
				dir = function() return function() return nil end end,
			},
		})
		helpers.assert_eq(log_manager.init(make_state()), true,
			"the rollover harness must initialize before exercising the read boundary")

		local status_before = nil
		if failure_mode == nil then
			local _, _, status = rotation.read_new_entries()
			status_before = status
		end
		local rollover_result = log_manager.day_rollover()
		local offset_before_append = rotation.get_offset()
		local date_before_append = rotation.get_date()
		local append_result = nil
		if failure_mode == "remove" or failure_mode == "remove_throw" then
			append_result = rotation.append_log({
				type = "typing",
				timestamp = "2099-06-30 23:59:59.999",
				text = "x",
			})
		end
		local _, offset_after, status_after = rotation.read_new_entries()
		return {
			append_result = append_result,
			date_before_append = date_before_append,
			journal_removes = observed.journal_removes,
			journal_opens = observed.journal_opens,
			journal_closes = observed.journal_closes,
			marker_writes = observed.marker_writes,
			offset_before_append = offset_before_append,
			reset_calls = observed.reset_calls,
			read_calls = observed.read_calls,
			rollover_result = rollover_result,
			status_before = status_before,
			status_after = status_after,
			offset_after = offset_after,
		}
	end, debug.traceback)

	io.open = real_open
	os.remove = real_remove
	for _, name in ipairs(STUBBED_MODULES) do
		package.loaded[name] = saved_modules[name]
	end
	package.loaded["modules.keylogger.log_manager"] = nil
	if not ok then error(result_or_error, 0) end
	return result_or_error
end





-- ==========================================
-- ==========================================
-- ======= 2/ Committed EOF Ownership =======
-- ==========================================
-- ==========================================

helpers.describe("keylogger rollover requires committed EOF", function()
	helpers.it("preserves a non-empty journal when its read fails", function()
		local result = run_rollover_case("read")
		helpers.assert_true(result.read_calls >= 1,
			"the failure must come from attempting to read the non-empty journal")
		helpers.assert_eq(result.journal_removes, 0,
			"read failure must never reach Rotation.rollover's delete boundary")
		helpers.assert_eq(result.reset_calls, 0,
			"read failure must preserve the aggregate resumption context")
		helpers.assert_eq(result.rollover_result, false,
			"day_rollover must report a retryable failure when EOF was not committed")
		helpers.assert_eq(result.status_after, "failed",
			"rotation must expose read failure separately from EOF")
		helpers.assert_eq(result.offset_after, 0,
			"a failed read must preserve the last committed byte offset")
	end)

	helpers.it("preserves a fully read journal when close does not commit", function()
		local result = run_rollover_case("close")
		helpers.assert_eq(result.journal_removes, 0,
			"close failure must invalidate EOF before the delete boundary")
		helpers.assert_eq(result.reset_calls, 0,
			"close failure must preserve the aggregate resumption context")
		helpers.assert_eq(result.rollover_result, false,
			"day_rollover must report failure until the reader closes successfully")
		helpers.assert_eq(result.status_after, "failed",
			"rotation must expose close failure separately from committed EOF")
	end)

	helpers.it("allows rollover only after a successful close at exact EOF", function()
		local result = run_rollover_case(nil)
		helpers.assert_eq(result.status_before, "eof",
			"an exact end offset with a successful close must commit EOF explicitly")
		helpers.assert_eq(result.journal_removes, 1,
			"a committed EOF may cross the rollover delete boundary exactly once")
		helpers.assert_eq(result.reset_calls, 1,
			"successful rollover must reset aggregate context exactly once")
		helpers.assert_eq(result.rollover_result, true,
			"day_rollover must report success after committed EOF")
	end)

	helpers.it("publishes no rollover state when today.log deletion is refused", function()
		for _, failure_mode in ipairs({ "remove", "remove_throw" }) do
			local result = run_rollover_case(failure_mode)
			helpers.assert_eq(result.journal_removes, 1,
				failure_mode .. " must attempt the exact journal deletion once")
			helpers.assert_eq(result.rollover_result, false,
				failure_mode .. " must keep rollover retryable")
			helpers.assert_eq(result.offset_before_append, JOURNAL_SIZE,
				failure_mode .. " must preserve the committed journal offset")
			helpers.assert_eq(result.date_before_append, "2099-06-30",
				failure_mode .. " must preserve the journal date")
			helpers.assert_eq(result.reset_calls, 0,
				failure_mode .. " must preserve aggregate resumption context")
			helpers.assert_eq(result.marker_writes, 0,
				failure_mode .. " must not publish a durable rollover marker")
			helpers.assert_eq(result.journal_closes, 0,
				failure_mode .. " must retain the append handle")
			helpers.assert_eq(result.journal_opens, 1,
				failure_mode .. " must reuse the exact retained journal handle")
			helpers.assert_eq(result.append_result, true,
				failure_mode .. " must leave the append owner usable")
		end
	end)
end)
