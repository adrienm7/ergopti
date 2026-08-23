--- tests/unit/modules/gestures/test_kickstart_respects_pause.lua

--- ==============================================================================
--- MODULE: Regression — kickstart_hid must not act while the script is paused
--- DESCRIPTION:
--- CoreState.enabled is the FEATURE flag; CoreState.suspended is the pause. The
--- timer entry points check both, but the wake/unlock sibling had no gate at all,
--- so it still warped the cursor and posted a synthetic scroll while suspended.
---
--- ROOT CAUSE ENCODED:
--- One async sibling omitted the shared enabled+suspended invariant. The
--- maintainer states "pause = everything off", and a cursor that jumps during a
--- pause is the most visible possible way to break it.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("gestures: the HID kickstart is silent while paused", function()

	helpers.it("the timer guard sites consult the suspend flag, not only the feature flag", function()
		local src = helpers.read_driver_source("kickstart_hid")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the gestures source must be readable or this asserts nothing")

		-- Every guard preceding a kickstart must mention the pause flag. Counting
		-- rather than matching one spelling: the point is that NO site is left
		-- checking the feature flag alone.
		local weak = 0
		for line in src:gmatch("[^\n]+") do
			if line:find("if not CoreState.enabled then return end", 1, true) then
				weak = weak + 1
			end
		end
		helpers.assert_eq(weak, 0,
			"a guard that checks only CoreState.enabled lets the kickstart warp the cursor and "
			.. "post a synthetic scroll during a pause; the pause flag is CoreState.suspended")
	end)

	helpers.it("the real wake callback performs no HID action while suspended", function()
		local reset_modules = {
			"modules.gestures.init", "modules.gestures.engine",
			"modules.gestures.actions", "modules.gestures.conflicts",
			"infra.notifications", "infra.logger", "infra.manifest_reader",
			"infra.timings", "hs._asm.undocumented.touchdevice",
			"hs.caffeinate.watcher",
		}
		for _, name in ipairs(reset_modules) do
			package.loaded[name] = nil
		end
		_G.ERGOPTI_TOUCH_DEVICES = {}
		_G.ERGOPTI_TOUCH_WATCHERS = {}
		_G.ERGOPTI_SLEEP_WATCHER = nil
		_G.ERGOPTI_GESTURE_PRIMER = nil

		package.loaded["tests.stubs.hs"] = nil
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		local cursor_writes = 0
		local scroll_posts = 0
		hs_stub.mouse.absolutePosition = function(position)
			if position ~= nil then cursor_writes = cursor_writes + 1 end
			return position or { x = 10, y = 20 }
		end
		hs_stub.eventtap.event.newScrollWheelEvent = function()
			return {
				post = function() scroll_posts = scroll_posts + 1 end,
			}
		end
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub

		local function noop() end
		local function committed() return true end
		package.loaded["infra.notifications"] = { notify = noop }
		package.loaded["infra.logger"] = setmetatable({
			pcall = function(_, fn, ...) return pcall(fn, ...) end,
		}, { __index = function() return noop end })
		package.loaded["infra.manifest_reader"] = {
			default_for = function() return false end,
		}
		package.loaded["infra.timings"] = {
			sec = function() return 1 end,
		}
		package.loaded["modules.gestures.engine"] = setmetatable({
			init           = committed,
			stop           = committed,
			unblock_scroll = committed,
		}, { __index = function() return noop end })
		package.loaded["modules.gestures.actions"] = setmetatable({
			init                 = committed,
			force_cleanup        = committed,
			resume_after_cleanup = committed,
			AX_NAMES             = {},
			SG_NAMES             = {},
		}, { __index = function() return noop end })
		package.loaded["modules.gestures.conflicts"] = setmetatable({}, {
			__index = function() return noop end,
		})
		package.loaded["hs._asm.undocumented.touchdevice"] = {
			devices = function() return {} end,
		}

		local wake_callback = nil
		local wake_module = {
			systemDidWake = 1,
			screensDidUnlock = 2,
			new = function(callback)
				wake_callback = callback
				return { start = committed, stop = committed }
			end,
		}
		package.loaded["hs.caffeinate.watcher"] = wake_module

		local gestures = require("modules.gestures.init")
		gestures.start()
		helpers.assert_type(wake_callback, "function",
			"the test must drive the production callback registered with the wake watcher")
		gestures.suspend()
		local cursor_baseline = cursor_writes
		local scroll_baseline = scroll_posts

		wake_callback(wake_module.systemDidWake)
		wake_callback(wake_module.screensDidUnlock)

		helpers.assert_eq(cursor_writes, cursor_baseline,
			"wake/unlock must not move the cursor while gestures are suspended")
		helpers.assert_eq(scroll_posts, scroll_baseline,
			"wake/unlock must not post synthetic scroll input while gestures are suspended")
		gestures.stop()
		for _, name in ipairs(reset_modules) do package.loaded[name] = nil end
		package.loaded["hs"] = nil
		_G.ERGOPTI_TOUCH_DEVICES = nil
		_G.ERGOPTI_TOUCH_WATCHERS = nil
		_G.ERGOPTI_SLEEP_WATCHER = nil
		_G.ERGOPTI_GESTURE_PRIMER = nil
	end)

end)
