--- tests/unit/modules/gestures/test_actions_fixture_scope.lua

--- ==============================================================================
--- MODULE: Gesture Actions Fixture Isolation
--- DESCRIPTION:
--- Verifies exact cache restoration and native rebinding across fixture outcomes.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")

local function snapshot()
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	return saved
end

local function with_observer(callback)
	local saved, native = snapshot(), rawget(_G, "hs")
	local loader = helpers.load_with_stubs
	local outcome = table.pack(xpcall(callback, debug.traceback))
	helpers.load_with_stubs = loader
	for name in pairs(package.loaded) do
		if saved[name] == nil then package.loaded[name] = nil end
	end
	for name, value in pairs(saved) do package.loaded[name] = value end
	_G.hs = native
	if not outcome[1] then error(outcome[2], 0) end
end

helpers.describe("Gesture actions fixture ownership", function()
	for _, initial in ipairs({ "absent", "false", "existing" }) do
		for _, mode in ipairs({ "success", "callback failure", "construction failure" }) do
			helpers.it("(gesture-fixture-scope) restores " .. initial .. " owners after " .. mode, function()
				with_observer(function()
					local sentinel
					if initial == "false" then sentinel = false end
					if initial == "existing" then sentinel = {} end
					for _, name in ipairs({ "modules.gestures.actions", "infra.notifications",
						"adapters.timer_scheduler", "_generated.gesture_emit_actions", "hs", "hs.timer",
						"ui.menu.gesture_fixture_unrelated" }) do
						package.loaded[name] = sentinel
					end
					_G.hs = sentinel
					local expected = snapshot()
					local marker = "injected gesture fixture failure"
					local loader = helpers.load_with_stubs
					local constructions = 0
					helpers.load_with_stubs = function(...)
						local result = loader(...)
						constructions = constructions + 1
						if mode == "construction failure" then error(marker, 0) end
						return result
					end
					local outcome = table.pack(pcall(Fixture.with_fixture, function(fresh, with_features)
						local actions, calls = fresh()
						helpers.assert_type(actions.execute_single, "function")
						with_features(actions, calls, function(shortcuts, gestures)
							helpers.assert_type(shortcuts, "table")
							helpers.assert_type(gestures, "table")
						end)
						if mode == "callback failure" then error(marker, 0) end
						return "completed", nil, false
					end))
					helpers.load_with_stubs = loader
					helpers.assert_eq(constructions, 1, "failure follows real native construction")
					helpers.assert_eq(outcome[1], mode == "success")
					if mode == "success" then
						helpers.assert_eq(outcome.n, 4)
						helpers.assert_eq(outcome[2], "completed")
						helpers.assert_nil(outcome[3])
						helpers.assert_eq(outcome[4], false)
					else
						helpers.assert_true(tostring(outcome[2]):find(marker, 1, true) ~= nil)
					end
					helpers.assert_true(rawequal(rawget(_G, "hs"), sentinel), "restore native identity")
					for name, value in pairs(expected) do
						helpers.assert_true(rawequal(package.loaded[name], value), "restore cache identity: " .. name)
					end
					for name in pairs(package.loaded) do
						helpers.assert_true(expected[name] ~= nil, "no new cache residue: " .. name)
					end
				end)
			end)
		end
	end

	helpers.it("(gesture-fixture-scope) rebinds real consumers on every construction", function()
		with_observer(function()
			Fixture.with_fixture(function(fresh)
				local previous_timer, previous_notifications
				for attempt = 1, 2 do
					local _, calls = fresh()
					local timer = require("adapters.timer_scheduler")
					local notifications = require("infra.notifications")
					local clock_reads, notification_creations = 0, 0
					calls.hs.timer.secondsSinceEpoch = function()
						clock_reads = clock_reads + 1
						return attempt * 101
					end
					calls.hs.notify.new = function()
						notification_creations = notification_creations + 1
						return nil
					end
					helpers.assert_eq(timer.now(), attempt * 101)
					helpers.assert_eq(clock_reads, 1)
					helpers.assert_eq(notifications.notify("fixture probe"), false)
					helpers.assert_eq(notification_creations, 1)
					if attempt == 2 then
						helpers.assert_true(timer ~= previous_timer)
						helpers.assert_true(notifications ~= previous_notifications)
					end
					previous_timer, previous_notifications = timer, notifications
				end
			end)
		end)
	end)

	helpers.it("(gesture-fixture-scope) rejects escaped constructors after scope closure", function()
		with_observer(function()
			local fresh, with_features = Fixture.with_fixture(function(load, feature) return load, feature end)
			for _, callback in ipairs({ fresh, with_features }) do
				local ok, reason = pcall(callback)
				helpers.assert_eq(ok, false)
				helpers.assert_true(tostring(reason):find("no longer active", 1, true) ~= nil)
			end
		end)
	end)
end)
