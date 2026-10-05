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
--- @param replacements table|nil Cached, current rows { label, value }.
--- @param modal_observer function|nil Limited originating-owner restoration observer.
--- @return boolean shown
--- @return boolean retry Explicit choice after acknowledged native restoration.
--- @return any replacement An opaque choice only after native restoration.
function M.show(origin, replacements, modal_observer)
	local title = require("window_titles").compose((I18n.get("llm.unreachable.title"):gsub("{1}", function() return "Ollama" end)))
	local body = (I18n.get("llm.unreachable.body_unconfirmed"):gsub("{1}", function() return "Ollama" end)
		:gsub("{2}", function() return origin end))
	local keep_off = I18n.get("llm.unreachable.keep_off")
	local retry = I18n.get("button.retry")
	local command
	local choices = type(replacements) == "table" and #replacements > 0
	if Shell.has_command("zenity") then
		command = "zenity " .. (choices and "--list" or "--question") .. " --no-markup --title=" .. Shell.quote(title)
			.. " --text=" .. Shell.quote(body)
		if choices then
			command = command .. " --column='' --column='' --hide-column=1 --print-column=1"
				.. " --ok-label=" .. Shell.quote(I18n.get("llm.unreachable.apply"))
				.. " --cancel-label=" .. Shell.quote(keep_off) .. " retry " .. Shell.quote(retry)
		else
			command = command .. " --ok-label=" .. Shell.quote(retry) .. " --cancel-label=" .. Shell.quote(keep_off)
		end
	elseif Shell.has_command("kdialog") then
		command = "kdialog " .. (choices and "--menu" or "--yesno") .. " " .. Shell.quote(body) .. " --title " .. Shell.quote(title)
		if choices then
			command = command .. " retry " .. Shell.quote(retry)
		else
			command = command .. " --yes-label " .. Shell.quote(retry) .. " --no-label " .. Shell.quote(keep_off)
		end
	else
		Logger.warn(LOG, "The local AI stays off; no native acknowledgement dialog is available.")
		return require("adapters.notifier").send(body, { title = title, level = "warning" }) == true, false
	end
	if choices then
		for index, row in ipairs(replacements) do
			command = command .. " replacement_" .. tostring(index) .. " " .. Shell.quote(row.label)
		end
	end
	local restored = true
	local confirmed, answer = Modal.run(function()
		-- The native owner can refuse its release and still invoke the callback.
		if not restored then return false end
		return Shell.exec_checked(command)
	end, { observer = function(stage, receipt)
		if stage == "refused" or (stage == "after" and receipt.ok ~= true) then restored = false end
		if type(modal_observer) == "function" and modal_observer(stage, receipt) ~= true then restored = false end
		return restored
	end })
	local shown = confirmed == true and restored
	if not shown then Logger.warn(LOG, "The local AI retry was not confirmed or native restoration did not settle.") end
	if not shown then return false, false end
	if not choices then return true, true end
	local selected = type(answer) == "string" and answer:match("^([^\r\n]*)[\r\n]*$") or nil
	if selected == "retry" then return true, true end
	local index = selected and tonumber(selected:match("^replacement_(%d+)$"))
	return true, false, index and replacements[index] and replacements[index].value or nil
end

return M
