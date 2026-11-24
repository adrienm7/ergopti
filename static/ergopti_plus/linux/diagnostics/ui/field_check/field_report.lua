--- diagnostics/ui/field_check/field_report.lua

--- ==============================================================================
--- BRIDGE HANDLER: In-App Field Report (Linux)
--- DESCRIPTION:
--- Débogage's « Lancer le field report (tous les tests) »: a click hands the
--- daemon's own field run session its steps in-process
--- (diagnostics/engine/field_run/field_run.lua Session:submit_in_app), so the
--- run is the field report's own, with no clone and no collector: the same
--- steps, verdicts and result files under the session's folder. The shared
--- field report window (_shared/ui/field_report/) shows each step as it goes,
--- then the summary (_shared/diagnostics/engine/field_check/field_report.lua)
--- and its buttons; one evidence line goes to the log.
--- Bridge name: "field_report"
---
--- FEATURES & RATIONALE:
--- 1. Nothing is pushed or committed: the results stay in the session folder,
---    which the window names and opens on request.
--- 2. One run at a time: a click while it runs brings the window back.
--- 3. Stop, or closing the window while the run goes on, cancels the run: the
---    session closes it as interrupted.
--- 4. The page sends action names only. Copy puts the complete report on the
---    clipboard; « Create a GitHub issue » goes through the diagnostics runner
---    (diagnostics/ui/healthcheck/report.lua report_field_run): the bug form
---    carries the evidence line, the clipboard the redacted report.
--- 5. Without a window (no WebKitGTK, no display) the finished report opens
---    in the one-click checks' dialog (diagnostics/ui/field_check/window.lua),
---    and the log says so.
--- ==============================================================================

local M = {}
M.bridge_name = "field_report"

local FieldReport = require("diagnostics.engine.field_check.field_report")

local LOG = "diagnostics.ui.field_check.field_report"

-- The window's app id (its _shared/ui directory), the name of its bridge too
local APP = M.bridge_name

--- The row and the title of its report (the row's own label).
M.ROW = require("settings.engine.keys").COMMAND.FIELD_REPORT
M.TITLE_KEY = "menu.debug." .. M.ROW

-- The page's actions
local PAGE_ACTIONS = { cancel = true, open_folder = true, copy = true, issue = true, close = true }

-- The run on screen: its session, steps and states, then its report; nil
-- when none was started or its window was closed after the end
local _run = nil

--- The logger, looked up on every use (a suite swaps it per case).
--- @return table
local function logger()
	return require("core.logger.engine.shim")
end

--- Native services, replaceable by tests.
--- @return table
local function native()
	local FieldRun = require("diagnostics.engine.field_run.field_run")
	local services = require("diagnostics.ui.field_check.window").native_services(nil)
	services.session = FieldRun.current
	services.coverage = function()
		local Paths = require("core.fs.engine.paths")
		return FieldRun.read_declaration(Paths.driver_root() .. "/diagnostics/data/field_todo_coverage.json")
	end
	services.title_key = function(check)
		local module = FieldRun.CHECK_RUNNERS[check]
		return module and require(module).title_key or nil
	end
	services.window = require("core.ui.ui.webview_manager")
	services.locale = function() return require("core.i18n.engine.i18n").get_locale() end
	services.open_folder = function(dir, done)
		return require("apps.adapters.desktop_opener").open(dir, done, function() return true end)
	end
	services.issue = function(line, text, done)
		return require("diagnostics.ui.healthcheck.report").report_field_run(line, text, nil, done)
	end
	return services
end

--- Reports whether the in-app run goes on.
--- @return boolean
function M.is_running()
	return _run ~= nil and _run.report == nil
end





-- ==============================
-- ==============================
-- ======= 1/ The Window ========
-- ==============================
-- ==============================

--- Pushes one message into the run's window.
--- @param run table
--- @param message table
--- @return boolean pushed
local function push(run, message)
	if _run ~= run or not run.windowed then return false end
	local ok, json = pcall(require("core.text.engine.json").encode, message)
	if not ok then
		logger().error(LOG, "A field report window message could not be encoded: %s.", tostring(json))
		return false
	end
	return run.env.window.eval_js(APP, "if(window.receiveFieldReport)window.receiveFieldReport(" .. json .. ")") == true
end

--- The page's first message: the steps with their state so far.
--- @param run table
--- @return table
local function init_message(run)
	local steps, not_run = {}, {}
	for _, step in ipairs(run.request.steps) do
		table.insert(steps, { id = step.id, title = run.titles[step.id], state = run.states[step.id] })
	end
	for _, item in ipairs(run.request.not_run) do table.insert(not_run, { id = item.step, reason = item.reason }) end
	return { type = "init", steps = steps, not_run = not_run, open_key = "field_report.open_files" }
end

--- The page's last message: the verdict, the counts and the folder.
--- @param run table
--- @return table
local function done_message(run)
	local summary = run.report.summary
	return { type = "done", passed = summary.passed, interrupted = summary.interrupted, counts = summary.counts,
		folder = run.report.dir }
end

--- Moves a step to its new state on screen.
local function step_changed(run, id, state)
	run.states[id] = state
	push(run, { type = "step", id = id, state = state })
end

--- Builds the report once the run ended, logs it and shows it.
local function finished(run, done, dir)
	-- A run can end before the session hands back its request, or while the
	-- window opens: the end is held until both are known
	if run.request == nil or run.opening then
		run.held = { done = done, dir = dir }
		return
	end
	local env, translate = run.env, run.env.translate
	local summary = FieldReport.summary({ results = run.results, not_run = run.request.not_run, separate = {},
		coverage = run.coverage, done = done, dir = dir })
	local line = FieldReport.format_log_line(summary)
	logger().evidence(LOG, "Field report result: %s", line)
	logger().success(LOG, "In-app field report finished: %s.",
		summary.interrupted and "interrupted" or summary.passed and "pass" or "fail")
	local text = FieldReport.format_text(summary, translate, function(step)
		local key = run.checks[step] and env.title_key(run.checks[step])
		return key and translate(key) or nil
	end)
	run.report = { summary = summary, line = line, text = text, dir = dir }
	if _run ~= run then return end
	if run.windowed then
		push(run, done_message(run))
	elseif not run.closed then
		logger().warn(LOG, "The field report window is not open; the report opens in a dialog.")
		require("diagnostics.ui.field_check.window").show_report(env, LOG, M.TITLE_KEY, text)
		_run = nil
	else
		_run = nil
	end
end





-- ==========================
-- ==========================
-- ======= 2/ The Run =======
-- ==========================
-- ==========================

--- Runs the field report in-app and opens its window.
--- @param services table|nil Test doubles for native services.
--- @return boolean started
function M.run(services)
	local env = services or native()
	local translate = env.translate
	if M.is_running() then
		logger().warn(LOG, "The field report refused: it is still running.")
		if not (_run.windowed and env.window.bring_to_front(APP)) then env.notify(translate("field_check.busy")) end
		return false
	end
	local session = env.session()
	if session == nil then
		logger().error(LOG, "The field report cannot run: the daemon has no field run session.")
		env.notify(translate("field_check.all.unavailable"))
		return false
	end
	-- A finished run's window is replaced by the new run's
	if _run ~= nil and _run.windowed then env.window.hide(APP) end
	local run = { env = env, session = session, coverage = env.coverage(), results = {}, checks = {}, titles = {},
		states = {} }
	_run = run
	logger().start(LOG, "In-app field report started…")
	local request, why = session:submit_in_app({
		step_started = function(_, step)
			run.checks[step.id] = step.check
			step_changed(run, step.id, "running")
		end,
		step_recorded = function(_, _, result)
			table.insert(run.results, result)
			step_changed(run, result.step, result.verdict)
		end,
		finished = function(done, dir) finished(run, done, dir) end,
	})
	if request == nil then
		if _run == run then _run = nil end
		logger().warn(LOG, "The field report refused by the field run session: %s.", tostring(why))
		env.notify(translate(why == "busy" and "field_check.busy" or "field_check.all.unavailable"))
		return false
	end
	run.request = request
	for _, step in ipairs(request.steps) do
		local key = step.check and env.title_key(step.check)
		run.titles[step.id] = key and translate(key) or step.id
		run.states[step.id] = run.states[step.id] or "pending"
	end
	if _run == run then
		run.opening = true
		run.windowed = env.window.show(APP, env.locale()) == true
		run.opening = false
		if not run.windowed then
			logger().warn(LOG, "The field report window could not open; the run goes on without it.")
			env.notify((translate("field_check.all.started"):gsub("{1}", function() return tostring(#request.steps) end)))
		end
	end
	local held = run.held
	run.held = nil
	if held then finished(run, held.done, held.dir) end
	return true
end

--- Stops the run on screen, if it still goes on.
--- @param run table
--- @return boolean cancelled
local function cancel(run)
	if run.report ~= nil then return false end
	logger().info(LOG, "The person stopped the field report.")
	return run.session:cancel_in_app() == true
end

--- Performs one action of the page.
--- @param run table
--- @param name string
--- @param context table|nil The routed message's context (close_owned_window).
--- @return table|nil The answer to the page.
local function perform(run, name, context)
	if name == "cancel" then
		cancel(run)
		return nil
	end
	if name == "close" then
		run.closed = true
		cancel(run)
		local owned = type(context) == "table" and type(context.close_owned_window) == "function"
		local closed = owned and context.close_owned_window() or run.env.window.hide(APP)
		if closed and _run == run and run.report then _run = nil end
		return nil
	end
	if run.report == nil then
		logger().warn(LOG, "Refused the field report action '%s' before the end of the run.", name)
		return { type = "action", action = name, ok = false }
	end
	if name == "copy" then
		local copied = run.env.copy(run.report.text) == true
		logger().info(LOG, "Report copy %s.", copied and "done" or "refused")
		return { type = "action", action = name, ok = copied }
	end
	local function answer(ok) push(run, { type = "action", action = name, ok = ok == true }) end
	if name == "open_folder" then
		local request = run.env.open_folder(run.report.dir, function(receipt)
			answer(type(receipt) == "table" and receipt.ok == true)
		end)
		if request == nil then answer(false) end
	else
		run.env.issue(run.report.line, run.report.text, answer)
	end
	return nil
end

--- Handles an incoming page message.
--- @param payload any String or table from host_bridge.js.
--- @param _state table Daemon state (unused: the run holds its own session).
--- @param context table|nil { app_name, epoch, close_owned_window } from the webview manager.
--- @return table|nil The answer the page receives.
function M.on_message(payload, _state, context)
	local run = _run
	if run == nil or run.request == nil then
		logger().warn(LOG, "A field report window message arrived with no run on screen.")
		return nil
	end
	if payload == "ready" then
		push(run, init_message(run))
		if run.report then push(run, done_message(run)) end
		return nil
	end
	local name = type(payload) == "table" and payload.action or nil
	if type(name) ~= "string" or not PAGE_ACTIONS[name] then
		logger().warn(LOG, "Refused a field report window message that is not one of its actions.")
		return nil
	end
	logger().info(LOG, "Field report window action: %s.", name)
	local ok, answer = xpcall(perform, debug.traceback, run, name, context)
	if not ok then
		logger().error(LOG, "The field report window action '%s' failed: %s", name, tostring(answer))
		return { type = "action", action = name, ok = false }
	end
	return answer
end

--- The person closed the window with its close box: the run stops with it.
--- @param _epoch number|nil
function M.on_window_closed(_epoch)
	local run = _run
	if run == nil then return end
	run.windowed, run.closed = false, true
	cancel(run)
	if _run == run and run.report then _run = nil end
end

--- Forgets the run; tests only.
function M._reset()
	_run = nil
end

return M
