--- tests/unit/diagnostics/ui/field_check/test_field_report.lua

--- ==============================================================================
--- MODULE: In-App Field Report (Linux)
--- DESCRIPTION:
--- Débogage's « Lancer le field report (tous les tests) » on Linux:
--- 1. the shared report's contract (_shared/tests/lua/diagnostics/field_report_contract.lua);
--- 2. the Debug menu routes the row to this module, and every check of the
---    field run has its Tests row title;
--- 3. a click hands the daemon's field run session its steps in-process and,
---    when the run ends, shows one report from a fresh loop turn with the
---    results folder; a second click, a busy session and a daemon with no
---    session only say so.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.diagnostics.field_report_contract")(helpers)

helpers.describe("field report: the Linux row", function()
	helpers.it("is routed by the Debug menu, and each field run check names its Tests row title", function()
		local handle = assert(io.open(helpers.driver_root() .. "/diagnostics/ui/menu_debug.lua", "rb"))
		local source = handle:read("*a")
		handle:close()
		helpers.assert_contains(source,
			'[COMMAND.FIELD_REPORT] = function() require("diagnostics.ui.field_check.field_report").run() end,')
		local FieldRun = require("diagnostics.engine.field_run.field_run")
		for check, module in pairs(FieldRun.CHECK_RUNNERS) do
			helpers.assert_type(require(module).title_key, "string", "the " .. check .. " check has no title")
		end
	end)
end)

--- A session double that records the observer and lets the test settle the run.
local function fake_session(answer)
	local session = { observer = nil }
	function session:submit_in_app(observer)
		if answer then return nil, answer end
		self.observer = observer
		return { request_id = "app-1", dir = "/run/fr/results/app-1",
			steps = { { id = "field_network", kind = "field_check", check = "network" } },
			not_run = { { step = "driver_reload", reason = "needs_collector" } } }
	end
	return session
end

--- Loads the module over scripted services.
local function with_report(session, body)
	local saved = package.loaded["diagnostics.ui.field_check.field_report"]
	package.loaded["diagnostics.ui.field_check.field_report"] = nil
	local Ui = require("diagnostics.ui.field_check.field_report")
	Ui._reset()
	local world = { notes = {}, dialogs = {}, copies = {}, deferred = {} }
	local services = {
		translate = function(key)
			if key == "common.label_value" then return "{1} : {2}" end
			if key == "field_check.all.started" then return "started {1}" end
			if key == "field_check.all.saved_in" then return "saved {1}" end
			return "[" .. key .. "]"
		end,
		notify = function(message) table.insert(world.notes, message) end,
		dialog = function(title, text) table.insert(world.dialogs, { title = title, text = text }); return true end,
		copy = function(text) table.insert(world.copies, text); return true end,
		defer = function(fn) table.insert(world.deferred, fn) end,
		session = function() return session end,
		coverage = function() return { points = { { id = "pac_real", checks = { { step = "field_network" } } } } } end,
		title_key = function(check) return check == "network" and "menu.debug.field_check_network" or nil end,
	}
	local ok, err = pcall(body, Ui, services, world)
	Ui._reset()
	package.loaded["diagnostics.ui.field_check.field_report"] = saved
	if not ok then error(err, 0) end
end

helpers.describe("field report: the Linux run", function()
	helpers.it("hands the session its steps and shows one report with the folder once the run ends", function()
		local session = fake_session()
		with_report(session, function(Ui, services, world)
			helpers.assert_true(Ui.run(services))
			helpers.assert_eq(world.notes[1], "started 1")
			helpers.assert_true(not Ui.run(services), "a second click starts nothing")
			helpers.assert_eq(world.notes[2], "[field_check.busy]")
			session.observer.step_started(1, { id = "field_network", check = "network" })
			session.observer.step_recorded(1, {}, { step = "field_network", verdict = "pass", codes = {},
				report = { check = "network", passed = true, steps = { { id = "probe", state = "pass" } } } })
			session.observer.finished({ request_id = "app-1", interrupted = false }, "/run/fr/results/app-1")
			helpers.assert_true(not Ui.is_running())
			helpers.assert_eq(#world.dialogs, 0, "the report opens from a fresh loop turn")
			world.deferred[1]()
			helpers.assert_eq(world.dialogs[1].title, "[menu.debug.field_report]")
			local text = world.dialogs[1].text
			helpers.assert_contains(text, "[field_check.all.verdict_pass]")
			helpers.assert_contains(text, "✅ [menu.debug.field_check_network] — field_network, pac_real")
			helpers.assert_contains(text, "➖ driver_reload : [field_check.all.reason.needs_collector]")
			helpers.assert_contains(text, "saved /run/fr/results/app-1")
			helpers.assert_eq(world.copies[1], text)
			helpers.assert_true(Ui.run(services), "a finished run can start again")
		end)
	end)

	helpers.it("only says so when the session is busy or the daemon has none", function()
		with_report(fake_session("busy"), function(Ui, services, world)
			helpers.assert_true(not Ui.run(services))
			helpers.assert_eq(world.notes[1], "[field_check.busy]")
			helpers.assert_true(not Ui.is_running(), "a refused run leaves nothing pending")
		end)
		with_report(nil, function(Ui, services, world)
			helpers.assert_true(not Ui.run(services))
			helpers.assert_eq(world.notes[1], "[field_check.all.unavailable]")
		end)
	end)
end)
