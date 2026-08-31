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
local DelayResolver = require("hotstrings.delay_resolver")
local Priority = require("hotstring_priority")
local Extensions = require("hotstrings.extensions")
local Paths = require("infra.paths")
local TomlReader = require("toml_codec.reader")

local LOG = "modules.hotstrings.hotstrings_config"

-- Where the disabled-category set is persisted. One key holding a comma-joined
-- list rather than one key per category: the set is read and written whole, and
-- a per-key layout leaves orphans behind when a category is renamed.
local DISABLED_KEY = "hotstrings.disabled_categories"

-- Where per-category and per-section overrides are persisted. A TOML beside the
-- packs rather than a storage key, because it is a file the user is expected to
-- open: the same one the config window edits and the same shape macOS writes.
local OVERRIDES_FILE = "hotstrings_overrides.toml"

-- The reserved override key holding the user's GLOBAL default delay, as opposed
-- to any one category's. Spelled exactly as AHK spells it
-- (infra/hotstrings/hotstrings_catalogue.ahk consults `_HotstringsOverrides["_global"]`
-- as the lowest-priority user value) so the two override files stay readable by
-- the same rules — where the file LIVES differs per driver by design, but what a
-- key means inside it must not.
--
-- The leading underscore is what keeps it out of the catalogue: category ids are
-- TOML file stems, and no pack is named "_global".
local GLOBAL_CATEGORY = "_global"


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
local _magic_key      = nil
local _canonical_magic_key = nil

--- Called after any change that alters what the menu should show. Set by the
--- daemon; nil in the harness, where nothing is drawn.
local _on_change = nil

--- Supplies mappings that no TOML file describes. See set_extra_mappings_provider.
local _extra_mappings_provider = nil

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


-- The cross-driver fallbacks, read once from the shared TOML. No literal here:
-- the AutoHotkey and Hammerspoon drivers both read the same file, and a
-- re-typed 0.75 is how three drivers end up disagreeing about how long a
-- hotstring waits.
local GLOBAL_DEFAULT_DELAY = nil
local GLOBAL_DEFAULT_COLOR = nil
-- The shade the settings window's "make everything grey" button applies. Read
-- from the shared defaults rather than written here: it was a literal inside the
-- macOS bridge, equal by coincidence to the personal category's colour.
local NEUTRAL_COLOR = nil
local CATEGORY_DEFAULT_COLORS = {}

--- Loads _shared/modules/hotstrings/defaults.toml, or raises.
---
--- Fail-fast, deliberately and in agreement with the other two drivers: a
--- missing file is a broken install, and a driver that silently substituted its
--- own numbers would expand at a different speed from the one the user
--- configured, with nothing in the log to say so.
local function load_shared_defaults()
	local path = Paths.shared("modules/hotstrings/defaults.toml")
	local parsed = TomlReader.parse(path)
	local sections = type(parsed) == "table" and parsed.sections or nil
	if type(sections) ~= "table" then
		error("[hotstrings_config] shared defaults not readable: " .. tostring(path))
	end

	--- @param section string
	--- @param key string
	--- @return any
	local function require_key(section, key)
		local s = sections[section]
		if type(s) ~= "table" or s[key] == nil then
			error(string.format("[hotstrings_config] missing key [%s].%s in %s", section, key, path))
		end
		return s[key]
	end

	GLOBAL_DEFAULT_DELAY = tonumber(require_key("delays", "default_sec"))
	GLOBAL_DEFAULT_COLOR = require_key("colors", "global_default")
	NEUTRAL_COLOR        = require_key("colors", "neutral")
	CATEGORY_DEFAULT_COLORS.personal = require_key("colors", "personal")

	if type(GLOBAL_DEFAULT_DELAY) ~= "number" then
		error("[hotstrings_config] [delays].default_sec must be a number in " .. path)
	end
end

load_shared_defaults()




-- =========================================
-- =========================================
-- ======= 3/ Delays and colours ===========
-- =========================================
-- =========================================

--- User overrides, by category:
--- { [category] = { delay, color, show_tooltip, sections = { [name] = { ... } } } }
local _overrides = {}

--- Memoised resolutions, cleared by every writer below. The tooltip preview
--- resolves once per candidate on every keystroke, so the cascade would
--- otherwise be walked several times per key on the input path.
local _resolve_cache = {}

--- The override file's path.
--- @return string
local function overrides_path()
	local home = require("infra.config_paths").home()
	return home .. "/.config/ergopti/" .. OVERRIDES_FILE
end

--- Reads the override file into memory. A missing file is the normal case.
local function load_overrides()
	_overrides = {}
	_resolve_cache = {}

	local path = overrides_path()
	local fh = io.open(path, "r")
	if not fh then return end
	fh:close()

	local ok, parsed = pcall(TomlReader.parse, path)
	if not ok or type(parsed) ~= "table" or type(parsed.sections) ~= "table" then
		-- Loud, not silent: a malformed override file means the user's delays are
		-- being ignored, and the only symptom otherwise is "my settings did
		-- nothing".
		Logger.error(LOG, "Override file '%s' is malformed — user delays and colours ignored.", path)
		return
	end

	-- A section is named either "category" or "category.section". Flat in the
	-- file because that is what a user editing it by hand can read, and it is the
	-- shape macOS writes.
	for name, values in pairs(parsed.sections) do
		local category, section = name:match("^([^%.]+)%.(.+)$")
		category = category or name
		local entry = _overrides[category] or { sections = {} }
		entry.sections = entry.sections or {}
		local target = entry
		if section then
			entry.sections[section] = entry.sections[section] or {}
			target = entry.sections[section]
		end
		if values.delay ~= nil then target.delay = tonumber(values.delay) end
		if values.color ~= nil then target.color = values.color end
		if values.show_tooltip ~= nil then target.show_tooltip = values.show_tooltip end
		_overrides[category] = entry
	end
end

--- Writes the override file back.
--- @return boolean
local function save_overrides()
	local lines = {
		"# ~/.config/ergopti/" .. OVERRIDES_FILE,
		"# Written by the Ergopti+ daemon. Safe to edit by hand.",
		"",
	}

	local names = {}
	for category in pairs(_overrides) do names[#names + 1] = category end
	table.sort(names)

	--- Emits one TOML table, or nothing when it carries no override.
	--- @param header string
	--- @param values table
	local function emit(header, values)
		if values.delay == nil and values.color == nil and values.show_tooltip == nil then return end
		lines[#lines + 1] = "[" .. header .. "]"
		if values.delay ~= nil then
			lines[#lines + 1] = string.format("delay = %s", tostring(values.delay))
		end
		if values.color ~= nil then
			-- Escaped by hand rather than with string.format("%q"): that is a LUA
			-- literal quoter, it emits Lua escape sequences a TOML reader does not
			-- share, and a repo-wide ratchet forbids it outright because the same
			-- call in a shell command leaves $VAR and `cmd` live.
			local escaped = tostring(values.color):gsub("\\", "\\\\"):gsub('"', '\\"')
			lines[#lines + 1] = 'color = "' .. escaped .. '"'
		end
		if values.show_tooltip ~= nil then
			lines[#lines + 1] = string.format("show_tooltip = %s", tostring(values.show_tooltip))
		end
		lines[#lines + 1] = ""
	end

	for _, category in ipairs(names) do
		local entry = _overrides[category]
		emit(category, entry)
		local sections = {}
		for name in pairs(entry.sections or {}) do sections[#sections + 1] = name end
		table.sort(sections)
		for _, name in ipairs(sections) do
			emit(category .. "." .. name, entry.sections[name])
		end
	end

	local path = overrides_path()
	local fh = io.open(path, "w")
	if not fh then
		Logger.error(LOG, "Cannot write '%s' — the override will not survive a restart.", path)
		return false
	end
	fh:write(table.concat(lines, "\n"))
	fh:close()
	Logger.debug(LOG, "Overrides written to %s.", path)
	return true
end

--- The effective delay, colour and preview setting for a category or section.
---
--- The cascade lives in _shared/lua/hotstrings/delay_resolver.lua and is shared
--- with macOS. What differs between the drivers is where the override file lives
--- and how a TOML is parsed; what must not differ is the order of the rungs.
--- @param category string
--- @param section string|nil
--- @return table { delay, color, show_tooltip, priority, has_override }
function M.resolve(category, section)
	local key = tostring(category) .. "\1" .. tostring(section or "")
	local cached = _resolve_cache[key]
	if cached then return cached end

	local user = _overrides[category] or {}
	local meta = _categories[category] or {}

	local resolved = DelayResolver.resolve({
		user_category  = user,
		user_section   = section and (user.sections or {})[section] or nil,
		meta_category  = meta,
		meta_section   = section and (meta.sections or {})[section] or nil,
		default_delay  = M.get_global_delay(),
		default_color  = GLOBAL_DEFAULT_COLOR,
		category_color = CATEGORY_DEFAULT_COLORS[category],
		default_priority = Priority.source_priority(category),
	})
	_resolve_cache[key] = resolved
	return resolved
end

--- The delay used by every category that declares none: the user's global
--- choice, or the shipped default.
---
--- Occupies the same rung as AHK's reserved "_global" override key — the lowest
--- USER value, sitting just above the hardcoded shared default and below
--- anything a category or section says. It is spelled as a normal override entry
--- rather than as a field of its own so that one writer, one file and one
--- clear-override path serve it like all the others; GLOBAL_CATEGORY is not a
--- real category, and nothing enumerates it, because the catalogue is what
--- lists categories and this key never appears there.
--- @return number Seconds.
function M.get_global_delay()
	local entry = _overrides[GLOBAL_CATEGORY]
	local delay = entry and tonumber(entry.delay) or nil
	if delay then return delay end
	return GLOBAL_DEFAULT_DELAY
end

--- Whether the user has set a global delay of their own.
--- @return boolean
function M.has_global_delay_override()
	local entry = _overrides[GLOBAL_CATEGORY]
	return entry ~= nil and tonumber(entry.delay) ~= nil
end

--- Sets the global default delay.
--- @param seconds number|nil nil clears it, restoring the shipped default.
--- @return boolean
function M.set_global_delay(seconds)
	if seconds == nil then return M.clear_override(GLOBAL_CATEGORY, nil) end
	if type(seconds) ~= "number" or seconds < 0 then
		Logger.error(LOG, "set_global_delay(): %s is not a non-negative number.", tostring(seconds))
		return false
	end
	return M.set_override(GLOBAL_CATEGORY, nil, "delay", seconds)
end

--- Sets one override field, persisting it.
--- @param category string
--- @param section string|nil nil targets the whole category.
--- @param field string "delay" | "color" | "show_tooltip"
--- @param value any nil clears the field.
--- @return boolean
function M.set_override(category, section, field, value)
	if type(category) ~= "string" or category == "" then return false end
	-- "priority" was missing until 2026-08-05. The settings window has a priority
	-- field per category and per section, the bridge forwards it, and this guard
	-- rejected it — so the control wrote an ERROR to the log and nothing else. The
	-- window gave no sign, because the bridge answered with a refreshed payload
	-- either way.
	if field ~= "delay" and field ~= "color" and field ~= "show_tooltip" and field ~= "priority" then
		Logger.error(LOG, "set_override(): '%s' is not an overridable field.", tostring(field))
		return false
	end

	local entry = _overrides[category] or { sections = {} }
	entry.sections = entry.sections or {}
	local target = entry
	if section then
		entry.sections[section] = entry.sections[section] or {}
		target = entry.sections[section]
	end
	target[field] = value
	_overrides[category] = entry

	_resolve_cache = {}
	local ok = save_overrides()
	notify_change()
	return ok
end

--- The values a category's own TOML declares, with no user override applied.
---
--- Published for the settings window, which shows the shipped value as the
--- placeholder behind an empty field and marks a row "(default)" when the user
--- has not overridden it. Without it the window cannot tell the two apart and
--- every row reads as user-set.
--- @param category string
--- @param section string|nil
--- @return table { delay, color, show_tooltip, priority } — any may be nil.
function M.get_toml_defaults(category, section)
	local meta = _categories[category] or {}
	if section then
		local entry = (meta.sections or {})[section] or {}
		return {
			delay        = entry.delay,
			color        = entry.color,
			show_tooltip = entry.show_tooltip,
			priority     = entry.priority,
		}
	end
	return {
		delay        = meta.delay,
		color        = meta.color,
		show_tooltip = meta.show_tooltip,
		priority     = meta.priority,
	}
end

--- The user's own override table for a category or section.
---
--- Returned as a copy: the window is handed this to decide which fields are
--- marked as overridden, and a caller that mutated the live table would change
--- the cascade without going through set_override or clearing the resolve cache.
--- @param category string
--- @param section string|nil
--- @return table Possibly empty; never nil.
function M.get_user_override(category, section)
	local entry = _overrides[category]
	if not entry then return {} end
	local source = entry
	if section then source = (entry.sections or {})[section] end
	if type(source) ~= "table" then return {} end
	return {
		delay        = source.delay,
		color        = source.color,
		show_tooltip = source.show_tooltip,
		priority     = source.priority,
	}
end

--- Clears overrides for a category, or one of its sections, or one field of one.
---
--- The third parameter was missing until 2026-08-05, and it was a trap rather
--- than a bug: the settings window's ↺ buttons are PER FIELD on all three
--- drivers, so the natural port of macOS's `clear_override(cat, sec, "color")`
--- compiled here, silently discarded the third argument, and wiped that scope's
--- delay, colour, tooltip AND priority instead of just its colour.
--- @param category string
--- @param section string|nil nil targets the whole category.
--- @param field string|nil nil clears every field of that scope.
--- @return boolean
function M.clear_override(category, section, field)
	local entry = _overrides[category]
	if not entry then return true end

	if field ~= nil then
		if field ~= "delay" and field ~= "color" and field ~= "show_tooltip" and field ~= "priority" then
			Logger.error(LOG, "clear_override(): '%s' is not an overridable field.", tostring(field))
			return false
		end
		local target = entry
		if section then target = (entry.sections or {})[section] end
		if type(target) == "table" then target[field] = nil end
	elseif section then
		if entry.sections then entry.sections[section] = nil end
	else
		_overrides[category] = nil
	end

	_resolve_cache = {}
	local ok = save_overrides()
	notify_change()
	return ok
end

--- The shared global default delay, in milliseconds.
---
--- Published so the config window reads the canon instead of mirroring it: the
--- macOS window carried its own 750 with a comment saying the two "must stay in
--- sync", which is the definition of two sources.
--- @return integer
function M.get_global_default_delay_ms()
	return math.floor(GLOBAL_DEFAULT_DELAY * 1000 + 0.5)
end

--- The neutral shade the settings window's "make everything grey" button applies.
---
--- Exposed rather than let the bridge read the TOML again: this module is where
--- the shared defaults are loaded and validated, and a second reader is a second
--- place to get the path or the key wrong. It cannot be nil — load_shared_defaults
--- raises when the key is missing, so a caller never needs a fallback of its own.
--- @return string A "#RRGGBB" colour.
function M.get_neutral_color()
	return NEUTRAL_COLOR
end

--- Test seam: replaces the parsed category metadata without a filesystem scan.
---
--- The sibling of _set_overrides_for_test, and needed for the same reason. The
--- cross-driver resolve corpus is about the PRECEDENCE cascade, not about finding
--- files: routing it through load_all() would make it depend on `find`, which is
--- Windows' find.exe on a developer's machine and answers with silence. The
--- vectors then all resolve to the global default and the corpus reports a
--- divergence from macOS that does not exist. The parse itself is covered by
--- test_loader_catalogue.lua, which is where it belongs.
--- @param categories table|nil Map of category id to its parsed metadata.
function M._set_categories_for_test(categories)
	_categories = categories or {}
	_resolve_cache = {}
end

--- Test seam: replaces the in-memory overrides without touching the file.
--- @param overrides table|nil
function M._set_overrides_for_test(overrides)
	_overrides = overrides or {}
	_resolve_cache = {}
end




-- =========================================
-- =========================================
-- ======= 4/ Initialisation ===============
-- =========================================
-- =========================================

--- @param engine table The hotstring engine.
--- @param config_dir string|nil Explicit config path; nil resolves the XDG one.
--- @param on_change function|nil Called whenever the menu's view of the config changes.
function M.init(engine, config_dir, on_change)
	_engine = engine
	_on_change = type(on_change) == "function" and on_change or nil
	_magic_key = nil
	_canonical_magic_key = nil
	if type(config_dir) == "string" and config_dir ~= "" then
		_config_dir = config_dir
	else
		local home = require("infra.config_paths").home()
		local xdg = home .. "/.config/ergopti/hotstrings"
		local fh = io.open(xdg, "r")
		if fh then fh:close(); _config_dir = xdg end
	end
	_disabled_groups = load_disabled()
	load_overrides()
	Logger.info(LOG, "Config manager initialised (dir=%s, %d disabled).",
		_config_dir or "(bundled)", count_disabled())
end

--- Registers a source of mappings that do not come from a TOML file.
---
--- The prefix expansions built from personal_info.toml are the only caller: they
--- are assembled in code, they change when the user edits that file or flips a
--- dynamic-family toggle, and they must be rebuilt on every load rather than
--- cached. Injected rather than required directly so this module keeps knowing
--- nothing about the dynamic-hotstrings layer — and so a test can supply two
--- mappings instead of a personal_info.toml.
--- @param provider function|nil Returns an array of mapping tables. nil clears it.
function M.set_extra_mappings_provider(provider)
	if provider ~= nil and type(provider) ~= "function" then
		Logger.error(LOG, "set_extra_mappings_provider(): expected a function, got %s.", type(provider))
		return false
	end
	_extra_mappings_provider = provider
	Logger.debug(LOG, "Extra mappings provider: %s.", provider and "set" or "cleared")
	return true
end

--- Sets the effective and shipped magic keys used while staging TOML mappings.
--- @param effective string User-selected key or the shipped default.
--- @param canonical string Shipped key embedded in canonical TOML triggers.
--- @return boolean
function M.set_magic_key(effective, canonical)
	local Terminators = require("keymap.terminators")
	if Terminators.validate_magic_key(effective) ~= true
		or Terminators.validate_magic_key(canonical) ~= true
	then
		Logger.error(LOG, "Magic-key catalogue substitution refused invalid state.")
		return false
	end
	_magic_key = effective
	_canonical_magic_key = canonical
	return true
end


-- =========================================
-- =========================================
-- ======= 5/ Loading ======================
-- =========================================
-- =========================================

--- The extension packs installed on this machine, as loader entries.
---
--- Separate from the bundled/user merge below because extensions answer a
--- different question: those two settle "which copy of a category do we load",
--- this one is "what did the user install on top". Returned in the shape
--- load_catalogue understands directly, so no caller has to know the namespacing
--- rule that keeps a third party's `rolls.toml` from displacing the bundled one.
--- @return table Array of { path, category, extension }.
function M.extension_packs()
	if type(Paths.extension_roots) ~= "function" then return {} end

	local found = Extensions.scan(Paths.extension_roots(), {
		list_dirs  = Loader.list_subdirs,
		list_files = Loader.find_toml_files,
		read_file  = Loader.read_file,
	})

	local entries = {}
	for _, extension in ipairs(found) do
		for _, pack in ipairs(extension.toml_files) do
			entries[#entries + 1] = {
				path      = pack.path,
				category  = Extensions.category_key(extension.id, pack.stem),
				extension = { id = extension.id, name = extension.name },
			}
		end
	end
	if #entries > 0 then
		Logger.info(LOG, "Extensions: %d pack(s) from %d extension(s).", #entries, #found)
	end
	return entries
end

--- The TOML files to load: the bundled packs, overlaid with the user's.
---
--- Merged rather than exclusive. Choosing ONE directory meant that creating a
--- single personal file hid all five shared categories, which is not a
--- configuration anybody would ask for. Overlaid by file STEM because that is
--- what a category is: a same-stem file in the user's directory is an explicit
--- override, not a second category with the same name. The standalone installer
--- no longer seeds those files; its one-time migration retires only copies that
--- are byte-identical to the previously installed canonical bundle.
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

	-- Extension packs come last and are NOT keyed by stem: they carry their own
	-- namespaced category key so a third party shipping `rolls.toml` cannot
	-- replace the bundled category of that name. Appended rather than merged for
	-- the same reason — an extension adds categories, it never substitutes one.
	for _, entry in ipairs(M.extension_packs()) do
		paths[#paths + 1] = entry
	end

	return paths
end

function M.load_all()
	if not _engine then
		Logger.error(LOG, "load_all(): engine not initialised.")
		return 0
	end

	_toml_paths = resolve_paths()

	-- An empty catalogue is not an empty load. This used to return here, which
	-- meant a machine whose hotstring TOMLs were missing or unreadable also lost
	-- the prefix expansions built from personal_info.toml — two unrelated files,
	-- one of which was punishing the other.
	if #_toml_paths == 0 then
		Logger.warn(LOG, "load_all(): no TOML files found.")
	end

	local catalogue = Loader.load_catalogue(_toml_paths, {
		magic_key = _magic_key,
		canonical_magic_key = _canonical_magic_key,
	})
	_parse_errors = tonumber(catalogue.errors) or 0
	if catalogue.committed ~= true then
		Logger.error(LOG,
			"Catalogue reload refused: %d source(s) failed without a healthy snapshot; keeping %d mapping(s).",
			_parse_errors, #_mappings)
		return #_mappings
	end
	local staged_mappings = catalogue.mappings
	local staged_categories = catalogue.categories

	-- Mappings that no file describes — today, the prefix expansions built from
	-- personal_info.toml. Appended AFTER the catalogue and BEFORE the filter, so
	-- the disable set and the dedup pass treat them exactly like any other
	-- mapping: a user who switches the dynamic category off loses these too, which
	-- is what the category claims to control.
	if _extra_mappings_provider then
		local ok, extra = pcall(_extra_mappings_provider)
		if not ok then
			Logger.error(LOG, "The extra mappings provider raised — those mappings are absent: %s.",
				tostring(extra))
		elseif type(extra) == "table" then
			for _, mapping in ipairs(extra) do
				staged_mappings[#staged_mappings + 1] = mapping
			end
			Logger.debug(LOG, "Appended %d mapping(s) from the provider.", #extra)
		end
	end

	-- Filter what the user switched off, at either level. A section is checked
	-- separately from its category so re-enabling a category restores exactly the
	-- sections it had rather than all of them.
	local filtered = {}
	for _, m in ipairs(staged_mappings) do
		local off = _disabled_groups[m.group]
			or (m.section and _disabled_groups[m.group .. "." .. m.section])
		if not off then
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
			-- A private mapping's trigger is a fragment of its own secret — the
			-- first six characters of the IBAN — so it cannot be named even while
			-- explaining why it was dropped.
			if m.is_private then
				Logger.warn(LOG, "Duplicate trigger in a private mapping skipped (content withheld).")
			else
				Logger.warn(LOG, "Duplicate trigger '%s' skipped.", m.trigger)
			end
		else
			triggers[m.trigger] = true
			deduped[#deduped + 1] = m
		end
	end
	if dupes > 0 then Logger.warn(LOG, "%d duplicate(s) skipped.", dupes) end

	_engine:load_mappings(deduped)
	_mappings = staged_mappings
	_categories = staged_categories

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
-- ======= 6/ Category Management ==========
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
	-- Section keys are left alone on purpose: disabling everything and enabling
	-- it again should give the user back the sections they had chosen, not reset
	-- their per-section choices as a side effect.
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

--- The storage key for one section's enable state.
---
--- Sections live in the same set as categories, keyed "category.section". One
--- namespace rather than two, because a category and a section are both just
--- "something the user switched off" and a second set would need its own
--- persistence, its own reload and its own reset.
--- @param category string
--- @param section string
--- @return string
local function section_key(category, section)
	return category .. "." .. section
end

--- Whether one section of a category is active.
---
--- A section inside a disabled category reports disabled regardless of its own
--- state: the menu greys it, and a user who re-enables the category gets back
--- exactly the sections they had, rather than all of them.
--- @param category string
--- @param section string
--- @return boolean
function M.is_section_enabled(category, section)
	if _disabled_groups[category] then return false end
	return not _disabled_groups[section_key(category, section)]
end

--- Whether the user has this section TICKED, regardless of its category's gate.
---
--- Two different questions live behind one answer above, and conflating them
--- cost the menu real information: a category switched off made every one of its
--- sections read as disabled, so the menu unticked them all at once and the user
--- could no longer see which ones would come back. Their choices were never lost
--- — they are still stored — but the screen said otherwise, which looks exactly
--- like a reset.
---
--- `is_section_enabled` stays the EFFECTIVE answer and is what the loader filters
--- on. This one is what a checkbox should show. macOS keeps them separate for the
--- same reason and feeds them to `checked` and `disabled` independently.
--- @param category string
--- @param section string
--- @return boolean
function M.is_section_checked(category, section)
	return not _disabled_groups[section_key(category, section)]
end

--- How many hotstrings a category is ACTUALLY firing right now.
---
--- Not the same as the number it holds. A user reads the figure beside a category
--- as "what this is doing"; switch the category off, or untick half its sections,
--- and the number must fall — that is how they check a disable took effect, which
--- is the main reason to look at it. It never moved, so a fully disabled
--- Autocorrection went on advertising 14 231 entries.
---
--- Windows encodes the same rule in hotstring_count_policy.ahk: a disabled scope
--- shows no active hotstrings, not the count it would have if re-enabled.
--- @param category string
--- @return integer
function M.active_count(category)
	local cat = _categories[category]
	if not cat then return 0 end
	if _disabled_groups[category] then return 0 end

	-- A category with no declared sections cannot be counted section by section;
	-- its gate is the only switch it has, and the gate is on.
	local order = cat.sections_order or {}
	if #order == 0 then return cat.count or 0 end

	local total = 0
	for _, name in ipairs(order) do
		if M.is_section_checked(category, name) then
			local section = (cat.sections or {})[name]
			total = total + ((section and section.count) or 0)
		end
	end
	return total
end

--- Flips one section.
--- @param category string
--- @param section string
function M.toggle_section(category, section)
	if type(category) ~= "string" or type(section) ~= "string" then return end
	local key = section_key(category, section)
	if _disabled_groups[key] then
		_disabled_groups[key] = nil
	else
		_disabled_groups[key] = true
	end
	save_disabled()
	M.load_all()
	notify_change()
end

--- Sets every section of a category at once.
--- @param category string
--- @param enabled boolean
function M.set_all_sections(category, enabled)
	local cat = _categories[category]
	if not cat then return end
	-- Enabling lifts the category gate too. Without this the row could set every
	-- section on and change nothing visible, because the gate above them was
	-- still shut — and the user had to find and click a second control to make
	-- the first one mean anything. Both reference drivers lift it here.
	if enabled then _disabled_groups[category] = nil end
	for name in pairs(cat.sections or {}) do
		local key = section_key(category, name)
		if enabled then
			_disabled_groups[key] = nil
		else
			_disabled_groups[key] = true
		end
	end
	save_disabled()
	M.load_all()
	notify_change()
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
-- ======= 7/ Queries ======================
-- =========================================
-- =========================================

function M.mapping_count() return #_mappings end
function M.parse_error_count() return _parse_errors end
function M.get_config_dir() return _config_dir end

return M
