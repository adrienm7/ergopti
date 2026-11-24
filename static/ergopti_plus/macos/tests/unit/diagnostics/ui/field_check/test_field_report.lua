--- tests/unit/diagnostics/ui/field_check/test_field_report.lua

--- ==============================================================================
--- MODULE: In-App Field Report (macOS)
--- DESCRIPTION:
--- Débogage's « Lancer le field report (tous les tests) » on macOS:
--- 1. the shared report's contract (_shared/tests/lua/diagnostics/field_report_contract.lua);
--- 2. the row stands just before Tests and the builder routes it;
--- 3. a click hands the app's field run session its steps in-process and, when
---    the run ends, shows one report with each Tests row title, the rows a
---    person runs separately and the results folder; a second click, a busy
---    session and a missing session only notify.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

require("tests.lua.diagnostics.field_report_contract")(helpers)

local MODULES = { "core.logger.engine.logger", "core.i18n.engine.i18n", "diagnostics.ui.field_check" }

local function read_json(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return Json.decode(text)
end

helpers.describe("field report: the macOS row", function()
	helpers.it("stands just before Tests and is routed by the builder", function()
		local manifest = read_json(helpers.shared("menu/data/menu_manifest.json"))
		local at
		for index, row in ipairs(manifest.debug_menu) do if row.id == "field_report" then at = index end end
		helpers.assert_not_nil(at, "the Debug menu declares the field report row")
		helpers.assert_eq(manifest.debug_menu[at + 1].id, "debug_tests")
		local builder = assert(helpers.read_driver_unit('require("diagnostics.ui.field_check").run('))
		helpers.assert_contains(builder,
			'[COMMAND.FIELD_REPORT] = function() require("diagnostics.ui.field_check").run_field_report() end')
	end)
end)

--- A session double that records the observer.
local function fake_session(answer)
	local session = {}
	function session:submit_in_app(observer)
		if answer then return nil, answer end
		self.observer = observer
		return { request_id = "app-1", dir = "/Users/u/fr/results/app-1",
			steps = {
				{ id = "field_lease", kind = "field_check", check = "lease" },
				{ id = "key_accounting", kind = "field_check", check = "typing_selftest" },
			},
			not_run = { { step = "guided_menus", reason = "needs_person" } } }
	end
	return session
end

--- Loads the window over scripted services.
local function with_report(session, body)
	helpers.with_stub_scope(MODULES, function()
		package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
		package.loaded["core.i18n.engine.i18n"] = {
			get = function(key)
				if key == "common.label_value" then return "{1} : {2}" end
				if key == "field_check.all.saved_in" then return "saved {1}" end
				return "[" .. key .. "]"
			end,
			format = function(key, ...) return "[" .. key .. "]" .. table.concat({ ... }, ",") end,
		}
		package.loaded["diagnostics.ui.field_check"] = nil
		local Window = require("diagnostics.ui.field_check")
		Window._reset()
		local world = { notes = {}, alerts = {}, copies = {} }
		local services = {
			notify = function(_, text) table.insert(world.notes, text) end,
			alert = function(title, text, copy)
				table.insert(world.alerts, { title = title, text = text })
				return copy
			end,
			copy = function(text) table.insert(world.copies, text); return true end,
			after = function(_, fn) fn() end,
			session = function() if session then return session end return nil, "no folder" end,
			coverage = function() return { points = { { id = "lease_117_140", checks = { { step = "field_lease" } } } } } end,
		}
		body(Window, services, world)
	end)
end

helpers.describe("field report: the macOS run", function()
	helpers.it("hands the session its steps and shows one report once the run ends", function()
		local session = fake_session()
		with_report(session, function(Window, services, world)
			helpers.assert_true(Window.run_field_report(services))
			helpers.assert_eq(world.notes[1], "[field_check.all.started]2")
			helpers.assert_true(not Window.run_field_report(services), "a second click starts nothing")
			helpers.assert_eq(world.notes[2], "[field_check.busy]")
			session.observer.step_started(1, { id = "field_lease", check = "lease" })
			session.observer.step_recorded(1, {}, { step = "field_lease", verdict = "pass", codes = {},
				report = { check = "lease", passed = true, steps = { { id = "cli_present", state = "pass" } } } })
			session.observer.step_started(2, { id = "key_accounting", check = "typing_selftest" })
			session.observer.step_recorded(2, {}, { step = "key_accounting", verdict = "fail", codes = { "fail_x" },
				report = { check = "typing_selftest", passed = false, steps = { { id = "x", state = "fail" } } } })
			session.observer.finished({ request_id = "app-1", interrupted = false }, "/Users/u/fr/results/app-1")
			helpers.assert_eq(#world.alerts, 1)
			local alert = world.alerts[1]
			helpers.assert_eq(alert.title, "[menu.debug.field_report]")
			helpers.assert_contains(alert.text, "[field_check.all.verdict_fail]")
			helpers.assert_contains(alert.text, "✅ [menu.debug.field_check_lease] — field_lease, lease_117_140\n    ✅ [field_check.step.cli_present]")
			helpers.assert_contains(alert.text, "❌ key_accounting\n    ❌ x")
			helpers.assert_contains(alert.text, "➖ guided_menus : [field_check.all.reason.needs_person]")
			-- The key accounting row's own check needs a person; the run's typing self-test does not replace the row
			helpers.assert_contains(alert.text, "[field_check.all.separate_header]\n➖ [menu.debug.field_check_key_accounting]")
			helpers.assert_contains(alert.text, "saved /Users/u/fr/results/app-1")
			helpers.assert_eq(world.copies[1], alert.text)
			helpers.assert_true(Window.run_field_report(services), "a finished run can start again")
		end)
	end)

	helpers.it("only notifies when the session is busy or none can start", function()
		with_report(fake_session("busy"), function(Window, services, world)
			helpers.assert_true(not Window.run_field_report(services))
			helpers.assert_eq(world.notes[1], "[field_check.busy]")
			helpers.assert_true(Window.run_field_report({ notify = services.notify, session = function() return nil, "x" end,
				coverage = services.coverage }) == false)
			helpers.assert_eq(world.notes[2], "[field_check.all.unavailable]")
		end)
	end)
end)
