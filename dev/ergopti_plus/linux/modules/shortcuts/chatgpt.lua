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
--- 2. Durable-before-live mutation: a failed configuration write cannot appear saved.
--- 3. Web-only validation: arbitrary URI schemes never reach xdg-open from this
---    setting; the generic open-URL action remains the surface for other URLs.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ConfigOutdated = require("config_outdated")
local Manifest = require("infra.manifest_reader")
local Shell = require("adapters.shell_runner")
local Paths = require("infra.config_paths")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")

local LOG = "modules.shortcuts.chatgpt"
local FEATURE_PATH = "shortcuts.chatgpt_url"
local _configuration_owner = nil

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

--- Resolves only this owner's declared leaf from a decoded configuration. A
--- stored value that is not an HTTP(S) URL never reaches xdg-open: it is
--- outdated configuration, warned once, replaced by the manifest default and
--- left unmarked so the cleanup offers it.
--- @param document table Decoded configuration.
--- @param mark function|nil Optional exact-path ownership visitor.
--- @return string Effective URL.
local function resolve(document, mark)
	local section = document.shortcuts
	if section ~= nil and type(section) ~= "table" then
		ConfigOutdated.report({ "shortcuts" }, "a table of settings is expected here", Logger)
		return M.DEFAULT_URL
	end
	local stored = section and section.chatgpt_url
	if stored == nil then return M.DEFAULT_URL end
	if not M.is_valid(stored) then
		ConfigOutdated.report({ "shortcuts", "chatgpt_url" }, "the value is not an HTTP(S) URL", Logger)
		return M.DEFAULT_URL
	end
	if mark then mark("shortcuts", "chatgpt_url") end
	return stored
end

--- Reads one exact source for validation and conditional publication.
--- @param path string Configuration file.
--- @return string url
--- @return table source
local function read(path)
	local content, status, detail = Writer.read_classified(path)
	assert(status == "ok" or status == "absent", "ChatGPT configuration is unreadable: " .. tostring(detail))
	local document = Codec.decode(content or "")
	assert(type(document) == "table", "ChatGPT configuration is malformed")
	return resolve(document), { status = status, content = content }
end

--- Marks the same exact leaf consumed by the canonical reader.
--- @param document table Decoded configuration.
--- @param mark function Segment-based ownership visitor.
function M.mark_config_reads(document, mark)
	resolve(document, mark)
end

--- Returns the persisted URL, or the manifest default for proven absence.
--- @return string
function M.get_url()
	return (read(Paths.config("config.toml")))
end

--- Persists a sparse URL against the exact source that was validated.
--- @param value any
--- @return boolean Whether the durable value was accepted.
function M.set_url(value)
	if _configuration_owner ~= nil then return false end
	if not M.is_valid(value) then
		Logger.error(LOG, "Refusing an invalid ChatGPT URL.")
		return false
	end
	local called, committed, detail = pcall(function()
		local path = Paths.config("config.toml")
		local _, source = read(path)
		return Writer.batch_write(path, { Manifest.sparse_operation(FEATURE_PATH, value) }, nil, source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "ChatGPT URL was not persisted: %s.", tostring(called and detail or committed))
		return false
	end
	Logger.info(LOG, "ChatGPT URL updated.")
	return true
end

--- Opens the current URL in the desktop's default browser.
--- @return boolean Whether the launch command was accepted.
function M.open()
	if _configuration_owner ~= nil then return false end
	if not Shell.has_command("xdg-open") then
		Logger.error(LOG, "xdg-open is unavailable — the ChatGPT URL cannot be opened.")
		return false
	end
	local url = M.get_url()
	local opened = Shell.run("xdg-open " .. Shell.quote(url) .. " >/dev/null 2>&1 &")
	if not opened then Logger.error(LOG, "The ChatGPT URL could not be opened.") end
	return opened
end


--- Acquires this leaf alongside the shortcut runtime owners.
--- @param owner table Exact transaction token.
--- @return boolean acquired
function M.acquire_configuration(owner)
	if type(owner) ~= "table" or _configuration_owner ~= nil then return false end
	_configuration_owner = owner
	return true
end

--- Releases the exact leaf owner after acknowledged completion.
--- @param owner table Exact transaction token.
--- @return boolean released
function M.release_configuration(owner)
	if type(owner) ~= "table" or _configuration_owner ~= owner then return false end
	_configuration_owner = nil
	return true
end

--- Validates this same reader against a detached scoped candidate.
--- @param document table Decoded configuration.
--- @param written boolean|nil True for the document a scope just wrote: a URL
---   there is that write's output, so an invalid one raises.
--- @return string Effective URL.
function M.configuration_candidate(document, written)
	if written then
		local section = document.shortcuts
		local stored = type(section) == "table" and section.chatgpt_url or nil
		assert(stored == nil or M.is_valid(stored), "ChatGPT shortcut URL must be an HTTP(S) URL")
	end
	return resolve(document)
end

return M
