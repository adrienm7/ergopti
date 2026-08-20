--- tests/unit/modules/shortcuts/test_script_control_start_transaction.lua

--- ==============================================================================
--- MODULE: Script-Control Start Transaction Regression Tests
--- DESCRIPTION:
--- Models native eventtap and recurring-watchdog mutations that fail after the
--- resource has become active, then verifies retryable exact ownership and
--- stale-callback fencing through the public start/stop lifecycle.
---
--- ROOT CAUSE ENCODED:
--- The previous start path swallowed eventtap start errors and acquired the
--- watchdog with a start-before-return shorthand. Either failure could leave a
--- live native producer with no retained handle, while start still logged
--- success. Teardown likewise erased handles even when stop raised.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Installs the non-native dependencies used by script control.
local function install_dependency_stubs()
	package.loaded["infra.notifications"] = { notify = function() end }
	package.loaded["infra.keycodes"] = {
		F13_KARABINER_RETURN = 0x6A,
		F14_KARABINER_BACKSPACE = 0x6B,
		F15_KARABINER_ESCAPE = 0x6C,
		BACKSPACE = 0x33,
		RETURN = 0x24,
		ESCAPE = 0x35,
	}
	package.loaded["modules.gestures.engine"] = { init = function() end }
	package.loaded["modules.gestures.actions"] = {
		SG_NAMES = { "none", "script_pause_toggle" },
		get_label = function(name) return name end,
		execute_single = function() return true end,
	}
	package.loaded["adapters.event_provenance"] = {
		STATUS_UNREADABLE = "unreadable",
		classify_with_fence = function() return nil, "hardware", nil end,
	}
	package.loaded["adapters.synthetic_input"] = {
		defer_after_callback = function(_, callback)
			callback()
			return true
		end,
	}
	package.loaded["adapters.key_state"] = {
		is_right_altgr_held = function() return false end,
		describe_held_modifiers = function() return "none" end,
	}
end


--- Loads a fresh script-control module against exact native doubles.
--- @param scheduler table TimerScheduler test double.
--- @param tap_factory function Eventtap constructor.
--- @return table Script-control module.
local function fresh_script_control(scheduler, tap_factory)
	install_dependency_stubs()
	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["modules.shortcuts.script_control"] = nil
	return helpers.load_with_stubs("modules.shortcuts.script_control", {
		eventtap = {
			new = tap_factory,
			checkKeyboardModifiers = function() return { _raw = 0 } end,
			event = {
				types = { keyDown = 10 },
				properties = {
					eventSourceUserData = 1,
					eventSourceUnixProcessID = 2,
					eventSourceStateID = 3,
				},
				rawFlagMasks = {},
			},
		},
	})
end


--- Creates a scheduler whose watchdog can partially start and refuse cleanup.
--- @param options table Failure controls.
--- @return table scheduler
--- @return table state
local function scheduler_spy(options)
	local state = { every_calls = 0, cancel_calls = 0, handles = {} }
	local scheduler = {}

	function scheduler.every(_, callback)
		state.every_calls = state.every_calls + 1
		local handle = {
			callback = callback,
			fired = false,
			stop_allowed = options.stop_allowed ~= false,
		}
		state.handles[#state.handles + 1] = handle
		return handle, options.partial_every ~= true
	end

	function scheduler.cancel(handle)
		state.cancel_calls = state.cancel_calls + 1
		if handle.stop_allowed ~= true then return false end
		handle.fired = true
		return true
	end

	return scheduler, state
end


helpers.describe("script control: eventtap and watchdog acquisition is transactional", function()
	helpers.it("a duplicate start reuses the one fully committed native pair", function()
		local scheduler, state = scheduler_spy({})
		local create_calls = 0
		local tap = { enabled = false }
		function tap:start() self.enabled = true; return self end
		function tap:isEnabled() return self.enabled end
		function tap:stop() self.enabled = false; return self end
		local script_control = fresh_script_control(scheduler, function()
			create_calls = create_calls + 1
			return tap
		end)

		helpers.assert_true(script_control.start({}, {}, {}, nil))
		helpers.assert_true(script_control.start({}, {}, {}, nil))
		helpers.assert_eq(create_calls, 1,
			"duplicate start must not allocate a sibling eventtap")
		helpers.assert_eq(state.every_calls, 1,
			"duplicate start must not allocate a sibling watchdog")
		helpers.assert_true(script_control.stop())
	end)

	helpers.it("retains a tap that starts then throws until exact stop succeeds", function()
		local scheduler = scheduler_spy({})
		local create_calls = 0
		local tap = { enabled = false, stop_allowed = false }
		function tap:start()
			self.enabled = true
			error("native start failed after enabling")
		end
		function tap:isEnabled() return self.enabled end
		function tap:stop()
			if not self.stop_allowed then return false end
			self.enabled = false
			return self
		end
		local script_control = fresh_script_control(scheduler, function()
			create_calls = create_calls + 1
			return tap
		end)

		helpers.assert_eq(script_control.start({}, {}, {}, nil), false,
			"eventtap startup failure must be returned, not swallowed")
		helpers.assert_eq(create_calls, 1)
		helpers.assert_true(tap.enabled,
			"the test must model an active native resource after the thrown start")
		helpers.assert_eq(script_control.start({}, {}, {}, nil), false,
			"a successor must be refused while exact tap cleanup is pending")
		helpers.assert_eq(create_calls, 1,
			"cleanup debt must block allocation of a replacement eventtap")

		tap.stop_allowed = true
		helpers.assert_eq(script_control.stop(), true,
			"stop must retry the retained exact tap")
		helpers.assert_true(not tap.enabled)
	end)

	helpers.it("retains and fences a partially acquired watchdog", function()
		local scheduler, state = scheduler_spy({
			partial_every = true,
			stop_allowed = false,
		})
		local create_calls = 0
		local tap = { enabled = false, starts = 0 }
		function tap:start()
			self.starts = self.starts + 1
			self.enabled = true
			return self
		end
		function tap:isEnabled() return self.enabled end
		function tap:stop()
			self.enabled = false
			return self
		end
		local script_control = fresh_script_control(scheduler, function()
			create_calls = create_calls + 1
			return tap
		end)

		helpers.assert_eq(script_control.start({}, {}, {}, nil), false,
			"a partially acquired watchdog must roll back eventtap startup")
		helpers.assert_eq(state.every_calls, 1)
		local orphan = state.handles[1]
		local starts_before = tap.starts
		orphan.callback()
		helpers.assert_eq(tap.starts, starts_before,
			"a partial-start watchdog callback must be inert after rollback")

		helpers.assert_eq(script_control.start({}, {}, {}, nil), false,
			"watchdog cleanup debt must refuse a replacement tap")
		helpers.assert_eq(create_calls, 1)
		helpers.assert_eq(state.every_calls, 1)

		orphan.stop_allowed = true
		helpers.assert_eq(script_control.stop(), true,
			"stop must retry the retained exact watchdog handle")
	end)

end)
