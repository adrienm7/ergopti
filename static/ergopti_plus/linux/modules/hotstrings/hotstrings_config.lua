--- modules/hotstrings/hotstrings_config.lua

--- ==============================================================================
--- MODULE: Hotstrings Config Manager (Linux)
--- DESCRIPTION:
--- Manages the lifecycle of hotstring TOML files: discovery, loading, validation,
--- live reload, and per-category enable/disable. Wraps loader.lua and the engine
--- to provide a single config surface for the daemon and the menu.
---
--- WHAT CHANGED AND WHY:
--- The two sources used to be mutually exclusive: if ~/.config/ergopti/hotstrings
--- existed, the bundled packs were never read at all — so creating a single
--- personal file HID all five shared categories. They are merged now, with the
--- user's copy of a category replacing the bundled one by file stem, which is
--- also what install.sh produces (it copies the packs into that directory).
---
--- Enable state is persisted. It was in-memory only, so every toggle the user
--- made in the tray was forgotten on restart, silently, which reads as the menu
--- not working rather than as state not being saved.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Loader = require("modules.hotstrings.loader")
local Storage = require("adapters.storage")

local LOG = "modules.hotstrings.hotstrings_config"

-- Where the disabled-category set is persisted. One key holding a comma-joined
-- list rather than one key per category: the set is read and written whole, and
-- a per-key layout leaves orphans behind when a category is renamed.
local DISABLED_KEY = "hotstrings.disabled_categories"


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

local _engine         = nil
local _config_dir     = nil
local _toml_paths     = {}
local _mappings       = {}
local _categories     = {}
local _disabled_groups = {}
local _parse_errors   = 0

--- Called after any change that alters what the menu should show. Set by the
--- daemon; nil in the harness, where nothing is drawn.
local _on_change = nil

--- Reads the persisted disabled set.
local function load_disabled()
	local raw = Storage.get(DISABLED_KEY, "")
	local set = {}
	if type(raw) == "string" and raw ~= "" then
		for id in raw:gmatch("[^,]+") do set[id] = true end
	end
	return set
end

--- Writes the disabled set back.
local function save_disabled()
	local ids = {}
	for id in pairs(_disabled_groups) do ids[#ids + 1] = id end
	table.sort(ids)
	Storage.set(DISABLED_KEY, table.concat(ids, ","))
	Logger.debug(LOG, "Disabled categories persisted: %s.",
		#ids > 0 and table.concat(ids, ",") or "(none)")
end

--- Fires the menu-rebuild callback, if the daemon supplied one.
local function notify_change()
	if _on_change then pcall(_on_change) end
end


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

--- Counts the persisted disabled categories.
--- @return integer
local function count_disabled()
	local n = 0
	for _ in pairs(_disabled_groups) do n = n + 1 end
	return n
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

--- @param engine table The hotstring engine.
--- @param config_dir string|nil Explicit config path; nil resolves the XDG one.
--- @param on_change function|nil Called whenever the menu's view of the config changes.
function M.init(engine, config_dir, on_change)
	_engine = engine
	_on_change = type(on_change) == "function" and on_change or nil
	if type(config_dir) == "string" and config_dir ~= "" then
		_config_dir = config_dir
	else
		local home = require("infra.config_paths").home()
		local xdg = home .. "/.config/ergopti/hotstrings"
		local fh = io.open(xdg, "r")
		if fh then fh:close(); _config_dir = xdg end
	end
	_disabled_groups = load_disabled()
	Logger.info(LOG, "Config manager initialised (dir=%s, %d disabled).",
		_config_dir or "(bundled)", count_disabled())
end


-- =========================================
-- =========================================
-- ======= 4/ Loading ======================
-- =========================================
-- =========================================

--- The TOML files to load: the bundled packs, overlaid with the user's.
---
--- Merged rather than exclusive. Choosing ONE directory meant that creating a
--- single personal file hid all five shared categories, which is not a
--- configuration anybody would ask for. Overlaid by file STEM because that is
--- what a category is: install.sh copies the packs into the user's directory, so
--- the same stem appearing twice is the user's copy of a pack, not a second
--- category with the same name.
--- @return table Array of absolute paths.
local function resolve_paths()
	local by_stem, order = {}, {}

	--- @param path string
	local function add(path)
		local stem = path:match("([^/\\]+)%.toml$")
		if not stem then return end
		if not by_stem[stem] then order[#order + 1] = stem end
		by_stem[stem] = path
	end

	-- A single file as the config is the explicit-path case, and it means exactly
	-- that file — no merge, because the user named one thing.
	if _config_dir and _config_dir:match("%.toml$") then
		return { _config_dir }
	end

	local ok_paths, Paths = pcall(require, "infra.paths")
	local bundled = ok_paths and Paths.shared("modules/hotstrings") or nil
	if bundled then
		for _, path in ipairs(Loader.find_toml_files(bundled)) do add(path) end
	end

	-- Second, so the user's copy of a category replaces the bundled one.
	if _config_dir then
		for _, path in ipairs(Loader.find_toml_files(_config_dir)) do add(path) end
	end

	local paths = {}
	for _, stem in ipairs(order) do paths[#paths + 1] = by_stem[stem] end
	return paths
end

function M.load_all()
	if not _engine then
		Logger.error(LOG, "load_all(): engine not initialised.")
		return 0
	end

	_toml_paths = resolve_paths()

	if #_toml_paths == 0 then
		Logger.warn(LOG, "load_all(): no TOML files found.")
		return 0
	end

	local catalogue = Loader.load_catalogue(_toml_paths)
	_mappings = catalogue.mappings
	_categories = catalogue.categories
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

	Logger.success(LOG, "Loaded %d mapping(s) (%d categories, %d parse errors).",
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
	save_disabled()
	Logger.info(LOG, "Category '%s' disabled.", group_name)
end

function M.enable_group(group_name)
	if type(group_name) ~= "string" then return end
	_disabled_groups[group_name] = nil
	save_disabled()
	Logger.info(LOG, "Category '%s' enabled.", group_name)
end

function M.toggle_group(group_name)
	if _disabled_groups[group_name] then
		M.enable_group(group_name)
	else
		M.disable_group(group_name)
	end
	M.load_all()
	notify_change()
end

--- Enables every known category.
---
--- These two were called by the menu and did not exist, so the rows behind them
--- were silent no-ops: the `if` guarding the call was false and nothing
--- happened, which is indistinguishable from a click that missed.
--- @return integer Number of categories affected.
function M.enable_all()
	local changed = 0
	for id in pairs(_disabled_groups) do
		_disabled_groups[id] = nil
		changed = changed + 1
	end
	save_disabled()
	-- Once, not once per category: reloading inside the loop re-parses every
	-- TOML for every category, which on the magickey pack alone is 300 KB a turn.
	M.load_all()
	notify_change()
	Logger.info(LOG, "All categories enabled (%d re-enabled).", changed)
	return changed
end

--- Disables every known category.
--- @return integer Number of categories affected.
function M.disable_all()
	local changed = 0
	for id in pairs(_categories) do
		if not _disabled_groups[id] then
			_disabled_groups[id] = true
			changed = changed + 1
		end
	end
	save_disabled()
	M.load_all()
	notify_change()
	Logger.info(LOG, "All categories disabled (%d disabled).", changed)
	return changed
end

--- Restores the shipped state: everything enabled.
--- @return integer Number of categories affected.
function M.reset_defaults()
	return M.enable_all()
end

function M.is_group_enabled(group_name)
	return not _disabled_groups[group_name]
end

function M.get_groups()
	return _collect_groups(_mappings)
end

--- Every known category, keyed by id, with the metadata the menu renders.
--- @return table
function M.get_categories()
	return _categories
end

--- One category's metadata, or nil.
--- @param id string
--- @return table|nil
function M.get_category(id)
	return _categories[id]
end

--- The categories in the order the shared index declares, with anything
--- undeclared appended alphabetically.
---
--- The order is data, not a sort: _index.toml lists the packs from the smallest
--- behavioural change to the largest, and an alphabetical menu would put
--- autocorrection — the one that rewrites what the user typed — first.
--- @return table Array of category ids.
function M.get_category_order()
	local declared, seen, ordered = {}, {}, {}

	local ok_paths, Paths = pcall(require, "infra.paths")
	if ok_paths then
		local ok_read, parsed = pcall(function()
			return require("toml_codec.reader").parse(Paths.shared("modules/hotstrings/_index.toml"))
		end)
		local menu = ok_read and type(parsed) == "table" and parsed.sections
			and parsed.sections.menu or nil
		if type(menu) == "table" and type(menu.categories_order) == "table" then
			declared = menu.categories_order
		end
	end

	for _, id in ipairs(declared) do
		if _categories[id] and not seen[id] then
			seen[id] = true
			ordered[#ordered + 1] = id
		end
	end

	local rest = {}
	for id in pairs(_categories) do
		if not seen[id] then rest[#rest + 1] = id end
	end
	table.sort(rest)
	for _, id in ipairs(rest) do ordered[#ordered + 1] = id end

	return ordered
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
