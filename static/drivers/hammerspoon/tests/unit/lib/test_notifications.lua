--- tests/unit/lib/test_notifications.lua

--- ==============================================================================
--- MODULE: notifications Unit Tests
--- DESCRIPTION:
--- Verifies the notification wrapper's defensive behavior: nil titles are
--- ignored, the dispatch path catches errors via pcall, and debugLog respects
--- the DEBUG flag.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local notifications = helpers.load_with_stubs("lib.notifications")




-- =====================================
-- =====================================
-- ======= 1/ notify behavior ==========
-- =====================================
-- =====================================

helpers.describe("notifications.notify", function()
	helpers.it("returns silently for nil input", function()
		notifications.notify(nil)
	end)

	helpers.it("invokes hs.notify.new with a single message", function()
		local captured = nil
		_G.hs.notify.new = function(opts) captured = opts ; return { send = function() end } end
		notifications.notify("hello")
		helpers.assert_eq(captured.title, "Ergopti+")
		helpers.assert_eq(captured.informativeText, "hello")
	end)

	helpers.it("uses two-arg call as title + body", function()
		local captured = nil
		_G.hs.notify.new = function(opts) captured = opts ; return { send = function() end } end
		notifications.notify("My title", "My body")
		helpers.assert_eq(captured.title, "My title")
		helpers.assert_eq(captured.informativeText, "My body")
	end)

	helpers.it("does not crash if hs.notify.new throws", function()
		_G.hs.notify.new = function() error("boom") end
		notifications.notify("hello")
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

	helpers.it("survives a styled-text crash", function()
		notifications.DEBUG = true
		_G.hs.console.printStyledtext = function() error("nope") end
		notifications.debugLog("hello")
		notifications.DEBUG = false
	end)
end)
