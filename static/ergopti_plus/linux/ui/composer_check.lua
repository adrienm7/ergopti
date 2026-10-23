--- ui/composer_check.lua

--- ==============================================================================
--- MODULE: Composer Check Window (Linux)
--- DESCRIPTION:
--- The Debug menu's one-click « Test the composed layout »: a click runs the
--- shared steps (_shared/lua/layouts/composer_check.lua) over this driver's
--- composer environment (modules/keymap/composer_check.lua), writes the one
--- evidence record to the log and shows the result, one line per step, with a
--- « Copy report » button.
---
--- FEATURES & RATIONALE:
--- 1. One click, no arguments: the menu row names the check; nothing else is
---    asked of the user.
--- 2. The same text goes to the window and the clipboard, built from the same
---    privacy-safe result as the log line (field_check_report.lua).
--- 3. One run at a time: a second click while a check is pending only says so.
--- 4. The dialog is a zenity question whose two buttons are « Copy report » and
---    « Close »; it opens through ui.modal, which hands the keyboard back to the
---    desktop while it is open. Every collaborator is injectable.
--- ==============================================================================

local M = {}

local Report = require("field_check_report")
local Check  = require("layouts.composer_check")
local Logger = require("logger.shim")

local LOG = "composer_check"

-- The row's title, and the strings the dialog shows (all localized).
local TITLE_KEY = "menu.debug.composer_check"

-- Check currently running; one at a time.
local _running = false

--- Native services, replaceable by tests.
--- @return table
local function native()
	local I18n = require("infra.i18n")
	local Shell = require("adapters.shell_runner")
	return {
		translate = I18n.get,
		env = function() return require("modules.keymap.composer_check").env() end,
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

--- Reports whether a check is pending.
--- @return boolean
function M.is_running()
	return _running
end

--- Runs the check of the Debug menu row.
--- @param services table|nil Test doubles for native services.
--- @return boolean started False when a check is already pending.
function M.run(services)
	local env_services = services or native()
	local translate = env_services.translate
	if _running then
		Logger.warn(LOG, "Composer check refused: another one is still running.")
		env_services.notify(translate("field_check.busy"))
		return false
	end
	_running = true
	Logger.start(LOG, "Composer check started…")
	local report = Report.new_report(Check.CHECK_ID)
	local settled = false
	local function finish()
		if settled then return end
		settled = true
		_running = false
		local result = report.result()
		Logger.evidence(LOG, "Composer check result: %s", Report.format_log_line(result))
		Logger.success(LOG, "Composer check finished: %s.", result.passed and "pass" or "fail")
		local text = Report.format_text(result, translate)
		-- The dialog blocks: it opens from a fresh turn of the event loop.
		env_services.defer(function()
			local copy_label, close_label = translate("field_check.copy"), translate("field_check.close")
			if env_services.dialog(translate(TITLE_KEY), text, copy_label, close_label) then
				local copied = env_services.copy(text)
				Logger.info(LOG, "Report copy %s.", copied and "done" or "refused")
				if copied then env_services.notify(translate("field_check.copied")) end
			end
		end)
	end
	local env, env_err = env_services.env()
	if not env then
		Logger.error(LOG, "The composer check is unusable: %s.", tostring(env_err))
		report.step("composer_fixture", Report.STATE_FAIL, "unusable")
		finish()
		return true
	end
	local ran, err = pcall(Check.run, env, report, finish)
	if not ran then
		Logger.error(LOG, "Composer check raised: %s", tostring(err))
		if not report.has("internal_error") then report.step("internal_error", Report.STATE_FAIL, "raised") end
		finish()
	end
	return true
end

--- Forgets a pending run; tests only.
function M._reset()
	_running = false
end

return M
