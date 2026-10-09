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
---    notification per model, whose click opens the dialog, instead of a modal
---    dialog that would take the keystrokes.
--- ==============================================================================

local M = {}

local Logger        = require("infra.logger")
local i18n          = require("infra.i18n")
local Dialog        = require("infra.dialog_util")
local Notifications = require("infra.notifications")

local LOG = "llm.local_model_offer"

-- fn(model, on_done) -> boolean accepted; on_done(ok, reason) once the download settled
local _installer = nil

-- The dialog is modal: a second failure while it is open asks nothing more
local _asking = false

-- Models whose notification the automatic mode already posted
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




-- =====================================
-- =====================================
-- ======= 2/ Public API ===============
-- =====================================
-- =====================================

--- Registers the owner of model downloads (the AI menu's models manager).
--- @param installer function|nil fn(model, on_done) -> boolean accepted, where
---        on_done(ok, reason) runs once the download settled; nil clears it.
function M.set_installer(installer)
	if installer ~= nil and type(installer) ~= "function" then
		error("local_model_offer.set_installer: a function or nil is required")
	end
	_installer = installer
	Logger.debug(LOG, "Local model installer %s.", installer and "registered" or "cleared")
end

--- Downloads a model through the registered installer, the explicit choice of
--- the user (the dialog's button or the menu's row).
--- @param model string The model name, as the local server names it.
--- @return boolean accepted
function M.install(model)
	require_model(model, "install")
	if _installer == nil then
		-- The AI menu registers it when built: without it, only the name is left to show
		Logger.error(LOG, "Local model '%s' cannot be downloaded: no installer is registered.", model)
		show_notice(i18n.format("llm.local_model.missing_notice", model))
		return false
	end
	Logger.start(LOG, "Downloading local model '%s'…", model)
	local ok, accepted = pcall(_installer, model, function(done, reason)
		-- What the server holds changed: the next request lists it again
		local ok_ollama, Ollama = pcall(require, "modules.llm.api_ollama")
		if ok_ollama and type(Ollama) == "table" and type(Ollama.forget_local_models) == "function" then
			Ollama.forget_local_models()
		end
		if done == true then
			_notified[model] = nil
			Logger.success(LOG, "Local model '%s' downloaded.", model)
		else
			Logger.warn(LOG, "Local model '%s' was not downloaded (%s).", model, tostring(reason))
		end
	end)
	if not ok or accepted ~= true then
		Logger.error(LOG, "The download of local model '%s' was refused: %s.", model, tostring(accepted))
		return false
	end
	return true
end

--- Tells the user that a model is not installed and offers its download.
--- @param model string The model name, as the local server names it.
--- @param opts table|nil { automatic = true } for a request of the automatic
---        mode: a notification, once per model, whose click opens the dialog.
--- @return boolean offered
function M.offer(model, opts)
	require_model(model, "offer")
	local title = i18n.get("llm.local_model.missing_title")
	if type(opts) == "table" and opts.automatic == true then
		if _notified[model] then
			Logger.debug(LOG, "Local model '%s' is still missing; its notification was already posted.", model)
			return false
		end
		_notified[model] = true
		Logger.warn(LOG, "Local model '%s' is not installed; notifying the user.", model)
		local ok, sent = pcall(Notifications.notify, title, i18n.format("llm.local_model.missing_click", model),
			"warning", function() M.offer(model) end)
		if not ok or sent ~= true then
			Logger.error(LOG, "The missing-model notification for '%s' was not posted: %s.", model, tostring(sent))
			-- The next request tries again
			_notified[model] = nil
			return false
		end
		return true
	end
	if _asking then
		Logger.info(LOG, "Local model '%s' is missing; its dialog is already open.", model)
		return false
	end
	Logger.warn(LOG, "Local model '%s' is not installed; offering its download.", model)
	local download = i18n.get("menu.llm.btn_download")
	_asking = true
	local ok, choice = pcall(Dialog.block_alert, title, i18n.format("llm.local_model.missing_body", model),
		download, i18n.get("common.cancel"), "warning")
	_asking = false
	if not ok then
		Logger.error(LOG, "The missing-model dialog for '%s' could not be shown: %s.", model, tostring(choice))
		show_notice(i18n.format("llm.local_model.missing_notice", model))
		return false
	end
	if choice ~= download then
		Logger.info(LOG, "Download of local model '%s' declined.", model)
		return true
	end
	M.install(model)
	return true
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
	_installer, _asking, _notified = nil, false, {}
end

return M
