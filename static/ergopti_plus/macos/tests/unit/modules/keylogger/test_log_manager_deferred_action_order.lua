--- tests/unit/modules/keylogger/test_log_manager_deferred_action_order.lua

--- ==============================================================================
--- MODULE: Deferred keylogger action-boundary ordering
--- DESCRIPTION:
--- Proves the eventtap-safe flush path only swaps the live buffer into an
--- in-memory FIFO. Serialization and Rotation.append_log happen when the retained
--- timer fires, and later log entries cannot overtake the detached typing run.
--- ==============================================================================

local helpers = require("tests.helpers")


local function load_fixture(options)
	options = options or {}
	package.loaded["modules.keylogger.log_manager"] = nil
	package.loaded["modules.keylogger.rotation"] = nil
	package.loaded["modules.keylogger.sqlite_writer"] = nil
	package.loaded["modules.keylogger.aggregator"] = nil
	package.loaded["modules.keylogger.export"] = nil
	package.loaded["keylogger.metrics"] = nil
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.timer_scheduler"] = nil

	local appended = {}
	local sink_failures = options.sink_failures or 0
	package.loaded["modules.keylogger.rotation"] = {
		init = function() end,
		is_initialized = function() return true end,
		append_log = function(entry)
			if sink_failures > 0 then
				sink_failures = sink_failures - 1
				error("transient JSONL failure")
			end
			appended[#appended + 1] = entry
			return true
		end,
		read_new_entries = function() return {}, 0 end,
		get_offset = function() return 0 end,
		get_date = function() return os.date("%Y-%m-%d") end,
		set_offset = function() end,
		rollover = function() end,
	}
	package.loaded["modules.keylogger.sqlite_writer"] = {
		init = function() end,
		open_db = function() return true end,
		close_db = function() end,
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

	local wpm_calls = 0
	package.loaded["keylogger.metrics"] = {
		compute_wpm_from_events = function()
			wpm_calls = wpm_calls + 1
			return 0
		end,
	}

	local delayed = {}
	local failed_allocations = options.failed_allocations or 0
	local deferred_stop_failures = options.deferred_stop_failures or 0
	local deferred_stop_calls = 0
	local now_ns = 1000000000
	local function timer_handle(delay, callback, recurring, is_deferred, starts_running)
		local handle = {
			delay = delay,
			callback = callback,
			running = starts_running == true,
		}
		function handle:stop()
			if is_deferred then
				deferred_stop_calls = deferred_stop_calls + 1
				if deferred_stop_failures > 0 then
					deferred_stop_failures = deferred_stop_failures - 1
					return false
				end
			end
			self.running = false
			return self
		end
		function handle:start()
			self.running = true
			if is_deferred and options.deferred_activate_then_throw then
				error("deferred timer activated before start raised")
			end
			return self
		end
		function handle:fire()
			if not self.running then return end
			if not recurring then self.running = false end
			self.callback()
		end
		return handle
	end
	local timer_stub = {
		absoluteTime = function()
			now_ns = now_ns + 1000000
			return now_ns
		end,
		new = function(delay, callback)
			local is_deferred = delay <= 0.1
			if is_deferred and failed_allocations > 0 then
				failed_allocations = failed_allocations - 1
				return nil
			end
			local handle = timer_handle(delay, callback, true, is_deferred, false)
			if is_deferred then delayed[#delayed + 1] = handle end
			return handle
		end,
		doAfter = function(delay, callback)
			if failed_allocations > 0 then
				failed_allocations = failed_allocations - 1
				return nil
			end
			local handle = timer_handle(delay, callback, false, true, true)
			delayed[#delayed + 1] = handle
			if options.deferred_activate_then_throw then
				error("deferred timer activated before doAfter raised")
			end
			return handle
		end,
	}

	local saved_file_system = package.loaded["adapters.file_system"]
	package.loaded["adapters.file_system"] = {
		write = function() return true end,
		read = function() return nil end,
	}
	local log_manager = helpers.load_with_stubs("modules.keylogger.log_manager", {
		timer = timer_stub,
		fs = {
			attributes = function() return nil end,
			dir = function() return function() return nil end end,
		},
		execute = function() return "" end,
	})
	package.loaded["adapters.file_system"] = saved_file_system
	local state = {
		LOG_DIR = "/tmp/ergopti_action_epoch_order",
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
	log_manager.init(state)

	return {
		log_manager = log_manager,
		state = state,
		appended = appended,
		wpm_calls = function() return wpm_calls end,
		deferred_timer_count = function() return #delayed end,
		deferred_stop_calls = function() return deferred_stop_calls end,
		fire_next = function()
			for _, handle in ipairs(delayed) do
				if handle.running then handle:fire(); return true end
			end
			return false
		end,
	}
end


helpers.describe("log_manager deferred action boundaries", function()
	helpers.it("detaches without a sink call and preserves order with later appends", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.log_manager.defer_flush_buffer())

		helpers.assert_eq(#fixture.appended, 0,
			"the eventtap-safe path must not touch Rotation.append_log")
		helpers.assert_eq(fixture.wpm_calls(), 0,
			"even WPM iteration/serialization must stay outside the eventtap")
		helpers.assert_eq(fixture.state.buffer_text, "")
		helpers.assert_eq(#fixture.state.buffer_events, 0)

		fixture.log_manager.append_log({ type = "shortcut", key = "Cmd+K" })
		helpers.assert_eq(#fixture.appended, 0,
			"a later entry must queue behind the detached typing run")
		helpers.assert_true(fixture.fire_next())
		helpers.assert_eq(#fixture.appended, 2)
		helpers.assert_eq(fixture.appended[1].type, "typing")
		helpers.assert_eq(fixture.appended[1].text, "old")
		helpers.assert_eq(fixture.appended[2].type, "shortcut")
		helpers.assert_eq(fixture.wpm_calls(), 1)
		fixture.log_manager.stop()
	end)

	helpers.it("a failed timer allocation retains the snapshot for a later retry", function()
		local fixture = load_fixture({ failed_allocations = 1 })
		helpers.assert_true(fixture.log_manager.defer_flush_buffer(),
			"the detached snapshot is accepted once it enters the ordered outbox")
		helpers.assert_eq(#fixture.appended, 0)

		helpers.assert_true(fixture.log_manager.append_log({
			type = "system_event", action = "after",
		}), "a sibling queued behind the snapshot is accepted independently of scheduling")
		helpers.assert_true(fixture.fire_next())
		helpers.assert_eq(#fixture.appended, 2)
		helpers.assert_eq(fixture.appended[1].text, "old")
		helpers.assert_eq(fixture.appended[2].action, "after")
		fixture.log_manager.stop()
	end)

	helpers.it("a transient sink failure retries the same head before its siblings", function()
		local fixture = load_fixture({ sink_failures = 1 })
		helpers.assert_true(fixture.log_manager.defer_flush_buffer())
		fixture.log_manager.append_log({ type = "system_event", action = "after" })

		helpers.assert_true(fixture.fire_next())
		helpers.assert_eq(#fixture.appended, 0,
			"the failing head must remain queued and block later entries")
		helpers.assert_true(fixture.fire_next())
		helpers.assert_eq(#fixture.appended, 2)
		helpers.assert_eq(fixture.appended[1].text, "old")
		helpers.assert_eq(fixture.appended[2].action, "after")
		fixture.log_manager.stop()
	end)

	helpers.it("retains an activated candidate when start and rollback both fail", function()
		local fixture = load_fixture({
			deferred_activate_then_throw = true,
			deferred_stop_failures = 1,
		})
		helpers.assert_true(fixture.log_manager.defer_flush_buffer())
		helpers.assert_eq(fixture.deferred_timer_count(), 1,
			"the failed acquisition must still have one exact native candidate")

		fixture.log_manager.append_log({ type = "system_event", action = "after" })
		helpers.assert_eq(fixture.deferred_timer_count(), 1,
			"cleanup debt must block a sibling drain timer")
		helpers.assert_true(fixture.fire_next())
		helpers.assert_eq(#fixture.appended, 0,
			"an uncommitted candidate callback must stay fenced")

		helpers.assert_true(fixture.log_manager.stop(),
			"teardown must retry the exact candidate and synchronously drain its FIFO")
		helpers.assert_eq(fixture.deferred_stop_calls(), 2)
		helpers.assert_eq(#fixture.appended, 2)
		helpers.assert_eq(fixture.appended[1].text, "old")
		helpers.assert_eq(fixture.appended[2].action, "after")
	end)
end)

for _, name in ipairs({
	"modules.keylogger.log_manager", "modules.keylogger.rotation",
	"modules.keylogger.sqlite_writer", "modules.keylogger.aggregator",
	"modules.keylogger.export", "keylogger.metrics", "infra.logger",
	"adapters.timer_scheduler",
}) do
	package.loaded[name] = nil
end
