--- tests/unit/modules/keylogger/test_context_tracker_ax_focused_element_pcall.lua

--- ==============================================================================
--- MODULE: Regression — update_ax_observer guards AXFocusedUIElement read (F-HIGH-27)
--- DESCRIPTION:
--- Every other AX access inside M.update_ax_observer is pcall-wrapped —
--- observer creation, applicationElement, addWatcher, AXValue reads — except
--- the bootstrap `app_element:attributeValue("AXFocusedUIElement")` read. Since
--- update_ax_observer is invoked from an hs.application.watcher callback (which
--- reports uncaught errors only to the HS Console, never surfacing them to the
--- user or crashing loudly), a throw here silently left the new app's AX
--- observer permanently unattached — no secure-field detection, no autocorrect
--- tracking — for the rest of that app's session.
---
--- Fix: wrap the AXFocusedUIElement read in the same pcall pattern as its
--- neighbors. On failure, `focused` is treated as nil (same as "no focused
--- element yet") and the function proceeds to attach the observer and set
--- _state.ax_observer regardless.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The tracker now requires a pause predicate: its writers must be silent
--- while the script is paused. These scenarios exercise the RUNNING state.
local function NOT_PAUSED() return false end

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

--- Builds an hs override that stubs hs.axuielement with an application element
--- whose AXFocusedUIElement attributeValue() read throws.
--- @return table hs_overrides suitable for helpers.load_with_stubs.
local function make_throwing_ax_overrides()
	local fake_observer = {
		addWatcher   = function() end,
		callback     = function() end,
		start        = function() end,
		stop         = function() end,
	}
	local fake_app_element = {
		attributeValue = function(_self, attr)
			if attr == "AXFocusedUIElement" then
				error("simulated AX crash reading AXFocusedUIElement")
			end
			return nil
		end,
	}
	return {
		axuielement = {
			observer = {
				new = function(_pid) return fake_observer end,
			},
			applicationElement = function(_pid) return fake_app_element end,
		},
	}
end





-- =================================================================================
-- =================================================================================
-- ======= 1/ update_ax_observer survives a throwing AXFocusedUIElement read =======
-- =================================================================================
-- =================================================================================

helpers.describe("context_tracker: update_ax_observer guards AXFocusedUIElement (F-HIGH-27)", function()

	helpers.it("does not propagate when AXFocusedUIElement throws, and still sets _state.ax_observer", function()
		package.loaded["modules.keylogger.context_tracker"] = nil
		local CT = helpers.load_with_stubs("modules.keylogger.context_tracker", make_throwing_ax_overrides())

		local core_state = {}
		CT.init(core_state, {}, NOT_PAUSED)

		local ok, err = pcall(CT.update_ax_observer, 12345)

		helpers.assert_true(ok, "update_ax_observer must not propagate an error from a throwing AX read")
		helpers.assert_nil(err, "and must report no error — this runs on the focus watcher, "
			.. "so one escaping error takes the whole context tracker down")
		helpers.assert_true(core_state.ax_observer ~= nil,
			"_state.ax_observer must still be set to a valid observer despite the AX read failing")
	end)

	helpers.it("still works normally (non-regression) when AXFocusedUIElement succeeds", function()
		package.loaded["modules.keylogger.context_tracker"] = nil
		local fake_focused = {
			attributeValue = function(_self, attr)
				if attr == "AXValue" then return "some text" end
				return nil
			end,
		}
		local fake_observer = {
			addWatcher = function() end,
			callback   = function() end,
			start      = function() end,
			stop       = function() end,
		}
		local fake_app_element = {
			attributeValue = function(_self, attr)
				if attr == "AXFocusedUIElement" then return fake_focused end
				return nil
			end,
		}
		local hs_overrides = {
			axuielement = {
				observer = { new = function(_pid) return fake_observer end },
				applicationElement = function(_pid) return fake_app_element end,
			},
		}
		local CT = helpers.load_with_stubs("modules.keylogger.context_tracker", hs_overrides)

		local core_state = {}
		CT.init(core_state, {}, NOT_PAUSED)

		local ok, err = pcall(CT.update_ax_observer, 6789)

		helpers.assert_true(ok, "update_ax_observer must succeed when the AX read succeeds")
		helpers.assert_nil(err, "the happy-path control for the throwing case above")
		helpers.assert_true(core_state.ax_observer ~= nil, "_state.ax_observer must be set on the success path")
	end)
end)





-- ===========================================================================
-- ===========================================================================
-- ======= 2/ Source pin: the AXFocusedUIElement read is pcall-wrapped =======
-- ===========================================================================
-- ===========================================================================

helpers.describe("context_tracker: source pins the AXFocusedUIElement pcall guard (F-HIGH-27)", function()

	helpers.it("the AXFocusedUIElement read inside update_ax_observer is wrapped in pcall", function()
		-- Selected by a declaration unique to modules/keylogger/context_tracker.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function update_secure_field_state")
		helpers.assert_true(src ~= nil, "modules/keylogger/context_tracker.lua source must be locatable")

		local fn_start = src:find("function M.update_ax_observer", 1, true)
		helpers.assert_true(fn_start ~= nil, "update_ax_observer must still exist")
		local fn_end = src:find("\nend\n", fn_start)
		local body = src:sub(fn_start, fn_end or (fn_start + 3000))

		helpers.assert_true(
			body:find('pcall(function() return app_element:attributeValue("AXFocusedUIElement") end)', 1, true) ~= nil,
			"the AXFocusedUIElement read must be wrapped in pcall like every other AX call in this function"
		)
	end)

	helpers.it("keylogger uses the guarded ProcessLifecycle application watcher", function()
		-- Selected by a declaration unique to modules/keylogger/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local init_src = helpers.read_driver_source("local function ensure_browser_window_filter")
		helpers.assert_true(init_src ~= nil, "modules/keylogger/init.lua source must be locatable")

		helpers.assert_true(
			init_src:find("ProcessLifecycle.onAppActivate", 1, true) ~= nil
				and init_src:find("ProcessLifecycle.start()", 1, true) ~= nil,
			"keylogger must register application activation through ProcessLifecycle"
		)

		-- Selected by a declaration unique to adapters/process_lifecycle.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local adapter_src = helpers.read_driver_source("function M.getForegroundApp")
		helpers.assert_true(adapter_src ~= nil, "adapters/process_lifecycle.lua source must be locatable")
		local guard_pos = adapter_src:find("pcall(function()", 1, true)
		local watcher_pos = adapter_src:find("_app_watcher = hs.application.watcher.new", 1, true)
		helpers.assert_true(
			guard_pos ~= nil and watcher_pos ~= nil and guard_pos < watcher_pos,
			"ProcessLifecycle must create hs.application.watcher inside a pcall guard"
		)
	end)
end)
