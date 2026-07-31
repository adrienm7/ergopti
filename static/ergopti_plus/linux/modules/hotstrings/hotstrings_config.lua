--- modules/hotstrings/hotstrings_config.lua

--- ==============================================================================
--- MODULE: Hotstrings Config Manager (Linux)
--- DESCRIPTION:
--- Manages the lifecycle of hotstring TOML files: discovery, loading, validation,
--- live reload, and per-group enable/disable. Wraps loader.lua and the engine
--- to provide a single config surface for the daemon.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Loader = require("modules.hotstrings.loader")

local LOG = "modules.hotstrings.hotstrings_config"


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

local _engine         = nil
local _config_dir     = nil
local _toml_paths     = {}
local _mappings       = {}
local _disabled_groups = {}
local _parse_errors   = 0


-- =========================================
-- =========================================
-- ======= 2/ Helpers (before public API) ==
-- =========================================
-- =========================================

local function _count_groups(mappings)
	local seen = {}
	for _, m in ipairs(mappings) do
		if type(m.group) == "string" then seen[m.group] = true end
	end
	local count = 0
	for _ in pairs(seen) do count = count + 1 end
	return count
end

local function _collect_groups(mappings)
	local seen = {}
	local result = {}
	for _, m in ipairs(mappings) do
		if type(m.group) == "string" and not seen[m.group] then
			seen[m.group] = true
			result[#result + 1] = m.group
		end
	end
	return result
end


-- =========================================
-- =========================================
-- ======= 3/ Initialisation ===============
-- =========================================
-- =========================================

function M.init(engine, config_dir)
	_engine = engine
	if type(config_dir) == "string" and config_dir ~= "" then
		_config_dir = config_dir
	else
		local home = require("lib.config_paths").home()
		local xdg = home .. "/.config/ergopti/hotstrings"
		local fh = io.open(xdg, "r")
		if fh then fh:close(); _config_dir = xdg end
	end
	Logger.info(LOG, "Config manager initialised (dir=%s).", _config_dir or "(bundled)")
end


-- =========================================
-- =========================================
-- ======= 4/ Loading ======================
-- =========================================
-- =========================================

function M.load_all()
	if not _engine then
		Logger.error(LOG, "load_all(): engine not initialised.")
		return 0
	end

	-- Discover TOML files.
	if _config_dir and _config_dir:match("%.toml$") then
		_toml_paths = { _config_dir }
	elseif _config_dir then
		_toml_paths = Loader.find_toml_files(_config_dir)
	else
		local src = debug and debug.getinfo and debug.getinfo(1, "S")
		if src and src.source then
			local s = src.source
			if s:sub(1, 1) == "@" then s = s:sub(2) end
			local dir = s:match("^(.*[/\\])") or ""
			-- Two steps up from modules/hotstrings/, not three: three lands outside
			-- the tree entirely, so this bundled fallback found nothing.
			local ok_paths, Paths = pcall(require, "lib.paths")
			local bundled = ok_paths and Paths.shared("modules/hotstrings") or nil
			_toml_paths = Loader.find_toml_files(bundled)
		else
			_toml_paths = {}
		end
	end

	if #_toml_paths == 0 then
		Logger.warn(LOG, "load_all(): no TOML files found.")
		return 0
	end

	-- Load all mappings.
	_mappings = Loader.load(_toml_paths)
	_parse_errors = 0
	if #_mappings == 0 and #_toml_paths > 0 then
		_parse_errors = #_toml_paths
	end

	-- Filter disabled groups.
	local filtered = {}
	for _, m in ipairs(_mappings) do
		if not _disabled_groups[m.group] then
			filtered[#filtered + 1] = m
		end
	end

	-- Deduplicate triggers.
	local triggers = {}
	local deduped = {}
	local dupes = 0
	for _, m in ipairs(filtered) do
		if triggers[m.trigger] then
			dupes = dupes + 1
			Logger.warn(LOG, "Duplicate trigger '%s' skipped.", m.trigger)
		else
			triggers[m.trigger] = true
			deduped[#deduped + 1] = m
		end
	end
	if dupes > 0 then Logger.warn(LOG, "%d duplicate(s) skipped.", dupes) end

	_engine:load_mappings(deduped)

	Logger.success(LOG, "Loaded %d mapping(s) (%d groups, %d parse errors).",
		#deduped, _count_groups(deduped), _parse_errors)
	return #deduped
end

function M.reload()
	Logger.info(LOG, "Reload requested — re-scanning…")
	_toml_paths = {}
	return M.load_all()
end


-- =========================================
-- =========================================
-- ======= 5/ Group Management =============
-- =========================================
-- =========================================

function M.disable_group(group_name)
	if type(group_name) ~= "string" then return end
	_disabled_groups[group_name] = true
	Logger.info(LOG, "Group '%s' disabled.", group_name)
end

function M.enable_group(group_name)
	if type(group_name) ~= "string" then return end
	_disabled_groups[group_name] = nil
	Logger.info(LOG, "Group '%s' enabled.", group_name)
end

function M.toggle_group(group_name)
	if _disabled_groups[group_name] then
		M.enable_group(group_name)
	else
		M.disable_group(group_name)
	end
	M.load_all()
end

function M.is_group_enabled(group_name)
	return not _disabled_groups[group_name]
end

function M.get_groups()
	return _collect_groups(_mappings)
end


-- =========================================
-- =========================================
-- ======= 6/ Queries ======================
-- =========================================
-- =========================================

function M.mapping_count() return #_mappings end
function M.parse_error_count() return _parse_errors end
function M.get_config_dir() return _config_dir end

return M
