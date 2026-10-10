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
		create_if_absent = function() return true, "created" end,
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


-- Closed synthetic marker order frozen before the fairness implementation.
local FAIRNESS_MARKERS = {
	"001", "002", "003", "004", "005", "006", "007", "008", "009", "010", "011", "012", "013", "014", "015", "016",
	"017", "018", "019", "020", "021", "022", "023", "024", "025", "026", "027", "028", "029", "030", "031", "032",
	"033", "034", "035", "036", "037", "038", "039", "040", "041", "042", "043", "044", "045", "046", "047", "048",
	"049", "050", "051", "052", "053", "054", "055", "056", "057", "058", "059", "060", "061", "062", "063", "064",
	"065", "066", "067", "068", "069", "070", "071", "072", "073", "074", "075", "076", "077", "078", "079", "080",
	"081", "082", "083", "084", "085", "086", "087", "088", "089", "090", "091", "092", "093", "094", "095", "096",
	"097", "098", "099", "100", "101", "102", "103", "104", "105", "106", "107", "108", "109", "110", "111", "112",
	"113", "114", "115", "116", "117", "118", "119", "120", "121", "122", "123", "124", "125", "126", "127", "128",
	"129",
}

-- Reuse the original fixture and its real TimerScheduler wrapper. The capture
-- only retains its disclosed native timer port/handles; it alters no verdict.
local function load_fairness_fixture(options)
	local original = helpers.load_with_stubs
	local ctx = { recurring = {}, deferred = {} }
	helpers.load_with_stubs = function(name, ports, ...)
		if name == "modules.keylogger.log_manager" then
			ctx.timer = ports.timer
			local construct = ports.timer.new
			ports.timer.new = function(delay, callback)
				local handle = construct(delay, callback)
				if handle then
					local list = delay <= 0.1 and ctx.deferred or ctx.recurring
					list[#list + 1] = handle
				end
				return handle
			end
		end
		return original(name, ports, ...)
	end
	local ok, fixture = pcall(load_fixture, options)
	helpers.load_with_stubs = original
	if not ok then error(fixture, 0) end
	return fixture, ctx
end

local function queue_fairness_markers(fixture, first)
	for index = first or 1, #FAIRNESS_MARKERS do
		helpers.assert_true(fixture.log_manager.append_log({
			type = "system_event", action = "marker-" .. FAIRNESS_MARKERS[index],
		}))
	end
end

local function assert_fairness_order(fixture)
	helpers.assert_eq(#fixture.appended, #FAIRNESS_MARKERS)
	for index, marker in ipairs(FAIRNESS_MARKERS) do
		helpers.assert_eq(fixture.appended[index].action, "marker-" .. marker)
	end
end

local function finish_fairness_turns(fixture)
	for _ = 1, 5 do
		if #fixture.appended == #FAIRNESS_MARKERS then break end
		local before = #fixture.appended
		helpers.assert_true(fixture.fire_next())
		local committed = #fixture.appended - before
		helpers.assert_true(committed >= 1 and committed <= 64,
			"each healthy owned continuation has a finite committed prefix")
	end
	assert_fairness_order(fixture)
end

helpers.describe("deferred log count fairness", function()
	helpers.it("yields the deferred background prefix to an already eligible peer", function()
		local fixture, ctx = load_fairness_fixture()
		queue_fairness_markers(fixture)
		local peer_count
		local peer = ctx.timer.new(0.05, function() peer_count = #fixture.appended end)
		peer:start()
		helpers.assert_true(fixture.fire_next())
		helpers.assert_true(#fixture.appended >= 1 and #fixture.appended <= 64)
		helpers.assert_eq(ctx.deferred[#ctx.deferred].delay, 0,
			"a healthy yield uses the existing immediate continuation, not failure backoff")
		helpers.assert_true(fixture.fire_next())
		helpers.assert_true(peer_count >= 1 and peer_count <= 64)
		peer:stop()
		finish_fairness_turns(fixture)
		helpers.assert_true(fixture.log_manager.stop({ process_exit = true }))
	end)

	helpers.it("bounds recurring ingest independently of the queued deferred timer", function()
		local fixture, ctx = load_fairness_fixture()
		queue_fairness_markers(fixture)
		helpers.assert_eq(#ctx.recurring, 1)
		ctx.recurring[1]:fire()
		helpers.assert_true(#fixture.appended >= 1 and #fixture.appended <= 64)
		local peer_count = #fixture.appended -- next independent eligible observer
		helpers.assert_true(peer_count < #FAIRNESS_MARKERS)
		finish_fairness_turns(fixture)
		helpers.assert_true(fixture.log_manager.stop({ process_exit = true }))
	end)

	helpers.it("refuses durable EOF rollover until the whole memory suffix commits", function()
		local fixture = load_fairness_fixture()
		local rotation = package.loaded["modules.keylogger.rotation"]
		local writer = package.loaded["modules.keylogger.sqlite_writer"]
		local aggregator = package.loaded["modules.keylogger.aggregator"]
		local reads, rollovers, db_queries, resets = 0, 0, 0, 0
		rotation.read_new_entries = function() reads = reads + 1; return {}, 0, "eof" end
		rotation.rollover = function() rollovers = rollovers + 1; return true end
		writer.get_db = function() db_queries = db_queries + 1; return nil end
		aggregator.reset_ngram_ctx = function() resets = resets + 1 end
		queue_fairness_markers(fixture)
		helpers.assert_eq(fixture.log_manager.day_rollover(), false)
		helpers.assert_eq(#fixture.appended, 0, "midnight cannot force an unbounded memory flush")
		helpers.assert_eq(reads, 0)
		helpers.assert_eq(rollovers, 0)
		helpers.assert_eq(db_queries, 0)
		helpers.assert_eq(resets, 0)
		helpers.assert_true(fixture.fire_next())
		helpers.assert_eq(fixture.log_manager.day_rollover(), false)
		helpers.assert_eq(reads, 0)
		helpers.assert_eq(rollovers, 0)
		finish_fairness_turns(fixture)
		helpers.assert_eq(fixture.log_manager.day_rollover(), true)
		helpers.assert_eq(rollovers, 1)
		helpers.assert_eq(resets, 1)
		helpers.assert_true(fixture.log_manager.stop({ process_exit = true }))
	end)

	helpers.it("retains a refused prepared head and explicit stop debt before its suffix", function()
		local fixture, ctx = load_fairness_fixture()
		local rotation = package.loaded["modules.keylogger.rotation"]
		local append = rotation.append_log
		local blocked, builds, held = true, 0, nil
		rotation.append_log = function(entry)
			if held == nil then held = entry end
			if blocked then
				helpers.assert_true(rawequal(entry, held))
				return false
			end
			return append(entry)
		end
		helpers.assert_true(fixture.log_manager.defer_entry_builder(function()
			builds = builds + 1
			return { type = "system_event", action = "marker-001" }
		end))
		queue_fairness_markers(fixture, 2)
		helpers.assert_true(fixture.fire_next())
		helpers.assert_eq(#fixture.appended, 0)
		helpers.assert_eq(builds, 1)
		helpers.assert_eq(ctx.deferred[#ctx.deferred].delay, 0.1)
		helpers.assert_eq(fixture.log_manager.stop({ process_exit = true }), false)
		helpers.assert_eq(builds, 1)
		helpers.assert_eq(#fixture.appended, 0)
		local allocated = fixture.deferred_timer_count()
		blocked = false
		helpers.assert_true(fixture.log_manager.stop({ process_exit = true }))
		assert_fairness_order(fixture)
		helpers.assert_true(rawequal(fixture.appended[1], held))
		helpers.assert_eq(builds, 1)
		helpers.assert_eq(fixture.deferred_timer_count(), allocated)
	end)

	helpers.it("keeps explicit public ingest a complete flush with a foreign argument", function()
		local fixture = load_fairness_fixture()
		queue_fairness_markers(fixture)
		fixture.log_manager.ingest_once({})
		assert_fairness_order(fixture)
		helpers.assert_true(fixture.log_manager.stop({ process_exit = true }))
	end)

	helpers.it("keeps explicit stop complete while exact failed timer cleanup stays debt", function()
		local fixture = load_fairness_fixture({
			deferred_activate_then_throw = true, deferred_stop_failures = 2,
		})
		queue_fairness_markers(fixture)
		helpers.assert_eq(fixture.deferred_timer_count(), 1)
		helpers.assert_eq(fixture.log_manager.stop({ process_exit = true }), false)
		assert_fairness_order(fixture)
		helpers.assert_eq(fixture.deferred_timer_count(), 1)
		helpers.assert_true(fixture.log_manager.stop({ process_exit = true }))
		helpers.assert_eq(fixture.deferred_timer_count(), 1)
		assert_fairness_order(fixture)
	end)
end)

-- The original file's cleanup prefix remains whole; these additive controls
-- release the same owned module aliases after their separately scoped runs.
for _, name in ipairs({
	"modules.keylogger.log_manager", "modules.keylogger.rotation",
	"modules.keylogger.sqlite_writer", "modules.keylogger.aggregator",
	"modules.keylogger.export", "keylogger.metrics", "infra.logger",
	"adapters.timer_scheduler",
}) do
	package.loaded[name] = nil
end


-- Additional observation witnesses frozen before production authoring.
helpers.describe("deferred log fairness observation witnesses", function()
	helpers.it("lets a previously eligible peer observe the recurring prefix", function()
		local fixture, ctx = load_fairness_fixture()
		local peer_count
		local peer = ctx.timer.new(0.05, function() peer_count = #fixture.appended end)
		peer:start()
		queue_fairness_markers(fixture)
		ctx.recurring[1]:fire()
		helpers.assert_true(fixture.fire_next())
		helpers.assert_true(peer_count >= 1 and peer_count <= 64,
			"the recurring prefix returns before the independent eligible peer")
		peer:stop()
		finish_fairness_turns(fixture)
		helpers.assert_true(fixture.log_manager.stop({ process_exit = true }))
	end)

	helpers.it("preserves explicit SQL progress after a refused memory head", function()
		local fixture = load_fairness_fixture()
		local rotation = package.loaded["modules.keylogger.rotation"]
		local writer = package.loaded["modules.keylogger.sqlite_writer"]
		local append, blocked, db_queries = rotation.append_log, true, 0
		rotation.append_log = function(entry)
			if blocked then return false end
			return append(entry)
		end
		writer.get_db = function() db_queries = db_queries + 1; return nil end
		queue_fairness_markers(fixture)
		helpers.assert_eq(fixture.log_manager.ingest_once(), nil)
		helpers.assert_eq(db_queries, 1,
			"the original explicit ingest SQL boundary remains reachable on refusal")
		helpers.assert_eq(#fixture.appended, 0)
		blocked = false
		fixture.log_manager.ingest_once()
		assert_fairness_order(fixture)
		helpers.assert_true(fixture.log_manager.stop({ process_exit = true }))
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
