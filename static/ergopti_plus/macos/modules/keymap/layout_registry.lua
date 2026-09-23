--- modules/keymap/layout_registry.lua

--- ==============================================================================
--- MODULE: Layout Registry (macOS client)
--- DESCRIPTION:
--- Installs a layout of the keyboard-layout registry on macOS: downloads
--- index.json and the layout's .keylayout from the repository folder, verifies
--- the file against the index (_shared/lua/layouts/registry.lua), keeps the
--- verified copy in the configuration folder and installs the .keylayout
--- itself, unchanged, in ~/Library/Keyboard Layouts, where macOS lists it among
--- the input sources.
---
--- FEATURES & RATIONALE:
--- 1. macOS reads a .keylayout natively, so the registry file IS the installed
---    layout: nothing is converted, generated or rebuilt on this platform.
--- 2. Nothing is written before the layout matches its index. The local copy is
---    written layout first, index second, so an interruption leaves a layout
---    that no longer matches its index and is downloaded again, never a stale
---    index vouching for a file it does not describe.
--- 3. Every collaborator is injectable, so tests replay an installation without
---    network, Hammerspoon or a real home folder.
--- ==============================================================================

local Logger      = require("infra.logger")
local Paths       = require("infra.paths")
local ConfigPaths = require("infra.config_paths")
local FileSystem  = require("adapters.file_system")
local HttpClient  = require("adapters.http_client")
local Crypto      = require("adapters.crypto")
local Json        = require("json")
local Registry    = require("layouts.registry")

local M = {}

local LOG = "layout_registry"





-- ================================
-- ================================
-- ======= 1/ Settings ============
-- ================================
-- ================================

--- Folder macOS reads the current user's keyboard layouts from.
--- @return string Absolute path with a trailing slash.
local function user_layouts_dir()
	return FileSystem.expand_path("~/Library/Keyboard Layouts") .. "/"
end

--- Reads and decodes one shared JSON file.
--- @param rel string Path under _shared/.
--- @return table|nil value
--- @return string|nil error
local function read_shared_json(rel)
	local path = Paths.shared(rel)
	local raw = type(path) == "string" and FileSystem.read(path) or nil
	if type(raw) ~= "string" then return nil, "_shared/" .. rel .. " is unreadable" end
	local ok, decoded = pcall(Json.decode, raw)
	if not ok then return nil, "_shared/" .. rel .. " is not valid JSON" end
	return decoded, nil
end

--- The registry settings, resolved from the shared defaults.
--- @return table|nil settings
--- @return string|nil error
function M.settings()
	local layouts, layouts_err = read_shared_json("modules/layouts/defaults.json")
	if not layouts then return nil, layouts_err end
	local updater, updater_err = read_shared_json("modules/updater/defaults.json")
	if not updater then return nil, updater_err end
	return Registry.resolve(layouts, updater)
end

--- The production collaborators of M.install().
--- @param settings table Result of M.settings().
--- @return table
local function default_deps(settings)
	local client = HttpClient.new({ timeout_ms = settings.timeout_ms })
	return {
		settings = settings,
		transport = {
			get = function(url, headers, _timeout_ms, callback)
				client.get(url, headers, function(result)
					callback(result.status, result.body, result.error)
				end)
			end,
			decode_json = Json.decode,
			sha256 = function(text, callback)
				local digest = Crypto.sha256_bytes(text)
				if digest == "" then
					callback(nil, "the SHA-256 digest is unavailable")
				else
					callback(digest, nil)
				end
			end,
		},
		write = FileSystem.write,
		prepare_parent = FileSystem.prepare_parent_for_create,
		local_dir = ConfigPaths.get_config_dir() .. settings.local_folder .. "/",
		layouts_dir = user_layouts_dir(),
	}
end





-- ================================
-- ================================
-- ======= 2/ Installation ========
-- ================================
-- ================================

--- Writes one file, creating its folder first.
--- @param deps table
--- @param path string
--- @param content string
--- @return boolean ok
--- @return string|nil error
local function write_file(deps, path, content)
	local prepared, prepare_err = deps.prepare_parent(path)
	if not prepared then return false, "cannot create the folder of " .. path .. ": " .. tostring(prepare_err) end
	local written, write_err = deps.write(path, content)
	if not written then return false, "cannot write " .. path .. ": " .. tostring(write_err) end
	return true, nil
end

--- Publishes a verified download: the local copy, then the installed layout.
--- @param deps table
--- @param id string
--- @param detail table { entry, index_text, layout_text } from Registry.fetch.
--- @return string|nil installed_path
--- @return string|nil error
local function publish(deps, id, detail)
	local steps = {
		{ deps.local_dir .. id .. ".keylayout", detail.layout_text },
		{ deps.local_dir .. deps.settings.index_file, detail.index_text },
		{ deps.layouts_dir .. id .. ".keylayout", detail.layout_text },
	}
	for _, step in ipairs(steps) do
		local ok, err = write_file(deps, step[1], step[2])
		if not ok then return nil, err end
	end
	return steps[3][1], nil
end

--- Downloads, verifies and installs one registry layout.
--- on_done(true, { entry, path }) or on_done(false, reason) is called exactly once.
--- @param id string Registry id.
--- @param on_done function Terminal callback.
--- @param deps table|nil Collaborators; the production ones by default.
--- @return boolean dispatched False when nothing could be started (on_done was called).
function M.install(id, on_done, deps)
	if deps == nil then
		local settings, settings_err = M.settings()
		if not settings then
			Logger.error(LOG, "The layout registry is unusable: %s.", tostring(settings_err))
			on_done(false, settings_err)
			return false
		end
		deps = default_deps(settings)
	end
	Logger.start(LOG, "Installing the '%s' layout from the registry…", tostring(id))
	Registry.fetch(deps.settings, id, deps.transport, function(ok, detail)
		if not ok then
			Logger.error(LOG, "The '%s' layout was not installed: %s.", tostring(id), tostring(detail))
			on_done(false, detail)
			return
		end
		local path, publish_err = publish(deps, id, detail)
		if not path then
			Logger.error(LOG, "The '%s' layout was not installed: %s.", id, tostring(publish_err))
			on_done(false, publish_err)
			return
		end
		Logger.success(LOG, "Installed the '%s' layout, version %s, in %s.", id,
			tostring(detail.entry.version), path)
		on_done(true, { entry = detail.entry, path = path })
	end)
	return true
end

return M
