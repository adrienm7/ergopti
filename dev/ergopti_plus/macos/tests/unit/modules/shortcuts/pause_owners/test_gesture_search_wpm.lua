--- tests/unit/modules/shortcuts/pause_owners/test_gesture_search_wpm.lua

--- ==============================================================================
--- MODULE: Pause Owner gesture search wpm Regressions
--- DESCRIPTION:
--- Preserves the behavioral pause-owner regression scenarios with a focused
--- fixture boundary. Shared fixtures create fresh runtime state per invocation.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixtures = require("tests.unit.modules.shortcuts.pause_owners.fixtures")
local reset_module = fixtures.reset_module
local load_inventory_context = fixtures.load_inventory_context

local function load_real_wpm_surface(module_name)
	reset_module("tests.stubs.hs")
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	local cancel_mode = "true"
	local handles = {}
	local cancellations = {}
	package.loaded["adapters.timer_scheduler"] = {
		every = function(_, callback)
			local handle = { callback = callback }
			handles[#handles + 1] = handle
			return handle, true
		end,
		cancel = function(handle)
			cancellations[#cancellations + 1] = handle
			if cancel_mode == "false" then return false end
			if cancel_mode == "nil" then return nil end
			if cancel_mode == "throw" then error("WPM timer cancellation exploded") end
			return true
		end,
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.keylogger"] = {
		get_live_stats = function() return { wpm = 0 } end,
	}
	package.loaded["ui.wpm.shared"] = {
		get_active_source = function() return "none" end,
		get_source_color = function() return nil end,
		format_mpm_label = function(value) return tostring(value) end,
	}
	package.loaded["infra.paths"] = { shared = function() return nil end }
	package.loaded["adapters.graphics_renderer"] = {}
	package.loaded["ui.tooltip"] = { is_visible = function() return false end }
	reset_module(module_name)
	local surface = require(module_name)
	return surface, {
		handles = handles,
		cancellations = cancellations,
		set_cancel_mode = function(value) cancel_mode = value end,
	}
end

helpers.describe("HS-012 real WPM pause-restoration debt", function()
	for _, module_name in ipairs({
		"ui.wpm.wpm_menubar",
		"ui.wpm.wpm_widget",
	}) do
		helpers.it(module_name .. " survives stop-refusal, rollback-refusal, retry, resume", function()
			local surface, ctx = load_real_wpm_surface(module_name)
			helpers.assert_true(surface.start(false))
			helpers.assert_eq(#ctx.handles, 1,
				"positive control must own one real recurring WPM capability")

			ctx.set_cancel_mode("false")
			helpers.assert_eq(surface.stop(), false)
			helpers.assert_eq(surface.resume_after_pause(), false,
				"the simulated pause rollback must retain the exact timer debt")
			helpers.assert_true(surface.is_running(),
				"pre-pause running intent must survive while the runtime is stopped")

			ctx.set_cancel_mode("true")
			helpers.assert_true(surface.stop(),
				"a later pause retry must settle the original capability")
			helpers.assert_true(surface.is_running(),
				"settling cleanup must not erase the still-owed restore intent")
			helpers.assert_true(surface.resume_after_pause())
			helpers.assert_eq(#ctx.handles, 2,
				"the final resume must acquire one replacement runtime, exactly once")
			helpers.assert_true(surface.stop())
		end)
	end
end)

local function load_real_search_capture(stop_mode, click_mode, compose_gestures)
	for name in pairs(package.loaded) do
		if type(name) == "string" and name:match("^modules%.gestures%.actions") then
			package.loaded[name] = nil
		end
	end
	reset_module("tests.stubs.hs")
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local selection_reads = 0
	hs_stub.pasteboard.readAllData = function()
		return { ["public.utf8-plain-text"] = "ORIGINAL" }
	end
	hs_stub.pasteboard.clearContents = function() return true end
	hs_stub.pasteboard.getContents = function()
		selection_reads = selection_reads + 1
		return "selected words"
	end
	hs_stub.pasteboard.writeAllData = function() return true end
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.timings"] = { sec = function() return 0.2 end }
	package.loaded["adapters.synthetic_input"] = setmetatable({
		emit_key_stroke = function() return true end,
		defer_after_callback = function() return false end,
	}, { __index = function() return function() return true end end })
	package.loaded["modules.gestures.actions_click"] = setmetatable({
		force_cleanup = function()
			if click_mode == "false" then return false end
			if click_mode == "nil" then return nil end
			if click_mode == "throw" then error("click cleanup exploded") end
			return true
		end,
	}, { __index = function() return function() return true end end })
	package.loaded["modules.gestures.sticky_modifiers"] = {
		toggle = function() return true end,
		clear = function() return true end,
	}

	local actions = require("modules.gestures.actions")
	local gestures = nil
	local gesture_engine = nil
	if compose_gestures then
		local function permissive(overrides)
			return setmetatable(overrides or {}, {
				__index = function() return function() return true end end,
			})
		end
		gesture_engine = permissive({
			init = function() return true end,
			unblock_scroll = function() return true end,
		})
		package.loaded["modules.gestures.engine"] = gesture_engine
		package.loaded["modules.gestures.conflicts"] = permissive()
		package.loaded["infra.notifications"] = { notify = function() end }
		package.loaded["infra.manifest_reader"] = {
			default_for = function() return false end,
		}
		package.loaded["adapters.timer_scheduler"] = permissive({
			cancel = function() return true end,
		})
		package.loaded["modules.gestures"] = nil
		gestures = require("modules.gestures")
	else
		actions.init({ action_params = {} })
	end
	helpers.assert_true(actions.set_action_parameter(
		"tap_3", "search_web", "https://example.test/?q=%s"))
	helpers.assert_true(actions.execute_single("search_web", "tap_3"))
	local capture_timer = hs_stub.timer.__timers[#hs_stub.timer.__timers]
	helpers.assert_not_nil(capture_timer,
		"the real search action must own a positive-control capture timer")
	local native_stop = capture_timer.stop
	local current_stop_mode = stop_mode
	capture_timer.stop = function(self)
		if current_stop_mode == "false" then return false end
		if current_stop_mode == "nil" then return nil end
		if current_stop_mode == "throw" then error("timer stop exploded") end
		return native_stop(self)
	end
	return actions, hs_stub, capture_timer, function() return selection_reads end,
		function(mode) current_stop_mode = mode end, gestures, gesture_engine
end

helpers.describe("HS-012 real gesture-search ownership", function()
	helpers.it("opens a URL on the authorized positive-control timer", function()
		local _, hs_stub, capture_timer, selection_reads = load_real_search_capture()
		capture_timer:fire()
		helpers.assert_eq(selection_reads(), 1)
		helpers.assert_eq(#hs_stub.urlevent.__opened, 1,
			"the positive control proves the production callback can publish a URL")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("fences a live search timer when stop returns " .. mode, function()
			local actions, hs_stub, capture_timer, selection_reads =
				load_real_search_capture(mode)
			helpers.assert_eq(actions.force_cleanup(), false,
				"cleanup refusal must propagate to the gesture lifecycle")
			-- Deliver the native callback despite the refused stop. The exact slot
			-- remains retained, but authority was synchronously revoked first.
			capture_timer.fn()
			helpers.assert_eq(selection_reads(), 0)
			helpers.assert_eq(#hs_stub.urlevent.__opened, 0,
				"a refused search timer may never open a browser after cleanup")
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("propagates a " .. mode .. " click cleanup without leaking search", function()
			local actions, hs_stub, capture_timer, selection_reads =
				load_real_search_capture(nil, mode)
			helpers.assert_eq(actions.force_cleanup(), false,
				"the aggregate cleanup contract must require exact click settlement")
			capture_timer.fn()
			helpers.assert_eq(selection_reads(), 0)
			helpers.assert_eq(#hs_stub.urlevent.__opened, 0)
		end)
	end
end)

helpers.describe("HS-012 real gesture-search pause composition", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("settles a " .. mode .. " search timer through real Gestures and ScriptControl", function()
			local actions, hs_stub, capture_timer, selection_reads, set_stop_mode,
				real_gestures, gesture_engine = load_real_search_capture(mode, nil, true)
			local timer_count = #hs_stub.timer.__timers
			local suspended_during_stop = false
			local stop_calls = 0
			local stop_identities = {}
			local adverse_stop = capture_timer.stop
			capture_timer.stop = function(self)
				stop_calls = stop_calls + 1
				stop_identities[#stop_identities + 1] = self
				suspended_during_stop = suspended_during_stop or real_gestures.is_suspended()
				return adverse_stop(self)
			end

			local script_control = load_inventory_context({
				gestures = real_gestures,
				gesture_actions = actions,
				gesture_engine = gesture_engine,
			})
			helpers.assert_true(script_control.pause_all(),
				"the public request reports drain acceptance, not local commit")
			helpers.assert_eq(script_control.is_paused(), false,
				"a refused native search cleanup must not publish PAUSED")
			helpers.assert_true(suspended_during_stop,
				"Gestures must close its logical delivery fence before fallible timer cleanup")
			helpers.assert_eq(stop_calls, 2,
				"the faulting pause step and its inverse must retry the same search debt")
			helpers.assert_eq(stop_identities[1], capture_timer)
			helpers.assert_eq(stop_identities[2], capture_timer,
				"pause rollback must not replace the refused native timer")

			set_stop_mode("true")
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.is_paused(),
				"retry must settle the retained timer before committing PAUSED")
			helpers.assert_true(real_gestures.is_suspended())
			helpers.assert_eq(stop_calls, 3)
			helpers.assert_eq(stop_identities[3], capture_timer,
				"the retry must settle the same retained native timer, not a successor")
			capture_timer.fn()
			helpers.assert_eq(selection_reads(), 0)
			helpers.assert_eq(#hs_stub.urlevent.__opened, 0)
			local timer_count_after_pause = #hs_stub.timer.__timers

			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(real_gestures.is_suspended(), false)
			helpers.assert_true(timer_count_after_pause >= timer_count)
			helpers.assert_eq(#hs_stub.timer.__timers, timer_count_after_pause,
				"RESUME may reopen gesture delivery but must not resurrect a stale search")
			capture_timer.fn()
			helpers.assert_eq(selection_reads(), 0)
			helpers.assert_eq(#hs_stub.urlevent.__opened, 0)
			script_control.stop()
			package.loaded["modules.gestures"] = nil
		end)

		helpers.it("accepts the exact late terminal after a " .. mode .. " search stop", function()
			local actions, hs_stub, capture_timer, selection_reads, set_stop_mode,
				real_gestures, gesture_engine = load_real_search_capture(mode, nil, true)
			local stop_calls = 0
			local stop_identities = {}
			local adverse_stop = capture_timer.stop
			capture_timer.stop = function(self)
				stop_calls = stop_calls + 1
				stop_identities[#stop_identities + 1] = self
				return adverse_stop(self)
			end

			local script_control = load_inventory_context({
				gestures = real_gestures,
				gesture_actions = actions,
				gesture_engine = gesture_engine,
			})
			helpers.assert_true(script_control.pause_all())
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(stop_calls, 2,
				"the faulting pause step and its inverse must retain the same timer")
			helpers.assert_eq(stop_identities[1], capture_timer)
			helpers.assert_eq(stop_identities[2], capture_timer)

			capture_timer:fire()
			helpers.assert_eq(capture_timer.running, false,
				"one-shot delivery is exact terminal proof for the refused timer")
			helpers.assert_eq(selection_reads(), 0)
			helpers.assert_eq(#hs_stub.urlevent.__opened, 0,
				"the late terminal remains behind the gesture delivery fence")

			set_stop_mode("true")
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.is_paused())
			helpers.assert_eq(stop_calls, 2,
				"retry must not cancel a one-shot capability that already terminated")
			local timer_count_after_pause = #hs_stub.timer.__timers

			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(real_gestures.is_suspended(), false)
			helpers.assert_eq(#hs_stub.timer.__timers, timer_count_after_pause)
			capture_timer.fn()
			helpers.assert_eq(selection_reads(), 0)
			helpers.assert_eq(#hs_stub.urlevent.__opened, 0)
			script_control.stop()
			package.loaded["modules.gestures"] = nil
		end)
	end
end)
