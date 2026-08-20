--- platform/remap/tap_hold_writer.lua

--- ==============================================================================
--- MODULE: Tap-Hold Writer (Linux)
--- DESCRIPTION:
--- Persists a tap-hold override to ``~/.config/ergopti/tap_hold.toml``, then
--- regenerates kanata's config and reloads it so the change takes effect without
--- a restart.
---
--- WHY IT EXISTS:
--- this driver could READ the tap-hold configuration and not change it. The menu
--- showed every key's tap action and hold modifier greyed out, with the comment
--- « a clickable row that cannot change anything is worse than a greyed one » —
--- true of the row, and the wrong conclusion for the driver. Windows has edited
--- tap-holds from its tray since the feature existed, from this same file format;
--- a Linux user had to open a TOML by hand and restart the daemon.
---
--- THE FILE IS THE SAME ONE, and that matters more than the menu: the schema is
--- `[tap_hold.keys.<id>]` with `tap_action`, `hold_modifier` and `hold_layer`,
--- read by all three drivers from `_shared/tap_hold/defaults.toml` with the
--- user's file laid over it key by key. This module writes only the keys the user
--- has actually changed, so every other key keeps inheriting the shared default —
--- the merge manager.lua performs and the one macOS performs.
---
--- FEATURES & RATIONALE:
--- 1. Read-modify-write: the file is re-read before every change, so two menu
---    clicks in a row never lose the first one.
--- 2. Atomic-ish: written to a temporary file and renamed, so a crash mid-write
---    cannot leave a half-parsed override that silences the whole keyboard.
--- 3. Reload, not restart: manager.write_kbd() + manager.restart() puts the new
---    binding in force immediately, which is what makes the menu row honest.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "tap_hold_writer"

-- The keys this module may write. Anything else is a caller bug, and writing an
-- unknown field into the user's file would be read back by all three drivers.
local WRITABLE_FIELDS = { tap_action = true, hold_modifier = true, hold_layer = true }

local _manager = nil
local _path_provider = nil




-- ==========================================
-- ==========================================
-- ======= 1/ Initialisation ================
-- ==========================================
-- ==========================================

--- Injects the kanata manager and the path resolver.
---
--- The manager is a dependency rather than a require so the test suite can drive
--- this module without a kanata binary — writing a TOML and regenerating a config
--- are separable, and only one of them needs a daemon.
--- @param deps table { manager = table, tap_hold_path = function|nil }
function M.init(deps)
	Logger.start(LOG, "Initializing the tap-hold writer…")
	if type(deps) ~= "table" or type(deps.manager) ~= "table" then
		Logger.error(LOG, "M.init(): deps.manager must be a table — the writer is non-functional.")
		return
	end
	if _manager then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	_manager = deps.manager
	_path_provider = type(deps.tap_hold_path) == "function" and deps.tap_hold_path or nil
	Logger.success(LOG, "Tap-hold writer initialized.")
end

--- Guard for every public function that needs the injected state.
--- @param func_name string
--- @return boolean
local function require_state(func_name)
	if not _manager then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end

--- The user's override file.
--- @return string|nil
local function user_toml_path()
	if _path_provider then return _path_provider() end
	if type(_manager.tap_hold_config_path) == "function" then
		local ok, path = pcall(_manager.tap_hold_config_path)
		if ok and type(path) == "string" and path ~= "" then return path end
	end
	Logger.error(LOG, "No tap_hold.toml path — the override cannot be persisted.")
	return nil
end




-- ==========================================
-- ==========================================
-- ======= 2/ Reading what is there =========
-- ==========================================
-- ==========================================

--- Parses the user's file into { key_id -> { field -> value } }.
---
--- Only `[tap_hold.keys.*]` sections are kept: this module writes that table and
--- nothing else, so anything else in the file is the user's and is preserved by
--- being re-emitted verbatim below.
--- @param path string
--- @return table overrides, table foreign_lines
local function read_overrides(path)
	local overrides, foreign = {}, {}
	local fh = io.open(path, "r")
	if not fh then return overrides, foreign end

	local current = nil
	for line in fh:lines() do
		local section = line:match("^%s*%[([^%]]+)%]%s*$")
		if section then
			local key_id = section:match("^tap_hold%.keys%.(.+)$")
			if key_id then
				current = key_id
				overrides[key_id] = overrides[key_id] or {}
			else
				current = nil
				foreign[#foreign + 1] = line
			end
		elseif current then
			local field, value = line:match("^%s*([%w_]+)%s*=%s*(.+)%s*$")
			if field and WRITABLE_FIELDS[field] then
				overrides[current][field] = value:match('^"(.*)"$') or value
			elseif field then
				-- A field this module does not own (a per-key threshold, say) is kept
				-- exactly as written: the user put it there and nothing here has an
				-- opinion about it.
				overrides[current][field] = value
			end
		elseif line:match("%S") and not line:match("^%s*#") then
			foreign[#foreign + 1] = line
		end
	end
	fh:close()
	return overrides, foreign
end




-- ==========================================
-- ==========================================
-- ======= 3/ Writing it back ===============
-- ==========================================
-- ==========================================

--- Serialises the overrides and replaces the file.
--- @param path string
--- @param overrides table
--- @return boolean
local function write_overrides(path, overrides)
	local ids = {}
	for id in pairs(overrides) do ids[#ids + 1] = id end
	table.sort(ids)

	local lines = {
		"# tap_hold.toml — written by the Ergopti tray menu.",
		"#",
		"# Only the keys you have CHANGED appear here. Every other key keeps the",
		"# value from _shared/tap_hold/defaults.toml, which the driver merges under",
		"# this file key by key — so removing a section below restores that key's",
		"# default rather than disabling it.",
		"",
	}
	for _, id in ipairs(ids) do
		local entry = overrides[id]
		local fields = {}
		for field in pairs(entry) do fields[#fields + 1] = field end
		table.sort(fields)
		if #fields > 0 then
			lines[#lines + 1] = string.format("[tap_hold.keys.%s]", id)
			for _, field in ipairs(fields) do
				local value = entry[field]
				if type(value) == "string" and not value:match("^%d+%.?%d*$") then
					lines[#lines + 1] = string.format('%s = "%s"', field, value)
				else
					lines[#lines + 1] = string.format("%s = %s", field, tostring(value))
				end
			end
			lines[#lines + 1] = ""
		end
	end

	-- Temp file then rename: a crash mid-write would otherwise leave a file that
	-- parses to zero keys, which the loader reads as "the user disabled every
	-- tap-hold" rather than as damage.
	local tmp = path .. ".tmp"
	local fh, err = io.open(tmp, "w")
	if not fh then
		Logger.error(LOG, "Cannot write '%s' (%s) — the override will not survive.", tmp, tostring(err))
		return false
	end
	fh:write(table.concat(lines, "\n"))
	fh:close()
	-- rename() over an EXISTING file succeeds on POSIX and fails on Windows, and
	-- this module's tests run on both. The first write always worked and every
	-- later one silently did not, which is the worst possible half: the menu
	-- reported success and the user's second change never existed. So the target
	-- is removed on the retry rather than trusted to be overwritten.
	local ok = os.rename(tmp, path)
	if not ok then
		os.remove(path)
		ok = os.rename(tmp, path)
	end
	if not ok then
		Logger.error(LOG, "Cannot replace '%s' — the override was not saved.", path)
		os.remove(tmp)
		return false
	end
	Logger.info(LOG, "Tap-hold override written to %s (%d key(s)).", path, #ids)
	return true
end

--- Regenerates kanata's config and reloads it so the change is in force now.
--- @return boolean
local function apply()
	if type(_manager.write_kbd) ~= "function" then
		Logger.error(LOG, "The kanata manager exposes no write_kbd — the file was saved but nothing reloaded it.")
		return false
	end
	local ok_write = _manager.write_kbd()
	if not ok_write then
		Logger.error(LOG, "kanata config regeneration failed — the saved override is not in force.")
		return false
	end
	-- Restarting is only meaningful when this driver started kanata; a
	-- system-managed instance rereads its own file and is not ours to bounce.
	if type(_manager.owns_process) == "function" and not _manager.owns_process() then
		Logger.info(LOG, "kanata is managed elsewhere — config regenerated, reload it yourself to apply.")
		return true
	end
	if type(_manager.restart) == "function" then
		return _manager.restart() and true or false
	end
	return true
end

--- Applies one field change to one key and reloads.
--- @param key_id string Key id as it appears in [tap_hold.keys.<id>].
--- @param field string One of tap_action / hold_modifier / hold_layer.
--- @param value string|nil The new value; nil removes the field.
--- @return boolean
function M.set_field(key_id, field, value)
	if not require_state("set_field") then return false end
	if type(key_id) ~= "string" or key_id == "" then
		Logger.error(LOG, "set_field(): a key id is required — nothing written.")
		return false
	end
	if not WRITABLE_FIELDS[field] then
		Logger.error(LOG, "set_field(): '%s' is not a writable tap-hold field — nothing written.", tostring(field))
		return false
	end
	local path = user_toml_path()
	if not path then return false end

	local overrides = read_overrides(path)
	overrides[key_id] = overrides[key_id] or {}
	-- A hold is either a modifier or a layer, never both: the loader treats them
	-- as mutually exclusive, and leaving the other behind would make which one
	-- wins depend on the reader.
	if field == "hold_modifier" then overrides[key_id].hold_layer = nil end
	if field == "hold_layer" then overrides[key_id].hold_modifier = nil end
	overrides[key_id][field] = value

	if not write_overrides(path, overrides) then return false end
	return apply()
end

--- Clears every override for one key, returning it to the shared default.
--- @param key_id string
--- @return boolean
function M.clear_key(key_id)
	if not require_state("clear_key") then return false end
	local path = user_toml_path()
	if not path then return false end
	local overrides = read_overrides(path)
	overrides[key_id] = nil
	if not write_overrides(path, overrides) then return false end
	return apply()
end

--- Removes the user's file entirely — every key returns to the shared default.
--- @return boolean
function M.reset_all()
	if not require_state("reset_all") then return false end
	local path = user_toml_path()
	if not path then return false end
	os.remove(path)
	Logger.info(LOG, "Tap-hold overrides cleared — every key is back to the shared default.")
	return apply()
end

--- True when the user's file names this key at all.
--- @param key_id string
--- @return boolean
function M.is_overridden(key_id)
	if not require_state("is_overridden") then return false end
	local path = user_toml_path()
	if not path then return false end
	local overrides = read_overrides(path)
	return overrides[key_id] ~= nil
end

return M
