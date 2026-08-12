--- modules/hotstrings/hotstrings_config.lua

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
---   3. Hard fallbacks (`GLOBAL_DEFAULT_DELAY`, `GLOBAL_DEFAULT_COLOR`).
---
--- SUPPORTED CATEGORY NAMESPACES:
---   - Standard categories  : resolve("magickey"), resolve("autocorrection"), …
---   - Extension overrides  : resolve_ext("ergopti-demo", toml_path, section?)
---     The user override key in hotstrings_config.toml is "ext.<id>" so it
---     never collides with a bare category name.
---
--- FEATURES & RATIONALE:
--- 1. Single source of truth: HS and AHK both read the same TOML metadata,
---    so per-group defaults stop being duplicated across drivers.
--- 2. Cross-driver overrides: the user override file lives at a shared path
---    so changes made from the HS menu show up in AHK (and vice versa).
--- 3. Lazy TOML parsing: each category TOML is parsed at most once per
---    session via the existing `lib.toml.reader` to avoid duplicate I/O.
--- ==============================================================================

local M = {}
local Logger     = require("infra.logger")
local Paths      = require("infra.paths")
local TomlReader = require("infra.toml.reader")
local FileSystem = require("adapters.file_system")
-- The five-rung precedence, shared with Linux. It was written once here and
-- once in AutoHotkey and the two had already drifted; the rule is the thing
-- that must not differ, and where the override file lives is the thing that may.
local DelayResolver = require("hotstrings.delay_resolver")
local LOG        = "hotstrings_config"


-- =================================
-- =================================
-- ======= 1/ Constants ============
-- =================================
-- =================================

-- Ultimate fallbacks when neither a user override nor a TOML default is set.
-- LOADED AT REQUIRE-TIME from the shared cross-driver canon
-- (_shared/modules/hotstrings/defaults.toml) by load_shared_defaults() below — the
-- SINGLE source shared verbatim with the AutoHotkey driver. They start nil so
-- a missing file/key fails fast (rule 5.3) instead of masking driver drift
-- behind a hardcoded literal (rules 5.2 / 5.4). ``GLOBAL_DEFAULT_COLOR`` remains
-- the single source of truth for "no color set" — every per-category lookup
-- that finds nothing else lands here.
local GLOBAL_DEFAULT_DELAY = nil
local GLOBAL_DEFAULT_COLOR = nil

-- Per-category baseline that overrides ``GLOBAL_DEFAULT_COLOR`` only when no
-- TOML _meta or user override sets a color. Its "personal" entry is populated
-- from the shared canon by load_shared_defaults() — kept in one table so all
-- per-category baselines stay visible in one place.
local CATEGORY_DEFAULT_COLORS = {}

-- =================================
-- =================================
-- ======= 2/ Module State =========
-- =================================
-- =================================

-- Built-in word-delimiter set — mirrors HOTSTRINGS_DEFAULT_WORD_DELIMITERS in AHK.
-- CR and LF are always included; the rest are user-configurable.
local DEFAULT_WORD_DELIMITERS = " \t\r\n.,;:?!'’-=()[]/\\+*"

local _state = nil

--- Returns the first non-nil argument. Module-level rather than a closure built
--- inside M.resolve: it captures nothing, and the preview path calls resolve once
--- per candidate on every keystroke while a tooltip is eligible, so a fresh
--- closure per call is an allocation on the HID thread for no benefit.
--- @return any|nil The first argument that is not nil.
local function first_set(...)
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if v ~= nil then return v end
	end
	return nil
end

local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end





--- ====================================
--- ====================================
--- ======= 3/ Override File I/O =======
--- ====================================
--- ====================================

--- Parses the user override TOML file into two structures:
--- - overrides: { [category] = { delay = n, color = s, sections = { [name] = { delay, color } } } }
--- - global_word_delimiters: string|nil (from [__global__] word_delimiters key)
--- Unknown keys and malformed lines are silently ignored — the file is
--- user-edited (and machine-written) so robustness matters more than strictness.
--- @param path string Absolute path to the override file.
--- @return table overrides The parsed overrides.
--- @return string|nil word_delimiters The optional word-delimiter override.
--- @return string status `committed`, `absent`, or `error`.
local function parse_overrides(path)
	local result = {}
	local word_delimiters = nil
	local read_ok, content, read_status, read_detail = pcall(FileSystem.read_with_status, path)
	if not read_ok or read_status == "error" then
		Logger.error(LOG, "Override source read did not commit: %s.",
			tostring(read_ok and read_detail or content))
		return result, nil, "error"
	end
	if read_status == "absent" then return result, nil, "absent" end
	if read_status ~= "ok" or type(content) ~= "string" then
		Logger.error(LOG, "Override source returned an invalid read status: %s.", tostring(read_status))
		return result, nil, "error"
	end

	local current_cat = nil
	local current_sec = nil
	local in_global   = false

	for raw in (content .. "\n"):gmatch("([^\n]*)\n") do
		raw = raw:gsub("\r$", "")
		local line = raw:match("^%s*(.-)%s*$")
		if not line or line == "" or line:sub(1, 1) == "#" then goto continue end

		-- [__global__] — script-wide settings (word_delimiters, etc.)
		if line == "[__global__]" then
			in_global = true
			current_cat, current_sec = nil, nil
			goto continue
		end

		-- Any other section header resets the __global__ context
		if line:sub(1, 1) == "[" then
			in_global = false
		end

		-- word_delimiters in [__global__]
		if in_global then
			local wd = line:match("^word_delimiters%s*=%s*\"(.-)\"%s*$")
			if wd then
				-- Single-pass unescape so \\n decodes as backslash+n not newline
				wd = wd:gsub('\\(.)', function(c)
						return ({n="\n", r="\r", t="\t", ['\\']='\\', ['"']='"'})[c] or ('\\'..c)
					end)
				word_delimiters = wd
			end
			goto continue
		end

		-- [ext.name.section] — extension section override (3 dotted segments)
		local ext_name, ext_sec = line:match("^%[ext%.([%w_%-]+)%.([%w_%-]+)%]$")
		if ext_name and ext_sec then
			local key = "ext." .. ext_name
			result[key] = result[key] or { sections = {} }
			result[key].sections = result[key].sections or {}
			result[key].sections[ext_sec] = result[key].sections[ext_sec] or {}
			current_cat, current_sec = key, ext_sec
			goto continue
		end

		-- [ext.name] — extension file-level override (2 dotted segments, "ext." prefix)
		local ext_only = line:match("^%[ext%.([%w_%-]+)%]$")
		if ext_only then
			local key = "ext." .. ext_only
			result[key] = result[key] or { sections = {} }
			current_cat, current_sec = key, nil
			goto continue
		end

		-- [category.section] — standard section override (must be tested before plain [category])
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

			-- Lua patterns have no alternation (|); test "true" and "false" separately.
			local bool_val = line:match("^show_tooltip%s*=%s*(true)%s*$")
				or line:match("^show_tooltip%s*=%s*(false)%s*$")
			if bool_val then
				target.show_tooltip = (bool_val == "true")
				goto continue
			end

			local prio = line:match("^priority%s*=%s*(%d+)%s*$")
			if prio then
				local p = tonumber(prio)
				if p then target.priority = p end
				goto continue
			end
		end

		::continue::
	end

	return result, word_delimiters, "committed"
end

--- Escapes a string for a TOML basic string.
--- @param value string Raw string.
--- @return string escaped
local function escape_toml_string(value)
	return (value:gsub("\\", "\\\\")
		:gsub('"', '\\"')
		:gsub("\t", "\\t")
		:gsub("\n", "\\n")
		:gsub("\r", "\\r"))
end

--- Serializes the in-memory override table back to TOML.
--- @param overrides table The override table (same shape as parse_overrides).
--- @return string The serialized TOML content.
--- @param word_delimiters string|nil The [__global__] word_delimiters value, if set.
local function serialize_overrides(overrides, word_delimiters)
	local out = {
		"# Hotstrings — overrides utilisateur",
		"# Édité depuis la fenêtre « Délais & couleurs hotstrings ».",
		"# Ne pas mélanger les sections : chaque [category] et [category.section]",
		"# ne doit apparaître qu'une seule fois.",
		"",
	}

	-- [__global__] is re-emitted FIRST. parse_overrides returns it as a separate
	-- value from the category table, and this function only ever received the
	-- second — so every save from the delays-and-colours window rewrote the file
	-- without it, silently discarding the word_delimiters the AutoHotkey driver
	-- writes into the very same shared file. A round trip that reads more than it
	-- writes destroys whatever it did not read.
	if type(word_delimiters) == "string" and word_delimiters ~= "" then
		table.insert(out, "[__global__]")
		-- Written in the shape the PARSER reads: a plain double-quoted string with
		-- only the quote and the backslash escaped. string.format("%q") emits LUA
		-- escapes — a tab becomes \9 — which round-trips through Lua and not
		-- through `word_delimiters%s*=%s*"(.-)"`.
		local escaped = escape_toml_string(word_delimiters)
		table.insert(out, 'word_delimiters = "' .. escaped .. '"')
		table.insert(out, "")
	end

	-- Stable ordering: alphabetical category, alphabetical section.
	local cats = {}
	for cat, _ in pairs(overrides) do table.insert(cats, cat) end
	table.sort(cats)

	for _, cat in ipairs(cats) do
		local entry = overrides[cat]
		local has_file_level = entry.delay ~= nil or entry.color ~= nil or entry.show_tooltip ~= nil
			or entry.priority ~= nil
		if has_file_level then
			table.insert(out, string.format("[%s]", cat))
			if entry.delay ~= nil then
				table.insert(out, string.format("delay = %s", tostring(entry.delay)))
			end
			if entry.color ~= nil then
				table.insert(out, string.format("color = \"%s\"", entry.color))
			end
			if entry.show_tooltip ~= nil then
				table.insert(out, string.format("show_tooltip = %s", entry.show_tooltip and "true" or "false"))
			end
			if entry.priority ~= nil then
				table.insert(out, string.format("priority = %d", math.floor(entry.priority)))
			end
			table.insert(out, "")
		end

		if entry.sections then
			local secs = {}
			for s, _ in pairs(entry.sections) do table.insert(secs, s) end
			table.sort(secs)
			for _, sec in ipairs(secs) do
				local s_entry = entry.sections[sec]
				if s_entry.delay ~= nil or s_entry.color ~= nil or s_entry.show_tooltip ~= nil
					or s_entry.priority ~= nil then
					table.insert(out, string.format("[%s.%s]", cat, sec))
					if s_entry.delay ~= nil then
						table.insert(out, string.format("delay = %s", tostring(s_entry.delay)))
					end
					if s_entry.color ~= nil then
						table.insert(out, string.format("color = \"%s\"", s_entry.color))
					end
					if s_entry.show_tooltip ~= nil then
						table.insert(out, string.format("show_tooltip = %s", s_entry.show_tooltip and "true" or "false"))
					end
					if s_entry.priority ~= nil then
						table.insert(out, string.format("priority = %d", math.floor(s_entry.priority)))
					end
					table.insert(out, "")
				end
			end
		end
	end

	return table.concat(out, "\n")
end

--- Clones an override tree so a setter can build an unpublished candidate.
--- @param value any Value to clone.
--- @return any clone
local function clone_value(value)
	if type(value) ~= "table" then return value end
	local clone = {}
	for key, child in pairs(value) do clone[key] = clone_value(child) end
	return clone
end

--- Persists a candidate override state through the atomic file-system adapter.
--- @param overrides table Candidate overrides.
--- @param word_delimiters string|nil Candidate delimiter override.
--- @return boolean True on success, false on I/O failure.
local function save_to_disk(overrides, word_delimiters)
	if not _state then return false end
	if _state.writes_blocked then
		Logger.error(LOG, "Override save refused because the source read did not commit.")
		return false
	end
	local content = serialize_overrides(overrides, word_delimiters)
	local ok, committed = pcall(FileSystem.write, _state.path, content)
	if not ok or committed ~= true then
		Logger.error(LOG, "Failed to commit override file atomically.")
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

	local parse_ok, parsed, committed = pcall(TomlReader.parse, toml_path)
	if not parse_ok or committed ~= true or type(parsed) ~= "table" then
		Logger.error(LOG, "Category TOML read did not commit: '%s'.", toml_path)
		return { sections = {} }
	end
	cache[category] = {
		delay        = parsed.meta.delay,
		color        = parsed.meta.color,
		show_tooltip = parsed.meta.show_tooltip,
		priority     = parsed.meta.priority,
		sections     = parsed.meta.sections or {},
	}
	return cache[category]
end





--- =============================
--- =============================
--- ======= 5/ Public API =======
--- =============================
--- =============================

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

	local overrides, word_delimiters, read_status = parse_overrides(opts.override_path)
	_state = {
		path            = opts.override_path,
		toml_resolver   = opts.toml_resolver,
		overrides       = overrides,
		word_delimiters = word_delimiters,
		writes_blocked  = read_status == "error",
		toml_cache      = {},
		-- Memo for M.resolve, cleared by the three writers that can change an
		-- answer. Living in _state means M.init() resets it without a separate
		-- lifecycle to remember.
		resolve_cache   = {},
	}
	if read_status == "error" then
		Logger.error(LOG, "Initialization degraded: override source is unreadable and writes are blocked.")
		return false
	end
	Logger.success(LOG, "Initialized (override file: '%s').", opts.override_path)
	return true
end

--- Returns the effective delay (seconds) and color (hex string) for a group.
--- @param category string The TOML file name without extension (e.g. "rolls").
--- @param section string|nil Optional section name within the category.

--- Returns the shared global default expansion delay, in milliseconds.
---
--- Published so consumers read the canon instead of mirroring it. The hotstrings
--- config window carried its own `GLOBAL_DEFAULT_DELAY_MS = 750` with a comment
--- saying the two "must stay in sync" — which is the definition of two sources,
--- and the shared TOML is the one the AutoHotkey driver reads.
--- @return number|nil Milliseconds, or nil before init() has loaded the canon.
function M.get_global_default_delay_ms()
	if type(GLOBAL_DEFAULT_DELAY) ~= "number" then return nil end
	-- GLOBAL_DEFAULT_DELAY is held in seconds; the window speaks milliseconds.
	return math.floor(GLOBAL_DEFAULT_DELAY * 1000 + 0.5)
end

--- @return table { delay = number, color = string|nil, has_override = boolean }
function M.resolve(category, section)
	if not require_state("resolve") then
		return { delay = GLOBAL_DEFAULT_DELAY, color = nil, show_tooltip = true, has_override = false }
	end

	-- Memoised, like the AutoHotkey sibling (_HSResolveCache / _HSResolveGen in
	-- infra/hotstrings/hotstrings_config.ahk). The answer for a (category, section)
	-- pair is static between override and TOML changes, and the tooltip preview
	-- resolves it once per CANDIDATE on every keystroke — so the cascade was being
	-- re-walked several times per key on the HID thread. The two drivers were
	-- paying different costs for the same cascade because only one of them had
	-- reached this conclusion.
	--
	-- Invalidated by clearing the table in the three writers that can change the
	-- answer (set_override, clear_override, reload) rather than by a generation
	-- counter: the cache lives in _state, so M.init() resets it for free.
	local cache_key = tostring(category) .. "\0" .. tostring(section or "")
	local cached = _state.resolve_cache and _state.resolve_cache[cache_key]
	if cached then return cached end

	local user = _state.overrides[category] or { sections = {} }
	local user_sec = section and (user.sections or {})[section] or nil
	local meta = get_toml_meta(category)
	local meta_sec = section and meta.sections[section] or nil

	-- The cascade itself lives in _shared/lua/hotstrings/delay_resolver.lua.
	-- It was written once here and once in AutoHotkey, and the two had already
	-- drifted on what an explicit `false` means — which matters, because a
	-- category that ships `show_tooltip = false` is the common case and a rung
	-- testing truthiness turns its preview back on.
	local resolved = DelayResolver.resolve({
		user_category  = user,
		user_section   = user_sec,
		meta_category  = meta,
		meta_section   = meta_sec,
		default_delay  = GLOBAL_DEFAULT_DELAY,
		default_color  = GLOBAL_DEFAULT_COLOR,
		category_color = CATEGORY_DEFAULT_COLORS[category],
	})
	if _state.resolve_cache then _state.resolve_cache[cache_key] = resolved end
	return resolved
end

--- Resolves the effective delay and color for an extension hotstring file.
--- Mirrors HotstringsResolveExt() on the AHK side.
--- @param ext_id string Extension identifier (e.g. "ergopti-demo").
--- @param toml_path string Absolute path to the extension TOML file.
--- @param section string|nil Optional section name within the file.
--- @return table { delay = number, color = string|nil, has_override = boolean }
function M.resolve_ext(ext_id, toml_path, section)
	if not require_state("resolve_ext") then
		return { delay = GLOBAL_DEFAULT_DELAY, color = GLOBAL_DEFAULT_COLOR, show_tooltip = true, has_override = false }
	end

	local override_key = "ext." .. ext_id:lower()
	local user = _state.overrides[override_key] or { sections = {} }
	local user_sec = section and (user.sections or {})[section] or nil

	-- Read the extension TOML meta directly (bypasses the category-name resolver).
	local cache_key = "ext:" .. toml_path
	if not _state.toml_cache[cache_key] then
		local ok, parsed, committed = pcall(TomlReader.parse, toml_path)
		if ok and committed == true and type(parsed) == "table" then
			_state.toml_cache[cache_key] = {
				delay        = parsed.meta and parsed.meta.delay,
				color        = parsed.meta and parsed.meta.color,
				show_tooltip = parsed.meta and parsed.meta.show_tooltip,
				sections     = (parsed.meta and parsed.meta.sections) or {},
			}
		else
			Logger.error(LOG, "Extension TOML read did not commit: '%s'.", toml_path)
			return { delay = GLOBAL_DEFAULT_DELAY, color = GLOBAL_DEFAULT_COLOR,
				show_tooltip = true, has_override = false }
		end
	end
	local meta     = _state.toml_cache[cache_key]
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
		or GLOBAL_DEFAULT_COLOR

	local show_tooltip = true
	local function first_set_ext(...)
		for i = 1, select("#", ...) do
			local v = select(i, ...)
			if v ~= nil then return v end
		end
		return nil
	end
	local st_ext = first_set_ext(
		user_sec and user_sec.show_tooltip,
		user.show_tooltip,
		meta_sec and meta_sec.show_tooltip,
		meta.show_tooltip
	)
	if st_ext ~= nil then show_tooltip = st_ext end

	local has_override =
		(user_sec and (user_sec.delay ~= nil or user_sec.color ~= nil or user_sec.show_tooltip ~= nil))
		or (user.delay ~= nil or user.color ~= nil or user.show_tooltip ~= nil)
		or false

	return { delay = delay, color = color, show_tooltip = show_tooltip, has_override = has_override }
end

--- Sets a user override for a single field. Pass section=nil for file-level.
--- @param category string
--- @param section string|nil
--- @param field string "delay" or "color"
--- @param value number|string The new value. Use M.clear_override to remove.
--- @return boolean True on success.
function M.set_override(category, section, field, value)
	if not require_state("set_override") then return false end
	if field ~= "delay" and field ~= "color" and field ~= "show_tooltip" and field ~= "priority" then
		Logger.error(LOG, "set_override(): field must be 'delay', 'color', 'show_tooltip', or 'priority', got '%s'.", tostring(field))
		return false
	end

	local candidate = clone_value(_state.overrides)
	candidate[category] = candidate[category] or { sections = {} }
	local entry = candidate[category]
	entry.sections = entry.sections or {}

	if section then
		entry.sections[section] = entry.sections[section] or {}
		entry.sections[section][field] = value
	else
		entry[field] = value
	end

	if not save_to_disk(candidate, _state.word_delimiters) then return false end
	_state.overrides = candidate
	_state.resolve_cache = {}
	Logger.debug(LOG, "Override set: %s%s.%s = %s.",
		category, section and ("." .. section) or "", field, tostring(value))
	return true
end

--- Removes a user override for a field. Reverts to the TOML/global default.
--- @param category string
--- @param section string|nil
--- @param field string|nil "delay", "color", or nil to clear both.
--- @return boolean True on success.
function M.clear_override(category, section, field)
	if not require_state("clear_override") then return false end
	if _state.writes_blocked then
		Logger.error(LOG, "Override clear refused because the source read did not commit.")
		return false
	end
	local candidate = clone_value(_state.overrides)
	local entry = candidate[category]
	if not entry then return true end

	local target = section and (entry.sections or {})[section] or entry
	if not target then return true end

	if field then
		target[field] = nil
	else
		target.delay        = nil
		target.color        = nil
		target.show_tooltip = nil
		target.priority     = nil
	end

	if not save_to_disk(candidate, _state.word_delimiters) then return false end
	_state.overrides = candidate
	_state.resolve_cache = {}
	Logger.debug(LOG, "Override cleared: %s%s%s.",
		category,
		section and ("." .. section) or "",
		field and ("." .. field) or "")
	return true
end

--- Returns the absolute path of the override file (for diagnostics / UI).
--- @return string|nil
function M.get_override_path()
	if not _state then return nil end
	return _state.path
end

--- Re-reads the override file from disk, discarding the in-memory overrides
--- table and rebuilding it from `_state.path`. Intended for the case where the
--- AHK driver has externally rewritten the shared override file while this
--- process is still running.
---
--- NOT CURRENTLY WIRED IN (F-LOW-7): no production call site invokes this —
--- every setter in this module (M.set_override, M.clear_override,
--- M.set_word_delimiters) already keeps `_state.overrides` in sync in-memory
--- AND writes to disk immediately, so a same-process caller never needs to
--- re-read what it just wrote. There is also no cross-process file-watcher
--- on `_state.path` that would make an externally written file get picked up
--- automatically — this function only helps if something calls it
--- explicitly, which nothing currently does. Note it also
--- would NOT invalidate `_state.toml_cache` even if called: a reload after an
--- external write would still serve stale cached TOML `[_meta]` metadata for
--- any category already resolved once this session.
--- @return boolean
function M.reload()
	if not require_state("reload") then return false end
	local overrides, word_delimiters, read_status = parse_overrides(_state.path)
	if read_status == "error" then
		_state.writes_blocked = true
		Logger.error(LOG, "Override reload failed; prior memory retained and writes blocked.")
		return false
	end
	_state.overrides       = overrides
	_state.word_delimiters = word_delimiters
	_state.writes_blocked  = false
	_state.resolve_cache   = {}
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
	local ok, parsed, committed = pcall(TomlReader.parse, toml_path)
	if not ok or committed ~= true or type(parsed) ~= "table" then
		Logger.error(LOG, "Section-list TOML read did not commit: '%s'.", toml_path)
		return {}
	end
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
		priority = (meta_sec and meta_sec.priority) or meta.priority,
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
	if target.delay == nil and target.color == nil and target.show_tooltip == nil
		and target.priority == nil then return nil end
	return { delay = target.delay, color = target.color, show_tooltip = target.show_tooltip,
		priority = target.priority }
end

-- =================================================
-- =================================================
-- ======= 7/ Word-delimiter API ===================
-- =================================================
-- =================================================

--- Returns the effective word-delimiter string: user override when stored,
--- otherwise the built-in DEFAULT_WORD_DELIMITERS constant (mirrors AHK default).
--- @return string
function M.get_word_delimiters()
	if not require_state("get_word_delimiters") then return DEFAULT_WORD_DELIMITERS end
	return _state.word_delimiters or DEFAULT_WORD_DELIMITERS
end

--- Returns the built-in default word-delimiter string.
--- @return string
function M.get_default_word_delimiters()
	return DEFAULT_WORD_DELIMITERS
end

--- Patches only the shared global delimiter key while preserving other bytes.
--- @param existing string Complete committed source content.
--- @param delimiters string|nil Candidate delimiter value.
--- @return string content Candidate file content.
local function patch_word_delimiters(existing, delimiters)
	local lines = {}
	for line in (existing .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, (line:gsub("\r$", "")))
	end
	while #lines > 0 and lines[#lines] == "" do table.remove(lines) end

	local in_global = false
	local global_start = nil
	local key_lines = {}
	for index, line in ipairs(lines) do
		local trimmed = line:match("^%s*(.-)%s*$") or ""
		if trimmed == "[__global__]" then
			in_global = true
			global_start = index
		elseif in_global and trimmed:sub(1, 1) == "[" then
			in_global = false
		elseif in_global and trimmed:match("^word_delimiters%s*=") then
			table.insert(key_lines, index)
		end
	end
	local new_line = delimiters
		and ('word_delimiters = "' .. escape_toml_string(delimiters) .. '"')
		or nil
	if #key_lines > 0 then
		if new_line then lines[key_lines[1]] = new_line end
		local first_to_remove = new_line and 2 or 1
		for index = #key_lines, first_to_remove, -1 do table.remove(lines, key_lines[index]) end
	elseif new_line and global_start then
		table.insert(lines, global_start + 1, new_line)
	elseif new_line then
		if #lines > 0 then table.insert(lines, "") end
		table.insert(lines, "[__global__]")
		table.insert(lines, new_line)
	end

	if not new_line and global_start then
		local has_value = false
		for index = global_start + 1, #lines do
			local trimmed = (lines[index] or ""):match("^%s*(.-)%s*$") or ""
			if trimmed:sub(1, 1) == "[" then break end
			if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then has_value = true break end
		end
		if not has_value then table.remove(lines, global_start) end
	end

	return table.concat(lines, "\n") .. "\n"
end

--- Persists a new word-delimiter string to the [__global__] section of the
--- override file and updates the in-memory value.
--- Pass nil or the default string to clear the override (removes the key).
--- @param delimiters string|nil The new delimiter string, or nil to reset.
--- @return boolean True on success.
function M.set_word_delimiters(delimiters)
	if not require_state("set_word_delimiters") then return false end

	local candidate
	if delimiters == nil or delimiters == DEFAULT_WORD_DELIMITERS then
		candidate = nil
	else
		candidate = delimiters
	end

	if _state.writes_blocked then
		Logger.error(LOG, "Delimiter save refused because the source read did not commit.")
		return false
	end
	local read_ok, existing, read_status, read_detail = pcall(FileSystem.read_with_status, _state.path)
	if not read_ok or read_status == "error" then
		_state.writes_blocked = true
		Logger.error(LOG, "Delimiter save refused because the latest source read failed: %s.",
			tostring(read_ok and read_detail or existing))
		return false
	end
	if read_status ~= "ok" and read_status ~= "absent" then
		_state.writes_blocked = true
		Logger.error(LOG, "Delimiter save refused after an invalid read status: %s.", tostring(read_status))
		return false
	end
	if read_status == "ok" and type(existing) ~= "string" then
		_state.writes_blocked = true
		Logger.error(LOG, "Delimiter save refused because committed source bytes were not a string.")
		return false
	end
	local content = patch_word_delimiters(existing or "", candidate)
	local write_ok, committed = pcall(FileSystem.write, _state.path, content)
	if not write_ok or committed ~= true then
		Logger.error(LOG, "Failed to commit word_delimiters atomically.")
		return false
	end
	_state.word_delimiters = candidate
	Logger.debug(LOG, "word_delimiters persisted: %s.", candidate and
		('"' .. tostring(candidate) .. '"') or "(default — key removed)")
	return true
end





-- ==========================================================
-- ==========================================================
-- ======= 8/ Bootstrap: shared cross-driver defaults =======
-- ==========================================================
-- ==========================================================

--- Reads _shared/modules/hotstrings/defaults.toml at require-time and populates the
--- three hard-fallback constants from the single cross-driver source. A missing
--- file, section, or key raises an error (fail fast — no driver-side literal).
--- The path is resolved relative to THIS file (cwd-independent), mirroring
--- ui/tooltip/config.lua, so it behaves identically in production and in the
--- headless unit harness (where the module is re-required per test).
local function load_shared_defaults()
	-- Resolved through the single shared-tree resolver (Paths.shared) so the
	-- shared root lives in exactly one place, cwd-independent in production and
	-- in the headless unit harness.
	local toml_path = Paths.shared("modules/hotstrings/defaults.toml")

	local parsed, committed = TomlReader.parse(toml_path)
	if committed ~= true then
		error("[hotstrings_config] _shared/modules/hotstrings/defaults.toml read did not commit: " .. toml_path)
	end
	local sections = (type(parsed) == "table") and parsed.sections or nil
	if type(sections) ~= "table" then
		error("[hotstrings_config] _shared/modules/hotstrings/defaults.toml not readable: " .. toml_path)
	end

	local function require_key(section, key)
		local s = sections[section]
		if type(s) ~= "table" or s[key] == nil then
			error(string.format("[hotstrings_config] missing key [%s].%s in %s", section, key, toml_path))
		end
		return s[key]
	end

	GLOBAL_DEFAULT_DELAY             = tonumber(require_key("delays", "default_sec"))
	GLOBAL_DEFAULT_COLOR             = require_key("colors", "global_default")
	CATEGORY_DEFAULT_COLORS.personal = require_key("colors", "personal")

	if type(GLOBAL_DEFAULT_DELAY) ~= "number" then
		error("[hotstrings_config] [delays].default_sec must be a number in " .. toml_path)
	end

	Logger.done(LOG, "Shared hotstring defaults loaded (delay=%.2fs color=%s personal=%s).",
		GLOBAL_DEFAULT_DELAY, tostring(GLOBAL_DEFAULT_COLOR), tostring(CATEGORY_DEFAULT_COLORS.personal))
end

load_shared_defaults()

return M
