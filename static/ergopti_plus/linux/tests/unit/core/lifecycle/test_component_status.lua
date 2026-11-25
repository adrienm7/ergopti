--- tests/unit/core/lifecycle/test_component_status.lua

--- ==============================================================================
--- MODULE: Component Status
--- DESCRIPTION:
--- A missing component was told through one timed notification, which KDE
--- Plasma 6 dropped without keeping it in its history (field report, Arch
--- Linux, 2026-11-25): the user saw a tray and "nothing works". These cases pin
--- that a reported problem is logged once, posted as a persistent notice, and
--- leads the tray menu as a red row whose click shows the explanation.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A problem as gui_stack reports it.
local PROBLEM = { code = "windows_lgi", label = "Windows unavailable", title = "Ergopti+ needs a component",
	body = "Install lua51-lgi: sudo pacman -S --needed lua51-lgi" }

helpers.describe("component_status: a problem stays visible", function()

	helpers.it("posts the problem once as a persistent error notice", function()
		local Status = helpers.load_module("core.ui.engine.component_status")
		local sent = {}
		local notifier = { send = function(body, opts) sent[#sent + 1] = { body = body, opts = opts } end }
		helpers.assert_true(Status.report(PROBLEM, { notifier = notifier }))
		helpers.assert_true(not Status.report(PROBLEM, { notifier = notifier }), "a second report is refused")
		helpers.assert_eq(#sent, 1)
		helpers.assert_eq(sent[1].body, PROBLEM.body)
		helpers.assert_true(sent[1].opts.persistent, "the notice stays until closed")
		helpers.assert_eq(sent[1].opts.level, "error")
		helpers.assert_true(Status.has("windows_lgi"))
	end)

	helpers.it("leads the tray menu with a red row that shows the explanation", function()
		local Status = helpers.load_module("core.ui.engine.component_status")
		helpers.assert_eq(#Status.tray_rows(function() end), 0, "no row when nothing is wrong")
		Status.report(PROBLEM, {})
		local shown
		local rows = Status.tray_rows(function(title, body) shown = { title, body } end)
		helpers.assert_eq(#rows, 2)
		helpers.assert_eq(rows[1].title, "🔴 Windows unavailable")
		helpers.assert_true(rows[2].separator)
		rows[1].fn()
		helpers.assert_eq(shown[1], PROBLEM.title)
		helpers.assert_eq(shown[2], PROBLEM.body)
	end)

	helpers.it("refuses a problem without its explanation", function()
		local Status = helpers.load_module("core.ui.engine.component_status")
		local ok = pcall(Status.report, { code = "x", label = "l", title = "t" })
		helpers.assert_true(not ok)
	end)

	helpers.it("the tray adapter publishes the rows before the menu", function()
		local source = assert(helpers.read_module_source("tray.adapters.menu"))
		helpers.assert_true(source:find('require("core.ui.engine.component_status").tray_rows(', 1, true) ~= nil,
			"replace_menu prepends the status rows")
	end)
end)
