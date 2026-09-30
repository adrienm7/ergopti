--- ui/menu/menu_llm/mlx_repair_offer.lua

--- ==============================================================================
--- MODULE: MLX Repair Offer
--- DESCRIPTION:
--- Tells the user why the MLX runtime failed, in plain words, and carries the
--- button that fixes it: « Réparer l'installation MLX » removes Ergopti's own
--- MLX environment and installs it again. On a Mac that cannot run MLX it
--- offers Ollama instead; a repair refused twice on the same path shows that
--- path in the Finder.
---
--- FEATURES & RATIONALE:
--- 1. A button, never a command: a failed install used to end on "cause
---    inconnue" and a broken runtime on a notification asking to select MLX
---    again, which did nothing while MLX was already selected.
--- 2. Outside the caller's stack: failures arrive from task callbacks and the
---    import probe, where no modal dialog may run, so the dialog is deferred to
---    the timer scheduler; one dialog at a time, the newest cause shown.
--- 3. The router owns the install: the repair goes through
---    runtime_install_offer.select_mlx({ repair = true }), the one caller of
---    the checker's install_for_selection().
--- 4. The AI menu registers what it owns: the Ollama row's selection for an
---    unsupported Mac, and the model restart once a repair succeeded.
--- ==============================================================================

local M = {}

local Logger    = require("infra.logger")
local Diagnosis = require("modules.llm.mlx_bootstrap_diagnosis")

local LOG = "menu_llm.mlx_repair_offer"

-- Reveals a path in the Finder without a shell.
local OPEN_BIN = "/usr/bin/open"

-- Stateful singletons are resolved at call time: tests and reloads replace them.
local function checker() return require("modules.llm.mlx_deps_checker") end
local function i18n() return require("infra.i18n") end
local function router() return require("ui.menu.menu_llm.runtime_install_offer") end
local function dialogs() return require("infra.dialog_util") end
local function notifications() return require("infra.notifications") end
local function deferred() return require("infra.deferred_work") end

-- fn() -> boolean: selects the Ollama backend, as its menu row does
local _alternative = nil
-- fn() -> boolean: restarts the MLX model once a repair succeeded
local _resume = nil
-- Cause waiting for its deferred dialog; a newer failure replaces it
local _pending_cause = nil
local _scheduled = false
-- The dialog is modal: a second failure while it is open asks nothing more
local _asking = false
local _repair_running = false
-- Kind of the failure the last repair ended on; a permission refused again on
-- the same path is shown in the Finder rather than repaired a third time
local _last_repair_failure = nil





-- =====================================
-- =====================================
-- ======= 1/ Internal Helpers =========
-- =====================================
-- =====================================

--- Shows a path in the Finder.
--- @param path string Absolute path.
--- @return boolean started
local function reveal(path)
	local ok, started = pcall(function()
		local handle = require("adapters.shell_runner").spawn(OPEN_BIN, { "-R", path }, nil)
		return handle ~= nil and handle.start() == true
	end)
	if not ok or started ~= true then
		Logger.error(LOG, "The Finder could not show %s: %s.", tostring(path), tostring(started))
		return false
	end
	Logger.info(LOG, "Showed %s in the Finder.", path)
	return true
end

--- Resolves the cause to present: the given one, the checker's, or a generic one.
--- @param cause table|nil
--- @return table cause
local function resolve_cause(cause)
	if type(cause) == "table" and type(cause.kind) == "string" then return cause end
	local ok, known = pcall(function() return checker().get_failure_cause() end)
	if ok and type(known) == "table" and type(known.kind) == "string" then return known end
	return { kind = "exit", repairable = true }
end

--- Chooses the title, the body and the two buttons for a cause.
--- @param cause table Resolved cause.
--- @return table dialog { title, body, primary, secondary, action }
local function dialog_for(cause)
	local ok_venv, venv = pcall(function() return checker().venv_dir() end)
	local body = Diagnosis.describe(cause, {
		venv = ok_venv and venv or nil,
		log_path = Logger.today_log_path(),
	})
	if cause.kind == "unsupported" then
		if type(_alternative) == "function" then
			return {
				title = i18n().get("mlx.unsupported_title"), body = body,
				primary = i18n().get("mlx.use_ollama"), secondary = i18n().get("common.close"),
				action = "alternative",
			}
		end
		return { title = i18n().get("mlx.unsupported_title"), body = body, primary = i18n().get("common.ok") }
	end
	local refused_again = cause.kind == "permission" and type(cause.path) == "string"
		and _last_repair_failure == "permission"
	if refused_again or (cause.repairable ~= true and type(cause.path) == "string") then
		if refused_again then body = body .. "\n\n" .. i18n().get("mlx.repair_reveal_hint") end
		return {
			title = i18n().get("mlx.repair_title"), body = body,
			primary = i18n().get("mlx.repair_reveal"), secondary = i18n().get("common.later"),
			action = "reveal",
		}
	end
	if cause.repairable ~= true then
		return { title = i18n().get("mlx.repair_title"), body = body, primary = i18n().get("common.ok") }
	end
	return {
		title = i18n().get("mlx.repair_title"), body = body,
		primary = i18n().get("mlx.repair_button"), secondary = i18n().get("common.later"),
		action = "repair",
	}
end

--- Shows the dialog for one cause and runs the chosen action.
--- @param cause table|nil
--- @return boolean shown
local function present(cause)
	if _asking then
		Logger.info(LOG, "An MLX repair dialog is already open; this failure waits for it.")
		return false
	end
	cause = resolve_cause(cause)
	local dialog = dialog_for(cause)
	Logger.warn(LOG, "Offering the MLX %s action for a %s failure.",
		tostring(dialog.action or "acknowledge"), tostring(cause.kind))
	_asking = true
	local ok, choice = pcall(dialogs().block_alert, dialog.title, dialog.body,
		dialog.primary, dialog.secondary, "warning")
	_asking = false
	if not ok then
		Logger.error(LOG, "The MLX repair dialog could not be shown: %s", tostring(choice))
		return false
	end
	if choice ~= dialog.primary or dialog.action == nil then
		Logger.info(LOG, "MLX %s declined (%s).", tostring(dialog.action or "notice"), tostring(cause.kind))
		return true
	end
	if dialog.action == "repair" then
		M.repair()
	elseif dialog.action == "reveal" then
		reveal(cause.path)
	elseif dialog.action == "alternative" then
		local called, selected = pcall(_alternative)
		if not called or selected == false then
			Logger.error(LOG, "Selecting Ollama instead of MLX failed: %s.", tostring(selected))
		end
	end
	return true
end





-- =====================================
-- =====================================
-- ======= 2/ Public API ===============
-- =====================================
-- =====================================

--- Registers the selection of the other local backend (the Ollama row).
--- @param fn function|nil fn() -> boolean; nil clears it.
function M.set_alternative(fn)
	if fn ~= nil and type(fn) ~= "function" then
		error("mlx_repair_offer.set_alternative: a function or nil is required")
	end
	_alternative = fn
end

--- Registers the restart of the MLX model after a successful repair.
--- @param fn function|nil fn() -> boolean; nil clears it.
function M.set_resume(fn)
	if fn ~= nil and type(fn) ~= "function" then
		error("mlx_repair_offer.set_resume: a function or nil is required")
	end
	_resume = fn
end

--- Tells the user why MLX failed, with the button that fixes it. Deferred to
--- the timer scheduler; a failure arriving before the dialog opens replaces
--- the pending cause.
--- @param cause table|nil Cause from mlx_bootstrap_diagnosis, the checker's when nil.
--- @return boolean scheduled True when a dialog is scheduled or already pending.
function M.offer(cause)
	_pending_cause = cause
	if _scheduled then return true end
	local committed = deferred().after(0, function()
		_scheduled = false
		local pending = _pending_cause
		_pending_cause = nil
		present(pending)
	end, "mlx_repair_offer.present")
	if committed ~= true then
		Logger.error(LOG, "The MLX repair dialog could not be scheduled.")
		return false
	end
	_scheduled = true
	return true
end

--- Removes Ergopti's MLX environment and installs it again, then restarts
--- the MLX model; a failure opens the offer again with its own cause.
--- @return boolean accepted
function M.repair()
	if _repair_running then
		Logger.info(LOG, "An MLX repair is already running.")
		return false
	end
	_repair_running = true
	Logger.start(LOG, "Repairing the MLX installation on the user's request…")
	local ok, accepted = pcall(function()
		return router().select_mlx(function(done)
			_repair_running = false
			if done ~= true then
				local cause = resolve_cause(nil)
				_last_repair_failure = cause.kind
				Logger.error(LOG, "The MLX repair failed (%s).", tostring(cause.kind))
				return false
			end
			_last_repair_failure = nil
			Logger.success(LOG, "MLX installation repaired.")
			pcall(notifications().notify, i18n().get("mlx.repair_done"),
				i18n().get("mlx.deps_step_ready"), "success")
			-- The model restarts outside the installer's completion, which still
			-- holds its bootstrap intent while it delivers this result.
			if type(_resume) == "function" then
				local resume = _resume
				local committed = deferred().after(0, function()
					local resumed, result = pcall(resume)
					if not resumed or result == false then
						Logger.error(LOG, "The MLX model did not restart after the repair: %s.", tostring(result))
					end
				end, "mlx_repair_offer.resume")
				if committed ~= true then
					Logger.error(LOG, "The MLX model restart could not be scheduled after the repair.")
				end
			end
			return true
		end, { repair = true })
	end)
	if not ok or accepted ~= true then
		_repair_running = false
		Logger.error(LOG, "The MLX repair was not accepted: %s.", tostring(accepted))
		return false
	end
	return true
end

--- Forgets the pending dialog, the repair state and the registrations.
function M.reset()
	_alternative, _resume, _pending_cause = nil, nil, nil
	_scheduled, _asking, _repair_running, _last_repair_failure = false, false, false, nil
end

return M
