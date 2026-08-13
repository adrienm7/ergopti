--- tests/unit/modules/keylogger/test_synthetic_paste_not_logged_as_shortcut.lua

--- ==============================================================================
--- MODULE: Synthetic Paste Shortcut Provenance Guards
--- DESCRIPTION:
--- Drives the real keylogger handle_key callback. A Cmd+V keyDown carrying a
--- real SyntheticInput tag must never reach shortcut persistence, even after a
--- different eventtap consumer claims the same tag first. An otherwise identical
--- untagged Cmd+V remains a genuine user shortcut and proves the sink is live.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEYCODE_V = 9


--- Loads and starts the production keylogger with I/O boundaries in memory.
--- @return table fixture
local function load_fixture()
	local captured_handle = nil
	local shortcuts = {}
	local context_state = nil
	local log_manager = {
		init = function() return true end,
		ensure_ingest_running = function() return true end,
		defer_flush_buffer = function() return true end,
		flush_buffer = function() end,
		stop = function() return true end,
		log_shortcut = function(value) shortcuts[#shortcuts + 1] = value end,
	}
	package.loaded["modules.keylogger.log_manager"] = log_manager
	package.loaded["modules.keylogger.context_tracker"] = {
		init = function(state) context_state = state; return true end,
		update_private_status = function() end,
		app_watcher_cb = function() end,
		capture_frontmost_app = function()
			context_state.is_secure_field = false
			return true
		end,
	}
	package.loaded["modules.keylogger.kc_bridge"] = {
		init = function() return true end,
		set_log_manager = function() end,
		start = function() return true end,
		stop = function() return true end,
	}
	package.loaded["modules.keylogger.watchers"] = {
		init = function() return true end,
		caffeinate_cb = function() end,
		init_hardware_watchers = function() return true end,
		stop_hardware_watchers = function() return true end,
		check_idle = function() end,
		perform_maintenance = function() end,
	}
	package.loaded["adapters.process_lifecycle"] = {
		onAppActivate = function() end,
		start = function() return true end,
		stop = function() return true end,
	}
	package.loaded["adapters.keyboard_hook"] = {
		start = function(options)
			if options then captured_handle = options.onEvent end
			return true
		end,
		stop = function() return true end,
		isRunning = function() return true end,
	}
	package.loaded["adapters.input_source_broker"] = {
		subscribe = function() return true end,
		unsubscribe = function() return true end,
	}
	package.loaded["modules.keymap"] = { get_shift_side = function() return nil end }
	package.loaded["infra.manifest_reader"] = { default_for = function() return true end }
	package.loaded["infra.config_paths"] = { get_config_dir = function() return "/tmp" end }

	package.loaded["tests.stubs.hs"] = nil
	local base = require("tests.stubs.hs")
	local keycodes = {}
	for key, value in pairs(base.keycodes) do keycodes[key] = value end
	keycodes.map = base.keycodes.map
	keycodes.currentLayout = function() return "ABC" end
	keycodes.inputSourceChanged = function() end
	local application = {
		watcher = base.application.watcher,
		frontmostApplication = function()
			return {
				title = function() return "TestApp" end,
				name = function() return "TestApp" end,
				bundleID = function() return "com.example.Test" end,
				mainWindow = function() return nil end,
			}
		end,
	}
	local caffeinate = {
		watcher = {
			new = function()
				return {
					start = function(self) return self end,
					stop = function(self) return self end,
				}
			end,
		},
	}

	package.loaded["modules.keylogger.init"] = nil
	local keylogger = helpers.load_with_stubs("modules.keylogger.init", {
		keycodes = keycodes,
		application = application,
		caffeinate = caffeinate,
	})
	local live_hs = require("hs")
	local prior_timer_count = #live_hs.timer.__timers
	helpers.assert_eq(keylogger.start({ is_paused = function() return false end }), true,
		"the provenance fixture must start before it drives the real callback")
	local settled = 0
	for index = prior_timer_count + 1, #live_hs.timer.__timers do
		local timer = live_hs.timer.__timers[index]
		if timer.delay == 0 and timer.running then
			timer:fire()
			settled = settled + 1
		end
	end
	helpers.assert_eq(settled, 1,
		"exactly the deferred foreground-context capture must settle before input")
	helpers.assert_not_nil(captured_handle, "KeyboardHook must receive the real handle_key callback")
	return {
		keylogger = keylogger,
		context_state = context_state,
		handle = captured_handle,
		shortcuts = shortcuts,
		synthetic = require("adapters.synthetic_input"),
		provenance = require("adapters.event_provenance"),
		hs = require("hs"),
		cleanup = function()
			for _, name in ipairs({
				"modules.keylogger.init",
				"modules.keylogger.log_manager",
				"modules.keylogger.context_tracker",
				"modules.keylogger.kc_bridge",
				"modules.keylogger.watchers",
				"adapters.process_lifecycle",
				"adapters.keyboard_hook",
				"adapters.event_provenance",
				"adapters.synthetic_input",
				"modules.keymap",
				"infra.manifest_reader",
				"infra.config_paths",
			}) do
				package.loaded[name] = nil
			end
		end,
	}
end


--- Adds the native getters keylogger needs to an adapter-created Cmd+V event.
--- @param fixture table
--- @param event table
--- @return table event
local function decorate_paste_event(fixture, event)
	event.getType = function() return fixture.hs.eventtap.event.types.keyDown end
	event.getKeyCode = function() return KEYCODE_V end
	event.getFlags = function() return { cmd = true } end
	event.getCharacters = function() return "v" end
	return event
end


--- Creates an untagged physical Cmd+V.
--- @param fixture table
--- @return table event
local function physical_paste_event(fixture)
	local properties = fixture.hs.eventtap.event.properties
	return {
		getType = function() return fixture.hs.eventtap.event.types.keyDown end,
		getKeyCode = function() return KEYCODE_V end,
		getFlags = function() return { cmd = true } end,
		getCharacters = function() return "v" end,
		getProperty = function(_self, property)
			if property == properties.eventSourceUserData then return 0 end
			return fixture.hs.processInfo.processID
		end,
	}
end


--- Creates a real tagged replacement Cmd+V keyDown.
--- @param fixture table
--- @return table event
local function owned_paste_event(fixture)
	local tx = fixture.synthetic.begin("test.paste", "replacement")
	local batch = fixture.synthetic.begin_callback(tx)
	fixture.synthetic.keyStroke(batch, { "cmd" }, "v")
	local _, events = fixture.synthetic.finish_callback(batch, true)
	fixture.synthetic.seal(tx)
	return decorate_paste_event(fixture, events[1])
end


helpers.describe("keylogger: tagged paste is never persisted as a shortcut", function()
	helpers.it("keeps the physical Cmd+V shortcut path live", function()
		local fixture = load_fixture()
		helpers.assert_eq(fixture.context_state.is_secure_field, false,
			"the negative control requires a committed non-secure foreground context")
		helpers.assert_eq(fixture.keylogger.may_persist(), true,
			"the negative control must reach an enabled, unpaused persistence sink")
		fixture.handle(physical_paste_event(fixture))
		helpers.assert_eq(#fixture.shortcuts, 1,
			"the negative control must reach real shortcut persistence")
		helpers.assert_eq(fixture.shortcuts[1], "Cmd+V")
		fixture.cleanup()
	end)

	helpers.it("filters a real tag after another eventtap consumer claimed it", function()
		local fixture = load_fixture()
		local event = owned_paste_event(fixture)
		local first_consumer = fixture.provenance.classify(event, "keymap")
		helpers.assert_true(first_consumer and first_consumer.owned)
		fixture.handle(event)
		helpers.assert_eq(#fixture.shortcuts, 0,
			"consumer ordering must not turn an owned paste into a human shortcut")
		local keylogger_claim = fixture.provenance.classify(event, "keylogger")
		helpers.assert_true(keylogger_claim and keylogger_claim.duplicate,
			"the real keylogger callback must have claimed its independent slot")
		fixture.cleanup()
	end)
end)
