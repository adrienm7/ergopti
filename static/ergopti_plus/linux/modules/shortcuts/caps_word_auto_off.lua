--- modules/shortcuts/caps_word_auto_off.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off Settings (Linux)
--- DESCRIPTION:
--- Owns the config.toml leaves that decide what ends CapsWord on its own:
--- `shortcuts.caps_word.idle_timeout_seconds` (a delay without a keystroke,
--- 0 = never), `shortcuts.caps_word.terminators` (word delimiters of the
--- hotstring catalogue) and `[shortcuts.caps_word.pointer]` (one switch per
--- pointer kind). The rule itself is the shared policy
--- (_shared/lua/caps_word/auto_off.lua); this module reads and writes the
--- settings and names the pointer kind of a native evdev event.
---
--- FEATURES & RATIONALE:
--- 1. One Declaration: the pointer kinds are the features of the manifest
---    section shortcuts.caps_word.pointer, the delimiters the shared catalogue.
---    The only Linux table is the evdev code -> kind map, which must name
---    exactly the declared kinds or the module refuses to load.
--- 2. Outdated Values Warn: a stored value of another shape is reported once
---    through config_outdated and read as its manifest default; an unknown
---    delimiter key is dropped from the list with the same WARNING.
--- 3. No Disk on the Input Path: the values are cached. CapsWord refreshes
---    them when it is switched on, so a scope restore or a hand edit applies
---    from the next CapsWord on; the menu setters publish, then update the cache.
--- ==============================================================================

local M = {}
local TableUtil = require("table_util")

local Logger = require("logger.shim")
local Manifest = require("infra.manifest_reader")
local Paths = require("infra.config_paths")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local ConfigOutdated = require("config_outdated")
local Policy = require("caps_word.auto_off")
local EvdevCodes = require("infra.evdev_codes")
local InputEvent = require("infra.input_event")

local LOG = "modules.shortcuts.caps_word_auto_off"

local SECTION = "shortcuts.caps_word"
local POINTER_SECTION = "shortcuts.caps_word.pointer"
local IDLE_PATH = SECTION .. ".idle_timeout_seconds"
local TERMINATORS_PATH = SECTION .. ".terminators"

-- The pointer kind of each native evdev event this driver observes. Codes
-- come from infra/evdev_codes (kernel ABI); any other pointer button is one of
-- the "other" buttons, and the touchpad contact codes (BTN_DIGI range) are a
-- gesture. Checked against the manifest's declared kinds at load.
local BUTTON_KIND = {
	[EvdevCodes.BTN_LEFT] = "left_click",
	[EvdevCodes.BTN_RIGHT] = "right_click",
	[EvdevCodes.BTN_MIDDLE] = "middle_click",
}
local OTHER_BUTTON_KIND = "other_buttons"
local CONTACT_KIND = "gesture"
local MOTION_KIND = "pointer_motion"

-- Populated once; no preference IO on each keystroke.
local _settings = nil
local _policy = nil
local _kinds = nil





-- =========================================
-- =========================================
-- ======= 1/ Declared pointer kinds =======
-- =========================================
-- =========================================

--- The pointer kinds the manifest declares for Linux, in manifest order.
--- @return table Dense array of kind ids (a copy).
function M.pointer_kinds()
	if not _kinds then
		local kinds = {}
		for _, entry in ipairs(Manifest.features()) do
			local linux = false
			for _, platform in ipairs(entry.platforms or {}) do
				if platform == "linux" then linux = true end
			end
			if entry.section == POINTER_SECTION and linux then
				assert(entry.type == "boolean", "pointer kind " .. tostring(entry.id) .. " must be a boolean feature")
				kinds[#kinds + 1] = entry.id
			end
		end
		assert(#kinds > 0, "the manifest declares no CapsWord pointer kind for Linux")
		local declared = {}
		for _, kind in ipairs(kinds) do declared[kind] = true end
		local mapped = { [OTHER_BUTTON_KIND] = true, [CONTACT_KIND] = true, [MOTION_KIND] = true }
		for _, kind in pairs(BUTTON_KIND) do mapped[kind] = true end
		for kind in pairs(mapped) do
			assert(declared[kind], "the Linux pointer map names the undeclared CapsWord kind " .. kind)
		end
		for kind in pairs(declared) do
			assert(mapped[kind], "the Linux pointer map cannot see the declared CapsWord kind " .. kind)
		end
		_kinds = kinds
	end
	local copy = {}
	for index, kind in ipairs(_kinds) do copy[index] = kind end
	return copy
end

--- Every pointer kind the manifest declares, Linux or not, in manifest order,
--- for the menu: a kind this driver cannot see keeps its declared reason.
--- @return table Dense array of { kind, label_key, available, reason_key }.
function M.pointer_kind_rows()
	local rows = {}
	for _, entry in ipairs(Manifest.features()) do
		if entry.section == POINTER_SECTION then
			local linux = false
			for _, platform in ipairs(entry.platforms or {}) do
				if platform == "linux" then linux = true end
			end
			rows[#rows + 1] = { kind = entry.id, label_key = entry.description_key, available = linux,
				reason_key = not linux and entry.reason_key or nil }
		end
	end
	return rows
end

--- The pointer kind of an evdev EV_KEY press from an observed pointer.
--- @param code integer evdev code.
--- @return string|nil kind nil for a code that is no pointer button or contact.
function M.pointer_kind_of_button(code)
	if type(code) ~= "number" then return nil end
	if BUTTON_KIND[code] then return BUTTON_KIND[code] end
	if InputEvent.is_pointer_button(code) then return OTHER_BUTTON_KIND end
	if code >= EvdevCodes.BTN_DIGI_FIRST and code <= EvdevCodes.BTN_DIGI_LAST then return CONTACT_KIND end
	return nil
end

--- The pointer kind of an EV_REL report: a movement or a wheel turn.
--- @return string kind
function M.pointer_kind_of_motion()
	return MOTION_KIND
end





-- ===============================
-- ===============================
-- ======= 2/ The settings =======
-- ===============================
-- ===============================

local function copy_settings(settings)
	local copy = { idle_timeout_seconds = settings.idle_timeout_seconds, terminators = {}, pointer = {} }
	for index, key in ipairs(settings.terminators) do copy.terminators[index] = key end
	for kind, enabled in pairs(settings.pointer) do copy.pointer[kind] = enabled end
	return copy
end

--- The manifest defaults of every leaf.
--- @return table settings
local function default_settings()
	local defaults = { idle_timeout_seconds = Manifest.default_for(IDLE_PATH), terminators = {}, pointer = {} }
	for index, key in ipairs(Manifest.default_for(TERMINATORS_PATH)) do defaults.terminators[index] = key end
	for _, kind in ipairs(M.pointer_kinds()) do
		defaults.pointer[kind] = Manifest.default_for(POINTER_SECTION .. "." .. kind)
	end
	return defaults
end

--- Reads the delimiter list, dropping (and reporting) what this build does not know.
--- @param value any Stored list.
--- @param mark function|nil Cleanup ownership visitor.
--- @return table|nil list nil when the stored value is absent or not a list.
local function resolve_terminators(value, mark)
	if value == nil then return nil end
	if type(value) ~= "table" then
		ConfigOutdated.report(TERMINATORS_PATH, "a list of delimiter keys is expected", Logger)
		return nil
	end
	if TableUtil.count(value) ~= #value then
		ConfigOutdated.report(TERMINATORS_PATH, "a list of delimiter keys is expected", Logger)
		return nil
	end
	local kept, seen = {}, {}
	for _, key in ipairs(value) do
		if not Policy.is_terminator_key(key) then
			ConfigOutdated.report({ "shortcuts", "caps_word", "terminators", tostring(key) },
				"no hotstring delimiter has this key", Logger)
		elseif not seen[key] then
			seen[key] = true
			kept[#kept + 1] = key
		end
	end
	if mark then mark("shortcuts", "caps_word", "terminators") end
	return kept
end

--- Resolves exactly the leaves consumed here.
--- @param document table Decoded canonical configuration.
--- @param mark function|nil Cleanup ownership visitor.
--- @return table settings `{ idle_timeout_seconds, terminators, pointer }`.
local function resolve_settings(document, mark)
	local shortcuts = ConfigOutdated.settings_table(document.shortcuts, { "shortcuts" }, Logger)
	local section = ConfigOutdated.settings_table(shortcuts and shortcuts.caps_word, { "shortcuts", "caps_word" }, Logger)
	local settings = default_settings()

	local idle = section and section.idle_timeout_seconds
	if idle ~= nil then
		if Policy.validate_idle_timeout(idle) then
			settings.idle_timeout_seconds = idle
			if mark then mark("shortcuts", "caps_word", "idle_timeout_seconds") end
		else
			ConfigOutdated.report(IDLE_PATH, "the value is not a non-negative number of seconds", Logger)
		end
	end

	local list = resolve_terminators(section and section.terminators, mark)
	if list then settings.terminators = list end

	local pointer = ConfigOutdated.settings_table(section and section.pointer,
		{ "shortcuts", "caps_word", "pointer" }, Logger)
	if pointer then
		local kept = ConfigOutdated.partition({ "shortcuts", "caps_word", "pointer" }, pointer,
			function(kind, value)
				if settings.pointer[kind] == nil then return false, "no pointer kind has this name" end
				if type(value) ~= "boolean" then return false, "the value is not a boolean" end
				return true
			end, mark)
		for kind, enabled in pairs(kept) do settings.pointer[kind] = enabled end
	end
	return settings
end

--- Compiles and caches validated settings; a refusal is a bug in the resolver.
--- @param settings table Resolved settings.
local function publish(settings)
	local policy, reason = Policy.compile(settings, M.pointer_kinds())
	assert(policy, "resolved CapsWord settings must compile: " .. tostring(reason))
	_settings, _policy = settings, policy
end

local function read_settings()
	local content, status, detail = Writer.read_classified(Paths.config("config.toml"))
	assert(status == "ok" or status == "absent", "CapsWord configuration is unreadable: " .. tostring(detail))
	local decoded = Codec.decode(content or "")
	assert(type(decoded) == "table", "CapsWord configuration is malformed")
	return resolve_settings(decoded), { status = status, content = content }
end

--- Marks the same canonical values used by every read.
--- @param document table Decoded configuration.
--- @param mark function Exact ownership visitor.
function M.mark_config_reads(document, mark)
	resolve_settings(document, mark)
end

--- Reloads the cached values only after their canonical source is validated.
--- @return boolean acknowledged
function M.refresh()
	local called, value = pcall(read_settings)
	if not called then
		Logger.error(LOG, "CapsWord auto-off configuration refresh refused: %s.", tostring(value))
		return false
	end
	publish(value)
	return true
end

--- The cached settings, read once. An unreadable configuration leaves every
--- leaf on its manifest default until a refresh succeeds.
--- @return table settings A copy.
function M.settings()
	if _settings == nil and not M.refresh() then
		Logger.error(LOG, "CapsWord auto-off configuration is unreadable; the defaults apply until a refresh succeeds.")
		publish(default_settings())
	end
	return copy_settings(_settings)
end

--- The compiled policy of the cached settings.
--- @return table policy
function M.policy()
	if _policy == nil then M.settings() end
	return _policy
end

--- Publishes one sparse leaf, then the cache.
--- @param path string Feature path.
--- @param value any Validated value.
--- @param apply function Mutates a settings copy.
--- @return boolean committed
local function persist(path, value, apply)
	-- The Shortcuts scope owns every [shortcuts] leaf while it publishes.
	local manager = package.loaded["modules.shortcuts.manager"]
	if type(manager) == "table" and type(manager.configuration_admitted) == "function"
		and manager.configuration_admitted() ~= true then
		Logger.error(LOG, "CapsWord auto-off change refused: a shortcut configuration scope is still pending.")
		return false
	end
	local called, committed, detail = pcall(function()
		local _, source = read_settings()
		return Writer.batch_write(Paths.config("config.toml"),
			{ Manifest.sparse_operation(path, value) }, nil, source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "CapsWord auto-off change was not persisted: %s.", tostring(called and detail or committed))
		return false
	end
	local updated = M.settings()
	apply(updated)
	publish(updated)
	Logger.info(LOG, "%s set to %s.", path, type(value) == "table" and table.concat(value, ", ") or tostring(value))
	return true
end

--- Sets the delay without a keystroke after which CapsWord switches off.
--- @param seconds number Non-negative seconds; 0 = never.
--- @return boolean committed
function M.set_idle_timeout_seconds(seconds)
	if not Policy.validate_idle_timeout(seconds) then
		Logger.warn(LOG, "Invalid CapsWord delay '%s' refused.", tostring(seconds))
		return false
	end
	return persist(IDLE_PATH, seconds, function(settings) settings.idle_timeout_seconds = seconds end)
end

--- Checks or unchecks one delimiter.
--- @param key string Built-in delimiter key.
--- @param checked boolean Wanted state.
--- @return boolean committed
function M.set_terminator(key, checked)
	local list, reason = Policy.with_terminator(M.settings().terminators, key, checked)
	if not list then
		Logger.warn(LOG, "CapsWord delimiter change '%s' refused: %s.", tostring(key), tostring(reason))
		return false
	end
	return persist(TERMINATORS_PATH, list, function(settings) settings.terminators = list end)
end

--- Switches one pointer kind.
--- @param kind string Declared pointer kind.
--- @param enabled boolean Wanted state.
--- @return boolean committed
function M.set_pointer(kind, enabled)
	if type(enabled) ~= "boolean" or M.settings().pointer[kind] == nil then
		Logger.warn(LOG, "CapsWord pointer change '%s' = '%s' refused.", tostring(kind), tostring(enabled))
		return false
	end
	return persist(POINTER_SECTION .. "." .. kind, enabled, function(settings) settings.pointer[kind] = enabled end)
end

--- Forgets the cache (tests and a restarted session).
function M.reset_for_tests()
	_settings, _policy, _kinds = nil, nil, nil
end

return M
