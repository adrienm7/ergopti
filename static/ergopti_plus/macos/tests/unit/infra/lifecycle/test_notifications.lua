--- tests/unit/infra/lifecycle/test_notifications.lua

--- ==============================================================================
--- MODULE: notifications Unit Tests
--- DESCRIPTION:
--- Verifies exact native dispatch commitment: only a constructed notification
--- whose send method returns its capability may report success. Constructor and
--- send failures return a causal error without a false "dispatched" log line.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local notifications = helpers.load_with_stubs("infra.notifications")




-- =====================================
-- =====================================
-- ======= 1/ notify behavior ==========
-- =====================================
-- =====================================

helpers.describe("notifications.notify", function()
	helpers.it("refuses nil input with an explicit result", function()
		local dispatched, detail = notifications.notify(nil)
		helpers.assert_eq(dispatched, false)
		helpers.assert_contains(detail, "title")
	end)

	helpers.it("invokes hs.notify.new with a single message", function()
		local captured = nil
		_G.hs.notify.new = function(arg1, arg2)
			captured = type(arg1) == "function" and arg2 or arg1
			local native = {}
			native.send = function() return native end
			return native
		end
		local dispatched, detail = notifications.notify("hello")
		helpers.assert_true(dispatched, tostring(detail))
		helpers.assert_eq(captured.title, "ErgoptiPlus")
		helpers.assert_eq(captured.informativeText, "hello")
	end)

	helpers.it("uses two-arg call as title + body", function()
		local captured = nil
		_G.hs.notify.new = function(arg1, arg2)
			captured = type(arg1) == "function" and arg2 or arg1
			local native = {}
			native.send = function() return native end
			return native
		end
		local dispatched, detail = notifications.notify("My title", "My body")
		helpers.assert_true(dispatched, tostring(detail))
		helpers.assert_eq(captured.title, "ErgoptiPlus — My title")
		helpers.assert_eq(captured.informativeText, "My body")
	end)

	helpers.it("(nui-004-notice-privacy) logs a dispatched notice by shape, never its text", function()
		local lines = {}
		local Logger = require("infra.logger")
		helpers.admit_logger_privacy(Logger)
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = line end)
		_G.hs.notify.new = function()
			local native = {}
			native.send = function() return native end
			return native
		end
		local dispatched = notifications.notify("Command failed", "stderr: token=SECRET-42", "error")
		Logger.set_sink(nil)
		helpers.assert_true(dispatched)
		local rendered = table.concat(lines, "\n")
		helpers.assert_contains(rendered, "Notification dispatched")
		helpers.assert_true(rendered:find("SECRET-42", 1, true) == nil,
			"a notification body can quote stderr meant for the user alone")
		helpers.assert_true(rendered:find("Command failed", 1, true) == nil)
	end)

	helpers.it("(nui-004-notice-privacy) the hs.notify bridge logs English metadata only", function()
		local source = assert(helpers.read_driver_unit("-- Global user-notification logging bridge."))
		local bridge = source:match("%-%- Global user%-notification logging bridge%.(.-)\nend\n")
		helpers.assert_true(bridge ~= nil, "the bridge is found")
		helpers.assert_true(bridge:find("sans titre", 1, true) == nil and bridge:find("utilisateur", 1, true) == nil,
			"driver logs are English")
		helpers.assert_true(bridge:find('Logger.info("notify", "User notification created: title %d byte(s), body %d byte(s).", #t, #b)', 1, true) ~= nil,
			"only the notice's shape is logged")
	end)

	helpers.it("(nui-006-notification-ttl) withdraws a notice after the registry's duration", function()
		local captured = nil
		_G.hs.notify.new = function(arg1, arg2)
			captured = type(arg1) == "function" and arg2 or arg1
			local native = {}
			native.send = function() return native end
			return native
		end
		helpers.assert_true(notifications.notify("hello"))
		helpers.assert_eq(captured.withdrawAfter, require("infra.timings").sec("ui", "notification_ttl_ms"),
			"one declaration in _shared/core/timing/data/constants.toml, shared with Linux")
		local source = assert(helpers.read_module_source("infra.notifications"))
		helpers.assert_true(source:find("RETENTION_SEC = 5", 1, true) == nil and source:find("withdrawAfter   = 5", 1, true) == nil, "no typed copy of the duration")
	end)

	helpers.it("returns false and never claims dispatch if hs.notify.new throws", function()
		local lines = {}
		local Logger = require("infra.logger")
		helpers.admit_logger_privacy(Logger)
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = line end)
		_G.hs.notify.new = function() error("boom") end
		local dispatched, detail = notifications.notify("hello")
		Logger.set_sink(nil)
		helpers.assert_eq(dispatched, false)
		helpers.assert_contains(detail, "boom")
		local rendered = table.concat(lines, "\n")
		helpers.assert_contains(rendered, "Notification construction failed")
		helpers.assert_true(rendered:find("Notification dispatched", 1, true) == nil,
			"a caught constructor failure must never produce a success diagnostic")
	end)

	helpers.it("returns false and never claims dispatch if native send refuses", function()
		local lines = {}
		local Logger = require("infra.logger")
		helpers.admit_logger_privacy(Logger)
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = line end)
		_G.hs.notify.new = function()
			return { send = function() return false end }
		end
		local dispatched, detail = notifications.notify("hello")
		Logger.set_sink(nil)
		helpers.assert_eq(dispatched, false)
		helpers.assert_contains(detail, "send failed")
		local rendered = table.concat(lines, "\n")
		helpers.assert_contains(rendered, "Notification send failed")
		helpers.assert_true(rendered:find("Notification dispatched", 1, true) == nil,
			"an explicit native refusal must never produce a success diagnostic")
	end)

	helpers.it("refuses malformed native notification receipts without raising (notification-bad-receipt)", function()
		local hostile = setmetatable({}, { __index = function() error("native lookup failed") end })
		for _, receipt in ipairs({ true, hostile }) do
			_G.hs.notify.new = function() return receipt end
			local called, dispatched, detail = pcall(notifications.notify, "hello")
			helpers.assert_true(called, "a malformed native receipt must remain a refusal")
			helpers.assert_eq(dispatched, false)
			helpers.assert_contains(detail, "no send capability")
		end
	end)

	helpers.it("routes notification-click callback failures into the logger", function()
		local click_callback = nil
		local activation_attempts = 0
		local original_focus = _G.hs.focus
		local original_lookup = _G.hs.application.applicationsForBundleID
		local original_get = _G.hs.application.get
		_G.hs.notify.new = function(callback)
			click_callback = callback
			local native = {}
			native.send = function() return native end
			return native
		end
		_G.hs.focus = function() error("injected global focus failure", 0) end
		_G.hs.application.applicationsForBundleID = function()
			activation_attempts = activation_attempts + 1
			error("injected application activation failure", 0)
		end
		-- The click must never reach the name lookup that falls back to a scan
		-- of every window (issue #99).
		_G.hs.application.get = function()
			error("hs.application.get searches every window when nothing matches", 0)
		end
		local lines = {}
		local Logger = require("infra.logger")
		helpers.admit_logger_privacy(Logger)
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = line end)
		local dispatched = notifications.notify("click me")
		helpers.assert_eq(dispatched, true)
		helpers.assert_type(click_callback, "function")
		click_callback()
		_G.hs.focus = original_focus
		_G.hs.application.applicationsForBundleID = original_lookup
		_G.hs.application.get = original_get
		Logger.set_sink(nil)

		helpers.assert_eq(activation_attempts, 1,
			"a failed global focus step must not skip the independent app fallback")
		local rendered = table.concat(lines, "\n")
		helpers.assert_contains(rendered, "Notification click global focus failed")
		helpers.assert_contains(rendered, "Notification click application activation failed")
	end)

	-- A notice that asks the user to act elsewhere (Login Items approval) opens
	-- that place on click instead of bringing the app to the front.
	helpers.it("runs a supplied click action instead of focusing the app", function()
		local click = nil
		_G.hs.notify.new = function(callback)
			click = callback
			local native = {}
			native.send = function() return native end
			return native
		end
		local focused, acted = 0, 0
		local original_focus = _G.hs.focus
		_G.hs.focus = function() focused = focused + 1 end
		local dispatched = notifications.notify("approve", nil, "warning", function() acted = acted + 1 end)
		helpers.assert_true(dispatched)
		click()
		_G.hs.focus = original_focus
		helpers.assert_eq(acted, 1, "the click action must run")
		helpers.assert_eq(focused, 0, "the app must not steal focus from the place the notice opens")
	end)

	helpers.it("does not redeliver an already retired notification click (notification-click-once)", function()
		local click
		_G.hs.notify.new = function(callback)
			click = callback
			local native = {}
			native.send = function() return native end
			return native
		end
		local actions = 0
		helpers.assert_true(notifications.notify("approve", nil, "warning", function() actions = actions + 1 end))
		click()
		click()
		helpers.assert_eq(actions, 1, "a retired notification must not repeat its action")
		local scheduler = require("core.events.timer_scheduler")
		local previous_after = scheduler.after
		local expire
		scheduler.after = function(_, callback) expire = callback; return {}, true end
		local ok, err = pcall(function()
			helpers.assert_true(notifications.notify("late", nil, "warning", function() actions = actions + 1 end))
			expire()
			click()
			helpers.assert_eq(actions, 1, "a queued click must not revive an expired owner")
		end)
		scheduler.after = previous_after
		if not ok then error(err, 0) end
	end)

	helpers.it("refuses a click action that is not a function", function()
		local dispatched, detail = notifications.notify("approve", nil, "warning", "open")
		helpers.assert_eq(dispatched, false)
		helpers.assert_contains(detail, "click action")
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ debugLog =================
-- =====================================
-- =====================================

helpers.describe("notifications.debugLog", function()
	helpers.it("is a no-op when DEBUG is false (default)", function()
		notifications.DEBUG = false
		local called = false
		_G.hs.console.printStyledtext = function(_) called = true end
		notifications.debugLog("hello")
		helpers.assert_eq(called, false)
	end)

	helpers.it("invokes console output when DEBUG is true", function()
		notifications.DEBUG = true
		local called = false
		_G.hs.console.printStyledtext = function(_) called = true end
		notifications.debugLog("hello")
		helpers.assert_eq(called, true)
		notifications.DEBUG = false
	end)

	helpers.it("survives and logs a styled-text crash", function()
		notifications.DEBUG = true
		_G.hs.console.printStyledtext = function() error("nope") end
		local lines = {}
		local Logger = require("infra.logger")
		helpers.admit_logger_privacy(Logger)
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = line end)
		notifications.debugLog("hello")
		Logger.set_sink(nil)
		helpers.assert_contains(table.concat(lines, "\n"),
			"Styled debug console output failed")
		notifications.DEBUG = false
	end)
end)
