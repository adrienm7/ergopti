--- modules/updater/config_backup.lua

--- ==============================================================================
--- MODULE: Configuration Backup (Linux)
--- DESCRIPTION:
--- Binds the shared configuration backup owner (_shared/lua/updater/
--- config_backup.lua) to this driver: the configuration folder, the settings
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
--- 3. A link to a folder is neither followed nor copied: `ls -L` sees a folder
---    that plain `ls` does not, and following it could loop.
--- ==============================================================================

local M = {}

local Logger      = require("logger.shim")
local Paths       = require("infra.paths")
local ConfigPaths = require("infra.config_paths")
local Json        = require("json")
local Shell       = require("adapters.shell_runner")
local Writer      = require("toml_codec.writer")
local Shared      = require("updater.config_backup")

local LOG = "modules.updater.config_backup"

-- Test seam: replaces the owner options' ports (io, clock, roots).
M._overrides = nil





-- ==============================
-- ==============================
-- ======= 1/ File Ports ========
-- ==============================
-- ==============================

--- Runs `ls` on one folder and returns its entry lines.
--- @param flags string
--- @param dir string
--- @return table|nil lines
local function ls(flags, dir)
	local ok, output = Shell.exec_checked("ls " .. flags .. " -- " .. Shell.quote(dir))
	if not ok then return nil end
	local lines = {}
	for line in output:gmatch("[^\n]+") do lines[#lines + 1] = line end
	return lines
end

--- Lists one folder: files, folders, and anything else as "other".
--- @param dir string
--- @return table|nil entries
--- @return string|nil error "absent" for a folder that does not exist
local function list(dir)
	if not Shell.run("test -d " .. Shell.quote(dir)) then
		if Shell.run("test -e " .. Shell.quote(dir)) then return nil, "not a folder" end
		return nil, "absent"
	end
	local plain, followed = ls("-1Ap", dir), ls("-1ApL", dir)
	if not plain or not followed then return nil, "cannot list" end
	local linked_dirs = {}
	for _, line in ipairs(followed) do
		if line:sub(-1) == "/" then linked_dirs[line:sub(1, -2)] = true end
	end
	local entries = {}
	for _, line in ipairs(plain) do
		if line:sub(-1) == "/" then
			entries[#entries + 1] = { name = line:sub(1, -2), kind = "dir" }
		elseif linked_dirs[line] then
			entries[#entries + 1] = { name = line, kind = "other" }
		else
			entries[#entries + 1] = { name = line, kind = "file" }
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

--- Reads the shared backup rules.
--- @return table|nil rules
--- @return string|nil error
local function load_rules()
	local path = Paths.shared("modules/updater/defaults.json")
	local handle = path and io.open(path, "rb") or nil
	if not handle then return nil, "the shared updater defaults are unreadable" end
	local raw = handle:read("*a")
	handle:close()
	local ok, decoded = pcall(Json.decode, raw)
	if not ok then return nil, "the shared updater defaults are not JSON" end
	return Shared.rules(decoded)
end

--- Builds the owner over the current configuration folder. It is built per
--- use: the folder can move while the daemon runs (the paths editor).
--- @return table|nil owner
--- @return string|nil error
function M.owner()
	local rules, err = load_rules()
	if not rules then
		Logger.error(LOG, "Configuration backup unavailable: %s.", tostring(err))
		return nil, err
	end
	local overrides = M._overrides or {}
	local roots = overrides.roots
	if not roots then
		roots = { { id = "config", dir = ConfigPaths.get_config_dir() } }
		local ok_storage, Storage = pcall(require, "adapters.storage")
		if ok_storage and type(Storage) == "table" and type(Storage.path) == "function" then
			roots[#roots + 1] = { id = "settings_store", file = Storage.path() }
		else
			Logger.error(LOG, "Configuration backup refused: the settings store path is unknown.")
			return nil, "settings store unavailable"
		end
	end
	return Shared.new({
		rules = rules,
		roots = roots,
		io = overrides.io or file_ports(),
		json = { encode = Json.encode, decode = function(text)
			local ok, value = pcall(Json.decode, text)
			if not ok then return nil, tostring(value) end
			return value
		end },
		clock = overrides.clock or clock,
		logger = Logger,
		log = LOG,
	}), nil
end

M._list = list

return M
