--- tests/unit/modules/keylogger/test_action_epoch_consumer.lua

--- ==============================================================================
--- MODULE: Keylogger action-epoch consumer
--- DESCRIPTION:
--- Exercises the real keylogger event callback and its stable SyntheticInput
--- listener with both possible tap orders. The LogManager spy distinguishes the
--- O(1) deferred detach from synchronous flush/append sinks so an eventtap
--- regression cannot pass merely because the final output still looks right.
--- ==============================================================================

local helpers = require("tests.helpers")

local RESET_MODULES = {
	"modules.keylogger", "modules.keylogger.init", "modules.keylogger.log_manager",
	"modules.keylogger.rotation", "modules.keylogger.sqlite_writer",
	"modules.keylogger.aggregator", "modules.keylogger.export",
	"modules.keylogger.timestamp",
	"modules.keylogger.context_tracker", "modules.keylogger.kc_bridge",
	"modules.keylogger.watchers", "adapters.process_lifecycle",
	"adapters.keyboard_hook", "adapters.event_provenance",
	"adapters.synthetic_input", "adapters.input_source_broker",
	"infra.logger", "infra.timings",
	"infra.manifest_reader", "infra.i18n", "infra.dialog_util",
	"keylogger.metrics", "modules.keymap",
}


local function noop() end

local function lifecycle_watcher()
	local watcher = { _running = false }
	function watcher:start()
		self._running = true
		return self
	end
	function watcher:stop()
		self._running = false
		return self
	end
	return watcher
end

local function timer_is_running(timer)
	if type(timer.running) == "function" then return timer:running() end
	return timer.running == true
end

local function api(overrides)
	return setmetatable(overrides or {}, {
		__index = function(t, key)
			local value = noop
			rawset(t, key, value)
			return value
		end,
	})
end

local function context_api()
	local state = nil
	return api({
		init = function(core_state) state = core_state; return true end,
		capture_frontmost_app = function()
			if state then state.is_secure_field = false end
			return true
		end,
	})
end

local function start_and_settle_context(keylogger, script_control)
	local timers = _G.hs.timer.__timers
	local prior_count = #timers
	helpers.assert_eq(keylogger.start(script_control), true,
		"the action-epoch fixture must start before driving its event callback")
	local settled = 0
	for index = prior_count + 1, #timers do
		if timers[index].delay == 0 and timer_is_running(timers[index]) then
			timers[index]:fire()
			settled = settled + 1
		end
	end
	helpers.assert_eq(settled, 1,
		"exactly the deferred foreground-context capture must settle before input")
end


--- Loads the real LogManager behind the real keylogger while every one-shot
--- timer allocation returns nil. Persistence is represented only by Rotation's
--- append sink, so the test observes the production FIFO without touching disk.
--- @return table fixture Integration controls and observations.
local function load_timer_allocation_failure_fixture()
	for _, name in ipairs(RESET_MODULES) do package.loaded[name] = nil end

	local appended = {}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.keylogger.rotation"] = {
		init = noop,
		is_initialized = function() return true end,
		append_log = function(entry)
			appended[#appended + 1] = entry
			return true
		end,
		read_new_entries = function() return {}, 0 end,
		get_offset = function() return 0 end,
		get_date = function() return os.date("%Y-%m-%d") end,
		set_offset = noop,
		rollover = noop,
	}
	package.loaded["modules.keylogger.sqlite_writer"] = {
		init = noop,
		open_db = function() return true end,
		close_db = noop,
		get_db = function() return nil end,
		build_inserts = function() return {} end,
		persist_next_event_id = noop,
	}
	package.loaded["modules.keylogger.aggregator"] = {
		init = noop,
		get_ngram_ctx = function() return {} end,
		set_ngram_ctx = noop,
		reset_ngram_ctx = noop,
	}
	package.loaded["modules.keylogger.export"] = {
		init = noop,
		sync_foreign_data_sql = noop,
		get_native_app_category = function() return "other" end,
		get_device_short_id = function() return "test" end,
		get_sqlite_path = function() return nil end,
		get_db_rev = function() return 0 end,
	}
	package.loaded["keylogger.metrics"] = {
		compute_wpm_from_events = function() return 0 end,
	}

	local now_ns = 1000000000
	local timer_stub = { __timers = {}, fail_one_shot = false }
	local function timer_handle(delay, callback)
		local handle = { delay = delay, callback = callback, _running = false }
		function handle:start()
			self._running = true
			return self
		end
		function handle:stop()
			self._running = false
			return self
		end
		function handle:running() return self._running end
		function handle:fire()
			if self._running and self.callback then self.callback() end
		end
		timer_stub.__timers[#timer_stub.__timers + 1] = handle
		return handle
	end
	timer_stub.absoluteTime = function()
			now_ns = now_ns + 1000000
			return now_ns
		end
	timer_stub.secondsSinceEpoch = function() return os.time() end
	timer_stub.new = timer_handle
	timer_stub.doAfter = function(delay, callback)
		if timer_stub.fail_one_shot then return nil end
		local handle = timer_handle(delay, callback)
		handle:start()
		return handle
	end

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
	local hs_stub = _G.hs
	hs_stub.keycodes.currentLayout = function() return "ABC" end
	hs_stub.caffeinate = {
		watcher = {
			new = lifecycle_watcher,
		},
	}

	local core_state = nil
	local real_init = log_manager.init
	log_manager.init = function(state)
		core_state = state
		return real_init(state)
	end
	package.loaded["modules.keylogger.log_manager"] = log_manager

	local epoch = {}
	local listener = nil
	local synthetic_stub = {
		current_action_epoch = function() return epoch, 250 end,
		claim_physical_fence = function() return nil end,
		register_action_listener = function(id, callback)
			helpers.assert_eq(id, "modules.keylogger.action_epoch")
			listener = callback
			return true
		end,
		unregister_action_listener = function()
			listener = nil
			return true
		end,
	}
	package.loaded["adapters.synthetic_input"] = synthetic_stub
	package.loaded["adapters.event_provenance"] = {
		STATUS_OWNED = "owned",
		STATUS_FOREIGN = "foreign",
		STATUS_UNREADABLE = "unreadable",
		classify_with_fence = function(event)
			if event.provenance then return event.provenance, "owned", nil end
			return nil, "foreign", synthetic_stub.claim_physical_fence()
		end,
	}

	local handle_key = nil
	package.loaded["adapters.keyboard_hook"] = {
		start = function(options)
			if options and options.onEvent then handle_key = options.onEvent end
			return true
		end,
		stop = function() return true end,
		isRunning = function() return true end,
	}
	package.loaded["adapters.process_lifecycle"] = api({
		start = function() return true end,
		stop = function() return true end,
	})
	package.loaded["modules.keylogger.context_tracker"] = context_api()
	package.loaded["modules.keylogger.kc_bridge"] = api({
		init = function() return true end,
		set_log_manager = function() return true end,
		start = function() return true end,
		stop = function() return true end,
	})
	package.loaded["modules.keylogger.watchers"] = api({
		init = function() return true end,
		init_hardware_watchers = function() return true end,
		stop_hardware_watchers = function() return true end,
	})
	package.loaded["adapters.input_source_broker"] = {
		subscribe = function() return true end,
		unsubscribe = function() return true end,
	}
	package.loaded["modules.keymap"] = { get_shift_side = function() return "none" end }
	package.loaded["infra.timings"] = {
		ms = function(_section, key)
			local values = {
				micro_idle_timeout_ms = 30000,
				session_timeout_ms = 300000,
				wpm_window_ms = 15000,
				wpm_min_duration_ms = 2000,
				idle_check_interval_ms = 1000,
				maintenance_interval_ms = 1000,
				auto_flush_idle_ms = 120000,
			}
			return values[key] or 1000
		end,
		sec = function() return 1 end,
	}
	package.loaded["infra.config_paths"] = {
		get_config_dir = function() return "/tmp/ergopti_timer_failure" end,
	}
	package.loaded["infra.manifest_reader"] = { default_for = function() return false end }
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.dialog_util"] = { alert = noop }

	local keylogger = require("modules.keylogger.init")
	start_and_settle_context(keylogger, { is_paused = function() return false end })
	timer_stub.fail_one_shot = true
	core_state.session_start_time = 1

	local function physical_key(char)
		helpers.assert_type(handle_key, "function")
		return handle_key({
			getType = function() return hs_stub.eventtap.event.types.keyDown end,
			getKeyCode = function() return 0 end,
			getFlags = function() return {} end,
			getCharacters = function() return char end,
		})
	end

	return {
		keylogger = keylogger,
		log_manager = log_manager,
		core_state = function() return core_state end,
		appended = appended,
		physical_key = physical_key,
		advance = function() epoch = {} end,
		dispatch = function()
			helpers.assert_type(listener, "function")
			return listener(epoch, 250)
		end,
	}
end


local function load_fixture()
	for _, name in ipairs(RESET_MODULES) do package.loaded[name] = nil end

	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	hs_stub.keycodes.currentLayout = function() return "ABC" end
	hs_stub.caffeinate = {
		watcher = {
			new = lifecycle_watcher,
		},
	}
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local epoch = {}
	local handoff_time_ms = 250
	local pending_fence = nil
	local listener = nil
	local register_calls = 0
	local unregister_calls = 0
	local synthetic_stub = {
		current_action_epoch = function() return epoch, handoff_time_ms end,
		claim_physical_fence = function()
			if pending_fence == nil then return nil end
			local fence = pending_fence
			pending_fence = nil
			epoch = {}
			return fence
		end,
		register_action_listener = function(id, callback)
			helpers.assert_eq(id, "modules.keylogger.action_epoch")
			register_calls = register_calls + 1
			listener = callback
			return true
		end,
		unregister_action_listener = function(id)
			helpers.assert_eq(id, "modules.keylogger.action_epoch")
			unregister_calls = unregister_calls + 1
			listener = nil
			return true
		end,
	}
	package.loaded["adapters.synthetic_input"] = synthetic_stub
	package.loaded["adapters.event_provenance"] = {
		STATUS_OWNED = "owned",
		STATUS_FOREIGN = "foreign",
		STATUS_UNREADABLE = "unreadable",
		classify_with_fence = function(event)
			if event.provenance then return event.provenance, "owned", nil end
			return nil, "foreign", synthetic_stub.claim_physical_fence()
		end,
	}

	local handle_key = nil
	package.loaded["adapters.keyboard_hook"] = {
		start = function(options)
			if options and options.onEvent then handle_key = options.onEvent end
			return true
		end,
		stop = function() return true end,
		isRunning = function() return true end,
	}
	package.loaded["adapters.process_lifecycle"] = api({
		start = function() return true end,
		stop = function() return true end,
	})

	local core_state = nil
	local deferred_calls = 0
	local synchronous_flushes = 0
	local synchronous_appends = 0
	package.loaded["modules.keylogger.log_manager"] = api({
		init = function(state) core_state = state; return true end,
		ensure_ingest_running = function() return true end,
		stop = function() return true end,
		defer_flush_buffer = function()
			deferred_calls = deferred_calls + 1
			return true
		end,
		flush_buffer = function()
			synchronous_flushes = synchronous_flushes + 1
			return true
		end,
		append_log = function() synchronous_appends = synchronous_appends + 1 end,
	})
	package.loaded["modules.keylogger.context_tracker"] = context_api()
	package.loaded["modules.keylogger.kc_bridge"] = api({
		init = function() return true end,
		set_log_manager = function() return true end,
		start = function() return true end,
		stop = function() return true end,
	})
	package.loaded["modules.keylogger.watchers"] = api({
		init = function() return true end,
		init_hardware_watchers = function() return true end,
		stop_hardware_watchers = function() return true end,
	})
	package.loaded["adapters.input_source_broker"] = {
		subscribe = function() return true end,
		unsubscribe = function() return true end,
	}
	package.loaded["modules.keymap"] = { get_shift_side = function() return "none" end }
	package.loaded["infra.logger"] = api({
		pcall = function(_module_name, fn, ...)
			return pcall(fn, ...)
		end,
	})
	package.loaded["infra.timings"] = {
		ms = function(_section, key)
			local values = {
				micro_idle_timeout_ms = 30000,
				session_timeout_ms = 300000,
				wpm_window_ms = 15000,
				wpm_min_duration_ms = 2000,
				idle_check_interval_ms = 1000,
				maintenance_interval_ms = 1000,
				auto_flush_idle_ms = 120000,
			}
			return values[key] or 1000
		end,
		sec = function() return 1 end,
	}
	package.loaded["infra.manifest_reader"] = { default_for = function() return false end }
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.dialog_util"] = { alert = noop }
	package.loaded["keylogger.metrics"] = {
		compute_wpm_from_events = function() return 0 end,
	}

	local keylogger = require("modules.keylogger.init")
	start_and_settle_context(keylogger, { is_paused = function() return false end })

	local function action_event(provenance)
		helpers.assert_type(handle_key, "function")
		return handle_key({
			provenance = provenance,
			getType = function() return hs_stub.eventtap.event.types.keyDown end,
			getKeyCode = function() return 0 end,
			getFlags = function() return {} end,
			getCharacters = function() return "x" end,
		})
	end
	local function tagged_action_event()
		return action_event({ effect = "action", loopback = false })
	end
	local function physical_action_event() return action_event(nil) end

	return {
		keylogger = keylogger,
		core_state = function() return core_state end,
		advance = function() epoch = {} end,
		dispatch = function()
			helpers.assert_type(listener, "function")
			return listener(epoch, handoff_time_ms)
		end,
		set_handoff_time = function(value) handoff_time_ms = value end,
		fail_absolute_clock = function()
			hs_stub.timer.absoluteTime = function() error("monotonic clock unavailable") end
		end,
		tagged_action_event = tagged_action_event,
		physical_action_event = physical_action_event,
		queue_fence = function(events) pending_fence = { events = events } end,
		deferred_calls = function() return deferred_calls end,
		synchronous_flushes = function() return synchronous_flushes end,
		synchronous_appends = function() return synchronous_appends end,
		register_calls = function() return register_calls end,
		unregister_calls = function() return unregister_calls end,
	}
end


helpers.describe("keylogger action epochs", function()
	helpers.it("an action with no following event schedules the prior run for flush", function()
		local fixture = load_fixture()
		fixture.advance()
		fixture.dispatch()
		helpers.assert_eq(fixture.deferred_calls(), 1)
		fixture.keylogger.stop()
	end)

	helpers.it("both tap orders split the prior run exactly once", function()
		local before_publish = load_fixture()
		before_publish.tagged_action_event()
		helpers.assert_eq(before_publish.deferred_calls(), 0)
		before_publish.advance()
		before_publish.dispatch()
		helpers.assert_eq(before_publish.deferred_calls(), 1)
		before_publish.keylogger.stop()

		local after_publish = load_fixture()
		after_publish.advance()
		after_publish.tagged_action_event()
		after_publish.dispatch()
		helpers.assert_eq(after_publish.deferred_calls(), 1,
			"the listener must see the event-backstop acknowledgement and avoid a second split")
		after_publish.keylogger.stop()
	end)

	helpers.it("claims older output before recording the overtaking physical key", function()
		local fixture = load_fixture()
		local older_events = { { key = "older-action" } }
		fixture.queue_fence(older_events)
		local consume, returned_events = fixture.physical_action_event()

		helpers.assert_true(not consume)
		helpers.assert_true(returned_events == older_events,
			"the upstream keylogger tap must return older output before the original")
		helpers.assert_eq(fixture.deferred_calls(), 1,
			"the prior human run must split before the physical key is recorded")
		fixture.keylogger.stop()
	end)

	helpers.it("accepts a queued snapshot when timer allocation fails and logs the next key", function()
		local fixture = load_timer_allocation_failure_fixture()
		fixture.physical_key("a")
		helpers.assert_eq(fixture.core_state().buffer_text, "a")

		fixture.advance()
		fixture.dispatch()
		helpers.assert_eq(fixture.core_state().buffer_text, "",
			"the accepted snapshot must detach the pre-action run")

		fixture.physical_key("b")
		helpers.assert_eq(fixture.core_state().buffer_text, "b",
			"a timer-allocation failure must not poison later physical logging")
		helpers.assert_true(fixture.log_manager.flush_buffer(),
			"the post-action run must join the retained FIFO as accepted work")
		fixture.log_manager.ingest_once()

		helpers.assert_eq(#fixture.appended, 2)
		helpers.assert_eq(fixture.appended[1].text, "a",
			"the detached pre-action snapshot must remain the FIFO head")
		helpers.assert_eq(fixture.appended[2].text, "b",
			"the next physical key must persist behind the retained snapshot")
		fixture.keylogger.stop()
	end)

	helpers.it("the eventtap epoch branch never reaches synchronous LogManager sinks", function()
		local fixture = load_fixture()
		fixture.advance()
		fixture.tagged_action_event()
		helpers.assert_eq(fixture.deferred_calls(), 1)
		helpers.assert_eq(fixture.synchronous_flushes(), 0)
		helpers.assert_eq(fixture.synchronous_appends(), 0)
		fixture.keylogger.stop()
	end)

	helpers.it("acks a clockless handoff without poisoning later key events", function()
		local fixture = load_fixture()
		fixture.set_handoff_time(nil)
		fixture.fail_absolute_clock()
		fixture.advance()
		fixture.dispatch()
		fixture.dispatch()
		fixture.tagged_action_event()
		helpers.assert_eq(fixture.deferred_calls(), 1,
			"one action epoch must detach the human run exactly once")
		fixture.keylogger.stop()
	end)

	helpers.it("start and stop register the stable listener exactly once", function()
		local fixture = load_fixture()
		fixture.keylogger.start({ is_paused = function() return false end })
		helpers.assert_eq(fixture.register_calls(), 1)
		fixture.keylogger.stop()
		fixture.keylogger.stop()
		helpers.assert_eq(fixture.unregister_calls(), 1)
	end)
end)

for _, name in ipairs(RESET_MODULES) do package.loaded[name] = nil end
