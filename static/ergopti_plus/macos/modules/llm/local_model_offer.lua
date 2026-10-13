--- modules/llm/local_model_offer.lua

--- ==============================================================================
--- MODULE: Local Model Offer
--- DESCRIPTION:
--- Tells the user that a model the local server (Ollama) was asked for is not
--- installed, names it, and offers the button that downloads it through the
--- AI menu's model download flow.
---
--- FEATURES & RATIONALE:
--- 1. One owner of the message: the AI agent, the screen reading and the AI
---    agent menu name a missing model the same way, with the same Download
---    button, so the user never has to guess a command.
--- 2. The download stays with its owner: the AI menu registers the installer
---    (its models manager and download window) when it is built; this module
---    never pulls a model by itself.
--- 3. Never while typing: a request of the automatic mode posts one
---    notification per endpoint and model, whose click opens the dialog, instead of a modal
---    dialog that would take the keystrokes.
--- ==============================================================================

local M = {}

local Logger        = require("infra.logger")
local i18n          = require("infra.i18n")
local Dialog        = require("infra.dialog_util")
local Notifications = require("infra.notifications")

local LOG = "llm.local_model_offer"

-- fn(model, on_done, is_current) -> boolean accepted; on_done(ok, reason) settles once
local _installer = nil
local _installer_generation = 0

-- The dialog is modal: a second failure while it is open asks nothing more
local _asking = nil

-- Endpoint and model notifications retained by their original registration
local _notified = {}




-- =====================================
-- =====================================
-- ======= 1/ Internal Helpers =========
-- =====================================
-- =====================================

--- Validates a model name.
--- @param model any
--- @param caller string The public function, for the error.
local function require_model(model, caller)
	if type(model) ~= "string" or model == "" then
		error("local_model_offer." .. caller .. ": a model name is required")
	end
end

--- Shows a tooltip notice.
--- @param text string
local function show_notice(text)
	local ok_tooltip, tooltip = pcall(require, "ui.tooltip")
	local ok_show, shown = false, nil
	if ok_tooltip and type(tooltip) == "table" and type(tooltip.show) == "function" then
		ok_show, shown = pcall(tooltip.show, text, true, true)
	end
	if not ok_show or shown ~= true then
		Logger.warn(LOG, "Local model notice was not shown: %s.", tostring(shown))
	end
end


--- Checks the retained manual requester before acquiring source or UI ports.
--- @param owner table Captured offer owner.
--- @return boolean current
local function requester_current(owner)
	if owner.request_current == nil then return true end
	local ok, current = pcall(owner.request_current)
	return ok == true and current == true
end

--- Captures the original configured endpoint and download registration.
--- @return table|nil owner
local function capture_owner(opts)
	local owner = { installer = _installer, generation = _installer_generation }
	if type(opts) == "table" then owner.request_current = opts.current end
	if owner.request_current ~= nil and type(owner.request_current) ~= "function" then return nil end
	if not requester_current(owner) then return nil end
	local ok, api = pcall(require, "modules.llm.api_ollama")
	if not ok or type(api) ~= "table" or type(api.get_base_url) ~= "function"
		or type(api.capture_service_owner) ~= "function" or not requester_current(owner) then return nil end
	owner.api, owner.origin_reader, owner.service_reader = api, api.get_base_url, api.capture_service_owner
	local service_ok, service_current = pcall(owner.service_reader)
	if not service_ok or type(service_current) ~= "function" or not requester_current(owner) then return nil end
	owner.service_current = service_current
	local current_ok, current = pcall(owner.service_current)
	if not current_ok or current ~= true or not requester_current(owner) then return nil end
	local read_ok, origin = pcall(owner.origin_reader)
	current_ok, current = pcall(owner.service_current)
	if not current_ok or current ~= true or not read_ok or type(origin) ~= "string" or origin == ""
		or not requester_current(owner) or owner.installer ~= _installer or owner.generation ~= _installer_generation
		or package.loaded["modules.llm.api_ollama"] ~= api or api.get_base_url ~= owner.origin_reader
		or api.capture_service_owner ~= owner.service_reader then return nil end
	owner.origin = origin
	return owner
end

--- A held consent cannot borrow a successor endpoint, API or installer.
--- @param owner table
--- @return boolean current
local function owner_current(owner)
	if type(owner) ~= "table" or not requester_current(owner) or owner.installer ~= _installer
		or owner.generation ~= _installer_generation then return false end
	local ok, api = pcall(require, "modules.llm.api_ollama")
	if not ok or api ~= owner.api or api.get_base_url ~= owner.origin_reader
		or api.capture_service_owner ~= owner.service_reader then return false end
	local current_ok, current = pcall(owner.service_current)
	if not current_ok or current ~= true then return false end
	local read_ok, origin = pcall(owner.origin_reader)
	current_ok, current = pcall(owner.service_current)
	return current_ok and current == true and read_ok and origin == owner.origin
		and requester_current(owner) and owner.installer == _installer and owner.generation == _installer_generation
		and package.loaded["modules.llm.api_ollama"] == api and api.get_base_url == owner.origin_reader
		and api.capture_service_owner == owner.service_reader
end

--- Clears only the exact notice captured before download acquisition.
local function forget_notification(owner, model, original_rows, original_receipt)
	local rows = _notified[owner.origin]
	if rows and rows == original_rows and rows[model] == original_receipt then rows[model] = nil end
end

--- Dispatches exactly the owner whose consent was accepted.
--- @return boolean accepted
local function install_owned(model, owner)
	if not owner_current(owner) then
		Logger.warn(LOG, "Local model download consent expired after its source changed.")
		return false
	end
	if type(owner.installer) ~= "function" then
		Logger.error(LOG, "Local model '%s' cannot be downloaded: no installer is registered.", model)
		show_notice(i18n.format("llm.local_model.missing_notice", model))
		return false
	end
	local original_rows = _notified[owner.origin]
	local original_receipt = original_rows and original_rows[model]
	local admitted, terminal, pending = false, false, nil
	local function publish(done, reason)
		if terminal then return end
		terminal = true
		if not owner_current(owner) then return end
		if type(owner.api.forget_local_models) == "function" then owner.api.forget_local_models() end
		if not owner_current(owner) then return end
		if done == true then
			forget_notification(owner, model, original_rows, original_receipt)
			Logger.success(LOG, "Local model '%s' downloaded.", model)
		else
			Logger.warn(LOG, "Local model '%s' was not downloaded (%s).", model, tostring(reason))
		end
	end
	Logger.start(LOG, "Downloading local model '%s'…", model)
	local ok, accepted = pcall(owner.installer, model, function(done, reason)
		if terminal then return end
		if not admitted then
			if pending == nil then pending = { done, reason } end
			return
		end
		publish(done, reason)
	end, function() return owner_current(owner) end)
	if not ok or accepted ~= true or not owner_current(owner) then
		terminal = true
		Logger.error(LOG, "The download of local model '%s' was refused.", model)
		return false
	end
	admitted = true
	if pending then publish(pending[1], pending[2]) end
	return true
end




-- =====================================
-- =====================================
-- ======= 2/ Public API ===============
-- =====================================
-- =====================================

--- Registers the owner of model downloads (the AI menu's models manager).
--- @param installer function|nil fn(model, on_done, is_current) -> boolean accepted, where
---        on_done(ok, reason) settles once and is_current retains original consent; nil clears it.
function M.set_installer(installer)
	if installer ~= nil and type(installer) ~= "function" then
		error("local_model_offer.set_installer: a function or nil is required")
	end
	_installer_generation = _installer_generation + 1
	_installer = installer
	Logger.debug(LOG, "Local model installer %s.", installer and "registered" or "cleared")
end

--- Downloads a model through the registered installer, the explicit choice of
--- the user (the dialog's button or the menu's row).
--- @param model string The model name, as the local server names it.
--- @param opts table|nil { current = predicate } retaining manual requester currency.
--- @return boolean accepted
function M.install(model, opts)
	require_model(model, "install")
	local owner = capture_owner(opts)
	if owner == nil then
		Logger.warn(LOG, "Local model download refused: its endpoint identity is unavailable.")
		return false
	end
	return install_owned(model, owner)
end

--- Tells the user that a model is not installed and offers its download.
--- @param model string The model name, as the local server names it.
--- @param opts table|nil { automatic = true } for a request of the automatic
---        mode: a notification per source and model, bound to that source.
---        current = predicate optionally retains the original manual requester.
--- @return boolean offered
local function offer_owned(model, opts, owner)
	if not owner_current(owner) then
		Logger.warn(LOG, "Local model offer expired after its source changed.")
		return false
	end
	local title = i18n.get("llm.local_model.missing_title")
	if type(opts) == "table" and opts.automatic == true then
		local rows = _notified[owner.origin] or {}
		_notified[owner.origin] = rows
		if rows[model] and owner_current(rows[model]) then
			Logger.debug(LOG, "Local model '%s' is still missing; its notification was already posted.", model)
			return false
		end
		rows[model] = owner
		Logger.warn(LOG, "Local model '%s' is not installed; notifying the user.", model)
		local admitted, closed, pending_click = false, false, false
		local function on_click()
			if closed then return false end
			if not admitted then pending_click = true; return false end
			closed = true
			return offer_owned(model, nil, owner)
		end
		local ok, sent = pcall(Notifications.notify, title, i18n.format("llm.local_model.missing_click", model),
			"warning", on_click)
		if not ok or sent ~= true then
			closed = true
			Logger.error(LOG, "The missing-model notification for '%s' was not posted.", model)
			if rows[model] == owner then rows[model] = nil end
			return false
		end
		admitted = true
		if pending_click then on_click() end
		return true
	end
	if _asking then
		Logger.info(LOG, "Local model '%s' is missing; its dialog is already open.", model)
		return false
	end
	Logger.warn(LOG, "Local model '%s' is not installed; offering its download.", model)
	local download = i18n.get("menu.llm.btn_download")
	local asking = { owner = owner }
	_asking = asking
	local ok, choice = pcall(Dialog.block_alert, title, i18n.format("llm.local_model.missing_body", model),
		download, i18n.get("common.cancel"), "warning")
	if _asking == asking then _asking = nil end
	if not owner_current(owner) then
		Logger.warn(LOG, "Local model download consent expired after its source changed.")
		return false
	end
	if not ok then
		Logger.error(LOG, "The missing-model dialog for '%s' could not be shown.", model)
		show_notice(i18n.format("llm.local_model.missing_notice", model))
		return false
	end
	if choice ~= download then
		Logger.info(LOG, "Download of local model '%s' declined.", model)
		return true
	end
	return install_owned(model, owner)
end

function M.offer(model, opts)
	require_model(model, "offer")
	local owner = capture_owner(opts)
	if owner == nil then
		Logger.warn(LOG, "Local model offer refused: its endpoint identity is unavailable.")
		return false
	end
	return offer_owned(model, opts, owner)
end

--- Tells whether a failure reason of the local transport is a missing model.
--- @param reason any
--- @param detail any
--- @return boolean missing
function M.is_missing(reason, detail)
	if type(detail) ~= "table" or type(detail.model) ~= "string" or detail.model == "" then return false end
	local ok, Ollama = pcall(require, "modules.llm.api_ollama")
	return ok and type(Ollama) == "table" and Ollama.MODEL_MISSING ~= nil and reason == Ollama.MODEL_MISSING
end

--- Forgets the posted notifications and the installer, for tests and a fresh start.
function M.reset()
	_installer_generation = _installer_generation + 1
	_installer, _asking, _notified = nil, nil, {}
end

return M
