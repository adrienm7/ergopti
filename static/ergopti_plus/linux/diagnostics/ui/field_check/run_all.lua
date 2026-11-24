--- diagnostics/ui/field_check/run_all.lua

--- ==============================================================================
--- MODULE: Test Everything (Linux)
--- DESCRIPTION:
--- The Debug menu's « Test everything »: a click runs, one after the other,
--- every check of the Linux plan (_shared/diagnostics/data/field_check_all.json)
--- through the same headless runners the developer field run uses, writes one
--- evidence record and shows one combined report with a « Copy report » button:
--- each check's verdict, its field run step and the TODO-tests field points it
--- decides, then the Tests rows to run separately.
---
--- FEATURES & RATIONALE:
--- 1. The sequence, the deadlines and the report are the shared ones
---    (_shared/diagnostics/engine/field_check/run_all.lua); each check's
---    deadline is its field run step's (diagnostics/data/field_run_steps.json).
--- 2. The window and the clipboard copy are the one-click checks' own
---    (diagnostics/ui/field_check/window.lua).
--- 3. One run at a time: a second click while it runs only says so.
--- ==============================================================================

local M = {}

local RunAll = require("diagnostics.engine.field_check.run_all")

local LOG = "diagnostics.ui.field_check.run_all"

--- The row and the title of its combined report (the row's own label).
M.ROW = require("settings.engine.keys").COMMAND.FIELD_REPORT
M.TITLE_KEY = "menu.debug." .. M.ROW

-- True while the sequence runs
local _running = false

--- The logger, looked up on every use (a suite swaps it per case).
--- @return table
local function logger()
	return require("core.logger.engine.shim")
end

--- This driver's declarations: the shared plan, the field run steps and the
--- TODO-tests coverage.
--- @return table declaration, table steps, table coverage
local function declarations()
	local Paths = require("core.fs.engine.paths")
	local FieldRun = require("diagnostics.engine.field_run.field_run")
	local spec = FieldRun.load(Paths.shared_root(), Paths.driver_root())
	return FieldRun.read_declaration(Paths.shared("diagnostics/data/field_check_all.json")), spec.steps,
		FieldRun.read_declaration(Paths.driver_root() .. "/diagnostics/data/field_todo_coverage.json")
end

--- Native services, replaceable by tests.
--- @return table
local function native()
	local services = require("diagnostics.ui.field_check.window").native_services(nil)
	services.declarations = declarations
	services.runner = function(check)
		return require(require("diagnostics.engine.field_run.field_run").CHECK_RUNNERS[check])
	end
	-- The loop's deferred calls cannot be withdrawn, so a cancelled timer only stands down
	services.after = function(seconds, fn)
		local handle = { cancelled = false }
		local queued = require("core.events.loop").defer(function()
			if not handle.cancelled then fn() end
		end, seconds * 1000)
		assert(queued, "test everything: the event loop refused a timer")
		return handle
	end
	services.cancel = function(handle) handle.cancelled = true end
	return services
end

--- Reports whether the sequence runs.
--- @return boolean
function M.is_running()
	return _running
end

--- Runs every check of the Linux plan and shows the combined report.
--- @param services table|nil Test doubles for native services.
--- @return boolean started False when a run is already pending.
function M.run(services)
	local env = services or native()
	local translate = env.translate
	if _running then
		logger().warn(LOG, "Test everything refused: it is still running.")
		env.notify(translate("field_check.busy"))
		return false
	end
	local declaration, steps, coverage = env.declarations()
	local plan = RunAll.plan(declaration, "linux", steps, coverage)
	_running = true
	logger().start(LOG, "Test everything started: %d checks.", #plan.run)
	env.notify((translate("field_check.all.started"):gsub("{1}", function() return tostring(#plan.run) end)))
	RunAll.run(plan, {
		start = function(entry, on_result) return env.runner(entry.check).run_headless(on_result) end,
		after = env.after,
		cancel = env.cancel,
	}, function(summary)
		_running = false
		logger().evidence(LOG, "Test everything result: %s", RunAll.format_log_line(summary))
		logger().success(LOG, "Test everything finished: %s.", summary.passed and "pass" or "fail")
		require("diagnostics.ui.field_check.window").show_report(env, LOG, M.TITLE_KEY,
			RunAll.format_text(summary, translate))
	end)
	return true
end

--- Forgets a pending run; tests only.
function M._reset()
	_running = false
end

return M
