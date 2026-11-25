--- diagnostics/ui/field_check/init.lua

--- ==============================================================================
--- MODULE: Field Check Window
--- DESCRIPTION:
--- The Debug menu's one-click Mac checks: a click runs the check
--- (diagnostics/engine/field_check/field_check.lua over the real ports), writes the evidence line to the
--- log and shows the result, one line per step, with a « Copy report » button.
---
--- FEATURES & RATIONALE:
--- 1. One click, no arguments: the menu row names the check; nothing else is
---    asked of the user. The key accounting check says once, in a
---    notification, that it watches the keyboard, and that it keeps counts only.
--- 2. The same text goes to the window and the clipboard, built from the same
---    privacy-safe result as the log line.
--- 3. Localized: every sentence comes from the locales, step values included
---    (field_check.value.*, _shared/diagnostics/engine/field_check/report.lua
---    display_value); counts and versions are shown as they are.
--- 4. « Lancer le field report » runs this app's own field run in-app in the
---    shared progress window (diagnostics/ui/field_check/field_report_window.lua,
---    M.run_field_report): each step as it goes, then the report, its folder in
---    Finder, the report on the clipboard and the GitHub issue form. Without a
---    window the finished report opens in the dialog above, as on Linux.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local I18n = require("core.i18n.engine.i18n")
local Engine = require("diagnostics.engine.field_check.field_check")
local FieldReport = require("diagnostics.engine.field_check.field_report")
local FieldReportProgress = require("diagnostics.ui.field_check.field_report_progress")

local LOG = "diagnostics.ui.field_check"

--- Menu row id → check identity and window title key.
M.ROWS = {
	field_check_lease = { check = "lease", title = "menu.debug.field_check_lease" },
	field_check_owned_runtime = { check = "owned_runtime", title = "menu.debug.field_check_owned_runtime" },
	field_check_toolchain = { check = "toolchain", title = "menu.debug.field_check_toolchain" },
	field_check_login_items = { check = "login_items", title = "menu.debug.field_check_login_items" },
	field_check_key_accounting = { check = "key_accounting", title = "menu.debug.field_check_key_accounting", watches_keys = true },
}

--- Rows every driver shows (declared for all platforms in the shared manifest), as
--- opposed to the Mac-only ones above.
M.SHARED_ROWS = {
	field_check_network = { check = "network", title = "menu.debug.field_check_network" },
	composer_check = { check = "composer", title = "menu.debug.composer_check" },
}

--- The « Lancer le field report » row and the title of its report (the row's own label).
M.FIELD_REPORT_ROW = require("settings.engine.keys").COMMAND.FIELD_REPORT
M.FIELD_REPORT_TITLE = "menu.debug." .. M.FIELD_REPORT_ROW

--- Reads and decodes one bundled JSON declaration; a missing or broken file raises.
--- @param path string|nil Absolute path.
--- @return table
local function read_json(path)
	assert(type(path) == "string", "field check: a declaration path is unresolved")
	local value, err = require("core.fs.adapters.json_codec").decode_file(path)
	assert(type(value) == "table", "field check: unreadable declaration: " .. tostring(err))
	return value
end

--- This app's field run session for the in-app run: the running one, or one
--- started on demand on the installed folder.
--- @return table|nil session, string|nil error
local function in_app_session()
	return require("diagnostics.engine.field_run.field_run").start_in_app({})
end

--- The TODO-tests coverage of this driver's field run steps.
--- @return table coverage
local function coverage()
	local source = debug.getinfo(1, "S").source or ""
	local root = assert((source:sub(1, 1) == "@" and source:sub(2) or source):match("^(.*)/diagnostics/ui/field_check/init%.lua$"),
		"field check: the driver root is unresolved")
	return read_json(root .. "/diagnostics/data/field_todo_coverage.json")
end

--- Native services, replaceable by tests.
local function native()
	return {
		ports = function() return require("diagnostics.adapters.field_check_ports").new() end,
		notify = function(title, body, kind)
			return require("platform.focus.application_notifier").send(title, { body = body, kind = kind })
		end,
		alert = function(...) return require("core.ui.engine.dialog_util").block_alert(...) end,
		copy = function(text) return hs.pasteboard.setContents(text) end,
		after = function(seconds, fn) return require("core.events.timer_scheduler").after(seconds, fn) end,
		session = in_app_session,
		coverage = coverage,
		window = function(owner) return require("diagnostics.ui.field_check.field_report_window").open(owner) end,
		bring_to_front = function() return require("diagnostics.ui.field_check.field_report_window").bring_to_front() end,
		effects = {
			open_folder = function(dir, done)
				require("core.process.adapters.shell_runner").open(dir, done)
			end,
			copy = function(text) return require("clipboard.adapters.clipboard").write(text) == true end,
			issue = function(line, text, done)
				return require("diagnostics.ui.healthcheck.report").report_field_run(line, text, nil, done)
			end,
		},
	}
end

--- Shows a finished report from a fresh turn, with « Copy report » and « Close ».
--- @param env table Native services.
--- @param title_key string Locale key of the window title.
--- @param text string The report text.
local function show_report(env, title_key, text)
	-- A modal dialog is shown from a fresh turn, not from the port callback.
	env.after(require("core.timing.engine.timings").sec("ui", "ui_handoff_ms"), function()
		local copy_label, close_label = I18n.get("field_check.copy"), I18n.get("field_check.close")
		local clicked = env.alert(I18n.get(title_key), text, copy_label, close_label)
		if clicked == copy_label then
			local ok = env.copy(text)
			Logger.info(LOG, "Report copy %s.", ok and "done" or "refused")
			if ok then env.notify(I18n.get(title_key), I18n.get("field_check.copied"), "info") end
		end
	end)
end

--- Runs the check of a Debug menu row.
--- @param row_id string A key of M.ROWS.
--- @param services table|nil Test doubles for native services.
--- @return boolean started
function M.run(row_id, services)
	local row = M.ROWS[row_id] or M.SHARED_ROWS[row_id]
	assert(row ~= nil, "field check: unknown menu row " .. tostring(row_id))
	local env = services or native()
	if Engine.is_running() then
		env.notify(I18n.get(row.title), I18n.get("field_check.busy"), "warn")
		return false
	end
	if row.watches_keys then
		env.notify(I18n.get(row.title), I18n.get("field_check.keys_prompt"), "info")
	end
	return Engine.run(row.check, env.ports(), function(result)
		show_report(env, row.title, Engine.format_text(result, I18n.get))
	end)
end

-- True while the in-app field report runs, and whether its window opened.
local _report_running = false
local _report_windowed = false

--- The Tests rows a person runs alone: a row whose check no step of the run takes.
--- @param steps table The steps the in-app run takes.
--- @return table rows { {row} }
local function separate_rows(steps)
	local taken = {}
	for _, step in ipairs(steps) do taken[step.check] = true end
	local rows = {}
	for id, row in pairs(M.ROWS) do
		if not taken[row.check] then rows[#rows + 1] = { row = id } end
	end
	table.sort(rows, function(a, b) return a.row < b.row end)
	return rows
end

--- The Tests row title of a check, or nil for a developer field run check.
--- @param check string|nil
--- @return string|nil key
local function title_key_of(check)
	for _, rows in ipairs({ M.ROWS, M.SHARED_ROWS }) do
		for _, row in pairs(rows) do
			if row.check == check then return row.title end
		end
	end
	return nil
end

--- Débogage's « Lancer le field report (tous les tests) »: hands this app's
--- field run session (diagnostics/engine/field_run/field_run.lua; started on
--- demand on the installed folder when no clone opened one) its steps
--- in-process and shows them in the progress window as they go; when the run
--- ends, the window shows the report (_shared/diagnostics/engine/field_check/field_report.lua)
--- and its evidence line is written. Nothing is committed or pushed: the
--- window names the folder of the result files.
--- @param services table|nil Test doubles for native services.
--- @return boolean started
function M.run_field_report(services)
	local env = services or native()
	if _report_running then
		Logger.warn(LOG, "The field report refused: it is still running.")
		if not (_report_windowed and env.bring_to_front()) then
			env.notify(I18n.get(M.FIELD_REPORT_TITLE), I18n.get("field_check.busy"), "warn")
		end
		return false
	end
	local session, why = env.session()
	if session == nil then
		Logger.error(LOG, "The field report cannot run: no field run session (%s).", tostring(why))
		env.notify(I18n.get(M.FIELD_REPORT_TITLE), I18n.get("field_check.all.unavailable"), "warn")
		return false
	end
	local coverage = env.coverage()
	local results, checks = {}, {}
	-- A step reads as the Tests row that also runs its check alone, else its id
	local function title_of(check)
		local key = title_key_of(check)
		return key and I18n.get(key) or nil
	end
	local window = FieldReportProgress.new({
		open_key = "field_report.open_finder",
		title_of = function(step) return title_of(step.check) end,
		cancel = function() return session:cancel_in_app() end,
		effects = env.effects,
		logger = Logger,
		log = LOG,
	})
	-- Whether the window opened: without it the end shows the report in a dialog
	local windowed = false
	_report_running = true
	Logger.start(LOG, "In-app field report started…")
	-- Declared first: the observer reads the run the session hands back
	local run
	run, why = session:submit_in_app({
		step_started = function(_, step)
			checks[step.id] = step.check
			window.started(step)
		end,
		step_recorded = function(_, step, result)
			results[#results + 1] = result
			window.recorded(result.step or step.id, result.verdict)
		end,
		finished = function(done, dir)
			_report_running = false
			local summary = FieldReport.summary({ results = results, not_run = run.not_run,
				separate = separate_rows(run.steps), coverage = coverage, done = done, dir = dir })
			Logger.evidence(LOG, "Field report result: %s", FieldReport.format_log_line(summary))
			Logger.success(LOG, "In-app field report finished: %s.",
				summary.interrupted and "interrupted" or summary.passed and "pass" or "fail")
			local text = FieldReport.format_text(summary, I18n.get, function(step) return title_of(checks[step]) end)
			window.finished(summary, text)
			if not windowed then
				Logger.warn(LOG, "The field report window is not open; the report opens in a dialog.")
				show_report(env, M.FIELD_REPORT_TITLE, text)
			end
		end,
	})
	if run == nil then
		_report_running = false
		Logger.warn(LOG, "The field report refused by the field run session: %s.", tostring(why))
		env.notify(I18n.get(M.FIELD_REPORT_TITLE),
			I18n.get(why == "busy" and "field_check.busy" or "field_check.all.unavailable"), "warn")
		return false
	end
	window.attach(run)
	windowed = env.window(window) == true
	_report_windowed = windowed
	if not windowed then
		Logger.warn(LOG, "The field report window could not open; the run goes on without it.")
		env.notify(I18n.get(M.FIELD_REPORT_TITLE), I18n.format("field_check.all.started", #run.steps), "info")
	end
	return true
end

--- Forgets a pending field report; tests only.
function M._reset()
	_report_running, _report_windowed = false, false
end

return M
