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
--- Category and section choices are canonical config.toml preferences,
--- `hotstrings.groups.<group>` and `hotstrings.modules.<group>.<section>`, read
--- through the manifest's neutral defaults. Fresh independently admitted personal
--- sources start enabled; known historical owners retain their explicit choices
--- and historical missing-group false. A choice reaches the engine before it is
--- written. Refused personal choices restore the exact prior runtime image and
--- retain their lease until its native inverse is acknowledged.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ConfigOutdated = require("config_outdated")
local Loader = require("modules.hotstrings.loader")
local Shell = require("adapters.shell_runner")
local Writer = require("toml_codec.writer")
local LeafRows = require("toml_codec.leaf_rows")
local DelayResolver = require("hotstrings.delay_resolver")
local Priority = require("hotstring_priority")
local Extensions = require("hotstrings.extensions")
local ConfigPaths = require("infra.config_paths")
local Paths = require("infra.paths")
local TomlReader = require("toml_codec.reader")
local TomlCodec = require("toml_codec")
local KeyPath = require("toml_codec.key_path")
local Languages = require("hotstrings.languages")
local BulkScope = require("hotstrings.bulk_scope")
local PersonalFiles = require("hotstrings.personal_files")
local PersonalAdoption = require("infra.personal_file_adoption")
local ManifestReader = require("infra.manifest_reader")

local LOG = "modules.hotstrings.hotstrings_config"
local _personal_sources = {}
local _personal_adoptions = {}

--- Finds only a source explicitly admitted by the current native catalogue.
--- @param id string
--- @param inventory table|nil
--- @return table|nil record
local function personal_adoption(id, inventory)
	for _, record in ipairs(inventory or _personal_adoptions) do
		if record.owner == id then return record end
	end
end

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
-- Set once a catalogue has been published: before that, `_categories` is the
-- empty table a refused or failed load leaves, which proves nothing retired.
local _published      = false
local _parse_errors   = 0
local _magic_key      = nil
local _canonical_magic_key = nil
local _override_config_dir = nil

--- Explicit canonical category and section choices, as config.toml holds
--- them: { groups = { [id] = boolean }, modules = { [id] = { [section] = boolean } } }.
--- nil until init() has read them, and after a read that did not commit.
local _choices = nil

--- The transaction that owns hotstring configuration while it is set; ordinary
--- setters are refused until it releases, so they cannot interleave its inverse.
local _scope_owner = nil
local _scope_owner_epoch = 0
local _personal_transaction_owner, _prepared_personal_sources, _personal_debt
local _personal_gate_debt
local restore_personal_runtime
local _live_mappings = {}

--- Test seam: the canonical configuration file, nil for the XDG location.
local _config_file = nil

--- Called after any change that alters what the menu should show. Set by the
--- daemon; nil in the harness, where nothing is drawn.
local _on_change = nil

--- Supplies mappings that no TOML file describes. See set_extra_mappings_provider.
local _extra_mappings_provider = nil

--- Fires the menu-rebuild callback, if the daemon supplied one.
local function notify_change()
	if _on_change then pcall(_on_change) end
end

--- The canonical configuration file the choices are read from and written to.
--- @return string
local function config_file()
	return _config_file or ConfigPaths.config("config.toml")
end

--- Copies canonical choices so a candidate never aliases the published set.
--- @param source table
--- @return table
local function copy_choices(source)
	local copy = { groups = {}, modules = {} }
	for id, value in pairs(source.groups) do copy.groups[id] = value end
	for id, sections in pairs(source.modules) do
		copy.modules[id] = {}
		for name, value in pairs(sections) do copy.modules[id][name] = value end
	end
	return copy
end

--- Extracts the explicit category and section choices of a decoded config.toml.
--- A choice of the wrong shape, written by an older build, is never guessed:
--- it is outdated configuration, left absent (the neutral value), warned about
--- once and offered by the config cleanup. Raising here turned every
--- hotstring off for the session over one entry nothing reads.
--- @param document table Decoded configuration.
--- @return table choices Explicit choices only; absence stays absent.
local function decode_choices(document)
	assert(type(document) == "table", "hotstring configuration must be a table")
	local choices = { groups = {}, modules = {} }
	local hotstrings = document.hotstrings
	if hotstrings ~= nil and type(hotstrings) ~= "table" then
		ConfigOutdated.report({ "hotstrings" }, "[hotstrings] is not a table", Logger)
		return choices
	end
	local groups = hotstrings and hotstrings.groups
	if groups ~= nil and type(groups) ~= "table" then
		ConfigOutdated.report({ "hotstrings", "groups" }, "category choices are not a table", Logger)
		groups = nil
	end
	for id, value in pairs(groups or {}) do
		if type(id) == "string" and id ~= "" and type(value) == "boolean" then
			choices.groups[id] = value
		else
			ConfigOutdated.report({ "hotstrings", "groups", tostring(id) }, "a category choice takes true or false", Logger)
		end
	end
	local modules = hotstrings and hotstrings.modules
	if modules ~= nil and type(modules) ~= "table" then
		ConfigOutdated.report({ "hotstrings", "modules" }, "section choices are not a table", Logger)
		modules = nil
	end
	for id, sections in pairs(modules or {}) do
		if type(id) == "string" and id ~= "" and type(sections) == "table" then
			choices.modules[id] = {}
			for name, value in pairs(sections) do
				if type(name) == "string" and name ~= "" and type(value) == "boolean" then
					choices.modules[id][name] = value
				else
					ConfigOutdated.report({ "hotstrings", "modules", id, tostring(name) },
						"a section choice takes true or false", Logger)
				end
			end
		else
			ConfigOutdated.report({ "hotstrings", "modules", tostring(id) }, "section choices are not a table", Logger)
		end
	end
	return choices
end

--- Whether a published category's sections are the ones this build ships. A
--- category read from the user's same-stem override holds that file's sections
--- only: a choice for a bundled section it lacks is not retired, since removing
--- the override brings the section back.
--- @param category table Published category record.
--- @return boolean
local function sections_are_the_builds(category)
	if type(_config_dir) ~= "string" or _config_dir:match("%.toml$") then return true end
	local prefix = _config_dir .. "/"
	return type(category.path) ~= "string" or category.path:sub(1, #prefix) ~= prefix
end

--- Whether one explicit choice names something the published catalogue can
--- prove retired. Nothing is retired before a catalogue was published.
--- @param id string Category id.
--- @param section string|nil Section name, for a section choice.
--- @return boolean retired
local function choice_is_retired(id, section)
	if not _published then return false end
	local category = _categories[id]
	if category == nil then return true end
	if section == nil or not sections_are_the_builds(category) then return false end
	return not (category.sections or {})[section]
end

--- Reports the choices naming a category or section this build no longer
--- ships: ignored at runtime, offered by the config cleanup.
--- @param choices table Decoded choices.
local function report_retired_choices(choices)
	for id in pairs(choices.groups) do
		if choice_is_retired(id) then
			ConfigOutdated.report({ "hotstrings", "groups", id }, "no loaded hotstring category has this id", Logger)
		end
	end
	for id, sections in pairs(choices.modules) do
		for name in pairs(sections) do
			if choice_is_retired(id, name) then
				ConfigOutdated.report({ "hotstrings", "modules", id, name }, "no loaded hotstring section has this name", Logger)
			end
		end
	end
end

--- Reads the canonical choices with the exact bytes they came from.
--- @return table choices
--- @return table source Classified source for a conditional write.
local function read_choices()
	local content, status, detail = Writer.read_classified(config_file())
	assert(status == "ok" or status == "absent", "hotstring configuration is unreadable: " .. tostring(detail))
	local document = TomlCodec.decode(content or "")
	assert(type(document) == "table", "hotstring configuration is malformed")
	return decode_choices(document), { status = status, content = content }
end

--- Whether a runtime identity can be named by a canonical key path. A file stem
--- with a dot would split into two path segments and address another key.
--- @param id string
--- @return boolean
local function addressable(id)
	return type(id) == "string" and id ~= "" and not id:find(".", 1, true)
end

--- The desired state of one category: its explicit choice, else the manifest's.
--- @param choices table Canonical choices.
--- @param id string Runtime category identity.
--- @return boolean
local function group_choice(choices, id, inventory)
	if not addressable(id) then return false end
	if PersonalFiles.components(id) then
		local record = personal_adoption(id, inventory)
		if not record then return false end
		local enabled = PersonalAdoption.preferences(record, choices)
		return enabled
	end
	local value = choices.groups[id]
	if value == nil then value = ManifestReader.default_for("hotstrings.groups." .. id) end
	return value
end

--- The desired state of one section, independent of its category's gate.
--- @param choices table Canonical choices.
--- @param id string Runtime category identity.
--- @param section string Section name.
--- @return boolean
local function section_choice(choices, id, section, inventory)
	if not addressable(id) or not (PersonalFiles.components(id) and type(section) == "string" and section ~= ""
		or addressable(section)) then return false end
	local sections = choices.modules[id]
	if PersonalFiles.components(id) then
		local record = personal_adoption(id, inventory)
		if not record or record.admitted ~= true then return false end
		local _, supplied = PersonalAdoption.preferences(record, choices)
		sections = supplied
	end
	local value = sections and sections[section]
	if value == nil then value = ManifestReader.default_for(KeyPath.render({ "hotstrings", "modules", id, section })) end
	return value
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
--- { [category] = { delay, color, show_tooltip, priority, sections = { [name] = { ... } } } }
local _overrides = {}

--- Exact classified bytes from the last acknowledged override publication.
local _override_source = { status = "error" }
local _common_override_admitted = false

--- Memoised resolutions, cleared by every writer below. The tooltip preview
--- resolves once per candidate on every keystroke, so the cascade would
--- otherwise be walked several times per key on the input path.
local _resolve_cache = {}

--- The override file's path.
--- @return string
local function override_config_dir()
	return _override_config_dir or ConfigPaths.config()
end

local function overrides_path()
	return override_config_dir() .. "/" .. OVERRIDES_FILE
end

--- Reports the override-file entries naming a category or section this build
--- no longer loads: ignored at runtime and kept by every save, they are named
--- once so the user can fix them in hotstrings_overrides.toml, the one place
--- they live (the config cleanup only covers config.toml). A single explicit
--- hotstring file loads its own categories only, so nothing is judged there.
local function report_retired_overrides()
	if type(_config_dir) == "string" and _config_dir:match("%.toml$") then return end
	for id, entry in pairs(_overrides) do
		if id ~= GLOBAL_CATEGORY and choice_is_retired(id) then
			ConfigOutdated.report_in_file(overrides_path(), { id }, "no loaded hotstring category has this id")
		elseif id ~= GLOBAL_CATEGORY then
			for name in pairs(entry.sections or {}) do
				if choice_is_retired(id, name) then
					ConfigOutdated.report_in_file(overrides_path(), { id, name },
						"no loaded hotstring section has this name")
				end
			end
		end
	end
end

--- Interprets override file bytes, raising when they are not valid TOML.
--- @param content string Exact file bytes.
--- @return table overrides { [category] = { delay, color, show_tooltip, priority, sections } }
local function parse_override_content(content)
	local parsed = TomlCodec.decode(content)
	assert(type(parsed) == "table", "the override file is not valid TOML")
	local function override_fields(values)
		return {
			delay = tonumber(values.delay),
			color = values.color,
			show_tooltip = values.show_tooltip,
			priority = tonumber(values.priority),
		}
	end
	local overrides = {}
	for category, values in pairs(parsed) do
		if type(values) == "table" then
			local entry = override_fields(values)
			entry.sections = {}
			for section, section_values in pairs(values) do
				if type(section_values) == "table" then
					entry.sections[section] = override_fields(section_values)
				end
			end
			overrides[category] = entry
		end
	end
	return overrides
end

--- Reads the override file into memory. A missing file is the normal case.
local function load_overrides()
	_overrides = {}
	_resolve_cache = {}
	_override_source = { status = "error" }
	_common_override_admitted = false

	local path = overrides_path()
	local migration = require("hotstrings.common_autocorrection_migration")
	local migrated = migration.run(path, Paths.shared(migration.POLICY_PATH))
	local content, status = migrated.content, migrated.status
	if status == "absent" then
		_override_source = { status = "absent" }
		_common_override_admitted = true
		return
	end
	local ok, parsed = pcall(parse_override_content, content)
	if (status ~= "current" and status ~= "migrated") or not ok then
		Logger.error(LOG, "Override file '%s' is unreadable or malformed — user delays and colours ignored.", path)
		return
	end
	_overrides = parsed
	_override_source = { status = "ok", content = content }
	_common_override_admitted = migrated.common_admitted ~= false
end

--- Copies the override tree for a persistence transaction.
--- @param source table
--- @return table
local function copy_overrides(source)
	local copy = {}
	for category, entry in pairs(source) do
		local cloned = {
			delay = entry.delay,
			color = entry.color,
			show_tooltip = entry.show_tooltip,
			priority = entry.priority,
			sections = {},
		}
		for section, values in pairs(entry.sections or {}) do
			cloned.sections[section] = {
				delay = values.delay,
				color = values.color,
				show_tooltip = values.show_tooltip,
				priority = values.priority,
			}
		end
		copy[category] = cloned
	end
	return copy
end

--- Writes only changed owned leaves, retaining every unknown record and comment.
--- The load checkpoint crosses both preparation and publication; a fresh disk read
--- cannot authorize replacing a foreign edit or repairing an unreadable source.
--- @param overrides table Detached candidate tree.
--- @return boolean committed
local function save_overrides(overrides)
	if _override_source.status ~= "ok" and _override_source.status ~= "absent" then return false end
	local fields = { "delay", "color", "show_tooltip", "priority" }
	local rows = {}
	local function update(segments, previous, candidate)
		previous, candidate = previous or {}, candidate or {}
		for _, field in ipairs(fields) do
			if previous[field] ~= candidate[field] then
				rows[#rows + 1] = { section = KeyPath.render(segments), key = field,
					value = candidate[field], delete = candidate[field] == nil and true or nil }
			end
		end
	end
	local categories = {}
	for category in pairs(_overrides) do categories[category] = true end
	for category in pairs(overrides) do categories[category] = true end
	for category in pairs(categories) do
		local previous, candidate = _overrides[category] or {}, overrides[category] or {}
		update({ category }, previous, candidate)
		local sections = {}
		for section in pairs(previous.sections or {}) do sections[section] = true end
		for section in pairs(candidate.sections or {}) do sections[section] = true end
		for section in pairs(sections) do
			update({ category, section }, (previous.sections or {})[section], (candidate.sections or {})[section])
		end
	end
	local path = overrides_path()
	local prepared, detail, content, source = Writer.prepare_batch(path, rows, nil, _override_source)
	if prepared ~= true then
		Logger.error(LOG, "Cannot prepare override leaves: %s.", tostring(detail))
		return false
	end
	-- An empty clear of a proven absent source acknowledges absence without
	-- creating an empty override file. Preparation already checked its source.
	if #rows == 0 and source.status == "absent" then return true end
	local config_dir = override_config_dir()
	if not Shell.run("mkdir -p " .. Shell.quote(config_dir) .. " 2>/dev/null") then
		Logger.error(LOG, "Cannot create '%s' — overrides were not changed.", config_dir)
		return false
	end
	local committed, refusal = Writer.publish_if_unchanged(path, content, nil, source)
	if committed ~= true then
		Logger.error(LOG, "Cannot publish override leaves: %s.", tostring(refusal))
		return false
	end
	_override_source = { status = "ok", content = content }
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
	local adopted = personal_adoption(category)
	if adopted and adopted.admitted and adopted.legacy_name and _overrides[category] == nil then
		user = _overrides[adopted.legacy_name] or {}
	end
	local meta = _categories[category] or {}

	local resolved = DelayResolver.resolve({
		user_category  = user,
		user_section   = section and (user.sections or {})[section] or nil,
		meta_category  = meta,
		meta_section   = section and (meta.sections or {})[section] or nil,
		default_delay  = PersonalFiles.components(category) and PersonalFiles.additional_default_delay_seconds
			or M.get_global_delay(),
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
--- @param field string "delay" | "color" | "show_tooltip" | "priority"
--- @param value any nil clears the field.
--- @return boolean
function M.set_override(category, section, field, value)
	if type(category) ~= "string" or category == "" then return false end
	if PersonalFiles.components(category) then return M.set_personal_metadata(category, section, field, value) end
	-- A pending scope restores the override file only while it still holds the
	-- scope's candidate bytes; a rewrite here would strand that inverse for good.
	if _scope_owner ~= nil then
		Logger.error(LOG, "set_override() refused: a hotstring configuration scope is still pending.")
		return false
	end
	-- "priority" was missing until 2026-08-05. The settings window has a priority
	-- field per category and per section, the bridge forwards it, and this guard
	-- rejected it — so the control wrote an ERROR to the log and nothing else. The
	-- window gave no sign, because the bridge answered with a refreshed payload
	-- either way.
	if field ~= "delay" and field ~= "color" and field ~= "show_tooltip" and field ~= "priority" then
		Logger.error(LOG, "set_override(): '%s' is not an overridable field.", tostring(field))
		return false
	end

	local candidate = copy_overrides(_overrides)
	local entry = candidate[category] or { sections = {} }
	entry.sections = entry.sections or {}
	local target = entry
	if section then
		entry.sections[section] = entry.sections[section] or {}
		target = entry.sections[section]
	end
	target[field] = value
	candidate[category] = entry

	if not save_overrides(candidate) then return false end
	_overrides = candidate
	_resolve_cache = {}
	if field == "priority" and _engine then M.load_all() end
	notify_change()
	return true
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
	local candidate = copy_overrides(_overrides)
	local entry = candidate[category]
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
	if PersonalFiles.components(category) then
		if field == nil then return false end
		return M.set_personal_metadata(category, section, field, nil)
	end
	if _scope_owner ~= nil then
		Logger.error(LOG, "clear_override() refused: a hotstring configuration scope is still pending.")
		return false
	end
	local candidate = copy_overrides(_overrides)
	local entry = candidate[category]
	if not entry then return save_overrides(candidate) end

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
		candidate[category] = nil
	end

	if not save_overrides(candidate) then return false end
	_overrides = candidate
	_resolve_cache = {}
	if (field == nil or field == "priority") and _engine then M.load_all() end
	notify_change()
	return true
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

--- Routes override persistence to an isolated directory in behavioral tests.
--- @param path string|nil Absolute directory, or nil to restore production routing.
--- @return boolean
function M._set_override_config_dir_for_test(path)
	if path ~= nil and (type(path) ~= "string" or path:sub(1, 1) ~= "/") then return false end
	_override_config_dir = path
	return true
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
	if _scope_owner ~= nil then return false end
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
	_scope_owner = nil
	_personal_transaction_owner, _prepared_personal_sources, _personal_debt = nil, nil, nil
	_personal_gate_debt = nil
	_live_mappings = {}
	load_overrides()
	local read, choices = pcall(read_choices)
	if not read then
		-- Every catalogue stays off: a choice that cannot be read is never guessed.
		_choices = nil
		Logger.error(LOG, "Hotstring choices are unreadable; no catalogue will be published: %s.", tostring(choices))
		return false
	end
	_choices = choices
	Logger.info(LOG, "Config manager initialised (dir=%s).", _config_dir or "(bundled)")
	return true
end

--- Test seam: routes the canonical choices to an isolated configuration file.
--- @param path string|nil Absolute file path, or nil to restore production routing.
--- @return boolean
function M._set_config_file_for_test(path)
	if path ~= nil and (type(path) ~= "string" or path:sub(1, 1) ~= "/") then return false end
	_config_file = path
	return true
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

--- The extensions installed on this machine, as the shared scanner reports them.
--- A root or pack the scanner refuses is logged and left out, so one broken
--- third-party folder never costs the reload every other hotstring.
--- @return table Array of extension records (toml_files, bound_files, …).
function M.discover_extensions()
	if type(Paths.extension_roots) ~= "function" then return {} end
	return Extensions.scan(Paths.extension_roots(), {
		list_dirs  = Loader.list_subdirs,
		list_files = Loader.find_toml_files,
		read_file  = Loader.read_file,
		on_error   = function(where, err)
			Logger.error(LOG, "Extension %s is left out: %s.",
				tostring(where.path or (where.id and ("'" .. where.id .. "'")) or where.root), tostring(err))
		end,
	})
end

--- The extension packs installed on this machine, as loader entries.
---
--- Separate from the bundled/user merge below because extensions answer a
--- different question: those two settle "which copy of a category do we load",
--- this one is "what did the user install on top". Returned in the shape
--- load_catalogue understands directly, so no caller has to know the namespacing
--- rule that keeps a third party's `rolls.toml` from displacing the bundled one.
--- @param found table|nil Records from discover_extensions(); discovered when nil.
--- @return table Array of { path, category, extension }.
function M.extension_packs(found)
	found = found or M.discover_extensions()

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

--- The sections of a list that a set leaves out, in list order.
--- @param list table Section names.
--- @param set table Set of section names to leave out.
--- @return table
local function sections_without(list, set)
	local out = {}
	for _, name in ipairs(list) do
		if not set[name] then out[#out + 1] = name end
	end
	return out
end

--- The bound sections a user's copy of a category declares itself.
--- An unreadable copy declares none: the loader reports the file, and the
--- extension keeps supplying its sections.
--- @param path string The user's file.
--- @param sections table Section names an extension binds in that category.
--- @return table Set of the sections the file declares.
local function carried_sections(path, sections)
	local carried = {}
	local ok, data, committed = pcall(TomlReader.parse, path)
	if not ok or committed ~= true or type(data) ~= "table" or type(data.sections) ~= "table" then
		return carried
	end
	for _, name in ipairs(sections) do
		if data.sections[name] ~= nil then carried[name] = true end
	end
	return carried
end

--- Routes the bundled categories an extension binds to the files it ships.
---
--- A whole-category binding replaces the bundled file; a section binding loads
--- those sections from the extension file and every other section, and the
--- category's metadata, from the bundled one. The rules keep their category and
--- common source tier, so existing preferences still address them. Every bound
--- source is resolved through the shared owner, which refuses two owners.
---
--- The user's own copy of a category (resolve_paths overlays it on the bundled
--- one) is an explicit override and keeps what it carries: the whole category,
--- or each bound section it declares itself. An extension binding replaces the
--- bundled file, never the user's.
--- @param paths table Loader sources: paths, or { path, category, … } tables.
--- @param found table Records from discover_extensions().
--- @param user_paths table|nil Set of the source paths the user's folder supplies.
--- @return table The sources with the bound files routed in.
function M.route_bound_sources(paths, found, user_paths)
	user_paths = user_paths or {}
	local bound_sections, section_files, whole, whole_order, owners = {}, {}, {}, {}, {}
	for _, extension in ipairs(found) do
		for _, file in ipairs(extension.bound_files or {}) do
			local binding = file.binding
			if binding.sections == nil then
				whole[binding.category] = Extensions.bound_source(found, binding.category)
				whole_order[#whole_order + 1] = binding.category
				-- The category record names the extension that supplies it, so the
				-- menu lists it under that extension's own submenu.
				owners[binding.category] = { id = extension.id, name = extension.name }
			else
				for _, section in ipairs(binding.sections) do
					Extensions.bound_source(found, binding.category, section)
					local skipped = bound_sections[binding.category] or {}
					skipped[#skipped + 1] = section
					bound_sections[binding.category] = skipped
				end
				section_files[#section_files + 1] = {
					path = file.path, category = binding.category, only_sections = binding.sections,
					extension = { id = extension.id, name = extension.name },
				}
			end
		end
	end

	local routed, placed, kept = {}, {}, {}
	for _, source in ipairs(paths) do
		local path = type(source) == "table" and source.path or source
		local category = type(source) == "table" and source.category or path:match("([^/\\]+)%.toml$")
		local user = user_paths[path] == true
		if whole[category] and user then
			Logger.info(LOG, "Extensions: the user's copy of '%s' overrides the file extension '%s' binds.",
				category, owners[category].id)
			routed[#routed + 1] = { path = path, category = category, extension = owners[category] }
		elseif whole[category] then
			routed[#routed + 1] = { path = whole[category], category = category, extension = owners[category] }
		elseif bound_sections[category] then
			local entry = type(source) == "table" and source or { path = path }
			local skipped = bound_sections[category]
			if user then
				kept[category] = carried_sections(path, skipped)
				skipped = sections_without(skipped, kept[category])
				if #skipped < #bound_sections[category] then
					Logger.info(LOG, "Extensions: the user's copy of '%s' keeps its own bound section(s).", category)
				end
			end
			routed[#routed + 1] = {
				path = entry.path, category = category, extension = entry.extension,
				skip_sections = skipped,
			}
		else
			routed[#routed + 1] = source
		end
		placed[category] = true
	end
	-- A category the bundled catalogue no longer carries is still the file's.
	for _, category in ipairs(whole_order) do
		if not placed[category] then
			routed[#routed + 1] = { path = whole[category], category = category, extension = owners[category] }
		end
	end
	-- After the bundled files, so the category record starts from their metadata.
	-- A section the user's copy declares itself is not loaded a second time.
	for _, entry in ipairs(section_files) do
		local carried = kept[entry.category]
		local only = carried and sections_without(entry.only_sections, carried) or entry.only_sections
		if #only == #entry.only_sections then
			routed[#routed + 1] = entry
		elseif #only > 0 then
			routed[#routed + 1] = {
				path = entry.path, category = entry.category, only_sections = only, extension = entry.extension,
			}
		end
	end
	if next(whole) or #section_files > 0 then
		Logger.info(LOG, "Extensions: routed %d section file(s) into bundled categories.", #section_files)
	end
	return routed
end

--- The language packs declared by the shared hotstring index, read once.
--- An unreadable index raises: loading without it would drop every language.
--- @return table Array of { id, locale, categories }.
local _language_packs = nil
function M.language_packs()
	if _language_packs then return _language_packs end
	local path = Paths.shared("modules/hotstrings/_index.toml")
	local fh = io.open(path, "r")
	if not fh then error("[hotstrings_config] hotstring index is unreadable: " .. tostring(path)) end
	local raw = fh:read("*a")
	fh:close()
	_language_packs = Languages.packs(TomlCodec.decode(raw))
	return _language_packs
end

--- Whether a scanned path sits inside a declared language folder of `root`.
--- @param path string
--- @param root string
--- @return boolean
local function in_language_folder(path, root)
	for _, pack in ipairs(M.language_packs()) do
		local prefix = root .. "/" .. pack.id .. "/"
		if path:sub(1, #prefix) == prefix then return true end
	end
	return false
end

--- The TOML files to load: the bundled packs, overlaid with the user's.
---
--- Merged rather than exclusive. Choosing ONE directory meant that creating a
--- single personal file hid all five shared categories, which is not a
--- configuration anybody would ask for. Overlaid by file STEM because that is
--- what a category is: a same-stem file in the user's directory is an explicit
--- override, not a second category with the same name. The standalone installer
--- no longer seeds those files; its one-time migration retires only copies that
--- are byte-identical to the previously installed canonical bundle. The user's
--- copies stay overrides when an extension binds their category, so they are
--- handed to route_bound_sources by path. Independently owned additional files
--- use exact descriptor identities instead of overlaying another personal stem.
--- @return table Array of absolute paths.
local function resolve_paths()
	local by_stem, order, user_paths = {}, {}, {}
	local shipped_stems, additional = {}, {}
	local personal_sources, descriptors_by_path = {}, {}
	local function discover_personal(path, root)
		local relative = path:sub(#root + 1):gsub("^/+", "")
		local components = {}
		for component in relative:gmatch("[^/]+") do components[#components + 1] = component end
		if #components == 1 and components[1] == "personal_hotstrings.toml" then return end
		local descriptor = PersonalFiles.describe(components)
		descriptors_by_path[path] = descriptor
		personal_sources[#personal_sources + 1] = { path = path, descriptor = PersonalFiles.copy(descriptor) }
	end

	--- @param path string
	local function add(path)
		local stem = path:match("([^/\\]+)%.toml$")
		if not stem then return end
		if not by_stem[stem] then order[#order + 1] = stem end
		by_stem[stem] = path
	end

	-- A user-selected physical file stays exact. Selecting the actual shipped
	-- file names its logical category, including sections supplied by its bound
	-- extension; loading only its common fragment would lose the native controls.
	if _config_dir and _config_dir:match("%.toml$") then
		local category = _config_dir:match("([^/\\]+)%.toml$")
		local canonical = category and Paths.shared("modules/hotstrings/" .. category .. ".toml")
		if canonical and type(Loader.same_file) == "function" and Loader.same_file(_config_dir, canonical) then
			local found = Extensions.category_bindings(M.discover_extensions(), category)
			return M.route_bound_sources({ _config_dir }, found), personal_sources
		end
		local root = _config_dir:match("^(.*)/[^/]+$") or ""
		discover_personal(_config_dir, root)
		local descriptor = descriptors_by_path[_config_dir]
		return { descriptor and { path = _config_dir, personal_source = descriptor } or _config_dir }, personal_sources
	end

	local ok_paths, Paths = pcall(require, "infra.paths")
	local bundled = ok_paths and Paths.shared("modules/hotstrings") or nil
	-- Language folders are not overlaid by stem: french/autocorrection.toml is
	-- its own group, not a second copy of the neutral autocorrection.toml.
	if bundled then
		for _, path in ipairs(Loader.find_toml_files(bundled)) do
			if not in_language_folder(path, bundled) then
				add(path)
				local stem = path:match("([^/\\]+)%.toml$")
				if stem then shipped_stems[stem] = true end
			end
		end
	end

	-- Bound files keep their historical category identity even when the shared
	-- folder no longer carries them. Use one discovery receipt for classification
	-- and routing so the user's same-category copy remains its explicit override.
	local found = M.discover_extensions()
	for _, extension in ipairs(found) do
		for _, file in ipairs(extension.bound_files or {}) do
			shipped_stems[file.binding.category] = true
		end
	end

	-- Second, so the user's copy of a category replaces the bundled one.
	if _config_dir then
		for _, path in ipairs(Loader.find_toml_files(_config_dir, PersonalFiles.additional_scan_max_depth)) do
			if not in_language_folder(path, _config_dir) then
				discover_personal(path, _config_dir:gsub("/+$", ""))
				local stem = path:match("([^/\\]+)%.toml$")
				if shipped_stems[stem] or not descriptors_by_path[path] then
					add(path)
				else
					additional[#additional + 1] = { path = path, category = descriptors_by_path[path].id }
				end
				user_paths[path] = true
			end
		end
	end

	local paths = {}
	for _, stem in ipairs(order) do paths[#paths + 1] = by_stem[stem] end
	for _, source in ipairs(additional) do paths[#paths + 1] = source end

	-- Language packs, each under its group id "<language>_<stem>". The user's copy
	-- in the same sub-folder replaces the bundled one, as for the neutral packs.
	if bundled then
		for _, pack in ipairs(M.language_packs()) do
			for _, stem in ipairs(pack.categories) do
				local rel = "/" .. pack.id .. "/" .. stem .. ".toml"
				local path = bundled .. rel
				if _config_dir then
					local fh = io.open(_config_dir .. rel, "r")
					if fh then
						fh:close()
						path = _config_dir .. rel
						user_paths[path] = true
					end
				end
				paths[#paths + 1] = { path = path, category = Languages.group_id(pack.id, stem) }
			end
		end
	end

	-- Extension packs come last and are NOT keyed by stem: they carry their own
	-- namespaced category key so a third party shipping `rolls.toml` cannot
	-- replace the bundled category of that name. Appended rather than merged for
	-- the same reason — an extension adds categories, it never substitutes one.
	paths = M.route_bound_sources(paths, found, user_paths)
	for _, entry in ipairs(M.extension_packs(found)) do
		paths[#paths + 1] = entry
	end

	for position, source in ipairs(paths) do
		local path = type(source) == "table" and source.path or source
		local descriptor = descriptors_by_path[path]
		if descriptor then
			local owned = {}
			if type(source) == "table" then
				for key, value in pairs(source) do owned[key] = value end
			else
				owned.path = source
			end
			owned.personal_source = PersonalFiles.copy(descriptor)
			paths[position] = owned
		end
	end
	local records, represented = {}, {}
	for _, source in ipairs(paths) do
		local path = type(source) == "table" and source.path or source
		if type(source) == "table" and source.category and PersonalFiles.components(source.category) then
			represented[path] = true
		end
	end
	for _, source in ipairs(personal_sources) do
		local legacy = source.path:match("([^/\\]+)%.toml$")
		records[#records + 1] = { source = source.descriptor, path = source.path,
			legacy_name = legacy, legacy_stored = _overrides[legacy] ~= nil }
	end
	if #records == 0 then return paths, personal_sources, {} end
	local inventory, refusal = PersonalAdoption.stage(records, _choices,
		_config_dir:gsub("/+$", "") .. "/personal_hotstrings.toml")
	assert(inventory, "personal source adoption refused: " .. tostring(refusal))
	for _, record in ipairs(inventory) do
		if not represented[record.path] then
			record.admitted, record.exclusive, record.reason = false, false, "unavailable-owner"
		end
	end
	return paths, personal_sources, inventory
end

--- Loads one complete catalogue and reports whether runtime publication succeeded.
--- @return number Retained or newly accepted mapping count.
--- @return boolean True only after the engine acknowledges publication.
--- @param personal_owner any Reserved native publication owner slot.
--- @param cold_boot boolean|nil Explicit partial registration mode for the sole startup caller.
--- @return string|nil Refusal reason.
--- @return table|nil Classified receipt only after native publication.
function M.load_all(personal_owner, cold_boot)
	if _personal_transaction_owner and personal_owner ~= _personal_transaction_owner then
		return #_mappings, false, "personal-source-pending"
	end
	if not _engine then
		Logger.error(LOG, "load_all(): engine not initialised.")
		return 0, false, "engine-not-initialized"
	end
	local choices = _choices
	if not choices then
		Logger.error(LOG, "load_all(): hotstring choices are unavailable; the catalogue was not published.")
		return #_mappings, false, "choices-unavailable"
	end
	local common_requested = group_choice(choices, "autocorrection") == true
		and (section_choice(choices, "autocorrection", "names") == true
			or section_choice(choices, "autocorrection", "abbreviations") == true
			or section_choice(choices, "autocorrection", "technical_terms") == true)
	local common_unavailable = not _common_override_admitted and common_requested
	if common_unavailable and cold_boot ~= true then
		Logger.error(LOG, "Common autocorrection override migration is unacknowledged; the catalogue was not published.")
		return #_mappings, false, "common-autocorrection-overrides-unadmitted"
	end

	local staged_paths, staged_personal_sources, staged_personal_adoptions = resolve_paths()
	if common_unavailable then
		local admitted_paths = {}
		for _, source in ipairs(staged_paths) do
			local path = type(source) == "table" and source.path or source
			local category = type(source) == "table" and source.category or nil
			category = category or (type(path) == "string" and path:match("([^/\\]+)%.toml$"))
			if category ~= "autocorrection" then admitted_paths[#admitted_paths + 1] = source end
		end
		staged_paths = admitted_paths
	end

	-- An empty catalogue is not an empty load. This used to return here, which
	-- meant a machine whose hotstring TOMLs were missing or unreadable also lost
	-- the prefix expansions built from personal_info.toml — two unrelated files,
	-- one of which was punishing the other.
	if #staged_paths == 0 then
		Logger.warn(LOG, "load_all(): no TOML files found.")
	end

	local catalogue = Loader.load_catalogue(staged_paths, {
		magic_key = _magic_key,
		canonical_magic_key = _canonical_magic_key,
	}, _prepared_personal_sources)
	_parse_errors = tonumber(catalogue.errors) or 0
	if catalogue.committed ~= true then
		Logger.error(LOG,
			"Catalogue reload refused: %d source(s) failed without a healthy snapshot; keeping %d mapping(s).",
			_parse_errors, #_mappings)
		return #_mappings, false, "catalogue-not-committed"
	end
	local staged_mappings = catalogue.mappings
	local staged_categories = catalogue.categories
	local catalogue_count = #staged_mappings

	-- Mappings that no file describes — today, the prefix expansions built from
	-- personal_info.toml. Appended AFTER the catalogue so the priority pass treats
	-- them like any other mapping. Their provider has already applied its own
	-- switches (the dynamic master and each prefix family), which the menu offers;
	-- the catalogue choices below never gate them a second time.
	if _extra_mappings_provider then
		local ok, extra = pcall(_extra_mappings_provider)
		if not ok then
			Logger.error(LOG, "The extra mappings provider refused the catalogue: %s.",
				tostring(extra))
			return #_mappings, false, tostring(extra)
		elseif type(extra) == "table" then
			for _, mapping in ipairs(extra) do
				staged_mappings[#staged_mappings + 1] = mapping
			end
			Logger.debug(LOG, "Appended %d mapping(s) from the provider.", #extra)
		else
			Logger.error(LOG, "The extra mappings provider must return a table.")
			return #_mappings, false, "invalid-extra-mappings"
		end
	end

	-- Re-resolve catalogue priorities after loading the user's override file. The
	-- loader owns the per-entry rung; this manager owns user category and section
	-- rungs, so an edit can take effect without rewriting the source pack.
	for _, mapping in ipairs(staged_mappings) do
		if mapping._catalogue_priority == true then
			local user = _overrides[mapping.group] or {}
			local record = personal_adoption(mapping.group, staged_personal_adoptions)
			if record and record.admitted and record.legacy_name and _overrides[mapping.group] == nil then
				user = _overrides[record.legacy_name] or {}
			end
			local meta = staged_categories[mapping.group] or {}
			local user_section = mapping.section and (user.sections or {})[mapping.section] or nil
			local meta_section = mapping.section and (meta.sections or {})[mapping.section] or nil
			local override_priority = type(user_section) == "table" and user_section.priority or nil
				or user.priority
				or type(meta_section) == "table" and meta_section.priority or nil
				or meta.priority
			mapping.priority = Priority.resolve(
				mapping._declared_priority, override_priority, nil, mapping.group)
		elseif type(mapping.priority) ~= "number" then
			mapping.priority = Priority.source_priority(mapping.group)
		end
	end

	-- Keep what the canonical choices switch on, at both levels. A section is
	-- chosen separately from its category so re-enabling a category restores
	-- exactly the sections it had rather than all of them. Resolved once per
	-- identity: the corpus holds tens of thousands of mappings.
	local filtered, groups_on, sections_on, unaddressable = {}, {}, {}, {}
	for index, m in ipairs(staged_mappings) do
		local keep = index > catalogue_count
		if not keep and type(m.group) == "string" then
			keep = groups_on[m.group]
			if keep == nil then
				keep = group_choice(choices, m.group, staged_personal_adoptions)
				groups_on[m.group] = keep
				if not addressable(m.group) then unaddressable[m.group] = true end
			end
			if keep and m.section then
				local key = m.group .. "\0" .. m.section
				local checked = sections_on[key]
				if checked == nil then
					checked = section_choice(choices, m.group, m.section, staged_personal_adoptions)
					sections_on[key] = checked
				end
				keep = checked
			end
		end
		if common_unavailable and m.group == "autocorrection" then keep = false end
		if keep then filtered[#filtered + 1] = m end
	end
	for id in pairs(unaddressable) do
		Logger.error(LOG, "Category '%s' has no canonical configuration key and stays off; rename its file.", id)
	end

	-- Exact-trigger collisions are intentional engine input: equal-length
	-- candidates are ordered by effective priority, then registration order.
	local ok, committed = pcall(_engine.load_mappings, _engine, filtered)
	if not ok or committed ~= true then
		local reason = ok and "engine-publication-refused" or tostring(committed)
		Logger.error(LOG, "Catalogue publication refused: %s.", reason)
		return #_mappings, false, reason
	end
	_toml_paths = staged_paths
	_personal_sources = staged_personal_sources
	_personal_adoptions = staged_personal_adoptions or {}
	_mappings = staged_mappings
	_live_mappings = filtered
	_categories = staged_categories
	_published = true
	_resolve_cache = {}
	report_retired_choices(choices)
	report_retired_overrides()

	if common_unavailable then
		Logger.warn(LOG, "Common autocorrection is unavailable; loaded %d unrelated mapping(s).", #filtered)
	else
		Logger.success(LOG, "Loaded %d mapping(s) (%d categories, %d parse errors).",
			#filtered, _count_groups(filtered), _parse_errors)
	end
	return #filtered, true, nil, { committed = true, complete = not common_unavailable,
		unavailable = common_unavailable and { "autocorrection" } or {} }
end

function M.reload()
	Logger.info(LOG, "Reload requested — re-scanning…")
	return M.load_all()
end


-- =========================================
-- =========================================
-- ======= 6/ Category Management ==========
-- =========================================

local function engine_generation(engine)
	if type(engine) ~= "table" or type(engine.mapping_state) ~= "function" then return nil end
	local ok, state = pcall(engine.mapping_state, engine)
	local value = ok and type(state) == "table" and state.generation
	if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then return nil end
	return value
end

--- Settles only the exact candidate engine image owned by a refused gate edit.
--- Foreign runtime generations keep the lease closed rather than being replaced.
--- @return boolean restored
function M.retry_personal_gate_cleanup()
	local debt = _personal_gate_debt
	if not debt then return true end
	if _scope_owner ~= debt.owner or _personal_transaction_owner ~= debt.owner
		or _engine ~= debt.engine then return false end
	if not debt.restored then
		if engine_generation(_engine) ~= debt.generation or _live_mappings ~= debt.live then return false end
		if restore_personal_runtime(debt.snapshot) ~= true then return false end
		_choices = debt.snapshot.choices
		debt.restored = true
	end
	if M.release(debt.owner) ~= true then return false end
	_personal_transaction_owner, _personal_gate_debt = nil, nil
	return true
end
-- =========================================

--- Publishes candidate choices to the engine, then to config.toml.
---
--- The engine goes first so a catalogue it refuses never reaches the file. A
--- refused write republishes the previous choices, so the menu, the file and
--- the typing path keep agreeing. Each choice is sparse: a value equal to the
--- manifest's neutral default removes the key instead of repeating it.
--- @param changes table Dense array of `{ group, section|nil, enabled }`.
--- @param label string What asked, for the log.
--- @return boolean committed
--- @return string|nil reason Refusal reason.
local function commit_choices(changes, label)
	if M.retry_personal_gate_cleanup() ~= true then return false, "personal-gate-inverse-pending" end
	if _scope_owner ~= nil then
		Logger.error(LOG, "%s refused: a hotstring configuration scope is still pending.", label)
		return false, "scope-pending"
	end
	if not _engine then
		Logger.error(LOG, "%s refused: engine not initialised.", label)
		return false, "engine-not-initialized"
	end
	local canonical = false
	for _, change in ipairs(changes) do
		if PersonalFiles.components(change.group) then
			canonical = true
			local binding = M.personal_file_scope_binding(change.group)
			if not binding or binding.current() ~= true then
				Logger.error(LOG, "%s refused: the personal source binding is unavailable or stale.", label)
				return false, "stale-personal-source"
			end
		end
	end
	local previous = _choices
	local owner, snapshot, candidate_generation, candidate_live
	if canonical then
		if engine_generation(_engine) == nil then return false, "native-generation-unavailable" end
		owner = {}
		if M.acquire(owner) ~= true then return false, "scope-pending" end
		_personal_transaction_owner = owner
		snapshot = { paths = _toml_paths, sources = _personal_sources, adoptions = _personal_adoptions,
			mappings = _mappings, live = _live_mappings, categories = _categories, overrides = _overrides,
			override_source = _override_source, errors = _parse_errors, published = _published, choices = previous }
	end
	local called, committed, reason = pcall(function()
		local current, source = read_choices()
		local candidate, operations = copy_choices(current), {}
		for _, change in ipairs(changes) do
			local id, section, enabled = change.group, change.section, change.enabled
			assert(addressable(id) and (section == nil or addressable(section)
				or PersonalFiles.components(id) and type(section) == "string" and section ~= "") and type(enabled) == "boolean",
				"invalid hotstring choice")
			local path = section and { "hotstrings", "modules", id, section } or { "hotstrings", "groups", id }
			local neutral = ManifestReader.default_for(KeyPath.render(path))
			local explicit = nil
			if enabled ~= neutral then explicit = enabled end
			local adopted = personal_adoption(id)
			if adopted and adopted.admitted and adopted.legacy_name then explicit = enabled end
			if section then
				candidate.modules[id] = candidate.modules[id] or {}
				candidate.modules[id][section] = explicit
				if next(candidate.modules[id]) == nil then candidate.modules[id] = nil end
			else
				candidate.groups[id] = explicit
			end
			if explicit == nil then
				operations[#operations + 1] = { path = path, delete = true }
			else
				operations[#operations + 1] = { path = path, value = explicit }
			end
		end
		local personal_rows = {}
		for _, operation in ipairs(operations) do
			if PersonalFiles.preference_default(KeyPath.render(operation.path)) ~= nil then
				local parent = {}
				for index = 1, #operation.path - 1 do parent[index] = operation.path[index] end
				personal_rows[#personal_rows + 1] = { section = KeyPath.render(parent), key = operation.path[#operation.path],
					value = operation.value, delete = operation.delete }
			end
		end
		if not require("hotstrings.personal_metadata").exact_rows_available(source.content or "", personal_rows) then
			return false, "ambiguous-personal-preference-owner"
		end
		local rows = LeafRows.prepare(source.content or "", operations)
		for _, row in ipairs(rows) do
			local parts = KeyPath.parse(row.section, true)
			if parts and #parts == 3 and parts[1] == "hotstrings" and parts[2] == "modules"
				and PersonalFiles.components(parts[3]) and row.key:find(".", 1, true) then row.literal_key = true end
			local id = parts and ((#parts == 2 and parts[1] == "hotstrings" and parts[2] == "groups" and row.key)
				or (#parts == 3 and parts[1] == "hotstrings" and parts[2] == "modules" and parts[3]))
			local record = id and personal_adoption(id)
			if record and record.admitted and record.legacy_name and row.value == true and row.delete == nil then
				row.personal_choice = true
			end
		end
		local directory = config_file():match("^(.*)/[^/]+$")
		if source.status == "absent" and not Shell.run("mkdir -p " .. Shell.quote(directory) .. " 2>/dev/null") then
			return false, "the configuration folder cannot be created"
		end
		_choices = candidate
		local _, published, refusal = M.load_all(owner)
		if published ~= true then return false, refusal end
		if canonical then
			candidate_generation, candidate_live = engine_generation(_engine), _live_mappings
			if candidate_generation == nil then return false, "native-generation-unavailable" end
			for _, change in ipairs(changes) do
				if PersonalFiles.components(change.group) then
					local binding = M.personal_file_scope_binding(change.group)
					if not binding or binding.current() ~= true then return false, "stale-personal-source" end
				end
			end
		end
		if not require("hotstrings.personal_metadata").exact_rows_available(source.content or "", personal_rows) then
			return false, "ambiguous-personal-preference-owner"
		end
		local written, detail = Writer.batch_write(config_file(), rows, nil, source)
		if written ~= true then return false, tostring(detail) end
		return true
	end)
	if called and committed == true then
		if owner then
			if M.release(owner) ~= true then return false, "scope-release-refused" end
			_personal_transaction_owner = nil
		end
		Logger.info(LOG, "%s committed (%d choice(s)).", label, #changes)
		return true
	end
	reason = called and reason or tostring(committed)
	if canonical then
		if candidate_generation then
			_personal_gate_debt = { owner = owner, engine = _engine, snapshot = snapshot,
				generation = candidate_generation, live = candidate_live }
			M.retry_personal_gate_cleanup()
		else
			_choices = previous
			_toml_paths, _personal_sources, _personal_adoptions = snapshot.paths, snapshot.sources, snapshot.adoptions
			_mappings, _live_mappings, _categories = snapshot.mappings, snapshot.live, snapshot.categories
			_overrides, _override_source, _resolve_cache = snapshot.overrides, snapshot.override_source, {}
			_parse_errors, _published = snapshot.errors, snapshot.published
			if M.release(owner) == true then _personal_transaction_owner = nil end
		end
	elseif _choices ~= previous then
		_choices = previous
		local _, restored = M.load_all()
		if restored ~= true then
			Logger.error(LOG, "%s: the previous catalogue could not be republished.", label)
		end
	end
	Logger.error(LOG, "%s refused: %s.", label, tostring(reason))
	return false, reason
end

--- The categories the current catalogue offers, in a stable order.
--- @return table Array of category ids.
local function known_categories()
	local ids = {}
	for id in pairs(_categories) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

--- The sections one category declares, in a stable order.
--- @param id string
--- @return table Array of section names.
local function known_sections(id)
	local names = {}
	local category = _categories[id]
	for name in pairs(category and category.sections or {}) do names[#names + 1] = name end
	table.sort(names)
	return names
end

--- Switches one category off, keeping its section choices.
--- @param group_name string
--- @return boolean committed
function M.disable_group(group_name)
	if not addressable(group_name) then return false end
	if not M.is_group_enabled(group_name) then return true end
	return commit_choices({ { group = group_name, enabled = false } }, "Category '" .. group_name .. "' disable")
end

--- Switches one category on, keeping its section choices.
--- @param group_name string
--- @return boolean committed
function M.enable_group(group_name)
	if not addressable(group_name) then return false end
	if M.is_group_enabled(group_name) then return true end
	return commit_choices({ { group = group_name, enabled = true } }, "Category '" .. group_name .. "' enable")
end

--- Flips one category and redraws the menu.
--- @param group_name string
--- @return boolean committed
function M.toggle_group(group_name)
	if not addressable(group_name) then return false end
	local committed = commit_choices({ { group = group_name, enabled = not M.is_group_enabled(group_name) } },
		"Category '" .. group_name .. "' toggle")
	if committed then notify_change() end
	return committed
end

--- Enables every known category and every one of its sections.
---
--- These two were called by the menu and did not exist, so the rows behind them
--- were silent no-ops: the `if` guarding the call was false and nothing
--- happened, which is indistinguishable from a click that missed.
--- @return integer|boolean Number of choices changed, or false when refused.
function M.enable_all()
	local changes = {}
	for _, id in ipairs(known_categories()) do
		if addressable(id) then
			if not M.is_group_enabled(id) then changes[#changes + 1] = { group = id, enabled = true } end
			for _, name in ipairs(known_sections(id)) do
				if (addressable(name) or PersonalFiles.components(id)) and not M.is_section_checked(id, name) then
					changes[#changes + 1] = { group = id, section = name, enabled = true }
				end
			end
		end
	end
	if #changes == 0 then return 0 end
	-- One commit, not one per category: every commit republishes the catalogue,
	-- and magickey.toml alone is 300 KB of it.
	if not commit_choices(changes, "Enable every category") then return false end
	notify_change()
	return #changes
end

--- Disables every known category, leaving each section choice as it was.
--- @return integer|boolean Number of categories changed, or false when refused.
function M.disable_all()
	local changes = {}
	for _, id in ipairs(known_categories()) do
		if addressable(id) and M.is_group_enabled(id) then changes[#changes + 1] = { group = id, enabled = false } end
	end
	-- Section choices are left alone on purpose: disabling everything and enabling
	-- it again should give the user back the sections they had chosen.
	if #changes == 0 then return 0 end
	if not commit_choices(changes, "Disable every category") then return false end
	notify_change()
	return #changes
end

--- Whether any category gate is open, over the very inventory disable_all
--- closes: once the Hotstrings switch turned them all off, it reads off.
--- @return boolean
function M.any_enabled()
	for _, id in ipairs(known_categories()) do
		if M.is_group_enabled(id) then return true end
	end
	return false
end

--- Whether a category's gate is open.
--- @param group_name string
--- @return boolean
function M.is_group_enabled(group_name)
	if not _choices then return false end
	return group_choice(_choices, group_name)
end

--- Returns independently owned discovered personal-source records after publication.
--- Legacy overlay losers remain discoverable without being presented as live mappings.
--- @return table sources
function M.personal_file_sources()
	local sources = {}
	for index, source in ipairs(_personal_sources) do
		sources[index] = { path = source.path, descriptor = PersonalFiles.copy(source.descriptor) }
	end
	return sources
end

--- Returns read-only native directory diagnostics without activating sources.
--- @return table directories Skipped native links and depth-boundary paths.
function M.personal_unavailable_directories()
	return Loader.unavailable_directories(_config_dir, PersonalFiles.additional_scan_max_depth)
end

--- Captures the current independently admitted native file gate owner.
--- @param id string Canonical descriptor identity.
--- @return table|nil binding Fresh source/path fields and an exact-current checker.
function M.personal_file_scope_binding(id)
	if _personal_debt or _personal_gate_debt then return nil end
	local record = personal_adoption(id)
	if not record or record.admitted ~= true or not _categories[id] then return nil end
	local inventory, category, root = _personal_adoptions, _categories[id], _config_dir
	local engine, generation = _engine, engine_generation(_engine)
	if generation == nil then return nil end
	return { source = PersonalFiles.copy(record.source), path = record.path,
		current = function()
			if _personal_debt or _personal_gate_debt or _personal_adoptions ~= inventory or _categories[id] ~= category or _config_dir ~= root
				or _engine ~= engine or engine_generation(engine) ~= generation
				or PersonalAdoption.current(inventory, record) ~= true then return false end
			local _, _, fresh = resolve_paths()
			if not fresh or #fresh ~= #inventory then return false end
			local expected = {}
			for _, source in ipairs(inventory) do expected[source.owner] = source end
			for _, source in ipairs(fresh) do
				local previous = expected[source.owner]
				if not previous or previous.path ~= source.path or previous.admitted ~= source.admitted
					or previous.exclusive ~= source.exclusive or previous.legacy_name ~= source.legacy_name then return false end
				expected[source.owner] = nil
			end
			return next(expected) == nil
		end }
end

--- Projects field availability only from the current captured native owner.
--- @param id string Canonical additional-personal identity.
--- @return table|nil controls File and literal-section unavailable field flags.
function M.personal_metadata_controls(id)
	local binding, record = M.personal_file_scope_binding(id), personal_adoption(id)
	if not binding or binding.current() ~= true then return nil end
	local Metadata = require("hotstrings.personal_metadata")
	local active = _overrides[id] ~= nil and id or record.legacy_name
	local legacy = active and _overrides[active] or {}
	local result = { file = Metadata.readonly_fields(record.content, nil, legacy), sections = {} }
	for name in pairs(_categories[id].sections or {}) do
		result.sections[name] = Metadata.readonly_fields(record.content, name, legacy)
	end
	return result
end

restore_personal_runtime = function(snapshot)
	local engine, generation = _engine, engine_generation(_engine)
	if generation == nil then return false end
	local ok, restored = pcall(engine.load_mappings, engine, snapshot.live)
	if not ok or restored ~= true or _engine ~= engine or engine_generation(engine) ~= generation + 1 then return false end
	_toml_paths, _personal_sources, _personal_adoptions = snapshot.paths, snapshot.sources, snapshot.adoptions
	_mappings, _live_mappings, _categories = snapshot.mappings, snapshot.live, snapshot.categories
	_overrides, _override_source, _resolve_cache = snapshot.overrides, snapshot.override_source, {}
	_parse_errors, _published = snapshot.errors, snapshot.published
	return true
end

local function personal_runtime_current(debt)
	local generation = engine_generation(debt.engine)
	return _scope_owner == debt.owner and _scope_owner_epoch == debt.owner_epoch
		and _personal_transaction_owner == debt.owner and _engine == debt.engine and generation == debt.generation
		and _config_dir == debt.root and _choices == debt.choices
		and _mappings == debt.mappings and _toml_paths == debt.paths and _personal_sources == debt.sources
		and _live_mappings == debt.live and _personal_adoptions == debt.adoptions
		and _categories == debt.categories and _overrides == debt.overrides and _override_source == debt.override_source
end

--- Retains the native lease until both exact file and engine inverses commit.
function M.retry_personal_cleanup()
	local debt = _personal_debt
	if not debt then return true end
	if personal_runtime_current(debt) ~= true then return false end
	if debt.release_only then
		if M.release(debt.owner) ~= true then return false end
		_personal_debt, _personal_transaction_owner, _prepared_personal_sources = nil, nil, nil
		return true
	end
	if not debt.runtime_restored then
		if restore_personal_runtime(debt.snapshot) ~= true then return false end
		debt.generation, debt.live = engine_generation(debt.engine), _live_mappings
		debt.adoptions, debt.categories, debt.overrides = _personal_adoptions, _categories, _overrides
		debt.mappings, debt.paths, debt.sources = _mappings, _toml_paths, _personal_sources
		debt.override_source = _override_source
		debt.runtime_restored = true
	end
	if debt.source_published then
		if not debt.source_inverse_acknowledged then
			if Writer.publish_if_unchanged(debt.record.path, debt.record.content, nil,
				{ status = "ok", content = debt.content }) ~= true then return false end
			debt.source_inverse_acknowledged = true
		end
		if personal_runtime_current(debt) ~= true
			or PersonalAdoption.advance(debt.snapshot.adoptions, debt.record, debt.record.content) ~= true
			or personal_runtime_current(debt) ~= true then return false end
		debt.source_published = false
	end
	if debt.override_published then
		if debt.snapshot.override_source.status ~= "ok" or Writer.publish_if_unchanged(overrides_path(),
			debt.snapshot.override_source.content, nil, debt.override_target) ~= true then return false end
		if personal_runtime_current(debt) ~= true then return false end
		debt.override_published = false
	end
	if personal_runtime_current(debt) ~= true or M.release(debt.owner) ~= true then return false end
	_personal_debt, _personal_transaction_owner, _prepared_personal_sources = nil, nil, nil
	return true
end

--- Source metadata reaches the real engine before conditional source replacement.
--- A recognized legacy override may be removed only within this held cohort.
function M.set_personal_metadata(id, section, field, value)
	if M.retry_personal_cleanup() ~= true then return false end
	local binding, record = M.personal_file_scope_binding(id), personal_adoption(id)
	if not binding or binding.current() ~= true or _override_source.status == "error" then return false end
	local active = _overrides[id] ~= nil and id or record.legacy_name
	local legacy = active and _overrides[active] or {}
	local plan = require("hotstrings.personal_metadata").prepare(record.content, section, field, value, legacy)
	if not plan then return false end
	local rows, candidate_overrides = {}, copy_overrides(_overrides)
	local candidate_legacy = active and candidate_overrides[active]
	if plan.remove_file then
		candidate_legacy[field] = nil
		rows[#rows + 1] = { section = KeyPath.render({ active }), key = field, delete = true }
	end
	if plan.remove_section then
		candidate_legacy.sections[section][field] = nil
		rows[#rows + 1] = { section = KeyPath.render({ active, section }), key = field, delete = true }
	end
	local prepared, _, override_content = Writer.prepare_batch(overrides_path(), rows, nil, _override_source)
	if prepared ~= true then return false end
	local owner, snapshot = {}, { paths = _toml_paths, sources = _personal_sources, adoptions = _personal_adoptions,
		mappings = _mappings, live = _live_mappings, categories = _categories, overrides = _overrides,
		override_source = _override_source, errors = _parse_errors, published = _published }
	local root = _config_dir
	if M.acquire(owner) ~= true then return false end
	_personal_transaction_owner, _prepared_personal_sources = owner, { [record.path] = plan.content }
	_overrides, _resolve_cache = candidate_overrides, {}
	local override_changed = override_content ~= (snapshot.override_source.content or "")
	local override_target = { status = "ok", content = override_content }
	local override_published, source_published = false, false
	local engine, original_generation = _engine, engine_generation(_engine)
	local runtime = { owner = owner, owner_epoch = _scope_owner_epoch, engine = engine, snapshot = snapshot,
		generation = original_generation, root = root, choices = _choices,
		live = snapshot.live, adoptions = snapshot.adoptions, categories = snapshot.categories, overrides = candidate_overrides,
		mappings = snapshot.mappings, paths = snapshot.paths, sources = snapshot.sources, override_source = _override_source }
	local published_binding
	local ok, committed = pcall(function()
		local _, loaded = M.load_all(owner)
		if loaded ~= true or _config_dir ~= root or _engine ~= engine
			or engine_generation(engine) ~= original_generation + 1 then return false end
		runtime.generation, runtime.live = engine_generation(engine), _live_mappings
		runtime.adoptions, runtime.categories = _personal_adoptions, _categories
		runtime.mappings, runtime.paths, runtime.sources = _mappings, _toml_paths, _personal_sources
		local selected = personal_adoption(id)
		if not selected or selected.admitted ~= true or PersonalAdoption.current(_personal_adoptions, selected) ~= true then return false end
		if value ~= nil and M.resolve(id, section)[field] ~= value then return false end
		if personal_runtime_current(runtime) ~= true then return false end
		if override_changed then
			if Writer.publish_if_unchanged(overrides_path(), override_content, nil, snapshot.override_source) ~= true then return false end
			override_published = true
			if personal_runtime_current(runtime) ~= true then return false end
		end
		local final_binding = M.personal_file_scope_binding(id)
		if not final_binding or final_binding.current() ~= true then return false end
		published_binding = final_binding
		if Writer.publish_if_unchanged(record.path, plan.content, nil,
			{ status = "ok", content = record.content }) ~= true then return false end
		source_published = true
		return personal_runtime_current(runtime) == true
			and PersonalAdoption.advance(_personal_adoptions, selected, plan.content) == true
			and final_binding.current() == true
	end)
	_prepared_personal_sources = nil
	if not ok or committed ~= true then
		runtime.override_target, runtime.override_published = override_target, override_published
		runtime.source_published, runtime.record, runtime.content = source_published, record, plan.content
		_personal_debt = runtime
		M.retry_personal_cleanup()
		return false
	end
	if override_changed then _override_source = override_target; runtime.override_source = override_target end
	if personal_runtime_current(runtime) ~= true or M.release(owner) ~= true then
		runtime.runtime_restored, runtime.release_only = true, true
		_personal_debt = runtime
		return false
	end
	_personal_transaction_owner = nil
	notify_change()
	return true, published_binding
end

function M.get_groups()
	return _collect_groups(_mappings)
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
	return M.is_group_enabled(category) and M.is_section_checked(category, section)
end

--- Whether the user has this section TICKED, regardless of its category's gate.
---
--- Two different questions live behind one answer above, and conflating them
--- cost the menu real information: a category switched off made every one of its
--- sections read as disabled, so the menu unticked them all at once and the user
--- could no longer see which ones would come back.
---
--- `is_section_enabled` stays the EFFECTIVE answer and is what the loader filters
--- on. This one is what a checkbox should show. macOS keeps them separate for the
--- same reason and feeds them to `checked` and `disabled` independently.
--- @param category string
--- @param section string
--- @return boolean
function M.is_section_checked(category, section)
	if not _choices then return false end
	return section_choice(_choices, category, section)
end

--- How many hotstrings a category is ACTUALLY firing right now.
---
--- Not the same as the number it holds. A user reads the figure beside a category
--- as "what this is doing"; switch the category off, or untick half its sections,
--- and the number must fall — that is how they check a disable took effect.
---
--- Windows encodes the same rule in hotstring_count_policy.ahk: a disabled scope
--- shows no active hotstrings, not the count it would have if re-enabled.
--- @param category string
--- @return integer
function M.active_count(category)
	local cat = _categories[category]
	if not cat then return 0 end
	if not M.is_group_enabled(category) then return 0 end

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
--- @return boolean committed
function M.toggle_section(category, section)
	if not addressable(category) or not (addressable(section)
		or PersonalFiles.components(category) and type(section) == "string" and _categories[category]
		and (_categories[category].sections or {})[section]) then return false end
	local committed = commit_choices({ { group = category, section = section,
		enabled = not M.is_section_checked(category, section) } }, "Section '" .. category .. "." .. section .. "' toggle")
	if committed then notify_change() end
	return committed
end

--- Stages every section of the given categories in one candidate.
--- Enabling lifts each category gate too: without it the row could set every
--- section on and change nothing visible, because the gate above them was
--- still shut. Both reference drivers lift it here.
--- @param categories table Array of category ids.
--- @param enabled boolean
--- @return table|nil changes nil when a category is unknown.
local function section_changes(categories, enabled)
	local changes = {}
	for _, category in ipairs(categories) do
		if not _categories[category] or not addressable(category) then
			Logger.error(LOG, "Unknown or unaddressable category '%s' — its sections were not changed.", tostring(category))
			return nil
		end
		if enabled then changes[#changes + 1] = { group = category, enabled = true } end
		for _, name in ipairs(known_sections(category)) do
			if addressable(name) or PersonalFiles.components(category) then
				changes[#changes + 1] = { group = category, section = name, enabled = enabled }
			end
		end
	end
	return changes
end

--- Sets every section of a category at once.
--- @param category string
--- @param enabled boolean
--- @return boolean committed
function M.set_all_sections(category, enabled)
	if type(enabled) ~= "boolean" then return false end
	local changes = section_changes({ category }, enabled)
	if not changes then return false end
	local committed = commit_choices(changes, "Category '" .. tostring(category) .. "' sections")
	if committed then notify_change() end
	return committed
end

--- Sets every section of several categories at once — one language pack's
--- « tout activer » / « tout désactiver ». One candidate, so the whole language
--- commits or none of it does; enabling lifts each category gate.
--- @param categories table Array of category ids.
--- @param enabled boolean
--- @return boolean committed
function M.set_categories_sections(categories, enabled)
	if type(categories) ~= "table" or type(enabled) ~= "boolean" then return false end
	local changes = section_changes(categories, enabled)
	if not changes then return false end
	local committed = commit_choices(changes, "Language sections")
	if committed then notify_change() end
	return committed
end

--- Sets category gates and their sections as one acknowledged choice batch.
--- Independent engine gates and categories outside this scope are retained.
--- @param targets table Dense discovered category ids.
--- @param enabled boolean Explicit target state.
--- @return boolean committed
--- @return string|nil reason Stable planner or persistence refusal.
function M.set_category_scope_enabled(targets, enabled)
	local inventory = {}
	for id in pairs(_categories) do inventory[id] = known_sections(id) end
	local changes, reason = PersonalAdoption.plan_selection(inventory, targets, enabled)
	if not changes then
		Logger.error(LOG, "Category selection refused: %s.", reason)
		return false, reason
	end
	local committed, refusal = commit_choices(changes, "Hotstring category selection")
	if committed then notify_change() end
	return committed, refusal
end

--- Sets only the selected category gates in one acknowledged choice batch.
--- Existing section choices and categories outside the scope are retained.
--- @param targets table Dense discovered category ids.
--- @param enabled boolean Explicit target state.
--- @return boolean committed
--- @return string|nil reason Stable planner or persistence refusal.
function M.set_category_gates_enabled(targets, enabled)
	local inventory = {}
	-- This operation offers category gates only. The existing scope planner
	-- validates their known identities with no section leaves in this domain.
	for id in pairs(_categories) do inventory[id] = {} end
	local changes, reason = BulkScope.plan(inventory, targets, enabled)
	if not changes then
		Logger.error(LOG, "Category gate selection refused: %s.", reason)
		return false, reason
	end
	local committed, refusal = commit_choices(changes, "Hotstring category gate selection")
	if committed then notify_change() end
	return committed, refusal
end

--- Sets whole category gates and exact sections supplied by one extension.
--- A bound native feature participates in the same durable transaction without
--- changing unrelated sections of its common category.
--- @param targets table Dense whole-category ids.
--- @param bound table Dense `{ group, section }` bindings.
--- @param enabled boolean Explicit target state.
--- @return boolean committed
--- @return string|nil reason
function M.set_extension_sections_enabled(targets, bound, enabled)
	local inventory = {}
	for id in pairs(_categories) do inventory[id] = known_sections(id) end
	-- This driver's existing extension commands preserve each whole pack's
	-- section choices while switching its category gate.
	if type(targets) == "table" then
		for _, id in ipairs(targets) do if inventory[id] then inventory[id] = {} end end
	end
	local changes, reason = BulkScope.plan(inventory, targets, enabled, bound)
	if not changes then return false, reason end
	local committed, refusal = commit_choices(changes, "Extension hotstring selection")
	if committed then notify_change() end
	return committed, refusal
end

--- Rereads the canonical choices and republishes the catalogue with them.
--- Used after another owner published config.toml; a refusal keeps the previous
--- choices and catalogue.
--- @return boolean committed
--- @return string|nil reason
function M.refresh_choices()
	if _scope_owner ~= nil then return false, "scope-pending" end
	local read, choices = pcall(read_choices)
	if not read then
		Logger.error(LOG, "Hotstring choices refresh refused: %s.", tostring(choices))
		return false, tostring(choices)
	end
	local previous = _choices
	_choices = choices
	local _, published, reason = M.load_all()
	if published ~= true then
		_choices = previous
		return false, reason
	end
	notify_change()
	return true
end

--- The override file this owner reads and the scope publishes.
--- @return string
function M.override_path()
	return overrides_path()
end

--- The delay a section inherits once every user override is removed: its
--- corpus rungs, then the shared default. The scope compares it with the
--- manifest recommendation instead of assuming deletion restores it.
--- @param category string Loaded category.
--- @param section string Section name.
--- @return number seconds
function M.inherited_delay(category, section)
	local meta = _categories[category]
	assert(type(meta) == "table", "unknown hotstring category: " .. tostring(category))
	return DelayResolver.resolve({
		meta_category = meta,
		meta_section = (meta.sections or {})[section],
		default_delay = GLOBAL_DEFAULT_DELAY,
	}).delay
end

--- The categories shipped with the product: the bundled file stems and the
--- declared language packs. Personal and extension packs are user content.
--- @return table Set of category ids.
function M.bundled_categories()
	local set = {}
	local bundled = Paths.shared("modules/hotstrings")
	for _, path in ipairs(Loader.find_toml_files(bundled)) do
		local stem = path:match("([^/\\]+)%.toml$")
		if stem and not in_language_folder(path, bundled) then set[stem] = true end
	end
	for _, pack in ipairs(M.language_packs()) do
		for _, stem in ipairs(pack.categories) do set[Languages.group_id(pack.id, stem)] = true end
	end
	-- A category an extension binds (SFB reduction and rolls, moved into the
	-- shipped Ergopti extension) keeps its historical manifest rows: the scope
	-- still restores their recommended delays, as for any bundled category.
	for _, extension in ipairs(M.discover_extensions()) do
		for _, file in ipairs(extension.bound_files or {}) do set[file.binding.category] = true end
	end
	return set
end

--- Acquires the configuration for one scope transaction; ordinary setters are
--- refused until it releases.
--- @param owner table Transaction identity.
--- @return boolean acquired
function M.acquire(owner)
	if type(owner) ~= "table" or _scope_owner ~= nil then return false end
	_scope_owner = owner
	_scope_owner_epoch = _scope_owner_epoch + 1
	return true
end

--- Releases the configuration held by an owner.
--- @param owner table Transaction identity.
--- @return boolean released
function M.release(owner)
	if _scope_owner ~= owner then return false end
	_scope_owner = nil
	_scope_owner_epoch = _scope_owner_epoch + 1
	return true
end

--- Detached runtime state a scope restores after a refused publication.
--- @return table|nil snapshot nil while the choices are unreadable.
function M.configuration_snapshot()
	if not _choices then return nil end
	return { choices = copy_choices(_choices), overrides = copy_overrides(_overrides),
		override_source = { status = _override_source.status, content = _override_source.content },
		magic_key = _magic_key, canonical_magic_key = _canonical_magic_key }
end

--- Publishes a candidate configuration to the engine without writing a file.
--- The previous catalogue stays effective when the engine refuses.
--- @param owner table The acquiring transaction.
--- @param document table Decoded config.toml candidate.
--- @param override_content string Override file candidate bytes.
--- @param override_source table Exact classified target from the scope file owner.
--- @return boolean applied
function M.apply_configuration(owner, document, override_content, override_source)
	if _scope_owner ~= owner then return false end
	if type(override_source) ~= "table" or type(override_content) ~= "string"
		or not ((override_source.status == "ok" and override_source.content == override_content)
			or (override_source.status == "absent" and override_source.content == nil and override_content == "")) then
		return false
	end
	local decoded, choices = pcall(decode_choices, document)
	local parsed, overrides = pcall(parse_override_content, override_content)
	if not decoded or not parsed then
		Logger.error(LOG, "Candidate hotstring configuration refused: %s.", tostring(decoded and overrides or choices))
		return false
	end
	local previous_choices, previous_overrides, previous_source = _choices, _overrides, _override_source
	_choices, _overrides, _resolve_cache = choices, overrides, {}
	local _, committed, reason = M.load_all()
	if committed == true then
		_override_source = { status = override_source.status, content = override_source.content }
		return true
	end
	_choices, _overrides, _resolve_cache = previous_choices, previous_overrides, {}
	_override_source = previous_source
	local _, restored = M.load_all()
	Logger.error(LOG, "Candidate hotstring catalogue refused (%s); previous catalogue %s.",
		tostring(reason), restored == true and "republished" or "NOT republished")
	return false
end

--- Republishes an exact snapshot taken before a scope.
--- @param owner table The acquiring transaction.
--- @param snapshot table Result of M.configuration_snapshot().
--- @return boolean restored
function M.restore_configuration(owner, snapshot)
	if _scope_owner ~= owner or type(snapshot) ~= "table" then return false end
	_choices, _overrides, _resolve_cache = copy_choices(snapshot.choices), copy_overrides(snapshot.overrides), {}
	_override_source = { status = snapshot.override_source.status, content = snapshot.override_source.content }
	_magic_key, _canonical_magic_key = snapshot.magic_key, snapshot.canonical_magic_key
	local _, committed = M.load_all()
	return committed == true
end

--- Marks the choices this owner consumes for the unused-key cleanup: every
--- well-formed choice the published catalogue cannot prove retired, through
--- the same decoder the reader applies. Without a published catalogue (a
--- refused or failed load) every such choice is kept: a transient failure must
--- never offer the user's real settings for deletion.
--- @param document table Decoded config.toml.
--- @param mark function mark(...segments).
function M.mark_config_reads(document, mark)
	local choices = decode_choices(document)
	report_retired_choices(choices)
	for id in pairs(choices.groups) do
		if not choice_is_retired(id) then mark("hotstrings", "groups", id) end
	end
	for id, sections in pairs(choices.modules) do
		for name in pairs(sections) do
			if not choice_is_retired(id, name) then mark("hotstrings", "modules", id, name) end
		end
	end
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
