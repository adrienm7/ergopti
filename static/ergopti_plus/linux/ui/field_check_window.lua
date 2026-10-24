--- ui/field_check_window.lua

--- ==============================================================================
--- MODULE: Field Check Window Runner (Linux)
--- DESCRIPTION:
--- The one-click Debug menu checks (« Test the composed layout », « Test network
--- (PAC, proxy, download) ») share their run: a click runs the check's steps,
--- writes the one evidence record to the log and shows the result, one line per
--- step, with a « Copy report » button. This module is that run; a check supplies
--- only its identity, its steps and the environment they need.
---
--- FEATURES & RATIONALE:
--- 1. One click, no arguments: the menu row names the check; nothing else is
---    asked of the user.
--- 2. The same text goes to the window and the clipboard, built from the same
---    privacy-safe result as the log line (field_check_report.lua).
--- 3. One run at a time per check: a second click while a check is pending only
---    says so.
--- 4. The dialog is a zenity question whose two buttons are « Copy report » and
---    « Close »; it opens through ui.modal, which hands the keyboard back to the
---    desktop while it is open. Every collaborator is injectable.
--- 5. The logger is resolved at call time, so a suite can replace it per case.
--- ==============================================================================

local M = {}

local Report = require("field_check_report")

--- The logger, looked up on every use (a suite swaps it per case).
--- @return table
local function logger()
	return require("logger.shim")
end

--- Native services, replaceable by tests.
--- @param spec table The check's spec (supplies the environment).
--- @return table
local function native(spec)
	local I18n = require("infra.i18n")
	local Shell = require("adapters.shell_runner")
	return {
		translate = I18n.get,
		env = spec.env,
		notify = function(message) return require("adapters.application_notifier").send(message, { level = "info" }) end,
		--- Shows the report; returns true when the user asked to copy it.
		dialog = function(title, text, copy_label, close_label)
			local command = "zenity --question --no-markup --title=" .. Shell.quote(require("window_titles").compose(title))
				.. " --text=" .. Shell.quote(text)
				.. " --ok-label=" .. Shell.quote(copy_label)
				.. " --cancel-label=" .. Shell.quote(close_label)
			return (require("ui.modal").run(function() return Shell.exec_checked(command) end)) == true
		end,
		copy = function(text) return require("adapters.clipboard").write(text) end,
		defer = function(fn) return require("adapters.event_loop").defer(fn, 0) end,
	}
end

--- Creates the runner of one check.
--- @param spec table {
---   label = string        name in log lines ("Network check"),
---   log = string          logger module tag,
---   check_id = string     identity in the evidence record,
---   title_key = string    locale key of the window title,
---   steps = function(env, report, finish)  the check's steps,
---   env = function() -> env|nil, err       the environment the steps need,
---   unusable_step = string  step recorded when the environment is unusable }
--- @return table runner { run, is_running, _reset }
function M.new(spec)
	local runner = {}
	local running = false

	--- Reports whether a check is pending.
	--- @return boolean
	function runner.is_running()
		return running
	end

	--- Runs the check of the Debug menu row.
	--- @param services table|nil Test doubles for native services.
	--- @return boolean started False when a check is already pending.
	function runner.run(services)
		local env_services = services or native(spec)
		local translate = env_services.translate
		if running then
			logger().warn(spec.log, "%s refused: another one is still running.", spec.label)
			env_services.notify(translate("field_check.busy"))
			return false
		end
		running = true
		logger().start(spec.log, "%s started…", spec.label)
		local report = Report.new_report(spec.check_id)
		local settled = false
		local function finish()
			if settled then return end
			settled = true
			running = false
			local result = report.result()
			logger().evidence(spec.log, "%s result: %s", spec.label, Report.format_log_line(result))
			logger().success(spec.log, "%s finished: %s.", spec.label, result.passed and "pass" or "fail")
			local text = Report.format_text(result, translate)
			-- The dialog blocks: it opens from a fresh turn of the event loop.
			env_services.defer(function()
				local copy_label, close_label = translate("field_check.copy"), translate("field_check.close")
				if env_services.dialog(translate(spec.title_key), text, copy_label, close_label) then
					local copied = env_services.copy(text)
					logger().info(spec.log, "Report copy %s.", copied and "done" or "refused")
					if copied then env_services.notify(translate("field_check.copied")) end
				end
			end)
		end
		local env, env_err = env_services.env()
		if not env then
			logger().error(spec.log, "The %s is unusable: %s.", spec.label:lower(), tostring(env_err))
			report.step(spec.unusable_step, Report.STATE_FAIL, "unusable")
			finish()
			return true
		end
		local ran, err = pcall(spec.steps, env, report, finish)
		if not ran then
			logger().error(spec.log, "%s raised: %s", spec.label, tostring(err))
			if not report.has("internal_error") then report.step("internal_error", Report.STATE_FAIL, "raised") end
			finish()
		end
		return true
	end

	--- Forgets a pending run; tests only.
	function runner._reset()
		running = false
	end

	return runner
end

return M
