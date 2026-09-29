--- modules/updater/init.lua

--- ==============================================================================
--- MODULE: Packaged Update Identity
--- DESCRIPTION:
--- Exposes the installed build's channel, the launcher version, the build
--- identity (kind, version and commit), the releases page and the shared
--- update-channel registry used by the About menu. The automatic checks are
--- modules/updater/auto_check.lua's; the outer launcher's Sparkle controller
--- owns download progress, signature verification, installation, and
--- relaunch. This identity facade performs no update I/O.
--- ==============================================================================

local M = {}

local hs         = hs
local Logger     = require("infra.logger")
local Paths      = require("infra.paths")
local FileSystem = require("adapters.file_system")
local JsonCodec  = require("adapters.json_codec")
local Channels   = require("updater.channels")
local VersionLabel = require("updater.version_label")
local Snapshot   = require("diagnostics.snapshot")

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

--- Loads the shared update-channel registry. It has no fallback: a guessed
--- channel list could point the launcher at another channel's feed.
--- @return table registry updater.channels interpreter.
local function load_channel_registry()
	local path = Paths.shared("modules/updater/channels.json")
	local raw = type(path) == "string" and path ~= "" and FileSystem.read(path) or nil
	if type(raw) ~= "string" then error("the shared update channel registry is unreadable", 0) end
	local decoded, decode_err = JsonCodec.decode(raw)
	if decode_err then error("the shared update channel registry is not JSON: " .. tostring(decode_err), 0) end
	local registry, load_err = Channels.load(decoded)
	if not registry then error("the shared update channel registry is invalid: " .. tostring(load_err), 0) end
	return registry
end

local github = load_github_identity()
local channels = load_channel_registry()
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
--- The launcher sends "<CFBundleShortVersionString>+<CFBundleVersion>", and the
--- second part is the CI run number Sparkle orders builds by. Shown to the user
--- it read as a second release id ("0.0.0-dev.131+543"), so it is dropped here.
--- @return string version
function M.current_version()
	if M.is_local_source() then return "local" end
	if not launcher_version then return "local" end
	return (launcher_version:gsub("%+.*$", ""))
end

--- Returns the shared update-channel registry (updater.channels interpreter).
--- @return table registry
function M.channels()
	return channels
end

--- Returns the channel of the running build: the registry channel that owns
--- the launcher version, or the unreleased-build channel for a source run.
--- @return string channel Registry channel id.
function M.installed_channel()
	if M.is_local_source() then return channels.unreleased_build_channel end
	return channels.channel_for_tag(M.current_version()) or channels.unreleased_build_channel
end

--- Returns the public releases page used by the About menu.
--- @return string url
function M.releases_page_url()
	return string.format("https://github.com/%s/%s/releases", M.GH_OWNER, M.GH_REPO)
end

--- Resolves the build identity the About menu's version row names: a stamped
--- release (a launcher version) or a local build, and the commit it was built
--- from. The commit comes from the one resolver behind the diagnostics
--- (infra/diagnostic_snapshot.resolve_commit): the package build stamp, else
--- the checkout's .git read as files, never a spawned git. When neither tells,
--- that resolver logs a WARNING with the reason and the commit stays empty; a
--- resolver that raises is logged as an ERROR and read the same way, so the
--- About submenu it heads is still drawn.
--- @param commit_opts table|nil Forwarded to resolve_commit, for tests.
--- @return table identity { kind, version, commit }: commit is "" when unknown.
function M.resolve_build_identity(commit_opts)
	local version = M.current_version()
	local is_local = M.is_local_source() or version == "local"
	local kind = is_local and VersionLabel.KIND_LOCAL or VersionLabel.KIND_RELEASE
	local ok, commit, source = pcall(function()
		return require("infra.diagnostic_snapshot").resolve_commit(commit_opts)
	end)
	if not ok then
		Logger.error(LOG, "Build commit resolution raised: %s.", tostring(commit))
		commit, source = "", Snapshot.COMMIT_SOURCE_UNKNOWN
	end
	if source == Snapshot.COMMIT_SOURCE_UNKNOWN then commit = "" end
	Logger.info(LOG, "Build identity: %s build %s, commit %s (source %s).", kind,
		is_local and "from source" or version, commit ~= "" and commit or Snapshot.UNKNOWN, source)
	return { kind = kind, version = is_local and "" or version, commit = commit }
end

-- Resolved once per Lua state: the commit a running driver was built from
-- cannot change under it, and the menu reads it on every rebuild.
local _build_identity = nil

--- The build identity, resolved on first use (the boot-time menu build).
--- @return table identity { kind, version, commit }
function M.build_identity()
	if _build_identity == nil then _build_identity = M.resolve_build_identity() end
	return _build_identity
end

return M
