--- modules/hotstrings_config.lua

--- ==============================================================================
--- MODULE: Hotstrings Config
--- DESCRIPTION:
--- Resolves the effective delay (in seconds) and tooltip color for any
--- hotstring group/section by merging three layers, in order of decreasing
--- precedence:
---   1. User overrides — `~/.config/ergopti_plus/hotstrings_config.toml`,
---      edited from the "Délais & couleurs hotstrings" window.
---   2. TOML metadata — `delay` / `color` declared in each category TOML
---      under `[_meta]` (file scope) or `[_meta.sections.<name>]` (section).
---   3. Hard fallbacks (`GLOBAL_DEFAULT_DELAY`, no color).
---
--- FEATURES & RATIONALE:
--- 1. Single source of truth: HS and AHK both read the same TOML metadata,
---    so per-group defaults stop being duplicated across drivers.
--- 2. Cross-driver overrides: the user override file lives at a shared path
---    so changes made from the HS menu show up in AHK (and vice versa).
--- 3. Lazy TOML parsing: each category TOML is parsed at most once per
---    session via the existing `lib.toml_reader` to avoid duplicate I/O.
--- ==============================================================================

local M = {}
local Logger     = require("lib.logger")
local TomlReader = require("lib.toml_reader")
local LOG        = "hotstrings_config"


-- =================================
-- =================================
-- ======= 1/ Constants ============
-- =================================
-- =================================

-- Ultimate fallback when neither a user override nor a TOML default is set.
-- Mirrors the previous expansion baseline so removing every override returns
-- the user to the historical behaviour.
local GLOBAL_DEFAULT_DELAY = 0.75


-- =================================
-- =================================
-- ======= 2/ Module State =========
-- =================================
-- =================================

local _state = nil

local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end


-- ===================================
-- ===================================
-- ======= 3/ Override File I/O ======
-- ===================================
-- ===================================

--- Parses the user override TOML file into a nested structure:
---   { [category] = { delay = n, color = s, sections = { [name] = { delay, color } } } }
--- Unknown keys and malformed lines are silently ignored — the file is
--- user-edited (and machine-written) so robustness matters more than strictness.
--- @param path string Absolute path to the override file.
--- @return table The parsed overrides (empty table when file is missing).
local function parse_overrides(path)
	local result = {}
	local f = io.open(path, "r")
	if not f then return result end

	local current_cat = nil
	local current_sec = nil

	for raw in f:lines() do
		local line = raw:match("^%s*(.-)%s*$")
		if not line or line == "" or line:sub(1, 1) == "#" then goto continue end

		-- [category.section] — must be tested before plain [category]
		local cat, sec = line:match("^%[([%w_%-]+)%.([%w_%-]+)%]$")
		if cat and sec then
			result[cat] = result[cat] or { sections = {} }
			result[cat].sections = result[cat].sections or {}
			result[cat].sections[sec] = result[cat].sections[sec] or {}
			current_cat, current_sec = cat, sec
			goto continue
		end

		-- [category]
		local cat_only = line:match("^%[([%w_%-]+)%]$")
		if cat_only then
			result[cat_only] = result[cat_only] or { sections = {} }
			current_cat, current_sec = cat_only, nil
			goto continue
		end

		-- key = value (delay number, color string)
		if current_cat then
			local target = current_sec
				and result[current_cat].sections[current_sec]
				or result[current_cat]

			local num = line:match("^delay%s*=%s*([%-%d%.]+)%s*$")
			if num then
				local n = tonumber(num)
				if n then target.delay = n end
				goto continue
			end

			local col = line:match("^color%s*=%s*\"([^\"]*)\"%s*$")
			if col then
				target.color = col
				goto continue
			end
		end

		::continue::
	end

	pcall(function() f:close() end)
	return result
end

--- Serializes the in-memory override table back to TOML.
--- @param overrides table The override table (same shape as parse_overrides).
--- @return string The serialized TOML content.
local function serialize_overrides(overrides)
	local out = {
		"# Hotstrings — overrides utilisateur",
		"# Édité depuis la fenêtre « Délais & couleurs hotstrings ».",
		"# Ne pas mélanger les sections : chaque [category] et [category.section]",
		"# ne doit apparaître qu'une seule fois.",
		"",
	}

	-- Stable ordering: alphabetical category, alphabetical section.
	local cats = {}
	for cat, _ in pairs(overrides) do table.insert(cats, cat) end
	table.sort(cats)

	for _, cat in ipairs(cats) do
		local entry = overrides[cat]
		local has_file_level = entry.delay ~= nil or entry.color ~= nil
		if has_file_level then
			table.insert(out, string.format("[%s]", cat))
			if entry.delay ~= nil then
				table.insert(out, string.format("delay = %s", tostring(entry.delay)))
			end
			if entry.color ~= nil then
				table.insert(out, string.format("color = \"%s\"", entry.color))
			end
			table.insert(out, "")
		end

		if entry.sections then
			local secs = {}
			for s, _ in pairs(entry.sections) do table.insert(secs, s) end
			table.sort(secs)
			for _, sec in ipairs(secs) do
				local s_entry = entry.sections[sec]
				if s_entry.delay ~= nil or s_entry.color ~= nil then
					table.insert(out, string.format("[%s.%s]", cat, sec))
					if s_entry.delay ~= nil then
						table.insert(out, string.format("delay = %s", tostring(s_entry.delay)))
					end
					if s_entry.color ~= nil then
						table.insert(out, string.format("color = \"%s\"", s_entry.color))
					end
					table.insert(out, "")
				end
			end
		end
	end

	return table.concat(out, "\n")
end

--- Persists the current in-memory overrides to disk.
--- Called by every setter that mutates `_state.overrides`.
--- @return boolean True on success, false on I/O failure.
local function save_to_disk()
	if not _state then return false end
	local content = serialize_overrides(_state.overrides)
	local f, err = io.open(_state.path, "w")
	if not f then
		Logger.error(LOG, "Failed to open override file for writing: %s.", tostring(err))
		return false
	end
	local ok = pcall(function() f:write(content) end)
	pcall(function() f:close() end)
	if not ok then
		Logger.error(LOG, "Failed to write override file content.")
		return false
	end
	Logger.debug(LOG, "Override file written: '%s'.", _state.path)
	return true
end


-- ====================================
-- ====================================
-- ======= 4/ TOML Meta Cache =========
-- ====================================
-- ====================================

--- Returns the meta block for a category, parsing the TOML on first access.
--- Result shape: { delay = n?, color = s?, sections = { [name] = { delay, color, description } } }
--- @param category string Category name (lowercase, e.g. "rolls").
--- @return table The meta block (always a table, fields may be nil).
local function get_toml_meta(category)
	local cache = _state.toml_cache
	if cache[category] then return cache[category] end

	local toml_path = _state.toml_resolver(category)
	if type(toml_path) ~= "string" or toml_path == "" then
		cache[category] = { sections = {} }
		return cache[category]
	end

	local parsed = TomlReader.parse(toml_path)
	cache[category] = {
		delay    = parsed.meta.delay,
		color    = parsed.meta.color,
		sections = parsed.meta.sections or {},
	}
	return cache[category]
end


-- ============================
-- ============================
-- ======= 5/ Public API ======
-- ============================
-- ============================

--- Initializes the module. Must be called before any resolve/setter.
--- @param opts table { override_path = string, toml_resolver = function(category) -> path }
function M.init(opts)
	Logger.start(LOG, "Initializing…")
	if type(opts) ~= "table"
		or type(opts.override_path) ~= "string" or opts.override_path == ""
		or type(opts.toml_resolver) ~= "function"
	then
		Logger.error(LOG, "M.init(): opts.override_path and opts.toml_resolver are required.")
		return
	end
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end

	_state = {
		path          = opts.override_path,
		toml_resolver = opts.toml_resolver,
		overrides     = parse_overrides(opts.override_path),
		toml_cache    = {},
	}
	Logger.success(LOG, "Initialized (override file: '%s').", opts.override_path)
end

--- Returns the effective delay (seconds) and color (hex string) for a group.
--- @param category string The TOML file name without extension (e.g. "rolls").
--- @param section string|nil Optional section name within the category.
--- @return table { delay = number, color = string|nil, has_override = boolean }
function M.resolve(category, section)
	if not require_state("resolve") then
		return { delay = GLOBAL_DEFAULT_DELAY, color = nil, has_override = false }
	end

	local user = _state.overrides[category] or { sections = {} }
	local user_sec = section and (user.sections or {})[section] or nil
	local meta = get_toml_meta(category)
	local meta_sec = section and meta.sections[section] or nil

	local delay = (user_sec and user_sec.delay)
		or user.delay
		or (meta_sec and meta_sec.delay)
		or meta.delay
		or GLOBAL_DEFAULT_DELAY

	local color = (user_sec and user_sec.color)
		or user.color
		or (meta_sec and meta_sec.color)
		or meta.color

	local has_override =
		(user_sec and (user_sec.delay ~= nil or user_sec.color ~= nil))
		or (user.delay ~= nil or user.color ~= nil)
		or false

	return { delay = delay, color = color, has_override = has_override }
end

--- Sets a user override for a single field. Pass section=nil for file-level.
--- @param category string
--- @param section string|nil
--- @param field string "delay" or "color"
--- @param value number|string The new value. Use M.clear_override to remove.
--- @return boolean True on success.
function M.set_override(category, section, field, value)
	if not require_state("set_override") then return false end
	if field ~= "delay" and field ~= "color" then
		Logger.error(LOG, "set_override(): field must be 'delay' or 'color', got '%s'.", tostring(field))
		return false
	end

	_state.overrides[category] = _state.overrides[category] or { sections = {} }
	local entry = _state.overrides[category]
	entry.sections = entry.sections or {}

	if section then
		entry.sections[section] = entry.sections[section] or {}
		entry.sections[section][field] = value
	else
		entry[field] = value
	end

	Logger.debug(LOG, "Override set: %s%s.%s = %s.",
		category, section and ("." .. section) or "", field, tostring(value))
	return save_to_disk()
end

--- Removes a user override for a field. Reverts to the TOML/global default.
--- @param category string
--- @param section string|nil
--- @param field string|nil "delay", "color", or nil to clear both.
--- @return boolean True on success.
function M.clear_override(category, section, field)
	if not require_state("clear_override") then return false end
	local entry = _state.overrides[category]
	if not entry then return true end

	local target = section and (entry.sections or {})[section] or entry
	if not target then return true end

	if field then
		target[field] = nil
	else
		target.delay = nil
		target.color = nil
	end

	Logger.debug(LOG, "Override cleared: %s%s%s.",
		category,
		section and ("." .. section) or "",
		field and ("." .. field) or "")
	return save_to_disk()
end

--- Returns the absolute path of the override file (for diagnostics / UI).
--- @return string|nil
function M.get_override_path()
	if not _state then return nil end
	return _state.path
end

--- Re-reads the override file from disk. Useful when AHK has written to it.
--- @return boolean
function M.reload()
	if not require_state("reload") then return false end
	_state.overrides = parse_overrides(_state.path)
	Logger.debug(LOG, "Overrides reloaded from disk.")
	return true
end


-- =================================================
-- =================================================
-- ======= 6/ Introspection helpers (UI) ===========
-- =================================================
-- =================================================

--- Returns the ordered list of sections defined in a category TOML.
--- Each entry is { name = string, description = string }; separators ("-")
--- are filtered out. Used by the configuration window to render the section
--- list under each category.
--- @param category string Category name (lowercase).
--- @return table List of section descriptors in TOML declaration order.
function M.get_sections(category)
	if not require_state("get_sections") then return {} end
	local toml_path = _state.toml_resolver(category)
	if type(toml_path) ~= "string" or toml_path == "" then return {} end
	local parsed = TomlReader.parse(toml_path)
	local out = {}
	for _, name in ipairs(parsed.sections_order or {}) do
		if name ~= "-" then
			local section = parsed.sections[name]
			local desc = (section and section.description) or name
			table.insert(out, { name = name, description = desc })
		end
	end
	return out
end

--- Returns the TOML-default delay/color for a (category, section) pair —
--- the values that would apply if the user override layer were empty.
--- Used by the UI to show "back to default" state and to drive the reset button.
--- @param category string
--- @param section string|nil
--- @return table { delay = number, color = string|nil }
function M.get_toml_defaults(category, section)
	if not require_state("get_toml_defaults") then
		return { delay = GLOBAL_DEFAULT_DELAY, color = nil }
	end
	local meta = get_toml_meta(category)
	local meta_sec = section and meta.sections[section] or nil
	return {
		delay = (meta_sec and meta_sec.delay) or meta.delay or GLOBAL_DEFAULT_DELAY,
		color = (meta_sec and meta_sec.color) or meta.color,
	}
end

--- Returns the raw user override entry (or nil) for a (category, section)
--- pair. Distinguishing between "no override" and "override = TOML default"
--- is important for the UI's reset button state.
--- @param category string
--- @param section string|nil
--- @return table|nil { delay = number|nil, color = string|nil }
function M.get_user_override(category, section)
	if not require_state("get_user_override") then return nil end
	local cat = _state.overrides[category]
	if not cat then return nil end
	local target = section and (cat.sections or {})[section] or cat
	if not target then return nil end
	if target.delay == nil and target.color == nil then return nil end
	return { delay = target.delay, color = target.color }
end

return M
