--- ui/menu/menu_llm/mlx_repair_offer.lua

--- ==============================================================================
--- MODULE: MLX Repair Offer
--- DESCRIPTION:
--- Tells the user why the MLX runtime failed, or that it is not installed, in
--- plain words, and carries the button that fixes it: « Réparer l'installation
--- MLX » removes Ergopti's own MLX environment and installs it again, and
--- « Installer le moteur MLX » installs a runtime that is absent. On a Mac that
--- cannot run MLX it offers Ollama instead; a repair refused twice on the same
--- path shows that path in the Finder.
---
--- FEATURES & RATIONALE:
--- 1. A button, never a command: a failed install used to end on "cause
---    inconnue", and a broken or absent runtime on a notification asking to
---    select MLX in the menu, which did nothing while MLX was already selected.
--- 2. Outside the caller's stack: failures arrive from task callbacks and the
---    import probe, where no modal dialog may run, so the dialog is deferred to
---    the timer scheduler; one dialog at a time, the newest cause shown.
--- 3. The router owns the install: the repair and the install both go through
---    runtime_install_offer.select_mlx(), the one caller of the checker's
---    install_for_selection(), the repair with { repair = true }. A failed
---    install or repair opens this offer again with its cause and the repair
---    button, the retry of any failed installation.
--- 4. The AI menu registers what it owns: the Ollama row's selection for an
---    unsupported Mac, and the model restart once an installation succeeded.
--- ==============================================================================

local M = {}

local Logger    = require("infra.logger")
local Diagnosis = require("modules.llm.mlx_bootstrap_diagnosis")

local LOG = "menu_llm.mlx_repair_offer"

-- Reveals a path in the Finder without a shell.
local OPEN_BIN = "/usr/bin/open"

-- System Settings > Network, where the relay (proxy) of a managed Mac is set.
local NETWORK_SETTINGS_URL = "x-apple.systempreferences:com.apple.Network-Settings.extension"

-- Immutable canonical policy, loaded once through the native shared-path owner.
local _network_contract = nil

-- Stateful singletons are resolved at call time: tests and reloads replace them.
local function checker() return require("modules.llm.mlx_deps_checker") end
local function i18n() return require("infra.i18n") end
local function router() return require("ui.menu.menu_llm.runtime_install_offer") end
local function dialogs() return require("infra.dialog_util") end
local function notifications() return require("infra.notifications") end
local function deferred() return require("infra.deferred_work") end

-- fn() -> boolean: selects the Ollama backend, as its menu row does
local _alternative = nil
-- fn() -> boolean: restarts the MLX model once an installation succeeded
local _resume = nil
-- Cause waiting for its deferred dialog; a newer failure replaces it
local _pending_cause = nil
local _scheduled = false
-- The dialog is modal: a second failure while it is open asks nothing more
local _asking = false
-- An install or a repair is running: its end opens the offer again on failure
local _installation_running = false
-- Kind of the failure the last install or repair ended on; a permission refused
-- again on the same path is shown in the Finder rather than repaired once more
local _last_repair_failure = nil





-- =====================================
-- =====================================
-- ======= 1/ Internal Helpers =========
-- =====================================
-- =====================================

--- Loads shared policy data without a per-driver action or cause fallback.
local function network_contract()
	if _network_contract then return _network_contract end
	local path = require("infra.paths").shared("modules/network/managed_network.json")
	assert(type(path) == "string", "the shared managed network policy path is unavailable")
	local text = assert(require("adapters.file_system").read(path), "the shared managed network policy is unreadable")
	_network_contract = require("network.failure").new(require("json").decode(text))
	return _network_contract
end

local function network_cause(cause)
	if type(cause.network_report) == "table" then return cause.network_report.cause end
	return cause.kind == "network_unknown" and "unknown" or cause.kind
end

local function has_network_contract(cause)
	return type(cause.network_report) == "table" or Diagnosis.NETWORK_KINDS[cause.kind] == true
end

--- Rechecks the native revision after a modal chooser can run other callbacks.
local function failure_is_current(cause)
	return type(cause) == "table" and type(checker().failure_action_admitted) == "function"
		and checker().failure_action_admitted(cause.failure_revision) == true
end

--- Capabilities describe actual native openers and the current failed intent.
local function network_capabilities(cause)
	local shell = require("adapters.shell_runner")
	local fs = require("adapters.file_system")
	local function regular_file(path)
		if type(path) ~= "string" or path:sub(1, 1) ~= "/" then return false end
		local status, attributes = fs.path_status(path)
		return status == "present" and type(attributes) == "table" and attributes.mode == "file"
	end
	local can_open = type(shell.spawn) == "function" and regular_file(OPEN_BIN)
	local log_path = Logger.today_log_path()
	local log_exists = can_open and regular_file(log_path)
	return {
		owner_alive = failure_is_current(cause),
		retry_available = not _installation_running and type(router().select_mlx) == "function",
		proxy_settings_available = can_open == true,
		diagnostics_available = log_exists == true,
		alternative_backend_available = type(_alternative) == "function",
	}, log_exists and log_path or nil
end

local function admitted_network_action(cause, id)
	if not failure_is_current(cause) then return false end
	for _, action in ipairs(network_contract().actions(network_cause(cause), network_capabilities(cause))) do
		if action.id == id then return failure_is_current(cause) end
	end
	return false
end

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
	if cause.kind == "missing" then
		-- Nothing failed: the runtime was never installed, or its folder is gone.
		local install = i18n().get("mlx.install_button")
		local paragraphs = { i18n().get("mlx.runtime_missing_body") }
		if ok_venv and type(venv) == "string" then
			paragraphs[#paragraphs + 1] = i18n().format("mlx.install_action", venv, install)
		end
		return {
			title = i18n().get("mlx.runtime_missing_title"), body = table.concat(paragraphs, "\n\n"),
			primary = install, secondary = i18n().get("common.later"),
			action = "install",
		}
	end
	local body = Diagnosis.describe(cause, {
		venv = ok_venv and venv or nil,
		log_path = Logger.today_log_path(),
	})
	if has_network_contract(cause) then
		local capabilities = network_capabilities(cause)
		local actions = network_contract().actions(network_cause(cause), capabilities)
		local choices, ids = {}, {}
		for _, action in ipairs(actions) do
			choices[#choices + 1] = i18n().get(action.label_key)
			ids[#ids + 1] = action.id
		end
		if #choices == 0 then
			return { title = i18n().get("mlx.repair_title"), body = body, primary = i18n().get("common.ok") }
		end
		return { title = i18n().get("mlx.repair_title"), body = body, choices = choices, actions = ids }
	end
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
		Logger.info(LOG, "An MLX repair dialog is already open; this failure is only logged.")
		return false
	end
	cause = resolve_cause(cause)
	if cause.kind == "no_native_python" then
		-- The fix is a Python this Mac runs natively, not an MLX repair: its own
		-- offer names what was found and carries the install.
		return require("ui.python_runtime_offer").offer(cause.state)
	end
	if has_network_contract(cause) and not failure_is_current(cause) then
		Logger.debug(LOG, "Retained MLX network failure is stale or its native task owner is still active.")
		return false
	end
	local dialog = dialog_for(cause)
	Logger.warn(LOG, "Offering the MLX %s action for a %s failure.",
		tostring(dialog.action or (dialog.actions and table.concat(dialog.actions, "/")) or "acknowledge"),
		tostring(cause.kind))
	_asking = true
	local ok, choice
	if dialog.choices then
		local chosen
		ok, chosen = pcall(dialogs().choose, dialog.title, dialog.body, dialog.choices,
			i18n().get("common.later"), i18n().get("common.ok"))
		_asking = false
		if not ok then
			Logger.error(LOG, "The MLX network dialog could not be shown: %s", tostring(chosen))
			return false
		end
		local action = chosen and dialog.actions[chosen] or nil
		if action ~= nil and not admitted_network_action(cause, action) then
			Logger.debug(LOG, "Retained MLX failure choice refused after its modal dialog: %s.", tostring(action))
			return false
		end
		if action == "retry" then
			M.retry_failure(cause.failure_revision)
		elseif action == "proxy_settings" then
			local opened, started = pcall(function()
				if not failure_is_current(cause) then return false end
				local handle = require("adapters.shell_runner").spawn(OPEN_BIN, { NETWORK_SETTINGS_URL }, nil)
				return handle ~= nil and handle.start() == true
			end)
			if not opened or started ~= true then
				Logger.error(LOG, "The network settings could not be opened: %s.", tostring(started))
			end
		elseif action == "diagnostics" then
			local _, log_path = network_capabilities(cause)
			if not log_path or not failure_is_current(cause) then return false end
			local opened, started = pcall(function()
				local handle = require("adapters.shell_runner").spawn(OPEN_BIN, { log_path }, nil)
				return handle ~= nil and handle.start() == true
			end)
			if not opened or started ~= true then Logger.error(LOG, "The failure log could not be opened.") end
		elseif action == "alternative_backend" then
			if not failure_is_current(cause) then return false end
			local called, selected = pcall(_alternative)
			if not called or selected == false then
				Logger.error(LOG, "Selecting Ollama instead of MLX failed: %s.", tostring(selected))
			end
		else
			Logger.info(LOG, "MLX network fix declined (%s).", tostring(cause.kind))
		end
		return true
	elseif dialog.secondary == nil then
		-- The native alert types its optional arguments: a nil second button
		-- followed by a style is not "no button", so a notice passes neither.
		ok, choice = pcall(dialogs().block_alert, dialog.title, dialog.body, dialog.primary)
	else
		ok, choice = pcall(dialogs().block_alert, dialog.title, dialog.body,
			dialog.primary, dialog.secondary, "warning")
	end
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
	elseif dialog.action == "install" then
		M.install()
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

--- Runs the MLX runtime installation the user asked for through the router,
--- then restarts the MLX model. A failure is presented by the router, which
--- opens this offer again with its cause and the repair button.
--- @param mode string "install" for an absent runtime, "repair" to rebuild it, "retry" to reuse it when valid.
--- @param failure_revision number|nil Captured failed intent, required for a network retry.
--- @return boolean accepted
local function run_installation(mode, failure_revision)
	local label = mode == "repair" and "repair" or mode == "retry" and "retry" or "installation"
	if failure_revision ~= nil and checker().failure_action_admitted(failure_revision) ~= true then return false end
	if _installation_running then
		Logger.info(LOG, "An MLX installation or repair is already running.")
		return false
	end
	_installation_running = true
	Logger.start(LOG, "Running the MLX %s on the user's request…", label)
	if failure_revision ~= nil and checker().failure_action_admitted(failure_revision) ~= true then
		_installation_running = false
		Logger.warn(LOG, "MLX failure retry retired before native selection admission.")
		return false
	end
	local ok, accepted = pcall(function()
		return router().select_mlx(function(done)
			_installation_running = false
			if done ~= true then
				local cause = resolve_cause(nil)
				_last_repair_failure = cause.kind
				Logger.error(LOG, "The MLX %s failed (%s).", label, tostring(cause.kind))
				return false
			end
			_last_repair_failure = nil
			Logger.success(LOG, "MLX %s done.", label)
			pcall(notifications().notify,
				i18n().get(mode == "repair" and "mlx.repair_done" or "mlx.install_done"),
				i18n().get("mlx.deps_step_ready"), "success")
			-- The model restarts outside the installer's completion, which still
			-- holds its bootstrap intent while it delivers this result.
			if type(_resume) == "function" then
				local resume = _resume
				local committed = deferred().after(0, function()
					local resumed, result = pcall(resume)
					if not resumed or result == false then
						Logger.error(LOG, "The MLX model did not restart after the %s: %s.", label, tostring(result))
					end
				end, "mlx_repair_offer.resume")
				if committed ~= true then
					Logger.error(LOG, "The MLX model restart could not be scheduled after the %s.", label)
				end
			end
			return true
		end, mode == "repair" and { repair = true }
			or failure_revision ~= nil and { failure_revision = failure_revision } or nil)
	end)
	if not ok or accepted ~= true then
		_installation_running = false
		Logger.error(LOG, "The MLX %s was not accepted: %s.", label, tostring(accepted))
		return false
	end
	return true
end

--- Removes Ergopti's MLX environment and installs it again, then restarts
--- the MLX model; a failure opens the offer again with its own cause.
--- @return boolean accepted
function M.repair()
	return run_installation("repair")
end

--- Retries the exact failed native intent without granting a full runtime repair.
--- @param revision number Captured failure receipt revision.
--- @return boolean accepted
function M.retry_failure(revision)
	return run_installation("retry", revision)
end

--- Installs the absent MLX runtime, as selecting the MLX backend does, then
--- restarts the MLX model; a failure opens the offer again with its own cause
--- and the repair button.
--- @return boolean accepted
function M.install()
	return run_installation("install")
end

--- Forgets the pending dialog, the installation state and the registrations.
function M.reset()
	_alternative, _resume, _pending_cause = nil, nil, nil
	_scheduled, _asking, _installation_running, _last_repair_failure = false, false, false, nil
	_network_contract = nil
end

return M
