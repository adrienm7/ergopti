--- tests/unit/modules/keylogger/test_eventtap_persistence_deferred.lua

--- ==============================================================================
--- MODULE: Eventtap-safe keylogger persistence
--- DESCRIPTION:
--- Drives the real keylogger callback and real LogManager outbox while native
--- persistence boundaries remain observable in memory. It proves every tap-facing
--- branch returns before synthetic expansion, WPM conversion, JSONL append, file
--- write, or foreground-application lookup, then verifies strict FIFO delivery.
---
--- ROOT CAUSE ENCODED:
--- LogManager.append_log() used to drain an empty FIFO synchronously and
--- flush_buffer() converted its detached snapshot before returning. Modifier and
--- shortcut branches also queried the native application object in the callback.
--- A successful disk write raised no warning, so the tap could exceed its native
--- timeout without any Lua failure or file-log evidence.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEYCODE_A = 0
local KEYCODE_ENTER = 36
local KEYCODE_TAB = 48
local KEYCODE_M = 46
local KEYCODE_P = 35
local KEYCODE_V = 9
local KEYCODE_SPACE = 49
local KEYCODE_BACKSPACE = 51
local KEYCODE_ESCAPE = 53
local KEYCODE_CAPS_LOCK = 57
local KEYCODE_F1 = 122
local KEYCODE_LEFT = 123
local KEYCODE_LEFT_COMMAND = 55
local BUFFER_EVENT_CAP = 1024

local RESET_MODULES = {
	"adapters.event_provenance", "adapters.file_system",
	"adapters.input_source_broker", "adapters.keyboard_hook",
	"adapters.process_lifecycle", "adapters.synthetic_input",
	"adapters.timer_scheduler", "hs", "hs.fs", "hs.json", "hs.sqlite3",
	"hs.timer", "infra.config_paths", "infra.dialog_util", "infra.i18n",
	"infra.logger", "infra.manifest_reader", "infra.timings",
	"keylogger.metrics", "modules.keylogger", "modules.keylogger.aggregator",
	"modules.keylogger.context_tracker", "modules.keylogger.export",
	"modules.keylogger.init", "modules.keylogger.kc_bridge",
	"modules.keylogger.log_manager", "modules.keylogger.rotation",
	"modules.keylogger.sqlite_writer", "modules.keylogger.timestamp",
	"modules.keylogger.watchers", "modules.keymap", "tests.stubs.hs",
}


--- Creates a native-shaped lifecycle handle.
--- @return table watcher
local function lifecycle_handle()
	local handle = { _running = false }
	function handle:start()
		self._running = true
		return self
	end
	function handle:stop()
		self._running = false
		return self
	end
	function handle:running()
		return self._running
	end
	return handle
end


--- Captures every package/global slot replaced by one fixture.
--- @return function restore
local function capture_runtime()
	local saved_hs = _G.hs
	local saved_packages = {}
	for _, name in ipairs(RESET_MODULES) do saved_packages[name] = package.loaded[name] end
	return function()
		_G.hs = saved_hs
		for _, name in ipairs(RESET_MODULES) do
			package.loaded[name] = saved_packages[name]
		end
	end
end


--- Loads the real keylogger and LogManager against observable native boundaries.
--- @param options table|nil Fixture options.
--- @return table fixture
local function load_fixture(options)
	options = options or {}
	local restore_runtime = capture_runtime()
	for _, name in ipairs(RESET_MODULES) do package.loaded[name] = nil end

	local callback_active = false
	local handle_key = nil
	local core_state = nil
	local paused = false
	local sink_failures = options.sink_failures or 0
	local counters = {
		rotation = 0,
		json = 0,
		write = 0,
		wpm = 0,
		frontmost = 0,
		synthetic_chars = 0,
		inside_rotation = 0,
		inside_json = 0,
		inside_write = 0,
		inside_wpm = 0,
		inside_frontmost = 0,
		inside_synthetic_chars = 0,
	}
	local appended = {}

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.keylogger.rotation"] = {
		init = function() return true end,
		is_initialized = function() return true end,
		append_log = function(entry)
			counters.rotation = counters.rotation + 1
			counters.json = counters.json + 1
			counters.write = counters.write + 1
			if callback_active then
				counters.inside_rotation = counters.inside_rotation + 1
				counters.inside_json = counters.inside_json + 1
				counters.inside_write = counters.inside_write + 1
			end
			if sink_failures > 0 then
				sink_failures = sink_failures - 1
				return false
			end
			appended[#appended + 1] = entry
			return true
		end,
		read_new_entries = function() return {}, 0, "eof" end,
		get_offset = function() return 0 end,
		get_date = function() return "2026-08-20" end,
		set_offset = function() end,
		rollover = function() return true end,
	}
	package.loaded["modules.keylogger.sqlite_writer"] = {
		init = function() return true end,
		open_db = function() return true end,
		close_db = function() return true end,
		get_db = function() return nil end,
		build_inserts = function() return {} end,
		get_next_event_id = function() return 0 end,
		set_next_event_id = function() end,
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
		sync_foreign_data_sql = function() return {} end,
		get_native_app_category = function() return "other" end,
		get_device_short_id = function() return "test" end,
		get_sqlite_path = function() return nil end,
		get_db_rev = function() return 0 end,
	}
	package.loaded["keylogger.metrics"] = {
		compute_wpm_from_events = function()
			counters.wpm = counters.wpm + 1
			if callback_active then counters.inside_wpm = counters.inside_wpm + 1 end
			return 0
		end,
	}

	package.loaded["modules.keylogger.context_tracker"] = {
		init = function(state)
			core_state = state
			return true
		end,
		capture_frontmost_app = function()
			core_state.active_app_name = "Cached Editor"
			core_state.active_win_title = "Cached Document"
			core_state.is_secure_field = false
			return true
		end,
		app_watcher_cb = function() end,
		update_private_status = function() end,
		update_ax_observer = function() end,
	}
	package.loaded["modules.keylogger.kc_bridge"] = {
		init = function() return true end,
		set_log_manager = function() return true end,
		start = function() return true end,
		stop = function() return true end,
		is_running = function() return true end,
		is_ke_managed_output_kc = function() return false end,
	}
	package.loaded["modules.keylogger.watchers"] = {
		init = function() return true end,
		init_hardware_watchers = function() return true end,
		stop_hardware_watchers = function() return true end,
		is_running = function() return true end,
		check_idle = function() end,
		perform_maintenance = function() end,
		caffeinate_cb = function() end,
	}
	package.loaded["adapters.process_lifecycle"] = {
		onAppActivate = function() return true end,
		start = function() return true end,
		stop = function() return true end,
	}
	package.loaded["adapters.keyboard_hook"] = {
		start = function(config)
			handle_key = config and config.onEvent
			return type(handle_key) == "function"
		end,
		stop = function() return true end,
		isRunning = function() return true end,
	}
	package.loaded["adapters.input_source_broker"] = {
		subscribe = function() return true end,
		unsubscribe = function() return true end,
	}
	package.loaded["adapters.synthetic_input"] = {
		STATUS_FOREIGN = "foreign",
		current_action_epoch = function() return "epoch-1", 0 end,
		claim_physical_fence = function() return nil end,
		register_action_listener = function() return true end,
		unregister_action_listener = function() return true end,
	}
	package.loaded["adapters.event_provenance"] = {
		STATUS_OWNED = "owned",
		STATUS_FOREIGN = "foreign",
		STATUS_UNREADABLE = "unreadable",
		classify_with_fence = function() return nil, "foreign", nil end,
	}
	package.loaded["modules.keymap"] = { get_shift_side = function() return "none" end }
	package.loaded["infra.manifest_reader"] = { default_for = function() return true end }
	package.loaded["infra.config_paths"] = {
		get_config_dir = function() return "/tmp/ergopti_eventtap_deferred" end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.dialog_util"] = { alert = function() end }
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
				max_keystroke_delay_ms = 5000,
			}
			return values[key] or 1000
		end,
		sec = function() return 1 end,
	}

	local timers = {}
	local now_ns = 1000000000
	local function new_timer(delay, callback)
		local timer = lifecycle_handle()
		timer.delay = delay
		timer.callback = callback
		function timer:fire()
			if not self._running then return false end
			self.callback()
			return true
		end
		timers[#timers + 1] = timer
		return timer
	end
	local timer_stub = {
		new = new_timer,
		doAfter = function(delay, callback) return new_timer(delay, callback):start() end,
		doEvery = function(delay, callback) return new_timer(delay, callback):start() end,
		absoluteTime = function()
			now_ns = now_ns + 1000000
			return now_ns
		end,
		secondsSinceEpoch = function() return 1 end,
		delayed = {
			new = function(_delay, callback)
				local timer = lifecycle_handle()
				timer.callback = callback
				return timer
			end,
		},
	}
	local hs_overrides = {
		timer = timer_stub,
		application = {
			watcher = { activated = 1 },
			frontmostApplication = function()
				counters.frontmost = counters.frontmost + 1
				if callback_active then
					counters.inside_frontmost = counters.inside_frontmost + 1
				end
				return { title = function() return "Native Editor" end }
			end,
		},
		caffeinate = { watcher = { new = lifecycle_handle } },
		keycodes = { currentLayout = function() return "ABC" end, map = {} },
		fs = {
			attributes = function() return {} end,
			dir = function() return function() return nil end end,
		},
		execute = function() return "" end,
	}
	package.loaded["adapters.file_system"] = {
		write = function() return true end,
		create_if_absent = function() return true, "created" end,
		read = function() return nil end,
		read_with_status = function() return nil, "absent" end,
	}

	local keylogger = helpers.load_with_stubs("modules.keylogger.init", hs_overrides)
	local script_control = { is_paused = function() return paused end }
	local timers_before_start = #timers
	helpers.assert_true(keylogger.start(script_control),
		"the eventtap persistence fixture must start every required owner")
	for index = timers_before_start + 1, #timers do
		local timer = timers[index]
		if timer.delay == 0 and timer:running() then timer:fire() end
	end
	helpers.assert_type(handle_key, "function")
	helpers.assert_not_nil(core_state)
	helpers.assert_eq(core_state.is_secure_field, false,
		"the foreground bootstrap must publish a loggable cached context")

	local original_recorded_char = keylogger.recorded_char
	keylogger.recorded_char = function(...)
		counters.synthetic_chars = counters.synthetic_chars + 1
		if callback_active then
			counters.inside_synthetic_chars = counters.inside_synthetic_chars + 1
		end
		return original_recorded_char(...)
	end

	local fixture = {
		keylogger = keylogger,
		state = core_state,
		counters = counters,
		appended = appended,
		hs = require("hs"),
		set_paused = function(value) paused = value end,
	}
	function fixture.dispatch(event)
		callback_active = true
		local ok, consume, returned = xpcall(handle_key, debug.traceback, event)
		callback_active = false
		if not ok then error(consume, 0) end
		return consume, returned
	end
	function fixture.from_tap(callback)
		callback_active = true
		local ok, result_or_err = xpcall(callback, debug.traceback)
		callback_active = false
		if not ok then error(result_or_err, 0) end
		return result_or_err
	end
	function fixture.fire_next_deferred()
		for _, timer in ipairs(timers) do
			if timer:running() and timer.delay <= 0.1 then return timer:fire() end
		end
		return false
	end
	function fixture.cleanup()
		pcall(keylogger.stop)
		restore_runtime()
	end
	return fixture
end


--- Runs one fixture with exact runtime restoration after assertion failures.
--- @param options table|nil Fixture options.
--- @param body function Assertion body.
local function with_fixture(options, body)
	local fixture = load_fixture(options)
	local ok, err = xpcall(body, debug.traceback, fixture)
	fixture.cleanup()
	if not ok then error(err, 0) end
end


--- Builds one minimal physical event for the real callback.
--- @param fixture table Active fixture.
--- @param event_type number Native event type.
--- @param keycode number Key code.
--- @param chars string|nil Composed characters.
--- @param flags table|nil Modifier flags.
--- @return table event
local function physical_event(fixture, event_type, keycode, chars, flags)
	return {
		getType = function() return event_type end,
		getKeyCode = function() return keycode end,
		getCharacters = function() return chars or "" end,
		getFlags = function() return flags or {} end,
		getProperty = function() return 0 end,
	}
end


--- Returns all entries whose type matches the requested value.
--- @param entries table Persisted entries.
--- @param event_type string Event type.
--- @return table matches
local function entries_of_type(entries, event_type)
	local matches = {}
	for _, entry in ipairs(entries) do
		if entry.type == event_type then matches[#matches + 1] = entry end
	end
	return matches
end


helpers.describe("keylogger persistence stays outside eventtaps", function()
	helpers.it("detaches a stuck-key run at the bounded event watermark", function()
		with_fixture({}, function(fixture)
			local types = fixture.hs.eventtap.event.types
			for _ = 1, BUFFER_EVENT_CAP * 2 + 1 do
				fixture.dispatch(physical_event(fixture, types.keyDown, KEYCODE_A, "a"))
			end

			helpers.assert_eq(#fixture.state.buffer_events, 1,
				"two full runs must detach instead of growing the live event table")
			helpers.assert_eq(#fixture.state.rich_chunks, 1,
				"rich chunks must detach at the same watermark as raw events")
			helpers.assert_eq(fixture.counters.rotation, 0,
				"watermark detachment must remain O(1) inside the eventtap")

			helpers.assert_true(fixture.fire_next_deferred(),
				"each detached run must be owned by the deferred persistence queue")
			local typing = entries_of_type(fixture.appended, "typing")
			helpers.assert_eq(#typing, 2)
			for index, entry in ipairs(typing) do
				helpers.assert_eq(#entry.events, BUFFER_EVENT_CAP,
					"detached typing row " .. index .. " must stop at the event cap")
				helpers.assert_eq(#entry.text, BUFFER_EVENT_CAP)
				helpers.assert_eq(#entry.rich_text, BUFFER_EVENT_CAP)
			end
		end)
	end)

	helpers.it("applies the watermark to non-text and composed event siblings", function()
		for _, case in ipairs({
			{ label = "backspace", keycode = KEYCODE_BACKSPACE, chars = "\127", marker = "[BS]" },
			{ label = "caps lock", keycode = KEYCODE_CAPS_LOCK, chars = "", marker = "[CAPS]" },
		}) do
			with_fixture({}, function(fixture)
				local types = fixture.hs.eventtap.event.types
				for _ = 1, BUFFER_EVENT_CAP + 1 do
					fixture.dispatch(physical_event(
						fixture, types.keyDown, case.keycode, case.chars))
				end
				helpers.assert_eq(#fixture.state.buffer_events, 1,
					case.label .. " repeats must detach at the shared watermark")
				helpers.assert_true(fixture.fire_next_deferred())
				local typing = entries_of_type(fixture.appended, "typing")
				helpers.assert_eq(#typing, 1)
				helpers.assert_eq(#typing[1].events, BUFFER_EVENT_CAP)
				helpers.assert_eq(typing[1].events[1][1], case.marker)
			end)
		end

		with_fixture({}, function(fixture)
			local types = fixture.hs.eventtap.event.types
			for _ = 1, BUFFER_EVENT_CAP - 1 do
				fixture.dispatch(physical_event(fixture, types.keyDown, KEYCODE_A, "a"))
			end
			fixture.dispatch(physical_event(fixture, types.keyDown, KEYCODE_A, "éb"))
			helpers.assert_eq(#fixture.state.buffer_events, 1,
				"a multi-codepoint key must detach at the exact per-event boundary")
			helpers.assert_eq(fixture.state.buffer_events[1][1], "b")
			helpers.assert_true(fixture.fire_next_deferred())
			local typing = entries_of_type(fixture.appended, "typing")
			helpers.assert_eq(#typing, 1)
			helpers.assert_eq(#typing[1].events, BUFFER_EVENT_CAP)
			helpers.assert_eq(typing[1].events[BUFFER_EVENT_CAP][1], "é")
		end)
	end)

	helpers.it("preserves the next delay across every keystroke flush boundary", function()
		for _, boundary in ipairs({
			{ label = "space", keycode = KEYCODE_SPACE, chars = " " },
			{ label = "punctuation", keycode = KEYCODE_A, chars = "." },
			{ label = "tab", keycode = KEYCODE_TAB, chars = "\t" },
			{ label = "escape", keycode = KEYCODE_ESCAPE, chars = "\27" },
			{ label = "enter", keycode = KEYCODE_ENTER, chars = "\n" },
			{ label = "function key", keycode = KEYCODE_F1, chars = "" },
			{ label = "navigation", keycode = KEYCODE_LEFT, chars = "" },
		}) do
			with_fixture({}, function(fixture)
				local types = fixture.hs.eventtap.event.types
				fixture.dispatch(physical_event(fixture, types.keyDown, KEYCODE_A, "a"))
				fixture.dispatch(physical_event(
					fixture, types.keyDown, boundary.keycode, boundary.chars))
				fixture.dispatch(physical_event(fixture, types.keyDown, KEYCODE_A, "a"))
				fixture.dispatch(physical_event(fixture, types.keyDown, KEYCODE_SPACE, " "))
				helpers.assert_true(fixture.fire_next_deferred())

				local typing = entries_of_type(fixture.appended, "typing")
				helpers.assert_eq(#typing, 2, boundary.label .. " must split two typing rows")
				helpers.assert_eq(typing[2].events[1][1], "a")
				helpers.assert_true(typing[2].events[1][2] > 0,
					boundary.label .. " must re-seed the next inter-key delay")
			end)
		end
	end)

	helpers.it("defers every physical and acceptance branch in exact FIFO order", function()
		with_fixture({}, function(fixture)
			local types = fixture.hs.eventtap.event.types
			fixture.dispatch(physical_event(fixture, types.keyDown, KEYCODE_A, "a"))
			fixture.dispatch(physical_event(fixture, types.keyDown, KEYCODE_SPACE, " "))
			fixture.dispatch(physical_event(fixture, types.keyDown, KEYCODE_A, "."))
			fixture.dispatch(physical_event(fixture, types.keyDown, KEYCODE_LEFT, ""))
			fixture.dispatch(physical_event(
				fixture, types.flagsChanged, KEYCODE_LEFT_COMMAND, "", { cmd = true }))
			fixture.dispatch(physical_event(
				fixture, types.flagsChanged, KEYCODE_LEFT_COMMAND, "", {}))
			fixture.dispatch(physical_event(
				fixture, types.keyDown, KEYCODE_V, "v", { cmd = true }))
			fixture.dispatch(physical_event(fixture, types.keyDown, KEYCODE_M, "m"))
			fixture.dispatch(physical_event(fixture, types.leftMouseDown, 0, ""))
			fixture.dispatch(physical_event(fixture, types.scrollWheel, 0, ""))
			fixture.dispatch(physical_event(fixture, types.keyDown, KEYCODE_P, "p"))
			fixture.set_paused(true)
			fixture.dispatch(physical_event(fixture, types.keyDown, KEYCODE_A, "x"))
			fixture.set_paused(false)

			fixture.from_tap(function()
				fixture.keylogger.notify_synthetic("é", "hotstring", 1, "case", "é", false)
				fixture.keylogger.log_hotstring("teh", "the", "autocorrect")
				fixture.keylogger.notify_synthetic("go", "llm", 0, "remote", "go", false)
				fixture.keylogger.log_llm_accepted(
					"go", nil, { "go", "gone" }, 1, 0, "")
			end)

			helpers.assert_eq(fixture.counters.rotation, 0)
			helpers.assert_eq(fixture.counters.json, 0)
			helpers.assert_eq(fixture.counters.write, 0)
			helpers.assert_eq(fixture.counters.wpm, 0)
			helpers.assert_eq(fixture.counters.frontmost, 0)
			helpers.assert_eq(fixture.counters.synthetic_chars, 0,
				"per-codepoint synthetic expansion must wait for the retained drain")
			for _, name in ipairs({
				"inside_rotation", "inside_json", "inside_write", "inside_wpm",
				"inside_frontmost", "inside_synthetic_chars",
			}) do
				helpers.assert_eq(fixture.counters[name], 0,
					name .. " must remain zero before every eventtap returns")
			end

			helpers.assert_true(fixture.fire_next_deferred(),
				"accepted keylogger work must own a deferred drain")
			helpers.assert_true(#fixture.appended > 0)
			helpers.assert_true(fixture.counters.wpm > 0)
			helpers.assert_eq(fixture.counters.rotation, #fixture.appended)
			helpers.assert_eq(fixture.counters.json, #fixture.appended)
			helpers.assert_eq(fixture.counters.write, #fixture.appended)
			helpers.assert_eq(fixture.counters.synthetic_chars, 4,
				"one backspace and three inserted codepoints must be prepared once")

			local shortcuts = entries_of_type(fixture.appended, "shortcut")
			helpers.assert_eq(#shortcuts, 1)
			helpers.assert_eq(shortcuts[1].app, "Cached Editor")
			local modifiers = entries_of_type(fixture.appended, "system_event")
			helpers.assert_eq(modifiers[1].action, "modifier_press")
			helpers.assert_eq(modifiers[1].app, "Cached Editor")
			helpers.assert_eq(modifiers[2].action, "modifier_hold")
			helpers.assert_eq(modifiers[2].app, "Cached Editor")

			local hotstrings = entries_of_type(fixture.appended, "hotstring")
			local accepted = entries_of_type(fixture.appended, "llm_accepted")
			helpers.assert_eq(#hotstrings, 1)
			helpers.assert_eq(hotstrings[1].replacement, "the")
			helpers.assert_eq(#accepted, 1)
			helpers.assert_eq(accepted[1].prediction, "go")
			helpers.assert_true(
				entries_of_type(fixture.appended, "typing")[1].text:find("a ", 1, true) ~= nil,
				"the first physical run must stay ahead of every later action")
		end)
	end)

	helpers.it("prepares synthetic WPM once when the sink refuses and retries", function()
		with_fixture({ sink_failures = 1 }, function(fixture)
			fixture.state.recent_typing_eff = { 100, 200 }
			fixture.from_tap(function()
				fixture.keylogger.notify_synthetic("éx", "llm", 1, "remote", "éx", false)
				fixture.keylogger.log_llm_accepted("éx", nil, { "éx" }, 1, 1, "a")
			end)
			helpers.assert_eq(#fixture.state.recent_typing_eff, 2,
				"WPM mutation must not run in the originating eventtap")

			helpers.assert_true(fixture.fire_next_deferred())
			helpers.assert_eq(#fixture.appended, 0,
				"the refused FIFO head must remain unpublished")
			helpers.assert_eq(#fixture.state.recent_typing_eff, 3)
			helpers.assert_eq(fixture.counters.synthetic_chars, 3)

			helpers.assert_true(fixture.fire_next_deferred())
			helpers.assert_eq(#fixture.state.recent_typing_eff, 3,
				"retry must not replay synthetic WPM mutations")
			helpers.assert_eq(fixture.counters.synthetic_chars, 3,
				"retry must reuse the prepared synthetic record")
			helpers.assert_eq(#entries_of_type(fixture.appended, "typing"), 1)
			helpers.assert_eq(#entries_of_type(fixture.appended, "llm_accepted"), 1)
		end)
	end)
end)
