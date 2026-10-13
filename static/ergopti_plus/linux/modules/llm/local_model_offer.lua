--- modules/llm/local_model_offer.lua

--- ==============================================================================
--- MODULE: Missing Local Model Offer
--- DESCRIPTION:
--- Names a missing Ollama model and offers its existing download manager after
--- explicit manual consent bound to its original origin and installer. Automatic
--- typing only posts a notification owned by that endpoint.
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
--- @param automatic boolean Notifications do not acquire a download owner.
--- @return table
local function dependencies(automatic)
	local owner = _deps
	local deps = owner or {}
	local install, download = deps.install, nil
	if not automatic and install == nil then
		download = require("modules.llm.model_download")
		install = download.start
	end
	return {
		confirm = deps.confirm or confirm,
		notify = deps.notify or function(text, title)
			return require("adapters.application_notifier").send(text, { title = title, level = "warning" })
		end,
		install = download and function(base_url, model, on_done, current, on_retired)
			return install(base_url, model, model, on_done, current, on_retired)
		end or install,
		current = function()
			if _deps ~= owner then return false end
			if automatic then return true end
			if download then
				return package.loaded["modules.llm.model_download"] == download and download.start == install
			end
			return deps.install == install
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
--- @param opts table|nil { automatic, current, modal_observer, on_complete, on_retired }
--- @return boolean handled
--- @return boolean|nil downloading Exact affirmative installer admission, when attempted.
function M.handle(failure, opts)
	if not Policy.is_missing(failure) then return false end
	local model, base_url, reason = failure.model, failure.base_url, failure.reason
	local requesting = type(opts) == "table" and opts.current or nil
	local automatic = type(opts) == "table" and opts.automatic == true
	local complete = type(opts) == "table" and opts.on_complete or nil
	local retired = type(opts) == "table" and opts.on_retired or nil
	local deps = dependencies(automatic)
	local function bound()
		return failure.model == model and failure.base_url == base_url and failure.reason == reason
			and (type(opts) ~= "table" or (opts.current == requesting
				and opts.on_complete == complete and opts.on_retired == retired)) and deps.current()
	end
	local function current()
		if not bound() then return false end
		if type(requesting) ~= "function" then return true end
		local ok, admitted = pcall(requesting)
		return ok and admitted == true and bound()
	end
	if not current() then return true end
	local title = I18n.get("llm.local_model.missing_title")
	local name = Policy.normalize(model)
	local notices = _notified[base_url]
	if not notices then notices = {}; _notified[base_url] = notices end
	local notice = notices[name]
	if automatic then
		if notice ~= nil then return true end
		local ok, sent = pcall(deps.notify, label("llm.local_model.missing_notice", model), title)
		if ok and sent == true and current() and _notified[base_url] == notices and notices[name] == nil then
			notices[name] = {}
		end
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
	if not current() then return true end
	local installed, admitted = pcall(deps.install, base_url, model, function(done)
		if not current() then return end
		if done == true then
			if _notified[base_url] == notices and notice ~= nil and notices[name] == notice then
				notices[name] = nil
			end
			Logger.success(LOG, "Local model '%s' downloaded.", model)
			if type(complete) == "function" then complete() end
		else
			Logger.warn(LOG, "Local model '%s' download failed.", model)
		end
	end, current, retired)
	if not installed or admitted ~= true then
		Logger.warn(LOG, "Local model '%s' download was refused.", model)
	end
	return true, installed and admitted == true
end

--- Resets native effects and notices for isolated tests.
--- @param deps table|nil
function M._reset_for_test(deps)
	_deps, _asking, _notified = deps, false, {}
end

return M
