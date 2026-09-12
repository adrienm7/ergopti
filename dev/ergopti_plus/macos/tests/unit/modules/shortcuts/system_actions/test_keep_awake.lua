--- tests/unit/modules/shortcuts/system_actions/test_keep_awake.lua

--- ==============================================================================
--- MODULE: System Action Regression Tests
--- DESCRIPTION:
--- Exercises system actions while preserving exact native and dependency ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.system_actions_fixture")
local load_system = fixture.load_system
local with_fixture = fixture.with_fixture
local as_physical = fixture.as_physical
local fire_post_callback_actions = fixture.fire_post_callback_actions

helpers.describe("shortcuts.actions.system: keep_awake persistent alert", function()
	-- Builds a fresh module instance with spied alert + timer stubs.
	local function make_sys_with_alert_spy()
		package.loaded["infra.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil
		package.loaded["adapters.timer_scheduler"] = nil

		local show_calls      = {}
		local close_all_calls = 0

		local sys = load_system({
			alert = setmetatable({
				show = function(msg, duration)
					table.insert(show_calls, { msg = msg, duration = duration })
					return "test-alert-uuid"
				end,
				closeAll      = function() close_all_calls = close_all_calls + 1 end,
				closeSpecific = function() end,
			}, { __call = function(_, _) end }),
		})

		return sys, show_calls, close_all_calls
	end

	helpers.it("shows the on-banner with math.huge duration so it persists while active", function()
		with_fixture(function()
			local sys, show_calls = make_sys_with_alert_spy()
			sys.toggle_awake()
			local on_call = show_calls[#show_calls]
			helpers.assert_true(on_call ~= nil, "hs.alert.show should be called on toggle ON")
			helpers.assert_eq(on_call.duration, math.huge, "duration must be math.huge — not a fixed timeout")
		end)
	end)

	helpers.it("closes the banner on manual toggle OFF", function()
		with_fixture(function()
			package.loaded["infra.keycodes"] = nil
			package.loaded["modules.shortcuts.actions.system"] = nil
			package.loaded["adapters.timer_scheduler"] = nil

			local close_calls = 0

			local sys = load_system({
				alert = setmetatable({
					show          = function() return "test-alert-uuid" end,
					closeAll      = function() close_calls = close_calls + 1 end,
					closeSpecific = function() close_calls = close_calls + 1 end,
				}, { __call = function(_, _) end }),
			})

			sys.toggle_awake()   -- ON
			local calls_before = close_calls
			sys.toggle_awake()   -- OFF → the banner must be closed
			helpers.assert_true(close_calls > calls_before, "the banner must be closed on toggle OFF")
		end)
	end)

	helpers.it("closes the banner on stop_awake", function()
		with_fixture(function()
			package.loaded["infra.keycodes"] = nil
			package.loaded["modules.shortcuts.actions.system"] = nil
			package.loaded["adapters.timer_scheduler"] = nil

			local close_calls = 0

			local sys = load_system({
				alert = setmetatable({
					show          = function() return "test-alert-uuid" end,
					closeAll      = function() close_calls = close_calls + 1 end,
					closeSpecific = function() close_calls = close_calls + 1 end,
				}, { __call = function(_, _) end }),
			})

			sys.toggle_awake()   -- ON
			local calls_before = close_calls
			sys.stop_awake()     -- direct stop (e.g. module shutdown)
			helpers.assert_true(close_calls > calls_before, "the banner must be closed on stop_awake")
		end)
	end)

	-- Regression guard (shortcuts-awake-closes-all-alerts): closing OUR banner must
	-- not dismiss unrelated alerts other modules put on screen. Whenever the show
	-- call handed us an id, the close must target exactly that id and must never
	-- reach closeAll, which is a screen-wide sweep.
	helpers.it("closes only its own alert when an id was captured (never closeAll)", function()
		with_fixture(function()
			package.loaded["infra.keycodes"] = nil
			package.loaded["modules.shortcuts.actions.system"] = nil
			package.loaded["adapters.timer_scheduler"] = nil

			local close_all_calls = 0
			local closed_ids      = {}

			local sys = load_system({
				alert = setmetatable({
					show          = function() return "test-alert-uuid" end,
					closeAll      = function() close_all_calls = close_all_calls + 1 end,
					closeSpecific = function(id) closed_ids[#closed_ids + 1] = id end,
				}, { __call = function(_, _) end }),
			})

			sys.toggle_awake()   -- ON  → id captured
			sys.toggle_awake()   -- OFF → must close that id and nothing else

			helpers.assert_eq(close_all_calls, 0,
				"closeAll must NOT be called when an alert id is available — it dismisses every "
				.. "on-screen alert, including unrelated ones from other modules")
			helpers.assert_eq(closed_ids[#closed_ids], "test-alert-uuid",
				"the close must target the stored keep-awake alert id")
		end)
	end)

	-- Regression guard: closeAll must be called even when hs.alert.show returns nil
	-- (older Hammerspoon builds). This was the root cause of banners persisting after
	-- auto-deactivation — the ID was nil so nothing was ever closed.
	helpers.it("calls closeAll even when hs.alert.show returned nil (no ID captured)", function()
		with_fixture(function()
			package.loaded["infra.keycodes"] = nil
			package.loaded["modules.shortcuts.actions.system"] = nil
			package.loaded["adapters.timer_scheduler"] = nil

			local close_all_calls = 0

			local sys = load_system({
				alert = setmetatable({
					show          = function() return nil end,
					closeAll      = function() close_all_calls = close_all_calls + 1 end,
					closeSpecific = function() end,
				}, { __call = function(_, _) end }),
			})

			sys.toggle_awake()   -- ON  → awake_alert_id remains nil (show returned nil)
			local calls_before = close_all_calls
			sys.toggle_awake()   -- OFF → closeAll must still be called
			helpers.assert_true(close_all_calls > calls_before, "closeAll must be called even when alert ID is nil")
		end)
	end)

	-- Drives the auto-deactivation eventtap callback directly. Activates keep-awake,
	-- captures the watcher callback handed to eventtap.new, and replaces the clock so
	-- we can step past the activation grace window. Returns the module, a mutable
	-- clock, a closeAll counter, and the captured callback holder.
	local function activate_with_watcher()
		package.loaded["infra.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil
		package.loaded["adapters.timer_scheduler"] = nil
		package.loaded["adapters.synthetic_input"] = nil
		package.loaded["adapters.event_provenance"] = nil
		local sys = load_system()
		local hs  = _G.hs

		local clock = { now = 1000 }
		hs.timer.secondsSinceEpoch = function() return clock.now end

		-- Counts either close API: these tests assert the banner went away, not which
		-- call removed it (the normal path targets the stored id via closeSpecific).
		local close_all = { count = 0 }
		hs.alert.closeAll      = function() close_all.count = close_all.count + 1 end
		hs.alert.closeSpecific = function() close_all.count = close_all.count + 1 end
		hs.alert.show          = function() return "uuid" end

		local captured = { cb = nil }
		hs.eventtap.new = function(_types, cb)
			captured.cb = cb
			local tap = { enabled = false }
			function tap:start() self.enabled = true; return self end
			function tap:stop() self.enabled = false; return self end
			function tap:isEnabled() return self.enabled end
			return tap
		end

		sys.toggle_awake()   -- ON → builds and "starts" the watcher, capturing its callback
		return sys, clock, close_all, captured, require("adapters.synthetic_input")
	end

	-- A fake CGEvent of an arbitrary type that is neither keyDown nor mouseMoved,
	-- so the watcher callback falls straight through to the deactivation branch.
local function fake_activity_event()
		return as_physical({
			getType  = function() return 4242 end,
			getFlags = function() return {} end,
			location = function() return { x = 0, y = 0 } end,
		})
	end

	-- Regression for the `local type = _ev:getType()` shadow bug: it turned the
	-- type() builtin into a number, so `type(awake_timer.stop)` crashed the eventtap
	-- callback BEFORE close_awake_alert() ran — the banner stayed on screen forever
	-- after the user touched the touchpad/keyboard.
	helpers.it("auto-deactivation closes the banner without crashing (type-shadow regression)", function()
		with_fixture(function()
			local _sys, clock, close_all, captured = activate_with_watcher()
			helpers.assert_true(type(captured.cb) == "function", "toggle_awake must create a watcher callback")

			local before = close_all.count
			clock.now = clock.now + 100   -- well past the activation grace window
			-- Called directly: the regression this guards (the 'type' builtin shadowed
			-- inside the callback) raised, and a raise here now fails with that error
			-- rather than with a boolean. The assertion is the callback's EFFECT.
			captured.cb(fake_activity_event())
			fire_post_callback_actions(_G.hs)
			helpers.assert_true(close_all.count > before, "auto-deactivation must close the keep-awake banner")
		end)
	end)

	-- Regression for the double-Ctrl+M bug: a touchpad brush within the grace window
	-- (e.g. the thumb pressing Ctrl+M a second time) must NOT auto-deactivate, else
	-- the second Ctrl+M re-enables keep-awake instead of disabling it.
	helpers.it("ignores input within the activation grace window (rapid double Ctrl+M)", function()
		with_fixture(function()
			local _sys, clock, close_all, captured = activate_with_watcher()
			local before = close_all.count
			clock.now = clock.now + 0.1   -- inside the grace window
			captured.cb(fake_activity_event())
			helpers.assert_eq(close_all.count, before, "input within the grace window must not auto-deactivate")
		end)
	end)

	-- Regression for the dropped "empty keystroke": keep-awake must post a real
	-- no-op key (F18) every tick so the HID idle counter resets and Teams stays
	-- "available". Warping the mouse alone never resets that counter. The watcher
	-- must recognise THIS key as synthetic and not self-deactivate.

	-- A fake keyDown CGEvent with the given keycode and no modifiers.
	local function fake_key_event(keycode)
		return as_physical({
			getType    = function() return _G.hs.eventtap.event.types.keyDown end,
			getKeyCode = function() return keycode end,
			getFlags   = function() return {} end,
			location   = function() return { x = 0, y = 0 } end,
		})
	end

	helpers.it("_emit_activity_keystroke pumps one tagged F18 pair without advancing the action epoch (keep-awake-non-action)", function()
		with_fixture(function()
			local F18 = require("infra.keycodes").F18_WAKE_OS
			package.loaded["infra.keycodes"] = nil
			package.loaded["modules.shortcuts.actions.system"] = nil
			package.loaded["adapters.timer_scheduler"] = nil
			package.loaded["adapters.synthetic_input"] = nil
			package.loaded["adapters.event_provenance"] = nil

			-- Drive the production adapter all the way through its deferred Quartz
			-- pump. Looking only at a mocked emit_key_stroke call would stay green if
			-- the real transaction were accidentally observable and advanced the
			-- action epoch on every keep-awake tick.
			local payload_posts = 0
			local posted_trigger = nil
			package.loaded["tests.stubs.hs"] = nil
			local eventtap = require("tests.stubs.hs").eventtap
			local base_new_key = eventtap.event.newKeyEvent
			local base_new_mouse = eventtap.event.newMouseEvent
			eventtap.event.newKeyEvent = function(_mods, key, isDown)
				local event = base_new_key(_mods, key, isDown)
				event.post = function(self)
					payload_posts = payload_posts + 1
					return self
				end
				return event
			end
			eventtap.event.newMouseEvent = function(event_type, pos, mods)
				local event = base_new_mouse(event_type, pos, mods)
				event.post = function(self)
					posted_trigger = self
					return self
				end
				return event
			end
			local sys = load_system({
				eventtap = eventtap,
			})
			local hs = _G.hs

			local synthetic = require("adapters.synthetic_input")
			local provenance = require("adapters.event_provenance")
			local epoch_before = synthetic.current_action_epoch()

			sys._emit_activity_keystroke()
			local broker = hs.timer.__timers[#hs.timer.__timers]
			helpers.assert_not_nil(broker, "the deferred adapter must arm its broker timer")
			broker:fire()
			helpers.assert_not_nil(posted_trigger, "the broker must post its tagged pump trigger")

			local pump = nil
			for _, tap in ipairs(hs.eventtap.__taps) do
				if tap.types and tap.types[1] == hs.eventtap.event.types.otherMouseUp then
					pump = tap
					break
				end
			end
			helpers.assert_not_nil(pump, "the production synthetic-input pump must be active")
			local consume, events = pump.fn(posted_trigger)
			helpers.assert_true(consume)
			helpers.assert_eq(#events, 2, "the pump must return one key-down/key-up pair")
			helpers.assert_eq(payload_posts, 0,
				"payload keys must be callback-returned by the pump, never posted individually")
			helpers.assert_eq(events[1].key, F18, "wake key must be F18 (the keymap-reserved no-op)")
			helpers.assert_eq(events[1].isDown, true)
			helpers.assert_eq(events[2].key, F18)
			helpers.assert_eq(events[2].isDown, false)

			local user_data = hs.eventtap.event.properties.eventSourceUserData
			local down_tag = events[1]:getProperty(user_data)
			local up_tag = events[2]:getProperty(user_data)
			helpers.assert_true(down_tag ~= 0 and up_tag ~= 0 and down_tag ~= up_tag,
				"both F18 phases need distinct immutable provenance tags")
			helpers.assert_true(synthetic.current_action_epoch() == epoch_before,
				"a keep-awake heartbeat is not a user action and must preserve the action epoch")

			local down = provenance.classify(events[1], "unit.keep_awake")
			local up = provenance.classify(events[2], "unit.keep_awake")
			helpers.assert_true(down.owned and up.owned)
			helpers.assert_eq(down.owner, "shortcuts.keep_awake")
			helpers.assert_eq(down.effect, "replacement",
				"the explicit non-observable transaction must survive through the real pump")

			-- The pump hands the batch back to Quartz first, then closes it on the
			-- next runloop turn. Exercise that terminal transition as well: a sealed
			-- keep-awake heartbeat must not leave one transaction alive per tick.
			hs.timer.__fire_all()
			helpers.assert_eq(synthetic.stats().active_transactions, 0,
				"the dispatched keep-awake transaction must complete after pump handoff")

			-- Do not leak an adapter captured against this test's hs table into later
			-- system-action fixtures, which intentionally install partial hs overrides.
			package.loaded["adapters.synthetic_input"] = nil
			package.loaded["adapters.event_provenance"] = nil
		end)
	end)

	helpers.it("watcher ignores only an exactly tagged F18 and treats physical F18 as user activity (keep-awake-exact-provenance)", function()
		with_fixture(function()
			local F18 = require("infra.keycodes").F18_WAKE_OS
			local _sys, clock, close_all, captured, synthetic = activate_with_watcher()
			clock.now = clock.now + 100   -- past the activation grace window

			local tx = synthetic.begin("unit.keep_awake.owned", "replacement")
			local batch = synthetic.begin_callback(tx)
			synthetic.keyStroke(batch, {}, F18)
			local _, events = synthetic.finish_callback(batch, true)
			synthetic.seal(tx)
			local tagged_f18 = events[1]
			tagged_f18.getType = function() return _G.hs.eventtap.event.types.keyDown end
			tagged_f18.getKeyCode = function() return F18 end
			tagged_f18.getFlags = function() return {} end
			tagged_f18.location = function() return { x = 0, y = 0 } end

			local before = close_all.count
			captured.cb(tagged_f18)
			helpers.assert_eq(close_all.count, before,
				"an Ergopti-owned F18 heartbeat must not auto-deactivate keep-awake")

			-- F18 exists on extended/program keyboards. Keycode equality is not identity:
			-- the same untagged key must be treated like any other real user input.
			captured.cb(fake_key_event(F18))
			fire_post_callback_actions(_G.hs)
			helpers.assert_true(close_all.count > before,
				"a physical F18 press must auto-deactivate keep-awake")
		end)
	end)
end)
