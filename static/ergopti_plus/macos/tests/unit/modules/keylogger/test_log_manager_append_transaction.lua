--- tests/unit/modules/keylogger/test_log_manager_append_transaction.lua

--- ==============================================================================
--- MODULE: Keylogger Append Transaction Regression Tests
--- DESCRIPTION:
--- Proves a non-throwing filesystem refusal cannot discard a detached typing
--- snapshot or a later ordered log entry. Rotation accepts an append only after
--- an unbuffered handle is configured and write reports its documented success;
--- LogManager
--- retains the exact FIFO head until that strict commit occurs.
---
--- ROOT CAUSE ENCODED:
--- Lua file methods can report ENOSPC as `nil, error` without throwing. The old
--- append path ignored those results and returned nil on both success and failure.
--- Its deferred drain then advanced the queue after any non-throwing call, so an
--- OFF/quit flush emptied CoreState first and silently lost the only snapshot.
--- ==============================================================================

local helpers = require("tests.helpers")

local MUTATED_PACKAGE_SLOTS = {
	"adapters.file_system", "adapters.timer_scheduler",
	"hs", "hs.fs", "hs.json", "hs.sqlite3", "hs.timer",
	"infra.logger", "infra.timings", "keylogger.metrics",
	"modules.keylogger.aggregator", "modules.keylogger.export",
	"modules.keylogger.log_manager", "modules.keylogger.rotation",
	"modules.keylogger.sqlite_writer", "modules.keylogger.timestamp",
	"tests.stubs.hs",
}

--- Captures every global/package slot replaced by these behavioral fixtures.
--- @return function restore Exact restoration closure for test-order isolation.
local function capture_runtime()
	local saved_hs = _G.hs
	local saved_open = io.open
	local saved_packages = {}
	for _, name in ipairs(MUTATED_PACKAGE_SLOTS) do
		saved_packages[name] = package.loaded[name]
	end
	return function()
		io.open = saved_open
		_G.hs = saved_hs
		for _, name in ipairs(MUTATED_PACKAGE_SLOTS) do
			package.loaded[name] = saved_packages[name]
		end
	end
end

--- Runs one fixture body and restores its exact runtime mutations on failure too.
--- @param factory function Fixture constructor returning a restore method.
--- @param body function Assertion body receiving the fixture.
local function with_fixture(factory, body)
	local fixture = factory()
	local ok, err = xpcall(body, debug.traceback, fixture)
	fixture.restore()
	if not ok then error(err, 0) end
end





-- ==========================================
-- ==========================================
-- ======= 1/ Rotation Append Fixture =======
-- ==========================================
-- ==========================================

--- Loads Rotation against a configurable append handle without touching disk.
--- @param options table|nil Failure counters for open, setvbuf, and write.
--- @return table fixture Append results and captured durable lines.
local function load_rotation_fixture(options)
	options = options or {}
	local restore_runtime = capture_runtime()
	package.loaded["modules.keylogger.rotation"] = nil
	package.loaded["modules.keylogger.timestamp"] = {
		now_ts = function() return "2026-08-13 12:00:00.000" end,
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()

	local durable_lines = {}
	local open_failures = options.open_failures or 0
	local setvbuf_failures = options.setvbuf_failures or 0
	local write_failures = options.write_failures or 0
	local written_bytes = ""
	local closed_handles = 0

	io.open = function(_path, _mode)
		if open_failures > 0 then
			open_failures = open_failures - 1
			return nil, "ENOSPC", 28
		end
		local handle = {}
		function handle:setvbuf(mode)
			if setvbuf_failures > 0 then
				setvbuf_failures = setvbuf_failures - 1
				return nil, "setvbuf refused"
			end
			return mode == "no"
		end
		function handle:write(line)
			if write_failures > 0 then
				write_failures = write_failures - 1
				written_bytes = written_bytes .. "{partial"
				return nil, "ENOSPC", 28
			end
			written_bytes = written_bytes .. line
			durable_lines[#durable_lines + 1] = line
			return self
		end
		function handle:close()
			closed_handles = closed_handles + 1
			return true
		end
		return handle
	end

	local hs_stub = _G.hs or require("tests.stubs.hs")
	package.loaded["hs.json"] = hs_stub.json
	local rotation = require("modules.keylogger.rotation")

	return {
		rotation = rotation,
		durable_lines = durable_lines,
		written_bytes = function() return written_bytes end,
		closed_handles = function() return closed_handles end,
		restore = restore_runtime,
	}
end





-- =============================================
-- =============================================
-- ======= 2/ LogManager Ordered Fixture =======
-- =============================================
-- =============================================

--- Loads LogManager with a Rotation sink that explicitly refuses before commit.
--- @param sink_failures integer Number of exact false results before success.
--- @return table fixture State, captures, and controllable deferred timers.
local function load_log_manager_fixture(sink_failures)
	local restore_runtime = capture_runtime()
	for _, name in ipairs({
		"modules.keylogger.log_manager", "modules.keylogger.rotation",
		"modules.keylogger.sqlite_writer", "modules.keylogger.aggregator",
		"modules.keylogger.export", "keylogger.metrics", "infra.logger",
		"infra.timings", "adapters.timer_scheduler",
	}) do
		package.loaded[name] = nil
	end
	package.loaded["infra.logger"] = helpers.make_logger_stub()

	local appended = {}
	package.loaded["modules.keylogger.rotation"] = {
		init = function() end,
		is_initialized = function() return true end,
		append_log = function(entry)
			if sink_failures > 0 then
				sink_failures = sink_failures - 1
				return false
			end
			appended[#appended + 1] = entry
			return true
		end,
		read_new_entries = function() return {}, 0, "eof" end,
		get_offset = function() return 0 end,
		get_date = function() return "2026-08-13" end,
		set_offset = function() end,
		rollover = function() return true end,
	}
	package.loaded["modules.keylogger.sqlite_writer"] = {
		init = function() end,
		open_db = function() return true end,
		close_db = function() return true end,
		get_db = function() return nil end,
		build_inserts = function() return {} end,
		persist_next_event_id = function() end,
	}
	package.loaded["modules.keylogger.aggregator"] = {
		init = function() end,
		get_ngram_ctx = function() return {} end,
		set_ngram_ctx = function() end,
		reset_ngram_ctx = function() end,
	}
	package.loaded["modules.keylogger.export"] = {
		init = function() end,
		sync_foreign_data_sql = function() end,
		get_native_app_category = function() return "other" end,
		get_device_short_id = function() return "test" end,
		get_sqlite_path = function() return nil end,
		get_db_rev = function() return 0 end,
	}
	package.loaded["keylogger.metrics"] = {
		compute_wpm_from_events = function() return 12 end,
	}

	local delayed = {}
	local now_ns = 1000000000
	local function timer_handle(callback, recurring)
		local handle = { running = false }
		function handle:start() self.running = true; return self end
		function handle:stop() self.running = false; return true end
		function handle:fire()
			if not self.running then return false end
			if not recurring then self.running = false end
			callback()
			return true
		end
		return handle
	end
	local timer_stub = {
		absoluteTime = function()
			now_ns = now_ns + 1000000
			return now_ns
		end,
		new = function(delay, callback)
			local handle = timer_handle(callback, true)
			-- The five-second owner is the recurring ingest loop. Shorter candidates
			-- are transactional one-shots owned by TimerScheduler.after().
			if delay < 5 then delayed[#delayed + 1] = handle end
			return handle
		end,
		doAfter = function(_delay, callback)
			local handle = timer_handle(callback, false)
			delayed[#delayed + 1] = handle
			return handle
		end,
	}
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	hs_stub.timer = timer_stub
	hs_stub.fs = {
		attributes = function() return nil end,
		dir = function() return function() return nil end end,
	}
	hs_stub.execute = function() return "" end
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["hs.timer"] = timer_stub
	package.loaded["hs.fs"] = hs_stub.fs
	package.loaded["hs.json"] = hs_stub.json
	package.loaded["hs.sqlite3"] = hs_stub.sqlite3
	package.loaded["infra.timings"] = {
		sec = function() return 5 end,
		ms = function() return 2000 end,
	}

	local saved_file_system = package.loaded["adapters.file_system"]
	package.loaded["adapters.file_system"] = {
		write = function() return true end,
		read = function() return nil end,
	}
	local manager = require("modules.keylogger.log_manager")
	package.loaded["adapters.file_system"] = saved_file_system

	local state = {
		LOG_DIR = "/tmp/ergopti_append_transaction",
		buffer_events = { { "old", 20, {} } },
		buffer_text = "old",
		rich_chunks = { { type = "text", text = "old" } },
		last_time = 20,
		pending_keyup = { [1] = true },
		session_mouse_clicks = 0,
		session_mouse_scrolls = 0,
		mouse_distance_px = 0,
		last_flush_time = 0,
		session_app_name = "Editor",
		session_win_title = "Document",
		session_layout = "ABC",
		current_session_pause = 50,
		today_idx = {},
		manifest = {},
	}
	helpers.assert_true(manager.init(state), "fixture LogManager must initialize")

	return {
		manager = manager,
		state = state,
		appended = appended,
		fire_next = function()
			for _, handle in ipairs(delayed) do
				if handle.running then return handle:fire() end
			end
			return false
		end,
		restore = restore_runtime,
	}
end





-- ==========================================
-- ==========================================
-- ======= 3/ Exact Append Acceptance =======
-- ==========================================
-- ==========================================

helpers.describe("rotation exact append transaction", function()
	helpers.it("rejects a non-throwing write failure and commits one retry", function()
		with_fixture(function()
			return load_rotation_fixture({ write_failures = 1 })
		end, function(fixture)
			fixture.rotation.init({ paths = { today_log_path = "/tmp/today.log" }, state = {} })
			local first = fixture.rotation.append_log({ type = "typing", text = "owned" })
			local second = fixture.rotation.append_log({ type = "typing", text = "owned" })

			helpers.assert_eq(first, false, "nil, ENOSPC from write must be an explicit refusal")
			helpers.assert_true(second, "the exact retry must commit after storage recovers")
			helpers.assert_eq(#fixture.durable_lines, 1,
				"one refused write followed by one retry must yield one complete logical line")
			helpers.assert_true(fixture.written_bytes():find("{partial\n", 1, true) ~= nil,
				"retry must isolate a possibly partial failed write behind a line boundary")
			helpers.assert_true(fixture.closed_handles() >= 1,
				"the ambiguous failed handle must be invalidated before retry")
		end)
	end)

	helpers.it("rejects non-throwing open and unbuffered-mode failures", function()
		with_fixture(function()
			return load_rotation_fixture({ open_failures = 2 })
		end, function(fixture)
			fixture.rotation.init({ paths = { today_log_path = "/tmp/today.log" }, state = {} })
			helpers.assert_eq(fixture.rotation.append_log({ type = "typing", text = "open" }), false,
				"nil, ENOSPC from io.open must be an explicit refusal")
			helpers.assert_true(fixture.rotation.append_log({ type = "typing", text = "open" }))
			helpers.assert_eq(#fixture.durable_lines, 1)
		end)

		with_fixture(function()
			return load_rotation_fixture({ setvbuf_failures = 2 })
		end, function(fixture)
			fixture.rotation.init({ paths = { today_log_path = "/tmp/today.log" }, state = {} })
			helpers.assert_eq(fixture.rotation.append_log({ type = "typing", text = "mode" }), false,
				"a setvbuf refusal must not publish a buffered handle")
			helpers.assert_true(fixture.rotation.append_log({ type = "typing", text = "mode" }))
			helpers.assert_eq(#fixture.durable_lines, 1)
		end)
	end)
end)





-- ===========================================
-- ===========================================
-- ======= 4/ Snapshot Retry Ownership =======
-- ===========================================
-- ===========================================

helpers.describe("log_manager append transaction ownership", function()
	helpers.it("retains an OFF flush snapshot across refusal until exact commit", function()
		-- flush_buffer() attempts once; stop() retries once directly and once via
		-- its final ingest pass. Refuse all three so lifecycle debt remains visible.
		with_fixture(function()
			return load_log_manager_fixture(3)
		end, function(fixture)
			helpers.assert_eq(fixture.manager.flush_buffer(), false,
				"the first storage refusal must propagate to the lifecycle owner")
			helpers.assert_eq(fixture.state.buffer_text, "",
				"the live buffer is detached once; ownership moves to the FIFO")
			fixture.state.buffer_text = "new"
			fixture.state.buffer_events = { { "new", 30, {} } }

			helpers.assert_eq(fixture.manager.stop(), false,
				"stop must retain cleanup debt while the exact FIFO head is refused")
			helpers.assert_eq(#fixture.appended, 0)
			helpers.assert_true(fixture.manager.stop(),
				"a later stop retry must commit the retained snapshot")
			helpers.assert_eq(#fixture.appended, 1)
			helpers.assert_eq(fixture.appended[1].text, "old",
				"retry must serialize the detached snapshot, not the replacement live buffer")
			helpers.assert_eq(fixture.appended[1].events[1][1], "old")
		end)
	end)

	helpers.it("keeps a deferred FIFO head after an exact false sink result", function()
		with_fixture(function()
			return load_log_manager_fixture(1)
		end, function(fixture)
			helpers.assert_true(fixture.manager.defer_flush_buffer())
			helpers.assert_true(fixture.fire_next(), "the first deferred drain must run")
			helpers.assert_eq(#fixture.appended, 0,
				"an explicitly refused append must not be published as committed")
			helpers.assert_true(fixture.fire_next(),
				"the retained head must schedule a second drain")
			helpers.assert_eq(#fixture.appended, 1)
			helpers.assert_eq(fixture.appended[1].text, "old")
			helpers.assert_true(fixture.manager.stop())
		end)
	end)
end)
