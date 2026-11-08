--- tests/unit/modules/keystats/log_manager/test_log_manager_deferred_action_order.lua

--- ==============================================================================
--- MODULE: Deferred keystats action-boundary ordering
--- DESCRIPTION:
--- Proves the eventtap-safe flush path only swaps the live buffer into an
--- in-memory FIFO. Serialization and Rotation.append_log happen when the retained
--- timer fires, and later log entries cannot overtake the detached typing run.
--- ==============================================================================

local helpers = require("tests.helpers")
local EmptyLedger = require("tests.support.keystats.absent_ledger_file_system")


--- Establishes an actual absent source before asking the cipher to admit plaintext.
local function plaintext_cipher()
	package.loaded["infra.preferences"] = nil
	local path = os.tmpname()
	assert(os.remove(path))
	local logger = require("infra.logger")
	local previous, errors = logger.error, {}
	logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
	local _, status = helpers.load_with_stubs("infra.preferences").load(path)
	logger.error = previous
	helpers.assert_eq(status, "absent", table.concat(errors, "; "))
	return require("modules.keystats.text_cipher")
end

local function load_fixture(options)
	options = options or {}
	package.loaded["modules.keystats.log_manager"] = nil
	package.loaded["modules.keystats.rotation"] = nil
	package.loaded["modules.keystats.sqlite_writer"] = nil
	package.loaded["modules.keystats.aggregator"] = nil
	package.loaded["modules.keystats.export"] = nil
	package.loaded["keystats.metrics"] = nil
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.timer_scheduler"] = nil

	local appended = {}
	local sink_failures = options.sink_failures or 0
	package.loaded["modules.keystats.rotation"] = {
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
	package.loaded["modules.keystats.sqlite_writer"] = {
		init = function() end,
		open_db = function() return true end,
		close_db = function() end,
		get_db = function() return nil end,
		build_inserts = function() return {} end,
		persist_next_event_id = function() end,
	}
	package.loaded["modules.keystats.aggregator"] = {
		init = function() end,
		get_ngram_ctx = function() return {} end,
		set_ngram_ctx = function() end,
		reset_ngram_ctx = function() end,
	}
	package.loaded["modules.keystats.export"] = {
		cleanup = function() return true end,
		init = function() end,
		sync_foreign_data_sql = function() end,
		get_native_app_category = function() return "other" end,
		get_device_short_id = function() return "test" end,
		get_sqlite_path = function() return nil end,
		get_db_rev = function() return 0 end,
	}

	local wpm_calls = 0
	package.loaded["keystats.metrics"] = {
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
		create_if_absent = function() return true, "created" end,
		read = function() return nil end,
	}
	local log_manager = EmptyLedger.load({
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
		CACHE_DIR = "/tmp/ergopti_action_epoch_order/cache",
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
	helpers.it("retires queued ROI builders without evaluating them or discarding numerical rows", function()
		helpers.with_stub_scope({ "modules.keystats.text_cipher", "modules.keystats.init", "modules.keystats" }, function()
			package.loaded["modules.keystats.text_cipher"] = nil
			package.loaded["modules.keystats.init"], package.loaded["modules.keystats"] = nil, nil
			local cipher = plaintext_cipher()
			local fixture = load_fixture()
			helpers.assert_true(cipher.set_enabled(false))
			local built = 0
			helpers.assert_true(fixture.log_manager.defer_entry_builder(function()
				built = built + 1
				return { type = "new_trigger_candidate", word = "retired", occurrences = 5 }
			end, true))
			helpers.assert_true(fixture.log_manager.append_log({ type = "roi_snapshot", session_saved = 20, session_fired = 10 }))
			helpers.assert_true(cipher.set_enabled(true))
			helpers.assert_true(fixture.fire_next())
			helpers.assert_eq(built, 0)
			helpers.assert_eq(#fixture.appended, 1)
			helpers.assert_eq(fixture.appended[1].session_fired, 10)
			helpers.assert_eq(fixture.log_manager.append_log({ type = "trigger_halflife", trigger = "blocked" }), false)
			helpers.assert_true(cipher.set_enabled(false))
			helpers.assert_true(fixture.log_manager.append_log({ type = "new_trigger_candidate", word = "fresh", occurrences = 5 }))
			helpers.assert_true(fixture.fire_next())
			helpers.assert_eq(fixture.appended[2].word, "fresh")
		end)
	end)

	helpers.it("rechecks a reentrant encryption request before a built ROI row can start writing", function()
		helpers.with_stub_scope({ "modules.keystats.text_cipher", "modules.keystats.init", "modules.keystats" }, function()
			package.loaded["modules.keystats.text_cipher"] = nil
			package.loaded["modules.keystats.init"], package.loaded["modules.keystats"] = nil, nil
			local cipher = plaintext_cipher()
			local fixture = load_fixture()
			helpers.assert_true(cipher.set_enabled(false))
			helpers.assert_true(fixture.log_manager.defer_entry_builder(function()
				helpers.assert_eq(cipher.set_enabled(true), false, "the traversing FIFO cannot publish a new posture")
				return { type = "new_trigger_candidate", word = "revoked", occurrences = 5 }
			end, true))
			helpers.assert_true(fixture.log_manager.append_log({ type = "roi_snapshot", session_fired = 10 }))
			helpers.assert_true(fixture.fire_next())
			helpers.assert_eq(#fixture.appended, 1)
			helpers.assert_eq(fixture.appended[1].type, "roi_snapshot")
			helpers.assert_true(cipher.abandon_roi_encryption(false))
			helpers.assert_true(cipher.roi_text_enabled())
		end)
	end)

	helpers.it("settles the exact partial ROI append before publishing encryption and never rebuilds it", function()
		helpers.with_stub_scope({ "modules.keystats.text_cipher", "modules.keystats.init", "modules.keystats" }, function()
			package.loaded["modules.keystats.text_cipher"] = nil
			package.loaded["modules.keystats.init"], package.loaded["modules.keystats"] = nil, nil
			local cipher = plaintext_cipher()
			local fixture = load_fixture()
			helpers.assert_true(cipher.set_enabled(false))
			local sink = package.loaded["modules.keystats.rotation"]
			package.loaded["modules.keystats.rotation"] = nil
			local real = require("modules.keystats.rotation")
			package.loaded["modules.keystats.rotation"] = sink
			for name, callback in pairs(real) do sink[name] = callback end
			local path, original_open = os.tmpname(), io.open
			local handles, faults, builds = {}, 3, 0
			io.open = function(name, mode)
				local file, reason, code = original_open(name, mode)
				if not file or name ~= path or mode ~= "a+" then return file, reason, code end
				handles[#handles + 1] = file
				return {
					setvbuf = function(_, ...) return file:setvbuf(...) end,
					seek = function(_, ...) return file:seek(...) end,
					read = function(_, ...) return file:read(...) end,
					close = function() return file:close() end,
					write = function(_, bytes)
						if faults > 0 then
							faults = faults - 1
							assert(file:write(bytes:sub(1, 8)))
							return nil, "controlled partial append", 28
						end
						return file:write(bytes)
					end,
				}
			end
			local entry = { type = "new_trigger_candidate", word = "original", occurrences = 5,
				timestamp = "2026-11-07 10:00:00.000", app = "Editor" }
			local ok, reason = xpcall(function()
				sink.init({ paths = { today_log_path = path }, state = {}, recovery_turn_bytes = 4096 })
				helpers.assert_true(fixture.log_manager.defer_entry_builder(function() builds = builds + 1; return entry end, true))
				helpers.assert_true(fixture.log_manager.defer_entry_builder(function() error("unstarted text must be retired") end, true))
				helpers.assert_true(fixture.fire_next())
				helpers.assert_true(sink.has_pending_entry(entry))
				helpers.assert_eq(cipher.set_enabled(true), false)
				helpers.assert_eq(cipher.is_enabled(), false, "a refused receipt cannot publish ON")
				helpers.assert_eq(cipher.roi_text_enabled(), false, "new text stays closed while debt is retained")
				helpers.assert_eq(cipher.set_enabled(false), false, "an OFF refresh cannot reopen capture over unresolved debt")
				helpers.assert_eq(cipher.roi_text_enabled(), false)
				helpers.assert_eq(cipher.abandon_roi_encryption(false), true, "the recovered receipt can settle under the former OFF posture")
				helpers.assert_eq(cipher.is_enabled(), false)
				helpers.assert_eq(builds, 1)
				helpers.assert_eq(sink.has_pending_entry(entry), false)
				local file = assert(original_open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close())
				helpers.assert_eq(bytes, hs.json.encode(entry) .. "\n", "the exact row must occur once without truncation or regenerated identity")
				helpers.assert_true(cipher.set_enabled(true))
				helpers.assert_eq(cipher.is_enabled(), true)
				helpers.assert_eq(sink.append_log({ type = "new_trigger_candidate", word = "later", timestamp = entry.timestamp }), false)
			end, debug.traceback)
			io.open = original_open
			for _, file in ipairs(handles) do pcall(file.close, file) end
			os.remove(path)
			if not ok then error(reason, 0) end
		end)
	end)

end)

for _, name in ipairs({
	"adapters.ledger_append", "modules.keystats.log_manager", "modules.keystats.rotation",
	"modules.keystats.sqlite_writer", "modules.keystats.aggregator",
	"modules.keystats.export", "keystats.metrics", "infra.logger",
	"adapters.timer_scheduler",
}) do
	package.loaded[name] = nil
end
