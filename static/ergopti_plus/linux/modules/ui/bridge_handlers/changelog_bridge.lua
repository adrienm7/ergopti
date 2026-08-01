--- modules/ui/bridge_handlers/changelog_bridge.lua

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

--- Builds the initial changelog data payload.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local releases = {}

	-- Try to get releases from the updater if loaded.
	local ok_up, updater = pcall(require, "modules.updater.manager")
	if ok_up and updater then
		-- The updater may have cached release data.
		local cached = updater.get_cached_release()
		if cached then
			releases[#releases + 1] = {
				tag = cached.tag,
				notes = cached.notes or "",
				published_at = cached.published_at or "",
				prerelease = cached.prerelease or false,
			}
		end
	end

	return {
		releases = releases,
		repo_url = "https://github.com/adrienm7/ergopti/releases",
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
			return _build_initial_payload(state)
		end
		if payload == "refresh" then
			return _build_initial_payload(state)
		end
		if payload == "close" then
			Logger.info(LOG, "Changelog close requested.")
			return nil
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "open_release" and payload.url then
		Logger.info(LOG, "Open release: %s", payload.url)
		os.execute(string.format("xdg-open '%s' 2>/dev/null &",
			tostring(payload.url):gsub("'", "'\\''")))
		return { opened = true }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
