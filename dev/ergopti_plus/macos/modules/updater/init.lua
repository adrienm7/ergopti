--- modules/updater/init.lua

--- ==============================================================================
--- MODULE: Packaged Update Identity
--- DESCRIPTION:
--- Exposes the immutable channel, launcher version, and releases page used by
--- the About menu. The outer launcher's Sparkle controller exclusively owns
--- network checks, download progress, signature verification, installation,
--- and relaunch; this nested Hammerspoon module performs no update I/O.
--- ==============================================================================

local M = {}

local hs         = hs
local Logger     = require("infra.logger")
local Paths      = require("infra.paths")
local FileSystem = require("adapters.file_system")
local JsonCodec  = require("adapters.json_codec")

local LOG = "updater"
local BUNDLED_ID = "com.ergoptiplus.app.hammerspoon"
local DEFAULT_GITHUB = { owner = "adrienm7", repo = "ergopti" }

--- Loads the shared repository identity without introducing a second update
--- engine. Missing or invalid generated data remains visible in the log.
--- @return table github Repository owner and name.
local function load_github_identity()
	local defaults_path = Paths.shared("modules/updater/defaults.json")
	if type(defaults_path) == "string" and defaults_path ~= "" then
		local raw = FileSystem.read(defaults_path)
		if raw then
			local ok, parsed = pcall(JsonCodec.decode, raw)
			if ok and type(parsed) == "table" and type(parsed.github) == "table" then
				local owner = parsed.github.owner
				local repo = parsed.github.repo
				if type(owner) == "string" and owner ~= ""
					and type(repo) == "string" and repo ~= "" then
					return { owner = owner, repo = repo }
				end
			end
		end
	end
	Logger.warn(LOG, "Updater repository defaults unavailable; using the packaged identity.")
	return DEFAULT_GITHUB
end

local github = load_github_identity()
local launcher_version = (function()
	local ok, value = pcall(os.getenv, "ERGOPTI_LAUNCHER_VERSION")
	if ok and type(value) == "string" and value ~= "" then return value end
	return nil
end)()

M.GH_OWNER = github.owner
M.GH_REPO = github.repo

--- Reports whether Lua is running outside the packaged nested Hammerspoon app.
--- @return boolean local_source
function M.is_local_source()
	local info = hs.processInfo
	if not info then return true end
	return (info.bundleID or "") ~= BUNDLED_ID
end

--- Returns the outer launcher version injected into the nested process.
--- @return string version
function M.current_version()
	if M.is_local_source() then return "local" end
	return launcher_version or "local"
end

--- Returns the immutable channel stamped into the packaged launcher version.
--- @return string channel Either "dev" or "main".
function M.default_channel()
	if M.is_local_source() then return "dev" end
	if launcher_version and launcher_version:match("%-dev%.") then return "dev" end
	return "main"
end

--- Returns the public releases page used by the About menu.
--- @return string url
function M.releases_page_url()
	return string.format("https://github.com/%s/%s/releases", M.GH_OWNER, M.GH_REPO)
end

return M
