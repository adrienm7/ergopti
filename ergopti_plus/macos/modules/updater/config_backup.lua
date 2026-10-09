--- modules/updater/config_backup.lua

--- ==============================================================================
--- MODULE: Configuration Backup (macOS)
--- DESCRIPTION:
--- Binds the shared configuration backup owner (_shared/lua/updater/
--- config_backup.lua) to this driver: the configuration folder of
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
local Shared      = require("updater.config_backup")

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

--- Builds the owner over the current configuration folder. It is built per
--- use: the folder can move while the driver runs (the paths editor).
--- @return table|nil owner
--- @return string|nil error
function M.owner()
	local path = Paths.shared("modules/updater/defaults.json")
	local raw = type(path) == "string" and FileSystem.read(path) or nil
	local decoded = type(raw) == "string" and JsonCodec.decode(raw) or nil
	local rules, err = Shared.rules(decoded)
	if not rules then
		Logger.error(LOG, "Configuration backup unavailable: %s.", tostring(err))
		return nil, err
	end
	local overrides = M._overrides or {}
	local config_dir = ConfigPaths.get_config_dir()
	if not overrides.roots and (type(config_dir) ~= "string" or config_dir:sub(1, 1) ~= "/") then
		Logger.error(LOG, "Configuration backup refused: the configuration folder is unknown.")
		return nil, "configuration folder unknown"
	end
	return Shared.new({
		rules = rules,
		roots = overrides.roots or { { id = "config", dir = config_dir } },
		io = overrides.io or file_ports(),
		json = { encode = JsonCodec.encode, decode = JsonCodec.decode },
		clock = overrides.clock or clock,
		logger = Logger,
		log = LOG,
	}), nil
end

M._list = list

return M
