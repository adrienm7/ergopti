--- tests/unit/lib/test_notifications.lua

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
		helpers.assert_eq(captured.title, "Ergopti+")
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
		helpers.assert_eq(captured.title, "My title")
		helpers.assert_eq(captured.informativeText, "My body")
	end)

	helpers.it("returns false and never claims dispatch if hs.notify.new throws", function()
		local lines = {}
		local Logger = require("infra.logger")
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

	helpers.it("routes notification-click callback failures into the logger", function()
		local click_callback = nil
		local activation_attempts = 0
		local original_focus = _G.hs.focus
		local original_get = _G.hs.application.get
		_G.hs.notify.new = function(callback)
			click_callback = callback
			local native = {}
			native.send = function() return native end
			return native
		end
		_G.hs.focus = function() error("injected global focus failure", 0) end
		_G.hs.application.get = function()
			activation_attempts = activation_attempts + 1
			error("injected application activation failure", 0)
		end
		local lines = {}
		local Logger = require("infra.logger")
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = line end)
		local dispatched = notifications.notify("click me")
		helpers.assert_eq(dispatched, true)
		helpers.assert_type(click_callback, "function")
		click_callback()
		_G.hs.focus = original_focus
		_G.hs.application.get = original_get
		Logger.set_sink(nil)

		helpers.assert_eq(activation_attempts, 1,
			"a failed global focus step must not skip the independent app fallback")
		local rendered = table.concat(lines, "\n")
		helpers.assert_contains(rendered, "Notification click global focus failed")
		helpers.assert_contains(rendered, "Notification click application activation failed")
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
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = line end)
		notifications.debugLog("hello")
		Logger.set_sink(nil)
		helpers.assert_contains(table.concat(lines, "\n"),
			"Styled debug console output failed")
		notifications.DEBUG = false
	end)
end)
