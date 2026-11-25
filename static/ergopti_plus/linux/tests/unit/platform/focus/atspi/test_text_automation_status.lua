--- tests/unit/platform/focus/atspi/test_text_automation_status.lua

--- ==============================================================================
--- MODULE: Text Automation Status Tests (Linux)
--- DESCRIPTION:
--- Field report, KDE Plasma 6.8 Wayland, 2026-11-25: hotstrings were withheld
--- with no log line, no tray row and no diagnostics fact. These tests pin each
--- surface: the summary the diagnostics page shows, the one log line per
--- reason, and the red component_status row of a lasting condition only.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh status module with a recording component_status double.
--- @return table Status, table reports, table logger
local function fresh()
	local logger = helpers.make_logger_stub()
	package.loaded["core.logger.engine.shim"] = logger
	package.loaded["platform.focus.text_automation_status"] = nil
	local Status = require("platform.focus.text_automation_status")
	local reports = {}
	Status._set_dependencies_for_test({
		report = function(problem) reports[#reports + 1] = problem; return true end,
	}, function(key) return "<" .. key .. ">" end)
	return Status, reports
end

helpers.describe("text automation status", function()
	local previous_logger = package.loaded["core.logger.engine.shim"]

	helpers.it("(text-automation-visible) summarises open and closed with the guard's reason", function()
		local Status = fresh()
		helpers.assert_nil(Status.summary(), "unbound reads unknown")
		local state = { mode = "window", reason = "no_accessible_window" }
		Status.bind(function() return state end)
		helpers.assert_eq({ Status.summary() }, { "open", "no_accessible_window" })
		state = { mode = "field", reason = "field_admitted" }
		helpers.assert_eq({ Status.summary() }, { "open", "field_admitted" })
		state = { mode = "closed", reason = "password_field" }
		helpers.assert_eq({ Status.summary() }, { "closed", "password_field" })
		helpers.assert_eq(pcall(Status.bind, function() return state end), false, "a second bind is refused")
	end)

	helpers.it("(text-automation-visible) a lasting window-mode reason becomes one red tray row", function()
		local Status, reports = fresh()
		local rebuilt = 0
		Status.set_notice_listener(function() rebuilt = rebuilt + 1 end)
		Status.publish("window", "no_accessible_window")
		helpers.assert_eq(Status.tick(0), false, "not yet lasting")
		helpers.assert_true(Status.tick(1e12), "five seconds later it is named")
		helpers.assert_eq(#reports, 1)
		helpers.assert_eq(reports[1].code, "text_automation_no_accessible_window")
		helpers.assert_eq(reports[1].label, "<startup.linux_text_unchecked_label>")
		helpers.assert_eq(reports[1].body, "<startup.linux_text_reason_no_accessible_window>")
		helpers.assert_eq(rebuilt, 1)
		helpers.assert_eq(Status.tick(2e12), false, "named once")
		helpers.assert_true(reports[1].active(), "shown while it holds")
		Status.publish("field", "field_admitted")
		helpers.assert_eq(reports[1].active(), false, "hidden once a field verdict is back")
	end)

	helpers.it("(text-automation-visible) the tray waits the registry's notice delay, not a typed one", function()
		local previous_clock = package.loaded["core.logger.engine.monotonic"]
		package.loaded["core.logger.engine.monotonic"] = { now_ms = function() return 1000 end }
		local loaded, Status, reports = pcall(fresh)
		package.loaded["core.logger.engine.monotonic"] = previous_clock
		helpers.assert_true(loaded, tostring(Status))
		local after_ms = require("core.timing.engine.timings").ms("privacy", "text_automation_notice_after_ms")
		helpers.assert_true(after_ms > 0, "the registry holds a positive delay")
		Status.publish("window", "no_accessible_window")
		helpers.assert_eq(Status.tick(1000 + after_ms - 1), false, "one millisecond short of the delay")
		helpers.assert_true(Status.tick(1000 + after_ms), "named once the delay has passed")
		helpers.assert_eq(#reports, 1)
	end)

	helpers.it("(text-automation-visible) a closed condition that withholds everything is named", function()
		local Status, reports = fresh()
		Status.publish("closed", "no_detector")
		helpers.assert_true(Status.tick(1e12))
		helpers.assert_eq(reports[1].label, "<startup.linux_text_closed_label>")
	end)

	helpers.it("(text-automation-visible) transient and by-design reasons never reach the tray", function()
		local Status, reports = fresh()
		for _, reason in ipairs({ "password_field", "protected_context", "settling", "context_pending" }) do
			Status.publish("closed", reason)
			helpers.assert_eq(Status.tick(1e12), false, reason)
		end
		helpers.assert_eq(#reports, 0)
	end)

	helpers.it("(text-automation-visible) a KWin that does not run the focus script is one red row", function()
		local Status, reports = fresh()
		helpers.assert_eq(Status.check_desktop_focus(nil), false, "unknown yet")
		helpers.assert_eq(Status.check_desktop_focus("loaded"), false)
		helpers.assert_true(Status.check_desktop_focus("not_loaded"))
		helpers.assert_eq(Status.check_desktop_focus("unanswered"), false, "named once")
		helpers.assert_eq(#reports, 1)
		helpers.assert_eq(reports[1].code, "kwin_focus_script")
		helpers.assert_eq(reports[1].body, "<startup.linux_kwin_script_body>")
	end)

	package.loaded["core.logger.engine.shim"] = previous_logger
	package.loaded["platform.focus.text_automation_status"] = nil
end)
