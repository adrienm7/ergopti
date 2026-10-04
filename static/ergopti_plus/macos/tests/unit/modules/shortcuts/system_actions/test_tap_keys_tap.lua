--- tests/unit/modules/shortcuts/system_actions/test_tap_keys_tap.lua

--- ==============================================================================
--- MODULE: The number-row tap-key eventtap (macOS)
--- DESCRIPTION:
--- The raw keyDown tap of the tap keys: a plain press of a key its decision
--- names is consumed and the action runs behind the callback; a press with a
--- modifier (Option is this platform's AltGr), a key the decision lets through,
--- and an auto-repeat change nothing but the last, which is consumed and runs
--- nothing.
---
--- ROOT CAUSE ENCODED:
--- The only such tap was hard-wired to keycode 10 and one action (the instant
--- screenshot); the keys right of 0 could not be tapped at all.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.system_actions_fixture")
local with_fixture = fixture.with_fixture
local as_physical = fixture.as_physical
local make_sys_screenshot_spies = fixture.make_sys_screenshot_spies
local run_screenshot_deferred = fixture.run_screenshot_deferred

--- A physical keyDown event.
--- @param keycode integer
--- @param flags table
--- @param autorepeat boolean|nil
--- @param properties table The stub's eventtap property ids.
local function key_down(keycode, flags, autorepeat, properties)
	return as_physical({
		getKeyCode = function() return keycode end,
		getFlags = function() return flags end,
		getProperty = function(_, property)
			if property == properties.keyboardEventAutorepeat then return autorepeat and 1 or 0 end
			return 0
		end,
	})
end

helpers.describe("shortcuts.actions.system: the tap-key tap (tap-keys)", function()
	helpers.it("consumes a plain tap and runs the decided action behind the callback", function()
		with_fixture(function()
			local sys, spy = make_sys_screenshot_spies()
			local ran = {}
			sys.bind_tap_keys(nil, function(keycode)
				if keycode == 27 then return function() ran[#ran + 1] = keycode return true end end
				return nil
			end)
			local properties = spy.hs.eventtap.event.properties
			local consume = spy.captured_cb(key_down(27, {}, false, properties))
			helpers.assert_eq(consume, true, "a plain tap of an assigned key must not reach the application")
			helpers.assert_eq(#ran, 0, "the action must not run inside the eventtap callback")
			run_screenshot_deferred(spy)
			helpers.assert_eq(#ran, 1, "the action runs once the callback has returned")
		end)
	end)

	helpers.it("lets modifiers, AltGr and unassigned keys through, and swallows auto-repeat", function()
		with_fixture(function()
			local sys, spy = make_sys_screenshot_spies()
			local decided, ran = 0, 0
			sys.bind_tap_keys(nil, function(keycode)
				decided = decided + 1
				if keycode == 24 then return function() ran = ran + 1 return true end end
				return nil
			end)
			local properties = spy.hs.eventtap.event.properties
			for _, flag in ipairs({ "cmd", "alt", "ctrl", "shift", "fn" }) do
				helpers.assert_true(not spy.captured_cb(key_down(24, { [flag] = true }, false, properties)),
					flag .. " keeps the key's own character")
			end
			helpers.assert_eq(decided, 0, "a modified press is never even decided")
			helpers.assert_true(not spy.captured_cb(key_down(27, {}, false, properties)),
				"an unassigned key types as usual")
			helpers.assert_eq(spy.captured_cb(key_down(24, {}, true, properties)), true,
				"an auto-repeat of a tapped key is consumed")
			helpers.assert_true(not pcall(run_screenshot_deferred, spy),
				"and queues nothing: no post-callback dispatcher was started")
			helpers.assert_eq(ran, 0, "holding the key cannot repeat the action")
		end)
	end)

	helpers.it("refuses a tap without a decision function", function()
		with_fixture(function()
			local sys = make_sys_screenshot_spies()
			local ok = pcall(sys.bind_tap_keys, nil, nil)
			helpers.assert_true(not ok, "a tap that could never decide must fail at bind time")
		end)
	end)
end)

helpers.describe("tap-key physical source claims", function()
	helpers.it("(tap-keys) publishes only acknowledged plain delivery and respects live admission", function()
		with_fixture(function()
			local sys, spy = make_sys_screenshot_spies()
			local admitted, ran = true, 0
			local owner = sys.bind_tap_keys(function() return admitted end, function(code)
				if code == 50 then return function() ran = ran + 1 return true end end
			end)
			helpers.assert_not_nil(owner)
			helpers.assert_true(sys.has_tap_key_claim(50, {}))
			helpers.assert_eq(sys.has_tap_key_claim(27, {}), false)
			for _, name in ipairs({ "shift", "ctrl", "alt", "cmd", "fn" }) do
				helpers.assert_eq(sys.has_tap_key_claim(50, { [name] = true }), false)
			end
			admitted = false
			helpers.assert_eq(sys.has_tap_key_claim(50, {}), false)
			helpers.assert_eq(spy.captured_cb(key_down(50, {}, false, spy.hs.eventtap.event.properties)), false)
			admitted = true
			helpers.assert_true(spy.captured_cb(key_down(50, {}, false, spy.hs.eventtap.event.properties)))
			run_screenshot_deferred(spy)
			helpers.assert_eq(ran, 1)
			-- A failed native stop retires logical delivery immediately; the exact
			-- owner remains available only for cleanup, never for input callbacks.
			helpers.assert_eq(owner:delete(), false)
			helpers.assert_eq(sys.has_tap_key_claim(50, {}), false)
			helpers.assert_eq(spy.captured_cb(key_down(50, {}, false, spy.hs.eventtap.event.properties)), false)
			helpers.assert_eq(ran, 1)
			owner.tap.isEnabled = function() return false end
			helpers.assert_true(owner:delete())
			helpers.assert_eq(sys.has_tap_key_claim(50, {}), false)
		end)
	end)

	helpers.it("(tap-keys) refused native acquisition never publishes a source claim or delivers", function()
		with_fixture(function()
			local sys, spy = make_sys_screenshot_spies()
			local callback
			spy.hs.eventtap.new = function(_, captured)
				callback = captured
				return { start = function() return false end, stop = function() return true end,
					isEnabled = function() return false end }
			end
			local ran = 0
			local owner = sys.bind_tap_keys(nil, function() return function() ran = ran + 1 return true end end)
			helpers.assert_nil(owner)
			helpers.assert_eq(sys.has_tap_key_claim(50, {}), false)
			helpers.assert_type(callback, "function")
			helpers.assert_eq(callback(key_down(50, {}, false, spy.hs.eventtap.event.properties)), false)
			helpers.assert_eq(ran, 0)
		end)
	end)
end)
