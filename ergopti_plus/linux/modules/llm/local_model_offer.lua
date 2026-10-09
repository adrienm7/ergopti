--- modules/llm/local_model_offer.lua

--- ==============================================================================
--- MODULE: Missing Local Model Offer
--- DESCRIPTION:
--- Names a missing Ollama model and offers its existing download manager after
--- explicit manual consent. Automatic typing only posts a notification.
--- ==============================================================================

local M = {}
local Policy = require("llm.local_model_policy")
local Logger = require("logger.shim")
local I18n = require("infra.i18n")
local LOG = "modules.llm.local_model_offer"

local _asking = false
local _notified = {}
local _deps = nil





-- ================================
-- ================================
-- ======= 1/ Native Owners =======
-- ================================
-- ================================

--- Fills a translated model placeholder without interpreting model text.
--- @param key string
--- @param model string
--- @return string
local function label(key, model)
	return (I18n.get(key):gsub("{1}", function() return model end))
end

--- Asks through the existing modal keyboard-release owner.
--- @param title string
--- @param text string
--- @return boolean|nil nil when no native question could be shown.
local function confirm(title, text, opts)
	local Shell = require("adapters.shell_runner")
	title = require("window_titles").compose(title)
	local command
	if Shell.has_command("zenity") then
		command = "zenity --question --no-markup --default-cancel --title=" .. Shell.quote(title)
			.. " --text=" .. Shell.quote(text) .. " --ok-label=" .. Shell.quote(I18n.get("menu.llm.btn_download"))
			.. " --cancel-label=" .. Shell.quote(I18n.get("common.cancel"))
	elseif Shell.has_command("kdialog") then
		command = "kdialog --yesno " .. Shell.quote(text) .. " --title " .. Shell.quote(title)
			.. " --yes-label " .. Shell.quote(I18n.get("menu.llm.btn_download"))
			.. " --no-label " .. Shell.quote(I18n.get("common.cancel"))
	else
		return nil
	end
	local ok, _, reason = require("ui.modal").run(function() return Shell.exec_checked(command) end, { observer = type(opts) == "table" and opts.modal_observer or nil })
	if ok == true then return true end
	if reason == "command exited with status 1" then return false end
	return nil
end

--- Resolves native effects without acquiring ownership until needed.
--- @return table
local function dependencies()
	local deps = _deps or {}
	return {
		confirm = deps.confirm or confirm,
		notify = deps.notify or function(text, title)
			return require("adapters.application_notifier").send(text, { title = title, level = "warning" })
		end,
		install = deps.install or function(base_url, model, on_done, current)
			return require("modules.llm.model_download").start(base_url, model, model, on_done, current)
		end,
	}
end





-- ======================================
-- ======================================
-- ======= 2/ Missing Model Offer =======
-- ======================================
-- ======================================

--- Offers a missing model only for an already admitted, current native failure.
--- @param failure any Structured local-model failure.
--- @param opts table|nil { automatic, current, modal_observer }
--- @return boolean handled
function M.handle(failure, opts)
	if not Policy.is_missing(failure) then return false end
	local function current()
		if type(opts) ~= "table" or type(opts.current) ~= "function" then return true end
		local ok, admitted = pcall(opts.current)
		return ok and admitted == true
	end
	if not current() then return true end
	local model, title = failure.model, I18n.get("llm.local_model.missing_title")
	local deps = dependencies()
	local name = Policy.normalize(model)
	if type(opts) == "table" and opts.automatic == true then
		if not Policy.should_notify(_notified, model) then return true end
		local ok, sent = pcall(deps.notify, label("llm.local_model.missing_notice", model), title)
		if ok and sent == true then _notified[name] = true end
		if not ok or sent ~= true then Logger.warn(LOG, "Missing-model notification was refused: %s.", model) end
		return true
	end
	if _asking then return true end
	_asking = true
	local ok, accepted = pcall(deps.confirm, title, label("llm.local_model.missing_body", model), opts)
	_asking = false
	if not current() then return true end
	if not ok or accepted == nil then
		Logger.warn(LOG, "Missing-model confirmation could not be shown: %s.", model)
		deps.notify(label("llm.local_model.missing_notice", model), title)
		return true
	end
	if accepted ~= true then return true end
	Logger.start(LOG, "Downloading explicitly requested local model '%s'…", model)
	local installed, admitted = pcall(deps.install, failure.base_url, model, function(done)
		if done == true then
			_notified[name] = nil
			Logger.success(LOG, "Local model '%s' downloaded.", model)
		else
			Logger.warn(LOG, "Local model '%s' download failed.", model)
		end
	end, current)
	if not installed or admitted ~= true then
		Logger.warn(LOG, "Local model '%s' download was refused.", model)
	end
	return true
end

--- Resets native effects and notices for isolated tests.
--- @param deps table|nil
function M._reset_for_test(deps)
	_deps, _asking, _notified = deps, false, {}
end

return M
