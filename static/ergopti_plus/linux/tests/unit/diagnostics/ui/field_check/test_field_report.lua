--- tests/unit/diagnostics/ui/field_check/test_field_report.lua

--- ==============================================================================
--- MODULE: In-App Field Report (Linux)
--- DESCRIPTION:
--- Débogage's « Lancer le field report (tous les tests) » on Linux:
--- 1. the shared report's contract (_shared/tests/lua/diagnostics/field_report_contract.lua);
--- 2. the Debug menu routes the row to this module, and every check of the
---    field run has its Tests row title;
--- 3. a click hands the daemon's field run session its steps in-process and
---    opens the field report window, which receives each step's state, then
---    the summary; its buttons copy the report, open the folder and create the
---    issue; Stop, Close and the close box cancel the run;
--- 4. without a window the finished report opens in the one-click dialog; a
---    busy session and a daemon with no session only say so.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.diagnostics.field_report_contract")(helpers)

helpers.describe("field report: the Linux row", function()
	helpers.it("is routed by the Debug menu, and each field run check names its Tests row title", function()
		local source = assert(helpers.read_module_source("diagnostics.ui.menu_debug"))
		helpers.assert_contains(source,
			'[COMMAND.FIELD_REPORT] = function() require("diagnostics.ui.field_check.field_report").run() end,')
		helpers.assert_eq(require("core.ui.ui.webkit_host").bridge_for_app("field_report"), "field_report",
			"the window's page owns its bridge")
		local FieldRun = require("diagnostics.engine.field_run.field_run")
		for check, module in pairs(FieldRun.CHECK_RUNNERS) do
			helpers.assert_type(require(module).title_key, "string", "the " .. check .. " check has no title")
		end
	end)
end)

--- A session double that records the observer and lets the test settle the run.
local function fake_session(answer)
	local session = { observer = nil, cancelled = 0 }
	function session:submit_in_app(observer)
		if answer then return nil, answer end
		self.observer = observer
		return { request_id = "app-1", dir = "/run/fr/results/app-1",
			steps = { { id = "field_network", kind = "field_check", check = "network" },
				{ id = "field_composer", kind = "field_check", check = "composer" } },
			not_run = { { step = "driver_reload", reason = "needs_collector" } } }
	end
	function session:cancel_in_app()
		self.cancelled = self.cancelled + 1
		self.observer.finished({ request_id = "app-1", interrupted = true }, "/run/fr/results/app-1")
		return true
	end
	return session
end

--- The messages a window received, decoded.
local function received(world)
	local Json = require("core.text.engine.json")
	local messages = {}
	for _, js in ipairs(world.js) do
		table.insert(messages, Json.decode(js:match("receiveFieldReport%((.*)%)$")))
	end
	return messages
end

--- Loads the module over scripted services.
local function with_report(session, body, opts)
	opts = opts or {}
	local saved = package.loaded["diagnostics.ui.field_check.field_report"]
	package.loaded["diagnostics.ui.field_check.field_report"] = nil
	local Ui = require("diagnostics.ui.field_check.field_report")
	Ui._reset()
	local world = { notes = {}, dialogs = {}, copies = {}, deferred = {}, js = {}, shown = 0, hidden = 0, fronts = 0,
		opened = {}, issues = {} }
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
		locale = function() return "fr" end,
		window = {
			show = function(app) world.shown = world.shown + 1; world.app = app; return opts.windowless ~= true end,
			hide = function() world.hidden = world.hidden + 1; return true end,
			bring_to_front = function() world.fronts = world.fronts + 1; return true end,
			eval_js = function(_, js) table.insert(world.js, js); return true end,
		},
		open_folder = function(dir, done) table.insert(world.opened, dir); done({ ok = true }); return {} end,
		issue = function(line, text, done) table.insert(world.issues, { line = line, text = text }); done(true) end,
	}
	local ok, err = pcall(body, Ui, services, world)
	Ui._reset()
	package.loaded["diagnostics.ui.field_check.field_report"] = saved
	if not ok then error(err, 0) end
end

--- Plays a run through: the first step passes, the second fails.
local function settle(session)
	session.observer.step_started(1, { id = "field_network", check = "network" })
	session.observer.step_recorded(1, {}, { step = "field_network", verdict = "pass", codes = {},
		report = { check = "network", passed = true, steps = { { id = "probe", state = "pass" } } } })
	session.observer.step_started(2, { id = "field_composer", check = "composer" })
	session.observer.step_recorded(2, {}, { step = "field_composer", verdict = "fail", codes = { "probe_fail" } })
	session.observer.finished({ request_id = "app-1", interrupted = false }, "/run/fr/results/app-1")
end

helpers.describe("field report: the Linux window", function()
	helpers.it("opens the window, which follows each step, then the summary (field-report-window)", function()
		local session = fake_session()
		with_report(session, function(Ui, services, world)
			helpers.assert_true(Ui.run(services))
			helpers.assert_eq(world.app, "field_report")
			helpers.assert_eq(#world.notes, 0, "the window itself says the run started")
			session.observer.step_started(1, { id = "field_network", check = "network" })
			-- The page asks once loaded: it gets the steps with their state so far
			Ui.on_message("ready")
			local messages = received(world)
			local init = messages[#messages]
			helpers.assert_eq(init.type, "init")
			helpers.assert_eq(init.open_key, "field_report.open_files")
			helpers.assert_eq(init.steps[1], { id = "field_network", title = "[menu.debug.field_check_network]",
				state = "running" })
			helpers.assert_eq(init.steps[2], { id = "field_composer", title = "field_composer", state = "pending" })
			helpers.assert_eq(init.not_run, { { id = "driver_reload", reason = "needs_collector" } })
			helpers.assert_true(not Ui.run(services), "a second click starts nothing")
			helpers.assert_eq(world.fronts, 1, "it brings the window back")
			helpers.assert_eq(Ui.on_message({ action = "copy" }).ok, false, "nothing to copy before the end")
			settle(session)
			messages = received(world)
			helpers.assert_eq(messages[#messages - 1], { type = "step", id = "field_composer", state = "fail" })
			local done = messages[#messages]
			helpers.assert_eq(done.type, "done")
			helpers.assert_eq(done.passed, false)
			helpers.assert_eq(done.counts, { pass = 1, fail = 1 })
			helpers.assert_eq(done.folder, "/run/fr/results/app-1")
			helpers.assert_true(not Ui.is_running())
			helpers.assert_eq(#world.dialogs, 0, "the window replaces the dialog")
		end)
	end)

	helpers.it("copies the report, opens the folder and creates the issue (field-report-window)", function()
		local session = fake_session()
		with_report(session, function(Ui, services, world)
			Ui.run(services)
			settle(session)
			local answer = Ui.on_message({ action = "copy" })
			helpers.assert_eq(answer, { type = "action", action = "copy", ok = true })
			helpers.assert_contains(world.copies[1], "✅ [menu.debug.field_check_network] — field_network, pac_real")
			helpers.assert_contains(world.copies[1], "saved /run/fr/results/app-1")
			helpers.assert_eq(Ui.on_message({ action = "open_folder" }), nil, "the opener answers later")
			helpers.assert_eq(world.opened, { "/run/fr/results/app-1" }, "only the run's own folder")
			helpers.assert_eq(received(world)[#received(world)], { type = "action", action = "open_folder", ok = true })
			Ui.on_message({ action = "issue" })
			helpers.assert_eq(world.issues[1].text, world.copies[1])
			helpers.assert_contains(world.issues[1].line, "check=field_report verdict=fail request=app-1")
			helpers.assert_eq(received(world)[#received(world)], { type = "action", action = "issue", ok = true })
			helpers.assert_eq(Ui.on_message({ action = "open_folder", path = "/etc" }), nil)
			helpers.assert_eq(world.opened[2], "/run/fr/results/app-1", "a path from the page is ignored")
			helpers.assert_eq(Ui.on_message({ action = "rm" }), nil, "an unknown action is refused")
			Ui.on_message({ action = "close" })
			helpers.assert_eq(session.cancelled, 0, "closing a finished run cancels nothing")
			helpers.assert_eq(world.hidden, 1)
			helpers.assert_true(Ui.run(services), "a finished run can start again")
		end)
	end)

	helpers.it("Stop, Close and the close box cancel the run (field-report-window)", function()
		for _, close in ipairs({ "cancel", "close", "box" }) do
			local session = fake_session()
			with_report(session, function(Ui, services, world)
				Ui.run(services)
				if close == "box" then Ui.on_window_closed(1) else Ui.on_message({ action = close }) end
				helpers.assert_eq(session.cancelled, 1, close .. " stops the run")
				helpers.assert_true(not Ui.is_running())
				if close == "cancel" then
					local done = received(world)[#received(world)]
					helpers.assert_eq(done.interrupted, true, "Stop leaves the summary of the interrupted run")
				end
				helpers.assert_eq(#world.dialogs + #world.deferred, 0, close .. ": no dialog after the window")
			end)
		end
	end)

	helpers.it("shows the report in the dialog without a window (field-report-window)", function()
		local session = fake_session()
		with_report(session, function(Ui, services, world)
			helpers.assert_true(Ui.run(services))
			helpers.assert_eq(world.notes[1], "started 2", "without the window a notice says the run started")
			settle(session)
			helpers.assert_eq(#world.js, 0)
			world.deferred[1]()
			helpers.assert_eq(world.dialogs[1].title, "[menu.debug.field_report]")
			helpers.assert_contains(world.dialogs[1].text, "➖ driver_reload : [field_check.all.reason.needs_collector]")
		end, { windowless = true })
	end)

	helpers.it("holds a run that ends before its request is known (field-report-window)", function()
		local session = fake_session()
		local submit = session.submit_in_app
		function session:submit_in_app(observer)
			local run = submit(self, observer)
			observer.finished({ request_id = "app-1", interrupted = false }, run.dir)
			return run
		end
		with_report(session, function(Ui, services, world)
			helpers.assert_true(Ui.run(services))
			Ui.on_message("ready")
			local messages = received(world)
			helpers.assert_eq(messages[#messages].type, "done", "the page gets the end it missed")
		end)
	end)

	helpers.it("only says so when the session is busy or the daemon has none", function()
		with_report(fake_session("busy"), function(Ui, services, world)
			helpers.assert_true(not Ui.run(services))
			helpers.assert_eq(world.notes[1], "[field_check.busy]")
			helpers.assert_true(not Ui.is_running(), "a refused run leaves nothing pending")
			helpers.assert_eq(world.shown, 0)
		end)
		with_report(nil, function(Ui, services, world)
			helpers.assert_true(not Ui.run(services))
			helpers.assert_eq(world.notes[1], "[field_check.all.unavailable]")
		end)
	end)
end)
