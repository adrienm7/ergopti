--- ui/llm_enable_refusal.lua

--- ==============================================================================
--- MODULE: Local AI Enable Refusal
--- DESCRIPTION:
--- Names the configured Ollama address and offers an explicitly chosen retry.
--- The existing native modal owner must settle before another request starts.
--- ==============================================================================

local M = {}
local I18n = require("infra.i18n")
local Shell = require("adapters.shell_runner")
local Modal = require("ui.modal")
local Logger = require("logger.shim")
local LOG = "ui.llm_enable_refusal"





-- ================================
-- ================================
-- ======= 1/ Native Notice =======
-- ================================
-- ================================

--- Offers a fresh retry without a runtime repair or silent backend switch.
--- @param origin string Exact configured origin of the refused enable.
--- @return boolean shown
--- @return boolean retry Explicit choice after acknowledged native restoration.
function M.show(origin)
	local title = require("window_titles").compose((I18n.get("llm.unreachable.title"):gsub("{1}", function() return "Ollama" end)))
	local body = (I18n.get("llm.unreachable.body_unconfirmed"):gsub("{1}", function() return "Ollama" end)
		:gsub("{2}", function() return origin end))
	local keep_off = I18n.get("llm.unreachable.keep_off")
	local retry = I18n.get("button.retry")
	local command
	if Shell.has_command("zenity") then
		command = "zenity --question --no-markup --title=" .. Shell.quote(title)
			.. " --text=" .. Shell.quote(body) .. " --ok-label=" .. Shell.quote(retry)
			.. " --cancel-label=" .. Shell.quote(keep_off)
	elseif Shell.has_command("kdialog") then
		command = "kdialog --yesno " .. Shell.quote(body) .. " --title " .. Shell.quote(title)
			.. " --yes-label " .. Shell.quote(retry) .. " --no-label " .. Shell.quote(keep_off)
	else
		Logger.warn(LOG, "The local AI stays off; no native acknowledgement dialog is available.")
		return require("adapters.notifier").send(body, { title = title, level = "warning" }) == true, false
	end
	local restored = true
	local confirmed = Modal.run(function()
		-- The native owner can refuse its release and still invoke the callback.
		if not restored then return false end
		return Shell.exec_checked(command)
	end, { observer = function(stage, receipt)
		if stage == "refused" or (stage == "after" and receipt.ok ~= true) then restored = false end
		return true
	end }) == true
	local shown = confirmed and restored
	if not shown then Logger.warn(LOG, "The local AI retry was not confirmed or native restoration did not settle.") end
	return shown, shown
end

return M
