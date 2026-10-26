--- modules/updater/config_backup.lua

--- ==============================================================================
--- MODULE: Configuration Backup (macOS)
--- DESCRIPTION:
--- Binds the shared configuration backup owner (_shared/lua/updater/
--- config_backup.lua, assembled by config_backup_binding.lua) to this driver: the configuration folder of
--- infra/config_paths.lua and file ports over the FileSystem adapter's
--- classified reads, create-only writes and compare-and-publish. The Versions
--- window backs the configuration up through it before installing a release,
--- and restores a backup through it.
---
--- FEATURES & RATIONALE:
--- 1. One rule set: the extensions, the excluded folders and the names come
---    from the config_backup block of _shared/modules/updater/defaults.json.
--- 2. A link to a folder is neither followed nor copied (it could loop); a link
---    to a file is copied through its target.
--- ==============================================================================

local M = {}

local Logger      = require("infra.logger")
local Paths       = require("infra.paths")
local ConfigPaths = require("infra.config_paths")
local FsDir       = require("infra.fs_dir")
local FileSystem  = require("adapters.file_system")
local JsonCodec   = require("adapters.json_codec")
local Binding     = require("updater.config_backup_binding")

local LOG = "updater.config_backup"

-- Test seam: replaces the owner options' ports (io, clock, roots).
M._overrides = nil





-- ==============================
-- ==============================
-- ======= 1/ File Ports ========
-- ==============================
-- ==============================

--- Classifies one folder entry.
--- @param path string
--- @return string kind "file", "dir" or "other"
local function classify(path)
	local status, attributes = FileSystem.path_status(path)
	if status ~= "present" or type(attributes) ~= "table" then return "other" end
	if attributes.mode == "directory" then return "dir" end
	if attributes.mode == "file" then return "file" end
	if attributes.mode == "link" then
		-- A link to a folder could lead back up the tree: it is reported, never walked.
		return FileSystem.directory_status(path) == "present" and "other" or "file"
	end
	return "other"
end

--- Lists one folder.
--- @param dir string
--- @return table|nil entries
--- @return string|nil error "absent" for a folder that does not exist
local function list(dir)
	local status, detail = FileSystem.directory_status(dir)
	if status == "absent" then return nil, "absent" end
	if status ~= "present" then return nil, tostring(detail) end
	local names, listed, err = FsDir.try_entries(dir)
	if listed ~= true then return nil, tostring(err) end
	local entries = {}
	for _, name in ipairs(names) do
		if name ~= "." and name ~= ".." then
			entries[#entries + 1] = { name = name, kind = classify((dir:gsub("/+$", "")) .. "/" .. name) }
		end
	end
	return entries
end

--- The production file ports of the owner.
--- @return table
local function file_ports()
	return {
		list = list,
		read = function(path)
			local content, status, detail = FileSystem.read_with_status(path)
			if status == "ok" then return content end
			if status == "absent" then return nil, "absent" end
			return nil, tostring(detail or status)
		end,
		make_dir = function(path)
			if ConfigPaths.ensure_dir(path) == true then return true end
			return nil, "cannot create the folder"
		end,
		create = function(path, content)
			local created, status, detail = FileSystem.create_if_absent(path, content)
			if created == true then return true end
			return nil, tostring(detail or status)
		end,
		replace = function(path, content)
			local current, status, detail = FileSystem.read_with_status(path)
			if status ~= "ok" and status ~= "absent" then return nil, tostring(detail or status) end
			return FileSystem.write_if_unchanged(path, content, { status = status, content = current })
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
	local raw = type(path) == "string" and FileSystem.read(path) or nil
	if type(raw) ~= "string" then return nil, "the shared updater defaults are unreadable" end
	local decoded, decode_err = JsonCodec.decode(raw)
	if decoded == nil then return nil, tostring(decode_err or "the shared updater defaults are not JSON") end
	return decoded
end

--- The roots of this driver: the configuration folder only. The settings of
--- this driver live in hs.settings, not in a file a backup could copy.
--- @return table|nil roots
--- @return string|nil reason
--- @return string|nil log_text
local function default_roots()
	local config_dir = ConfigPaths.get_config_dir()
	if type(config_dir) ~= "string" or config_dir:sub(1, 1) ~= "/" then
		return nil, "configuration folder unknown",
			"Configuration backup refused: the configuration folder is unknown."
	end
	return { { id = "config", dir = config_dir } }
end

local _binding = Binding.new({
	logger = Logger,
	log = LOG,
	defaults = read_defaults,
	json = { encode = JsonCodec.encode, decode = JsonCodec.decode },
	file_ports = file_ports,
	clock = clock,
	default_roots = default_roots,
	overrides = function() return M._overrides end,
})

--- Builds the owner over the current configuration folder. It is built per
--- use: the folder can move while the driver runs (the paths editor).
--- @return table|nil owner
--- @return string|nil error
function M.owner() return _binding.owner() end

M._list = list

return M
