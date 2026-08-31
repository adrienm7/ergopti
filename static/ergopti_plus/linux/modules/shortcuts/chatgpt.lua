--- modules/shortcuts/chatgpt.lua

--- ==============================================================================
--- MODULE: ChatGPT Shortcut Preference (Linux)
--- DESCRIPTION:
--- Owns the canonical URL opened by Linux's default Ctrl+G shortcut. The value
--- comes from the shared feature manifest, survives daemon restarts, and is
--- opened through the driver's shell adapter.
---
--- WHY THIS MODULE EXISTS:
--- Linux captured Ctrl+G and could run a generic open-URL action, but never read
--- `shortcuts.chatgpt_url`. The setting was therefore declared for Windows and
--- macOS only even though the Linux input path already had every prerequisite.
---
--- FEATURES & RATIONALE:
--- 1. Manifest-owned default: all three drivers read the same shipped URL.
--- 2. Durable-before-live mutation: a failed storage write cannot appear saved.
--- 3. Web-only validation: arbitrary URI schemes never reach xdg-open from this
---    setting; the generic open-URL action remains the surface for other URLs.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Manifest = require("infra.manifest_reader")
local Shell = require("adapters.shell_runner")
local Storage = require("adapters.storage")

local LOG = "modules.shortcuts.chatgpt"
local FEATURE_PATH = "shortcuts.chatgpt_url"

M.DEFAULT_URL = Manifest.default_for(FEATURE_PATH)

--- Whether a value is a non-empty HTTP(S) URL with no whitespace.
--- @param value any
--- @return boolean
function M.is_valid(value)
	return type(value) == "string" and value:match("^https?://%S+$") ~= nil
end

if not M.is_valid(M.DEFAULT_URL) then
	error("[chatgpt] the manifest default for '" .. FEATURE_PATH .. "' is not an HTTP(S) URL.")
end

--- Returns the persisted URL, or the canonical shipped default.
--- @return string
function M.get_url()
	local stored = Storage.get(FEATURE_PATH, nil)
	if M.is_valid(stored) then return stored end
	if stored ~= nil then
		Logger.warn(LOG, "Stored ChatGPT URL is invalid — using the shipped default.")
	end
	return M.DEFAULT_URL
end

--- Persists a new URL.
--- @param value any
--- @return boolean Whether the durable value changed.
function M.set_url(value)
	if not M.is_valid(value) then
		Logger.error(LOG, "Refusing an invalid ChatGPT URL.")
		return false
	end
	if Storage.set(FEATURE_PATH, value) ~= true then
		Logger.error(LOG, "ChatGPT URL could not be persisted — the active value is unchanged.")
		return false
	end
	Logger.info(LOG, "ChatGPT URL updated.")
	return true
end

--- Opens the current URL in the desktop's default browser.
--- @return boolean Whether the launch command was accepted.
function M.open()
	if not Shell.has_command("xdg-open") then
		Logger.error(LOG, "xdg-open is unavailable — the ChatGPT URL cannot be opened.")
		return false
	end
	local url = M.get_url()
	local opened = Shell.run("xdg-open " .. Shell.quote(url) .. " >/dev/null 2>&1 &")
	if not opened then Logger.error(LOG, "The ChatGPT URL could not be opened.") end
	return opened
end

return M
