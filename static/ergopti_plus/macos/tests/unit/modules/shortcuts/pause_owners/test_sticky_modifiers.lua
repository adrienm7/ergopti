--- tests/unit/modules/shortcuts/pause_owners/test_sticky_modifiers.lua

--- ==============================================================================
--- MODULE: Pause Owner sticky modifiers Regressions
--- DESCRIPTION:
--- Preserves the behavioral pause-owner regression scenarios with a focused
--- fixture boundary. Shared fixtures create fresh runtime state per invocation.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixtures = require("tests.unit.modules.shortcuts.pause_owners.fixtures")
local reset_module = fixtures.reset_module
local load_inventory_context = fixtures.load_inventory_context

local function load_real_sticky_pause_owner()
	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:match("^modules%.gestures%.actions")
			or name == "modules.gestures.sticky_modifiers"
			or name == "modules.gestures"
			or name == "adapters.modifier_injector"
			or name == "adapters.timer_scheduler") then
			package.loaded[name] = nil
		end
	end
	reset_module("tests.stubs.hs")
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local native_timers = {}
	hs_stub.timer.new = function(delay, callback)
		local timer = {
			delay = delay,
			callback = callback,
			running_state = false,
			start_calls = 0,
			stop_calls = 0,
			stop_identities = {},
			stop_mode = "true",
		}
		function timer:start()
			self.start_calls = self.start_calls + 1
			self.running_state = true
			return self
		end
		function timer:stop()
			self.stop_calls = self.stop_calls + 1
			self.stop_identities[self.stop_calls] = self
			if self.stop_mode == "false" then return false end
			if self.stop_mode == "nil" then return nil end
			if self.stop_mode == "throw" then error("sticky timer stop exploded") end
			self.running_state = false
			return self
		end
		function timer:running() return self.running_state end
		function timer:deliver() callback() end
		native_timers[#native_timers + 1] = timer
		return timer
	end

	local deferred = {}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.event_provenance"] = {
		STATUS_UNREADABLE = "unreadable",
		classify_with_fence = function() return nil, "foreign", nil end,
	}
	package.loaded["adapters.synthetic_input"] = setmetatable({
		defer_after_callback = function(_label, callback)
			deferred[#deferred + 1] = callback
			return true
		end,
	}, { __index = function() return function() return true end end })

	local TimerScheduler = require("adapters.timer_scheduler")
	local Injector = require("adapters.modifier_injector")
	local Sticky = require("modules.gestures.sticky_modifiers")

	local function permissive(overrides)
		return setmetatable(overrides or {}, {
			__index = function() return function() return true end end,
		})
	end
	package.loaded["infra.notifications"] = { notify = function() end }
	package.loaded["infra.paths"] = { shared = function(path) return "missing/" .. path end }
	package.loaded["infra.timings"] = { sec = function() return 0.2 end }
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.text_utils"] = permissive({
		escape_gsub_replacement = function(value) return value end,
	})
	package.loaded["adapters.file_system"] = permissive({ read = function() return nil end })
	package.loaded["adapters.key_state"] = permissive({
		is_right_altgr_held = function() return false end,
		describe_held_modifiers = function() return "(none)" end,
	})
	package.loaded["adapters.shell_runner"] = permissive()
	package.loaded["infra.termination_coordinator"] = permissive()
	local function scoped_child(pause_name, resume_name, query_name, pending_name)
		local paused = {}
		return {
			[pause_name] = function(parent) paused[parent] = true; return true end,
			[resume_name] = function(parent) paused[parent] = false; return true end,
			[query_name] = function(parent) return paused[parent] == true end,
			[pending_name] = function() return false end,
		}
	end
	package.loaded["modules.shortcuts.actions.text"] = scoped_child(
		"pause_text_actions", "resume_text_actions",
		"is_text_actions_paused", "has_pending_text_action")
	package.loaded["modules.shortcuts.actions.system_mouse"] = scoped_child(
		"pause_mouse_actions", "resume_mouse_actions",
		"is_mouse_actions_paused", "has_pending_mouse_action")
	package.loaded["modules.shortcuts.actions.screenshot_save"] = scoped_child(
		"pause_screenshot_actions", "resume_screenshot_actions",
		"has_screenshot_pause_claim", "has_pending_screenshot_action")
	package.loaded["modules.gestures.actions_click"] = permissive({
		force_cleanup = function() return true end,
	})
	package.loaded["modules.gestures.sticky_modifiers"] = Sticky
	reset_module("modules.gestures.actions")
	local actions = require("modules.gestures.actions")

	local gesture_engine = permissive({
		init = function() return true end,
		unblock_scroll = function() return true end,
	})
	package.loaded["modules.gestures.engine"] = gesture_engine
	package.loaded["modules.gestures.actions"] = actions
	package.loaded["modules.gestures.conflicts"] = permissive()
	package.loaded["infra.manifest_reader"] = { default_for = function() return false end }
	package.loaded["adapters.timer_scheduler"] = TimerScheduler
	reset_module("modules.gestures")
	local gestures = require("modules.gestures")

	local function flush_deferred()
		local snapshot = deferred
		deferred = {}
		for _, callback in ipairs(snapshot) do callback() end
	end

	return {
		hs = hs_stub,
		timers = native_timers,
		injector = Injector,
		sticky = Sticky,
		actions = actions,
		gestures = gestures,
		gesture_engine = gesture_engine,
		flush_deferred = flush_deferred,
		deferred_count = function() return #deferred end,
	}
end

local function sticky_physical_event()
	local observed = { set_calls = 0, flags = {} }
	local event = {
		getFlags = function() return {} end,
		setFlags = function(_, flags)
			observed.set_calls = observed.set_calls + 1
			observed.flags = flags
		end,
	}
	return event, observed
end

helpers.describe("HS-012 real sticky-modifier pause ownership", function()
	for _, owner_kind in ipairs({ "timer", "injector" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("joins the exact " .. owner_kind .. " after " .. mode .. " cleanup", function()
				local fixture = load_real_sticky_pause_owner()

				-- Positive control: the real adapter can mutate a physical event while
				-- ACTIVE, and its deferred policy handoff consumes the first arm.
				helpers.assert_eq(fixture.sticky.toggle({ "cmd" }, 1), true)
				local positive_tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]
				local positive_event, positive_observed = sticky_physical_event()
				positive_tap.fn(positive_event)
				fixture.flush_deferred()
				helpers.assert_eq(positive_observed.set_calls, 1)
				helpers.assert_eq(positive_observed.flags.cmd, true)
				helpers.assert_eq(next(fixture.sticky.armed()), nil)

				helpers.assert_eq(fixture.sticky.toggle({ "shift" }, 1), true)
				local target_timer = fixture.timers[#fixture.timers]
				local target_tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]
				helpers.assert_not_nil(target_timer)
				helpers.assert_not_nil(target_tap)
				helpers.assert_true(target_tap ~= positive_tap,
					"the adverse arm must own a distinct exact eventtap")

				local tap_stop_calls = 0
				local tap_stop_identities = {}
				local tap_stop_mode = owner_kind == "injector" and mode or "true"
				local native_tap_stop = target_tap.stop
				target_tap.stop = function(self)
					tap_stop_calls = tap_stop_calls + 1
					tap_stop_identities[tap_stop_calls] = self
					if tap_stop_mode == "false" then return false end
					if tap_stop_mode == "nil" then return nil end
					if tap_stop_mode == "throw" then error("sticky tap stop exploded") end
					return native_tap_stop(self)
				end
				target_timer.stop_mode = owner_kind == "timer" and mode or "true"

				local script_control = load_inventory_context({
					gestures = fixture.gestures,
					gesture_actions = fixture.actions,
					gesture_engine = fixture.gesture_engine,
				})
				local suspended_during_cleanup = false
				if owner_kind == "timer" then
					local native_stop = target_timer.stop
					target_timer.stop = function(self)
						suspended_during_cleanup = suspended_during_cleanup
							or fixture.gestures.is_suspended()
						return native_stop(self)
					end
				else
					local adverse_stop = target_tap.stop
					target_tap.stop = function(self)
						suspended_during_cleanup = suspended_during_cleanup
							or fixture.gestures.is_suspended()
						return adverse_stop(self)
					end
				end

				helpers.assert_true(script_control.pause_all())
				helpers.assert_eq(script_control.is_paused(), false,
					"refused Sticky cleanup must prevent PAUSED publication")
				helpers.assert_true(suspended_during_cleanup,
					"Gestures must publish its logical fence before Sticky cleanup")
				local retained_modifier = owner_kind == "injector" and "shift" or nil
				helpers.assert_eq(next(fixture.sticky.armed()), retained_modifier,
					"only refused injector cleanup retains the exact logical modifier debt")

				local old_event, old_observed = sticky_physical_event()
				local deferred_before_late = fixture.deferred_count()
				target_tap.fn(old_event)
				target_timer:deliver()
				fixture.flush_deferred()
				helpers.assert_eq(old_observed.set_calls, 0,
					"a retained native tap must be inert after its delivery fence closes")
				helpers.assert_eq(fixture.deferred_count(), 0)
				helpers.assert_eq(deferred_before_late, 0)
				helpers.assert_eq(next(fixture.sticky.armed()), retained_modifier,
					"late callbacks stay inert without erasing retryable injector identity")

				target_timer.stop_mode = "true"
				tap_stop_mode = "true"
				helpers.assert_true(script_control.pause_all())
				helpers.assert_true(script_control.is_paused())
				helpers.assert_eq(next(fixture.sticky.armed()), nil,
					"the owning retry must clear the logical identity after native settlement")
				if owner_kind == "timer" then
					helpers.assert_true(target_timer.stop_calls >= 3,
						"retry and late delivery must keep targeting the same timer")
					for _, identity in ipairs(target_timer.stop_identities) do
						helpers.assert_true(identity == target_timer,
							"every retry must retain the exact timer capability")
					end
				else
					helpers.assert_eq(tap_stop_calls, 3,
						"pause, inverse, and retry must target the same retained eventtap")
					helpers.assert_true(tap_stop_identities[1] == target_tap,
						"first injector cleanup must target the exact eventtap")
					helpers.assert_true(tap_stop_identities[2] == target_tap,
						"pause inverse must retain the exact eventtap")
					helpers.assert_true(tap_stop_identities[3] == target_tap,
						"retry injector cleanup must settle the exact eventtap")
				end

				local timer_count = #fixture.timers
				local tap_count = #fixture.hs.eventtap.__taps
				target_tap.fn(old_event)
				target_timer:deliver()
				helpers.assert_eq(old_observed.set_calls, 0)
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(fixture.gestures.is_suspended(), false)
				helpers.assert_eq(#fixture.timers, timer_count,
					"RESUME must not resurrect a consumed Sticky timer")
				helpers.assert_eq(#fixture.hs.eventtap.__taps, tap_count,
					"RESUME must not resurrect a consumed modifier eventtap")
				target_tap.fn(old_event)
				target_timer:deliver()
				helpers.assert_eq(old_observed.set_calls, 0)
				script_control.stop()
			end)
		end
	end
end)
