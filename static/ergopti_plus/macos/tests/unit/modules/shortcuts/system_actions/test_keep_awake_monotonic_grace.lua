--- tests/unit/modules/shortcuts/system_actions/test_keep_awake_monotonic_grace.lua

--- ==============================================================================
--- MODULE: Keep-Awake Activation Grace Regression Tests
--- DESCRIPTION:
--- Drives the real system owner, provenance and deferred dispatcher with healthy
--- native taps and independent civil and awake clocks. Physical input always
--- passes; only the activation grace decides when its deferred auto-off may run.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"tests.stubs.hs",
	"modules.shortcuts.actions.system",
	"modules.shortcuts.actions.system_pixel",
	"modules.shortcuts.actions.system_mouse",
	"modules.shortcuts.actions.screenshot_save",
	"modules.shortcuts.actions.text",
	"modules.gestures",
	"modules.keystats.log_manager",
	"infra.notifications",
	"infra.key_event_health",
	"infra.logger",
	"infra.text_utils",
	"infra.timings",
	"infra.i18n",
	"infra.keycodes",
	"modules.keymap.control_sentinels",
	"adapters.key_state",
	"adapters.keyboard_geometry",
	"adapters.synthetic_input",
	"adapters.event_provenance",
	"adapters.event_clock",
	"adapters.timer_scheduler",
	"adapters.storage",
	"error_description",
	"number_policy",
}


--- Runs one system owner against coherent real timing and provenance consumers.
--- @param callback function Receives the system owner and native observations.
local function with_awake(callback)
	local saved_random, saved_randomseed = math.random, math.randomseed
	local ok, failure = xpcall(function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			-- Preserve the process RNG: its state cannot be snapshotted after the
			-- production activation seeds it. The healthy first tick stays at 3 s.
			math.randomseed = function() end
			math.random = function(low, high)
				if low == nil then return 0.5 end
				assert(low == 0 and high == 1, "unexpected jitter random bounds")
				return 1
			end
			local world = { awake = 10000, civil = 1700000000, taps = {}, timers = {}, closed = {}, errors = {} }
			local native = require("tests.stubs.hs")
			_G.hs = native

			--- Models the native self-returning one-shot timer without inline delivery.
			--- @param delay number Requested delay in seconds.
			--- @param fn function Native callback.
			--- @return table timer Exact native timer identity.
			local function make_timer(delay, fn)
				local timer = { delay = delay, fn = fn, active = false, stop_calls = 0 }
				function timer:start(interval)
					if interval ~= nil then self.delay = interval end
					self.active = true
					return self
				end
				function timer:stop()
					self.active = false
					self.stop_calls = self.stop_calls + 1
					return self
				end
				function timer:running() return self.active end
				function timer:fire()
					assert(self.active, "only an armed native timer may deliver")
					self.active = false
					self.fn()
				end
				world.timers[#world.timers + 1] = timer
				return timer
			end
			native.timer.absoluteTime = function() return math.floor(world.awake * 1e9) end
			native.timer.secondsSinceEpoch = function() return world.civil end
			native.timer.new = make_timer
			native.timer.delayed.new = make_timer
			native.timer.doAfter = function(delay, fn) return make_timer(delay, fn):start() end
			native.eventtap.new = function(types, fn)
				local tap = { types = types, fn = fn, enabled = false, stop_calls = 0 }
				function tap:start() self.enabled = true; return self end
				function tap:stop()
					self.enabled = false
					self.stop_calls = self.stop_calls + 1
					return self
				end
				function tap:isEnabled() return self.enabled end
				world.taps[#world.taps + 1] = tap
				return tap
			end
			native.alert.show = function() return "keep-awake-owned-banner" end
			native.alert.closeSpecific = function(id) world.closed[#world.closed + 1] = id end
			native.alert.closeAll = function() error("the exact owned banner must close independently") end
			native.mouse.absolutePosition = function() return { x = 100, y = 200 } end
			native.application.frontmostApplication = function() return nil end

			local logger = helpers.make_logger_stub()
			logger.error = function(_, format, ...) world.errors[#world.errors + 1] = string.format(format, ...) end
			package.loaded["infra.logger"] = logger
			package.loaded["infra.timings"] = {
				sec = function(group, key)
					local seconds = { tick_min_ms = 1, tick_max_ms = 5, return_delay_ms = 0.2 }
					assert(group == "keep_awake" and seconds[key] ~= nil, "unexpected keep-awake timing")
					return seconds[key]
				end,
			}
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.keycodes"] = { F18_WAKE_OS = 79 }
			local stored = {}
			package.loaded["adapters.storage"] = {
				get = function(key) return stored[key] end,
				set = function(key, value) stored[key] = value; return true end,
			}
			-- These sibling actions do not participate in keep-awake. Empty exports
			-- ensure an accidental call cannot be answered by a made-up method.
			for _, name in ipairs({
				"modules.shortcuts.actions.system_pixel", "modules.shortcuts.actions.system_mouse",
				"modules.shortcuts.actions.screenshot_save", "modules.shortcuts.actions.text",
				"modules.gestures", "infra.notifications", "infra.key_event_health",
				"infra.text_utils", "modules.keymap.control_sentinels", "adapters.key_state",
				"adapters.keyboard_geometry", "modules.keystats.log_manager",
			}) do package.loaded[name] = {} end
			local System = require("modules.shortcuts.actions.system")
			local Scheduler = require("adapters.timer_scheduler")
			helpers.assert_eq(System.toggle_awake(), true, "a healthy native watcher and tick must activate")
			helpers.assert_eq(System.is_awake_active(), true)
			helpers.assert_eq(#world.taps, 1)
			world.watcher = world.taps[1]
			helpers.assert_true(world.watcher:isEnabled())
			for _, timer in ipairs(world.timers) do
				if timer.active and timer.delay == 3 then world.tick = timer end
			end
			helpers.assert_not_nil(world.tick, "the real Scheduler must retain its first healthy jitter tick")
			local body_ok, body_failure = xpcall(function() callback(System, world, native) end, debug.traceback)
			helpers.assert_eq(System.stop_awake(), true, "teardown must retire the exact active owner")
			helpers.assert_eq(Scheduler.cancelAll(), true)
			for _, timer in ipairs(world.timers) do timer:stop() end
			helpers.assert_eq(#world.errors, 0, "callback errors must not be hidden by native guards")
			if not body_ok then error(body_failure, 0) end
		end)
	end, debug.traceback)
	math.random, math.randomseed = saved_random, saved_randomseed
	if not ok then error(failure, 0) end
end


--- Observes one real physical-input callback and its retained deferred auto-off.
--- @param kind string Registered scroll or keyboard input.
--- @param elapsed number Actual awake duration since activation.
--- @param correction number Civil-clock correction during activation.
--- @param should_disable boolean Whether the grace window has elapsed.
local function observe_activity(kind, elapsed, correction, should_disable)
	with_awake(function(System, world, native)
		world.awake = world.awake + elapsed
		world.civil = world.civil + elapsed + correction
		local event_type = kind == "scroll" and native.eventtap.event.types.scrollWheel or native.eventtap.event.types.keyDown
		local registered = false
		for _, accepted in ipairs(world.watcher.types) do if accepted == event_type then registered = true end end
		helpers.assert_true(registered, "the physical event must belong to the real watcher's event mask")
		local event = {
			getProperty = function(_, property)
				if kind == "scroll" and property == native.eventtap.event.properties.scrollWheelEventDeltaAxis1 then return 1 end
				return 0
			end,
			getType = function() return event_type end,
			getKeyCode = function() return 0 end,
			getFlags = function() return {} end,
			timestamp = function() return math.floor(world.awake * 1e9) end,
		}
		local consume, returned = world.watcher.fn(event)
		helpers.assert_eq(consume, false, "ordinary physical input must always pass through")
		helpers.assert_nil(returned)
		helpers.assert_eq(System.is_awake_active(), true, "native cleanup must wait until the callback returns")
		helpers.assert_eq(#world.closed, 0)
		local dispatcher = nil
		for _, timer in ipairs(world.timers) do
			if timer.active and timer.delay == 0 then
				helpers.assert_nil(dispatcher, "only one real lifecycle dispatcher may be armed")
				dispatcher = timer
			end
		end
		if should_disable then
			helpers.assert_not_nil(dispatcher, "elapsed awake grace must schedule physical-input auto-off")
			dispatcher:fire()
			helpers.assert_eq(System.is_awake_active(), false)
			helpers.assert_eq(world.watcher:isEnabled(), false)
			helpers.assert_eq(world.watcher.stop_calls, 1)
			helpers.assert_eq(world.tick.active, false)
			helpers.assert_eq(world.tick.stop_calls, 1)
			helpers.assert_eq(#world.closed, 1)
			helpers.assert_eq(world.closed[1], "keep-awake-owned-banner")

			local retired = world.watcher
			helpers.assert_eq(System.toggle_awake(), true, "a later healthy session must activate independently")
			local successor = world.taps[#world.taps]
			helpers.assert_true(successor ~= retired and successor:isEnabled())
			local retired_consume, retired_returned = retired.fn(event)
			helpers.assert_eq(retired_consume, false)
			helpers.assert_nil(retired_returned)
			helpers.assert_eq(System.is_awake_active(), true, "a retired native callback must not disable its successor")
			helpers.assert_eq(#world.closed, 1)
			for _, timer in ipairs(world.timers) do
				helpers.assert_true(not timer.active or timer.delay ~= 0,
					"a retired callback must not queue teardown for the current session")
			end
		else
			helpers.assert_nil(dispatcher, "a civil-clock step must not spend the awake activation grace")
			helpers.assert_eq(world.watcher:isEnabled(), true)
			helpers.assert_eq(world.tick.active, true)
		end
	end)
end


helpers.describe("keep-awake activation grace measures awake duration", function()
	for _, kind in ipairs({ "scroll", "keyboard" }) do
		helpers.it(kind .. " keeps the healthy early activation grace", function()
			observe_activity(kind, 0.1, 0, false)
		end)
		helpers.it(kind .. " auto-disables at the exact awake grace boundary", function()
			observe_activity(kind, 1, 0, true)
		end)
		helpers.it(kind .. " auto-disables after a civil-clock rollback", function()
			observe_activity(kind, 2, -60, true)
		end)
		helpers.it(kind .. " preserves early grace through a civil-clock advance", function()
			observe_activity(kind, 0.1, 60, false)
		end)
	end
end)
