--- modules/updater/config_backup.lua

--- ==============================================================================
--- MODULE: Configuration Backup (Linux)
--- DESCRIPTION:
--- Binds the shared configuration backup owner (_shared/lua/updater/
--- config_backup.lua, assembled by config_backup_binding.lua) to this driver: the configuration folder, the settings
--- store beside it (storage.json, which holds the folder override and the tray
--- choices), and file ports over the shared atomic writer. The Versions window
--- backs the configuration up through it before installing a release, and
--- restores a backup through it.
---
--- FEATURES & RATIONALE:
--- 1. One rule set: the extensions, the excluded folders and the names come
---    from the config_backup block of _shared/modules/updater/defaults.json.
--- 2. Exact bytes: copies are created and restored through toml_codec.writer's
---    classified read and compare-and-publish, never through a plain write.
--- 3. Native directory entries preserve every filename byte. Links to folders
---    are not traversed, and special endpoints are never opened. A dangling
---    file link retains the canonical classified read refusal.
--- ==============================================================================

local M = {}

local Logger      = require("logger.shim")
local Paths       = require("infra.paths")
local ConfigPaths = require("infra.config_paths")
local Json        = require("json")
local Shell       = require("adapters.shell_runner")
local NativeDirectory = require("infra.native_directory")
local Writer      = require("toml_codec.writer")
local Binding     = require("updater.config_backup_binding")
local ErrorDescription = require("error_description")

local LOG = "modules.updater.config_backup"

-- Test seam: replaces the owner options' ports (io, clock, roots).
M._overrides = nil





-- ==============================
-- ==============================
-- ======= 1/ File Ports ========
-- ==============================
-- ==============================

--- Classifies one folder entry exactly as the macOS port does. Only a regular
--- file is "file": reading a FIFO, a socket or a device node can block forever,
--- so those are "other" and never opened.
--- @param path string
--- @param kind string Kind of the entry itself (not followed).
--- @return string|nil kind "file", "dir" or "other"; nil when the link target is unknowable
--- @return string|nil error Why the link target cannot be classified
local function classify(path, kind)
	if kind == "directory" then return "dir" end
	if kind == "file" then return "file" end
	if kind ~= "link" then return "other" end
	-- A link to a folder could lead back up the tree: it is reported, never walked.
	local target, message, code = NativeDirectory.target_kind(path)
	if target == "directory" then return "other" end
	if target ~= nil then return target == "file" and "file" or "other" end
	-- A dangling link holds no configuration, so it cannot block the snapshot.
	if code == "ENOENT" then return "other" end
	-- A denied or looping target may hide configuration: refuse, never omit it.
	return nil, string.format("cannot classify %s: %s", path, tostring(message or code))
end

--- Lists one folder: files, folders, and anything else as "other".
--- @param dir string
--- @return table|nil entries
--- @return string|nil error "absent" for a folder that does not exist
local function list(dir)
	local target, message, code = NativeDirectory.target_kind(dir)
	if target == nil then
		if code == "ENOENT" then return nil, "absent" end
		return nil, ErrorDescription.describe(message or code)
	end
	if target ~= "directory" then return nil, "not a folder" end
	local listed, list_message = NativeDirectory.entries(dir)
	if not listed then return nil, ErrorDescription.describe(list_message or "cannot list") end
	local entries = {}
	for _, entry in ipairs(listed) do
		local kind, refusal = classify(NativeDirectory.join(dir, entry.name), entry.kind)
		if kind == nil then return nil, refusal end
		entries[#entries + 1] = { name = entry.name, kind = kind }
	end
	return entries
end

--- The production file ports of the owner.
--- @return table
local function file_ports()
	return {
		list = list,
		read = function(path)
			local content, status, detail = Writer.read_classified(path)
			if status == "ok" then return content end
			if status == "absent" then return nil, "absent" end
			return nil, tostring(detail or status)
		end,
		make_dir = function(path)
			if Shell.run("mkdir -p -- " .. Shell.quote(path)) then return true end
			return nil, "mkdir failed"
		end,
		create = function(path, content)
			return Writer.publish_if_unchanged(path, content, nil, { status = "absent" })
		end,
		replace = function(path, content)
			local current, status, detail = Writer.read_classified(path)
			if status ~= "ok" and status ~= "absent" then return nil, tostring(detail or status) end
			return Writer.publish_if_unchanged(path, content, nil, { status = status, content = current })
		end,
	}
end

--- Wall-clock time of a backup, in UTC.
--- @return table { stamp, iso }
local function clock()
	return { stamp = os.date("!%Y%m%d-%H%M%S"), iso = os.date("!%Y-%m-%dT%H:%M:%SZ") }
end





-- ==============================
-- ==============================
-- ======= 2/ The Owner =========
-- ==============================
-- ==============================

--- Reads the shared updater defaults the backup rules come from.
--- @return table|nil defaults
--- @return string|nil error
local function read_defaults()
	local path = Paths.shared("modules/updater/defaults.json")
	local raw, status
	if path then raw, status = Writer.read_classified(path) end
	if status ~= "ok" then return nil, "the shared updater defaults are unreadable" end
	local ok, decoded = pcall(Json.decode, raw)
	if not ok then return nil, "the shared updater defaults are not JSON" end
	return decoded
end

--- The roots of this driver: the configuration folder and the settings store
--- file beside it (it holds the folder override and the tray choices).
--- @return table|nil roots
--- @return string|nil reason
--- @return string|nil log_text
local function default_roots()
	local roots = { { id = "config", dir = ConfigPaths.get_config_dir() } }
	local ok_storage, Storage = pcall(require, "adapters.storage")
	if not (ok_storage and type(Storage) == "table" and type(Storage.path) == "function") then
		return nil, "settings store unavailable",
			"Configuration backup refused: the settings store path is unknown."
	end
	roots[#roots + 1] = { id = "settings_store", file = Storage.path() }
	return roots
end

local _binding = Binding.new({
	logger = Logger,
	log = LOG,
	defaults = read_defaults,
	json = { encode = Json.encode, decode = function(text)
		local ok, value = pcall(Json.decode, text)
		if not ok then return nil, tostring(value) end
		return value
	end },
	file_ports = file_ports,
	clock = clock,
	default_roots = default_roots,
	overrides = function() return M._overrides end,
})

--- Builds the owner over the current configuration folder. It is built per
--- use: the folder can move while the daemon runs (the paths editor).
--- @return table|nil owner
--- @return string|nil error
function M.owner() return _binding.owner() end

M._list = list

return M
