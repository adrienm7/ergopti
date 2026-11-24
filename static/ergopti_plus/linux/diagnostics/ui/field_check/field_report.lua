--- diagnostics/ui/field_check/field_report.lua

--- ==============================================================================
--- MODULE: In-App Field Report (Linux)
--- DESCRIPTION:
--- Débogage's « Lancer le field report (tous les tests) »: a click hands the
--- daemon's own field run session its steps in-process
--- (diagnostics/engine/field_run/field_run.lua Session:submit_in_app), so the
--- run is the field report's own, with no clone and no collector: the same
--- steps, verdicts and result files under the session's folder. When the run
--- ends, one window shows the combined report
--- (_shared/diagnostics/engine/field_check/field_report.lua) with a « Copy
--- report » button, and one evidence line goes to the log.
---
--- FEATURES & RATIONALE:
--- 1. Nothing is pushed or committed: the results stay in the session folder,
---    which the report names so the person can attach it to an issue.
--- 2. One run at a time: a click while it runs only says so.
--- 3. The window and the clipboard copy are the one-click checks' own
---    (diagnostics/ui/field_check/window.lua).
--- ==============================================================================

local M = {}

local FieldReport = require("diagnostics.engine.field_check.field_report")

local LOG = "diagnostics.ui.field_check.field_report"

--- The row and the title of its report (the row's own label).
M.ROW = require("settings.engine.keys").COMMAND.FIELD_REPORT
M.TITLE_KEY = "menu.debug." .. M.ROW

-- True while the in-app run goes on
local _running = false

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
	return services
end

--- Reports whether the in-app run goes on.
--- @return boolean
function M.is_running()
	return _running
end

--- Runs the field report in-app and shows its report when it ends.
--- @param services table|nil Test doubles for native services.
--- @return boolean started
function M.run(services)
	local env = services or native()
	local translate = env.translate
	if _running then
		logger().warn(LOG, "The field report refused: it is still running.")
		env.notify(translate("field_check.busy"))
		return false
	end
	local session = env.session()
	if session == nil then
		logger().error(LOG, "The field report cannot run: the daemon has no field run session.")
		env.notify(translate("field_check.all.unavailable"))
		return false
	end
	local coverage = env.coverage()
	local results, checks = {}, {}
	_running = true
	logger().start(LOG, "In-app field report started…")
	-- Declared first: the observer reads the run the session hands back
	local run, why
	run, why = session:submit_in_app({
		step_started = function(_, step) checks[step.id] = step.check end,
		step_recorded = function(_, _, result) table.insert(results, result) end,
		finished = function(done, dir)
			_running = false
			local summary = FieldReport.summary({ results = results, not_run = run.not_run, separate = {},
				coverage = coverage, done = done, dir = dir })
			logger().evidence(LOG, "Field report result: %s", FieldReport.format_log_line(summary))
			logger().success(LOG, "In-app field report finished: %s.",
				summary.interrupted and "interrupted" or summary.passed and "pass" or "fail")
			local text = FieldReport.format_text(summary, translate, function(step)
				local key = checks[step] and env.title_key(checks[step])
				return key and translate(key) or nil
			end)
			require("diagnostics.ui.field_check.window").show_report(env, LOG, M.TITLE_KEY, text)
		end,
	})
	if run == nil then
		_running = false
		logger().warn(LOG, "The field report refused by the field run session: %s.", tostring(why))
		env.notify(translate(why == "busy" and "field_check.busy" or "field_check.all.unavailable"))
		return false
	end
	env.notify((translate("field_check.all.started"):gsub("{1}", function() return tostring(#run.steps) end)))
	return true
end

--- Forgets a pending run; tests only.
function M._reset()
	_running = false
end

return M
