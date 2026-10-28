--- tests/unit/adapters/synthetic_input/test_modifier_injector_control_sentinels.lua

--- ==============================================================================
--- MODULE: Sticky Modifier Control Sentinel Isolation
--- DESCRIPTION:
--- A gesture's sticky modifier must wait for ordinary input while Karabiner's
--- F19/F20 controls reach their sole owner with exact flags. The real sticky
--- policy, injector, provenance, clock, scheduler and sentinel decoder compose
--- over healthy native boundaries: head-insert taps share one mutable event.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"modules.gestures.sticky_modifiers",
	"adapters.modifier_injector",
	"modules.keymap.control_sentinels",
	"keymap.control_signals",
	"adapters.event_provenance",
	"adapters.synthetic_input",
	"infra.key_event_health",
	"adapters.event_clock",
	"adapters.timer_scheduler",
	"infra.logger",
	"error_description",
	"number_policy",
	"keycodes",
}


--- Copies a native flag snapshot instead of aliasing the event's flag storage.
--- @param flags table Flag set.
--- @return table copy
local function copy_flags(flags)
	local copy = {}
	for name, enabled in pairs(flags) do copy[name] = enabled end
	return copy
end


--- Composes real owners over the reviewed Hammerspoon 1.1.1 native boundaries.
--- @param callback function Receives the composed fixture.
local function with_fixture(callback)
	helpers.with_stub_scope(OWNED_MODULES, function()
		local taps, deferred = {}, {}
		local types = { keyDown = 10, keyUp = 11 }
		local properties = { eventSourceUserData = 1, eventSourceUnixProcessID = 2 }
		local world = { signals = {}, app_events = {}, deliveries = {} }
		local clock_ns = 1000000000000
		local timer_api = {}
		timer_api.absoluteTime = function() return clock_ns end
		timer_api.secondsSinceEpoch = function() return clock_ns / 1e9 end
		timer_api.new = function(_seconds, fn)
			local timer = { enabled = false, callback = fn }
			function timer:start() self.enabled = true; return self end
			function timer:stop() self.enabled = false; return self end
			function timer:running() return self.enabled end
			return timer
		end
		timer_api.doAfter = function(seconds, fn) return timer_api.new(seconds, fn):start() end
		_G.hs = {
			processInfo = { processID = 4242 },
			timer = timer_api,
			eventtap = {
				event = { types = types, properties = properties },
				new = function(watched, fn)
					local mask = {}
					for _, kind in ipairs(watched) do mask[kind] = true end
					local tap = { enabled = false, mask = mask, callback = fn }
					function tap:start()
						if not self.enabled then table.insert(taps, 1, self) end
						self.enabled = true
						return self
					end
					function tap:stop() self.enabled = false; return self end
					function tap:isEnabled() return self.enabled end
					return tap
				end,
			},
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.synthetic_input"] = {
			claim_tag = function() return nil end,
			claim_physical_fence = function() return nil end,
			defer_after_callback = function(_label, fn)
				deferred[#deferred + 1] = fn
				return true
			end,
		}

		local Sentinels = require("modules.keymap.control_sentinels")
		local Keycodes = require("keycodes")
		local Timer = require("adapters.timer_scheduler")
		local Injector = require("adapters.modifier_injector")
		local Sticky = require("modules.gestures.sticky_modifiers")
		Sentinels.set_listener("test.sticky_control", function(signal)
			world.signals[#world.signals + 1] = signal
		end)
		-- The boot-installed keymap owns both phases. The runtime injector is
		-- started later, so head insertion lets it inspect the same event first.
		local owner = hs.eventtap.new({ types.keyDown, types.keyUp }, function(event)
			return Sentinels.claim_key(event:getKeyCode(), event:getType() == types.keyDown, event:getFlags())
		end):start()

		world.Sticky, world.Injector, world.Sentinels = Sticky, Injector, Sentinels
		world.Keycodes = Keycodes
		function world.deferred_count() return #deferred end
		function world.flush()
			local pending = deferred
			deferred = {}
			for _, fn in ipairs(pending) do fn() end
		end
		function world.send(code, flags, is_down)
			local event = { flags = copy_flags(flags), set_calls = 0 }
			local kind = is_down and types.keyDown or types.keyUp
			function event:getKeyCode() return code end
			function event:getType() return kind end
			function event:getFlags() return copy_flags(self.flags) end
			function event:setFlags(value)
				self.set_calls = self.set_calls + 1
				self.flags = copy_flags(value)
				return self
			end
			function event:getProperty(property)
				return property == properties.eventSourceUnixProcessID and 4242 or 0
			end
			function event:timestamp() return clock_ns end
			local current = {}
			for index, tap in ipairs(taps) do current[index] = tap end
			for _, tap in ipairs(current) do
				if tap.enabled and tap.mask[kind] then
					world.deliveries[#world.deliveries + 1] = { tap = tap, kind = kind, event = event }
					if tap.callback(event) == true then return true, event end
				end
			end
			world.app_events[#world.app_events + 1] = event
			return false, event
		end
		local ok, err = xpcall(function() callback(world) end, debug.traceback)
		Sticky.clear()
		Timer.cancelAll()
		owner:stop()
		if not ok then error(err, 0) end
	end)
end


-- The tags are the deployed Karabiner payloads. The real decoder, rather than
-- an expected-result stub, decides which signal reaches the keymap listener.
local CONTROL_CASES = {
	{ name = "F19 navigation exit", key = "F19_LAYER_NAV_EXITED", flags = {}, signal = "nav_layer_exited" },
	{ name = "F20 navigation entry", key = "F20_LAYER_NAV_ENTERED", flags = {}, signal = "nav_layer_entered" },
	{ name = "F20 one-shot Shift", key = "F20_LAYER_NAV_ENTERED", flags = { ctrl = true, alt = true }, signal = "one_shot_shift" },
	{ name = "F20 CapsWord activation", key = "F20_LAYER_NAV_ENTERED", flags = { ctrl = true, alt = true, shift = true }, signal = "capsword_activated" },
	{ name = "F20 CapsWord deactivation", key = "F20_LAYER_NAV_ENTERED", flags = { ctrl = true, alt = true, cmd = true }, signal = "capsword_deactivated" },
}

helpers.describe("modifier injector: reserved control isolation", function()
	for _, case in ipairs(CONTROL_CASES) do
		helpers.it("(sticky-control-isolation) preserves both phases and the arm across " .. case.name, function()
			with_fixture(function(world)
				helpers.assert_true(world.Sticky.toggle({ "cmd" }, 2))
				local code = world.Keycodes[case.key]
				local consumed, down = world.send(code, case.flags, true)
				helpers.assert_true(consumed, "only the sentinel owner consumes the reserved down")
				helpers.assert_eq(down.set_calls, 0, "the injector must not rewrite a control payload")
				helpers.assert_eq(down.flags, case.flags, "the exact native control tags must survive")
				helpers.assert_eq(world.signals, { case.signal }, "the real owner must decode the original signal")
				helpers.assert_eq(world.deferred_count(), 0, "a control must not schedule sticky consumption")
				helpers.assert_true(world.Injector.is_armed())
				helpers.assert_eq(world.Sticky.armed(), { cmd = true })

				local before_up = #world.deliveries
				local up_consumed, up = world.send(code, case.flags, false)
				helpers.assert_true(up_consumed, "the sentinel owner also consumes the reserved up")
				helpers.assert_eq(#world.deliveries, before_up + 1,
					"the keyDown-only injector must not receive a manufactured keyUp callback")
				helpers.assert_eq(up.set_calls, 0)
				helpers.assert_eq(up.flags, case.flags)
				helpers.assert_eq(world.signals, { case.signal }, "the release publishes no second signal")
				helpers.assert_eq(#world.app_events, 0, "neither reserved phase reaches the application")
				helpers.assert_true(world.Injector.is_armed(), "no reserved release owns the arm")

				local passed, letter = world.send(0, {}, true)
				helpers.assert_true(not passed, "the ordinary physical key must reach the application")
				helpers.assert_eq(letter.flags, { cmd = true })
				helpers.assert_eq(letter.set_calls, 1, "the following ordinary key spends the arm once")
				helpers.assert_true(not world.Injector.is_armed())
				helpers.assert_eq(world.deferred_count(), 1)
				world.flush()
				helpers.assert_eq(world.Sticky.armed(), {})
				local released, letter_up = world.send(0, {}, false)
				helpers.assert_true(not released, "the ordinary release remains application input")
				helpers.assert_eq(letter_up.set_calls, 0)
				helpers.assert_eq(#world.app_events, 2, "the ordinary press and release keep their pair")
			end)
		end)
	end

	helpers.it("(sticky-control-isolation) preserves ordinary physical modifier merging", function()
		with_fixture(function(world)
			helpers.assert_true(world.Sticky.toggle({ "ctrl" }, 2))
			local consumed, event = world.send(0, { alt = true }, true)
			helpers.assert_true(not consumed)
			helpers.assert_eq(event.flags, { alt = true, ctrl = true })
			helpers.assert_eq(event.set_calls, 1)
			helpers.assert_eq(world.signals, {})
			world.flush()
			helpers.assert_eq(world.Sticky.armed(), {})
		end)
	end)
end)
