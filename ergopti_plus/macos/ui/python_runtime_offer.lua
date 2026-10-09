--- ui/python_runtime_offer.lua

--- ==============================================================================
--- MODULE: Native Python Offer
--- DESCRIPTION:
--- Tells the user that an action needs a Python 3 this Mac can run natively,
--- names the interpreters found and the processor each one needs, and carries
--- the buttons that install one: Apple's command line tools, whose python3 is
--- the one /usr/bin/python3 runs, or the python.org installer page.
---
--- FEATURES & RATIONALE:
--- 1. A button, never a command: the helpers (pixel color, display mirror, the
---    input-source editor, the AI runtime installers) refuse an interpreter
---    macOS would run under Rosetta (adapters/python_interpreter.lua), and the
---    user must be able to fix that from the dialog (hardening-g).
--- 2. Outside the caller's stack: refusals arrive from shortcuts and task
---    callbacks, where no modal dialog may run, so the dialog is deferred to
---    the timer scheduler; one at a time, the newest state shown.
--- 3. Only when asked: nothing at boot needs Python, so this offer appears only
---    after the user starts an action that does.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "ui.python_runtime_offer"

-- Apple's installer of the command line tools, a native GUI flow.
local XCODE_SELECT_BIN = "/usr/bin/xcode-select"
local OPEN_BIN = "/usr/bin/open"
local PYTHON_DOWNLOAD_URL = "https://www.python.org/downloads/macos/"

-- Stateful singletons are resolved at call time: tests and reloads replace them.
local function i18n() return require("infra.i18n") end
local function dialogs() return require("infra.dialog_util") end
local function deferred() return require("infra.deferred_work") end
local function shell() return require("adapters.shell_runner") end

local _pending_state = nil
local _scheduled = false
local _asking = false





-- =====================================
-- =====================================
-- ======= 1/ Dialog ===================
-- =====================================
-- =====================================

--- Names a processor for the user.
--- @param arch string|nil "arm64" or "x86_64".
--- @return string
local function processor_name(arch)
	if arch == "x86_64" then return i18n().get("mlx.machine_intel") end
	return i18n().get("mlx.machine_apple_silicon")
end

--- Builds the dialog text for a resolver state.
--- @param state table State from python_interpreter.resolve().
--- @return string title, string body
function M.message_for(state)
	state = type(state) == "table" and state or {}
	local install = i18n().get("python.install_tools_button")
	local download = i18n().get("python.download_button")
	local action = i18n().format("python.install_action", install, download)
	if state.kind == "python_not_native" then
		local lines = {}
		for _, found in ipairs(type(state.found) == "table" and state.found or {}) do
			local archs = type(found.archs) == "table" and table.concat(found.archs, ", ") or "?"
			lines[#lines + 1] = "• " .. tostring(found.path) .. " (" .. archs .. ")"
		end
		return i18n().get("python.not_native_title"),
			i18n().format("python.not_native_body", processor_name(state.native), table.concat(lines, "\n"))
				.. "\n\n" .. action
	end
	return i18n().get("python.missing_title"), i18n().get("python.missing_body") .. "\n\n" .. action
end

--- Starts one detached system command.
--- @param executable string
--- @param args table
--- @param label string
--- @return boolean started
local function launch(executable, args, label)
	local ok, started = pcall(function()
		local handle = shell().spawn(executable, args, nil)
		return handle ~= nil and handle.start() == true
	end)
	if not ok or started ~= true then
		Logger.error(LOG, "%s could not start: %s.", label, tostring(started))
		return false
	end
	Logger.info(LOG, "%s started.", label)
	return true
end

--- Shows the dialog for one state and runs the chosen fix.
--- @param state table
--- @return boolean shown
local function present(state)
	if _asking then
		Logger.info(LOG, "A Python dialog is already open; this refusal is only logged.")
		return false
	end
	local title, body = M.message_for(state)
	local choices = { i18n().get("python.install_tools_button"), i18n().get("python.download_button") }
	Logger.warn(LOG, "Offering a native Python install (%s).", tostring(type(state) == "table" and state.kind))
	_asking = true
	local ok, choice = pcall(dialogs().choose, title, body, choices, i18n().get("common.later"),
		i18n().get("common.ok"))
	_asking = false
	if not ok then
		Logger.error(LOG, "The Python dialog could not be shown: %s", tostring(choice))
		return false
	end
	if choice == 1 then
		launch(XCODE_SELECT_BIN, { "--install" }, "Apple's command line tools installer")
	elseif choice == 2 then
		launch(OPEN_BIN, { PYTHON_DOWNLOAD_URL }, "The python.org download page")
	else
		Logger.info(LOG, "Native Python install declined.")
	end
	return true
end





-- =====================================
-- =====================================
-- ======= 2/ Public API ===============
-- =====================================
-- =====================================

--- Tells the user why an action found no native Python, with the buttons that
--- install one. Deferred to the timer scheduler; a newer refusal arriving
--- before the dialog opens replaces the pending state.
--- @param state table|nil State from python_interpreter.resolve().
--- @return boolean scheduled True when a dialog is scheduled or already pending.
function M.offer(state)
	_pending_state = state
	if _scheduled then return true end
	local committed = deferred().after(0, function()
		_scheduled = false
		local pending = _pending_state
		_pending_state = nil
		present(pending)
	end, "python_runtime_offer.present")
	if committed ~= true then
		Logger.error(LOG, "The Python dialog could not be scheduled.")
		return false
	end
	_scheduled = true
	return true
end

--- Forgets the pending dialog.
function M.reset()
	_pending_state, _scheduled, _asking = nil, false, false
end

return M
