--- tests/unit/platform/remap/test_runtime_recovery_consumers.lua

--- Native inert admission boundaries; frozen independent expectations.

local helpers = require("tests.helpers")
local fixture = require("tests.support.runtime_recovery_fixture")
local with_source, settled_scope, hold_settings = fixture.with_source, fixture.settled_scope, fixture.hold_settings
local OWNED = '[karabiner]\nruntime = "owned"\nintegration_enabled = true\n[future]\nrevision = 29\n'

helpers.describe("inert recovery complete local consumer boundary", function()
	for _, name in ipairs({ "start_gesture_watcher", "start_cycle_windows_hotkey",
		"start_alt_tab_windows_hotkey", "start_alt_tab_monitor_hotkey", "start_alt_tab_apps_hotkey" }) do
		helpers.it("revokes before genuine consumer entry: " .. name, function()
			with_source(OWNED, function(remap)
				local scope = settled_scope(remap)
				local watchers = require("platform.remap.watchers")
				pcall(watchers[name])
				helpers.assert_eq(scope.current(), false)
				helpers.assert_eq(remap.teardown_local(), true)
				helpers.assert_nil(remap.runtime_recovery_admission(), "exported consumer custody needs a new module lifetime")
			end)
		end)
	end
	for _, name in ipairs({ "stop_gesture_watcher", "stop_alt_tab_apps_tracker" }) do
		helpers.it("revokes after exact consumer stop port replacement: " .. name, function()
			with_source(OWNED, function(remap)
				local scope = settled_scope(remap)
				local watchers = require("platform.remap.watchers")
				local original = watchers[name]; watchers[name] = function() return true end
				helpers.assert_eq(scope.current(), false)
				watchers[name] = original
				helpers.assert_eq(scope.current(), false)
			end)
		end)
	end
	for _, field in ipairs({ "watcher", "hotkey_cycle_windows", "hotkey_alt_tab_apps" }) do
		helpers.it("revokes after retained local state handle appears: " .. field, function()
			with_source(OWNED, function(remap)
				local scope = settled_scope(remap)
				local state
				for index = 1, 20 do
					local name, value = debug.getupvalue(remap.runtime_recovery_admission, index)
					if name == "_state" then state = value; break end
				end
				helpers.assert_eq(type(state), "table")
				state[field] = {}
				helpers.assert_eq(scope.current(), false)
				state[field] = nil
				helpers.assert_eq(scope.current(), false)
			end)
		end)
	end
end)
