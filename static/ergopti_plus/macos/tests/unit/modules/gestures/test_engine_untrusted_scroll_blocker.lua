--- tests/unit/modules/gestures/test_engine_untrusted_scroll_blocker.lua

--- ==============================================================================
--- MODULE: Regression — an untrusted scroll blocker is deferred, not an error
--- DESCRIPTION:
--- The gestures module initializes its engine when it is first required, which
--- is before boot checks the Accessibility permission. An untrusted process gets
--- an eventtap that never enables, so on a first launch the scroll blocker could
--- not start and the engine logged an ERROR. gestures start() initializes the
--- engine again once the permission is granted, so that state is expected.
---
--- ROOT CAUSE ENCODED:
--- The packaged app's launch gate fails on any [ERROR] line: the first launch of
--- a fresh install, before onboarding, reported this expected state as an error.
--- A tap that does not enable while Accessibility IS granted stays an error.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh engine whose eventtaps never enable and whose logger records.
--- @param trusted boolean|nil What hs.accessibilityState reports.
--- @return table engine, table logged { level = { messages } }
local function load_engine(trusted)
	package.loaded["modules.gestures.engine"] = nil
	package.loaded["adapters.accessibility_permission"] = nil
	package.loaded["infra.logger"] = nil
	local Logger = helpers.load_with_stubs("infra.logger")
	local logged = { error = {}, warn = {} }
	Logger.error = function(_, fmt, ...) table.insert(logged.error, string.format(fmt, ...)) end
	Logger.warn = function(_, fmt, ...) table.insert(logged.warn, string.format(fmt, ...)) end
	local Engine = helpers.load_with_stubs("modules.gestures.engine")
	_G.hs.eventtap.__reset()
	local original_new = _G.hs.eventtap.new
	_G.hs.eventtap.new = function(types, fn)
		local tap = original_new(types, fn)
		tap.start = function(self) return self end
		tap.isEnabled = function() return false end
		return tap
	end
	_G.hs.accessibilityState = function() return trusted end
	return Engine, logged
end

local function actions()
	return {
		execute_single = function() return true end,
		execute_axis = function() return true end,
		set_gesture_in_progress = function() end,
	}
end

local function state()
	return { enabled = true, ga = {}, modes = {}, sensitivities = {} }
end




-- ===============================================
-- ===============================================
-- ======= 1/ Untrusted versus trusted ===========
-- ===============================================
-- ===============================================

helpers.describe("Engine.init(): a scroll blocker that does not enable", function()
	helpers.it("is deferred with a warning while Accessibility is not granted", function()
		local Engine, logged = load_engine(false)
		helpers.assert_eq(Engine.init(state(), actions()), false,
			"the engine stays uninitialized so gestures start() retries it")
		helpers.assert_eq(#logged.error, 0,
			"an untrusted first launch is no error: " .. table.concat(logged.error, " | "))
		helpers.assert_eq(#logged.warn, 1, "the deferral is still reported")
		_G.hs.accessibilityState = nil
	end)

	helpers.it("stays an error while Accessibility is granted", function()
		local Engine, logged = load_engine(true)
		helpers.assert_eq(Engine.init(state(), actions()), false)
		helpers.assert_eq(#logged.error, 1,
			"a tap that does not enable despite the permission is a real failure")
		_G.hs.accessibilityState = nil
	end)
end)
