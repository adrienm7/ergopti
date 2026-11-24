--- tests/unit/diagnostics/ui/field_check/test_field_report.lua

--- ==============================================================================
--- MODULE: In-App Field Report (macOS)
--- DESCRIPTION:
--- Débogage's « Lancer le field report (tous les tests) » on macOS:
--- 1. the shared report's contract (_shared/tests/lua/diagnostics/field_report_contract.lua);
--- 2. the row stands just before Tests and the builder routes it;
--- 3. a click hands the app's field run session its steps in-process and opens
---    the progress window, which follows each step and, when the run ends,
---    holds the report with each Tests row title, the rows a person runs
---    separately and the results folder; a second click brings the window back,
---    a busy session and a missing session only notify; without a window the
---    run goes on and its report opens in the one-click checks' dialog.
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
	local session = { cancelled = 0 }
	function session:cancel_in_app()
		self.cancelled = self.cancelled + 1
		return true
	end
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
		local world = { notes = {}, pushed = {}, copies = {}, windows = 0, alerts = {}, fronts = 0 }
		local services = {
			notify = function(_, text) table.insert(world.notes, text) end,
			alert = function(title, text)
				table.insert(world.alerts, { title = title, text = text })
				return "close"
			end,
			after = function(_, fn) fn() end,
			bring_to_front = function() world.fronts = world.fronts + 1; return true end,
			session = function() if session then return session end return nil, "no folder" end,
			coverage = function() return { points = { { id = "lease_117_140", checks = { { step = "field_lease" } } } } } end,
			window = function(owner)
				world.windows = world.windows + 1
				if world.refuse_window then return false end
				world.owner = owner
				owner.bind({
					push = function(message) table.insert(world.pushed, message); return true end,
					close = function() world.closed = true end,
				})
				return true
			end,
			effects = {
				open_folder = function(dir, done) world.folder = dir; done(true) end,
				copy = function(text) table.insert(world.copies, text); return true end,
				issue = function(line, text, done) world.issue = { line = line, text = text }; done(true) end,
			},
		}
		body(Window, services, world)
	end)
end

helpers.describe("field report: the macOS run", function()
	helpers.it("opens the progress window, follows each step and holds the report once the run ends", function()
		local session = fake_session()
		with_report(session, function(Window, services, world)
			helpers.assert_true(Window.run_field_report(services))
			helpers.assert_eq(world.windows, 1)
			helpers.assert_eq(#world.notes, 0, "the window replaces the start notice")
			helpers.assert_true(not Window.run_field_report(services), "a second click starts nothing")
			helpers.assert_eq(world.fronts, 1, "a second click brings the window back")
			helpers.assert_eq(#world.notes, 0)
			session.observer.step_started(1, { id = "field_lease", check = "lease" })
			world.owner.on_ready()
			local init = world.pushed[1]
			helpers.assert_eq(init.type, "init")
			helpers.assert_eq(init.open_key, "field_report.open_finder")
			helpers.assert_eq(init.steps[1].title, "[menu.debug.field_check_lease]")
			helpers.assert_eq(init.steps[1].state, "running", "the step started before the page loaded")
			helpers.assert_eq(init.steps[2].title, "key_accounting")
			helpers.assert_eq(init.not_run[1].id, "guided_menus")
			session.observer.step_recorded(1, {}, { step = "field_lease", verdict = "pass", codes = {},
				report = { check = "lease", passed = true, steps = { { id = "cli_present", state = "pass" } } } })
			helpers.assert_eq(world.pushed[2].state, "pass")
			session.observer.step_started(2, { id = "key_accounting", check = "typing_selftest" })
			session.observer.step_recorded(2, {}, { step = "key_accounting", verdict = "fail", codes = { "fail_x" },
				report = { check = "typing_selftest", passed = false, steps = { { id = "x", state = "fail" } } } })
			session.observer.finished({ request_id = "app-1", interrupted = false }, "/Users/u/fr/results/app-1")
			local done = world.pushed[#world.pushed]
			helpers.assert_eq(done.type, "done")
			helpers.assert_eq(done.passed, false)
			helpers.assert_eq(done.folder, "/Users/u/fr/results/app-1")
			world.owner.on_action("copy")
			local text = world.copies[1]
			helpers.assert_contains(text, "[field_check.all.verdict_fail]")
			helpers.assert_contains(text, "✅ [menu.debug.field_check_lease] — field_lease, lease_117_140\n    ✅ [field_check.step.cli_present]")
			helpers.assert_contains(text, "❌ key_accounting\n    ❌ x")
			helpers.assert_contains(text, "➖ guided_menus : [field_check.all.reason.needs_person]")
			-- The key accounting row's own check needs a person; the run's typing self-test does not replace the row
			helpers.assert_contains(text, "[field_check.all.separate_header]\n➖ [menu.debug.field_check_key_accounting]")
			helpers.assert_contains(text, "saved /Users/u/fr/results/app-1")
			world.owner.on_action("open_folder")
			helpers.assert_eq(world.folder, "/Users/u/fr/results/app-1")
			world.owner.on_action("issue")
			helpers.assert_eq(world.issue.text, text)
			helpers.assert_contains(world.issue.line, "check=field_report verdict=fail request=app-1")
			helpers.assert_eq(#world.alerts, 0, "the report stays in its window")
			helpers.assert_eq(session.cancelled, 0)
			helpers.assert_true(Window.run_field_report(services), "a finished run can start again")
		end)
	end)

	helpers.it("cancels the run when its window closes during it", function()
		local session = fake_session()
		with_report(session, function(Window, services, world)
			helpers.assert_true(Window.run_field_report(services))
			world.owner.on_action("close")
			helpers.assert_eq(session.cancelled, 1, "closing the window during the run cancels it")
			helpers.assert_true(world.closed)
			session.observer.finished({ request_id = "app-1", interrupted = true }, "/Users/u/fr/results/app-1")
			helpers.assert_eq(#world.alerts, 0, "a window the person closed opens no dialog")
		end)
	end)

	helpers.it("without a window, goes on and shows its report in the dialog", function()
		local session = fake_session()
		with_report(session, function(Window, services, world)
			world.refuse_window = true
			helpers.assert_true(Window.run_field_report(services))
			helpers.assert_eq(world.notes[1], "[field_check.all.started]2")
			helpers.assert_true(not Window.run_field_report(services))
			helpers.assert_eq(world.fronts, 0, "no window to bring back")
			helpers.assert_eq(world.notes[2], "[field_check.busy]")
			session.observer.finished({ request_id = "app-1", interrupted = false }, "/Users/u/fr/results/app-1")
			helpers.assert_eq(#world.alerts, 1)
			helpers.assert_eq(world.alerts[1].title, "[menu.debug.field_report]")
			helpers.assert_contains(world.alerts[1].text, "saved /Users/u/fr/results/app-1")
			helpers.assert_eq(session.cancelled, 0)
		end)
	end)

	helpers.it("only notifies when the session is busy or none can start", function()
		with_report(fake_session("busy"), function(Window, services, world)
			helpers.assert_true(not Window.run_field_report(services))
			helpers.assert_eq(world.notes[1], "[field_check.busy]")
			helpers.assert_true(Window.run_field_report({ notify = services.notify, session = function() return nil, "x" end,
				coverage = services.coverage }) == false)
			helpers.assert_eq(world.notes[2], "[field_check.all.unavailable]")
			helpers.assert_eq(world.windows, 0, "no window opens for a refused run")
		end)
	end)
end)
