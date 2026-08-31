--- ui/changelog/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Changelog / Release Notes Viewer
--- Handles JS->Lua messages from _shared/ui/changelog/.
--- Bridge name: "changelog_bridge"
--- ==============================================================================

local M = {}
M.bridge_name = "changelog_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.changelog"

-- Read canonical version from the single-source module (SSoT).
local Version = require("infra.version")
local Shell = require("adapters.shell_runner")

local REPOSITORY_URL = "https://github.com/adrienm7/ergopti"

--- Returns whether a URL belongs to the repository's HTTPS surface.
--- @param value any
--- @return boolean
local function is_allowed_repository_url(value)
	return type(value) == "string"
		and value:match("^https://github%.com/adrienm7/ergopti/?[A-Za-z0-9._~/%?=&+#-]*$") ~= nil
end

--- Converts the updater's cached record to the page's release schema.
--- @param cached table
--- @return table
local function page_release(cached)
	local tag = type(cached.tag) == "string" and cached.tag or ""
	local release_url = REPOSITORY_URL .. "/releases"
	if tag:match("^[A-Za-z0-9._+-]+$") then release_url = release_url .. "/tag/" .. tag end
	return {
		tag_name = tag,
		body = type(cached.notes) == "string" and cached.notes or "",
		html_url = release_url,
		published_at = type(cached.published_at) == "string" and cached.published_at or "",
		prerelease = cached.prerelease == true,
	}
end

--- Builds the initial changelog data payload.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state, channel)
	state = type(state) == "table" and state or {}
	channel = channel == "dev" and "dev" or "main"
	local releases = {}

	-- Try to get releases from the updater if loaded.
	local ok_up, updater = pcall(require, "modules.updater.manager")
	if ok_up and updater then
		-- The updater may have cached release data.
		local ok_cached, cached = pcall(function()
			return type(updater.get_cached_release) == "function" and updater.get_cached_release() or nil
		end)
		local ok_channel, cached_channel = pcall(function()
			return type(updater.get_channel) == "function" and updater.get_channel() or nil
		end)
		local expected_channel = channel == "dev" and "dev" or "stable"
		if ok_cached and cached and ok_channel and cached_channel == expected_channel then
			releases[#releases + 1] = page_release(cached)
		end
	end

	return {
		action = "releases",
		releases = releases,
		channel = channel,
		cache_miss = #releases == 0,
		repo_url = REPOSITORY_URL .. "/releases",
		version = state._version or Version.VERSION,
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Changelog UI ready.")
			return _build_initial_payload(state, "main")
		end
		if payload == "refresh" then
			return _build_initial_payload(state, "main")
		end
		if payload == "close" then
			Logger.info(LOG, "Changelog close requested.")
			return nil
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "fetch" then
		return _build_initial_payload(state, payload.channel)
	end

	if action == "open_url" then
		if not is_allowed_repository_url(payload.url) then
			Logger.error(LOG, "Changelog rejected a non-repository URL.")
			return { action = "open_url", opened = false, error = "Release URL refused." }
		end
		if not Shell.has_command("xdg-open") then
			Logger.error(LOG, "xdg-open is unavailable — the release URL cannot be opened.")
			return { action = "open_url", opened = false, error = "xdg-open is unavailable." }
		end
		local opened = Shell.run("xdg-open " .. Shell.quote(payload.url) .. " >/dev/null 2>&1 &")
		if opened then
			Logger.info(LOG, "Opened changelog release URL.")
		else
			Logger.error(LOG, "The changelog release URL could not be opened.")
		end
		return {
			action = "open_url",
			opened = opened,
			error = opened and nil or "Release URL could not be opened.",
		}
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
