--- modules/hotstrings/terminator_settings.lua

--- ==============================================================================
--- MODULE: Word-Delimiter Settings (Linux)
--- DESCRIPTION:
--- Owns which characters end a hotstring, and the delimiters the user added,
--- as canonical config.toml leaves read into the shared terminator catalogue:
---   [hotstrings.terminator_states]  key = true|false, only where a delimiter
---                                   differs from its catalogue default;
---   hotstrings.terminators          the user's own delimiters, as
---                                   { key, char, label, consume } records.
--- These are the paths and record fields macOS reads, so one configuration
--- means the same delimiters on both Lua drivers.
---
--- FEATURES & RATIONALE:
--- 1. config.toml, not storage.json. The choices used to live in storage.json,
---    outside every configuration scope, so « restore recommended » and
---    « clear » could never reach them; infra/legacy_hotstring_storage imports
---    an older install's value once.
--- 2. Sparse against the catalogue. A delimiter back on its default leaves no
---    key, so a catalogue default changed by a later build reaches every user
---    who never touched that delimiter.
--- 3. Outdated entries warn, never refuse. A state for an unknown key, a
---    non-boolean value or an unusable custom record is reported once through
---    the shared rule, read as absent and left for the config cleanup.
--- 4. Scope ownership. The hotstrings scope adopts its candidate document here
---    and restores the exact runtime snapshot on rollback; ordinary writes wait
---    while it holds the hotstring preferences.
--- ==============================================================================

local M = {}
local Terminators = require("keymap.terminators")
local Preferences = require("infra.hotstring_preferences")
local ConfigPaths = require("infra.config_paths")
local ConfigOutdated = require("config_outdated")
local Writer = require("toml_codec.writer")
local LeafRows = require("toml_codec.leaf_rows")
local Codec = require("toml_codec")
local Shell = require("adapters.shell_runner")
local Logger = require("logger.shim")

local LOG = "hotstrings.terminator_settings"

-- The two canonical paths, as segments.
local STATES_PATH = { "hotstrings", "terminator_states" }
local CUSTOM_PATH = { "hotstrings", "terminators" }

-- A delimiter the user adds is on when created (add_custom_terminator).
local CUSTOM_DEFAULT = true




-- =========================================
-- =========================================
-- ======= 1/ Catalogue ====================
-- =========================================
-- =========================================

--- The shipped delimiters, keyed by identity, with their default and chars.
--- @return table builtins key -> { default = boolean, chars = table }
local function builtins()
	local out = {}
	for _, def in ipairs(Terminators.get_terminator_defs()) do
		if def.key and def.custom ~= true then
			out[def.key] = { default = def.default_enabled ~= false, chars = def.chars or {} }
		end
	end
	return out
end

--- Why one custom record cannot be used, or nil when it can.
--- @param record any Candidate record.
--- @param shipped table Result of builtins().
--- @param keys table Custom keys already accepted in the same list.
--- @param chars table Custom characters already accepted in the same list.
--- @return string|nil detail
local function custom_refusal(record, shipped, keys, chars)
	if type(record) ~= "table" then return "a delimiter record is expected" end
	if type(record.key) ~= "string" or record.key == "" then return "a delimiter needs a text key" end
	if shipped[record.key] then return "'" .. record.key .. "' is a built-in delimiter" end
	if keys[record.key] then return "'" .. record.key .. "' is defined twice" end
	if Terminators.validate_character(record.char) ~= true then return "a delimiter is one character" end
	if type(record.label) ~= "string" or record.label == "" then return "a delimiter needs a label" end
	if type(record.consume) ~= "boolean" then return "consume is true or false" end
	if chars[record.char] then return "'" .. record.char .. "' is already a delimiter" end
	for _, entry in pairs(shipped) do
		for _, char in ipairs(entry.chars) do
			if char == record.char then return "'" .. record.char .. "' is already a delimiter" end
		end
	end
	return nil
end

--- Keeps the usable delimiter settings and names every unusable one.
--- @param states table|nil Key -> enabled.
--- @param custom table|nil Array of { key, char, label, consume } records.
--- @param reject function reject(path_segments, detail) for each unusable entry.
--- @param mark function|nil Cleanup mark(...segments) for each kept entry.
--- @return table settings { states = key -> boolean, custom = records }
local function keep_usable(states, custom, reject, mark)
	local shipped = builtins()
	local settings, keys, chars = { states = {}, custom = {} }, {}, {}
	for index, record in ipairs(custom or {}) do
		local detail = custom_refusal(record, shipped, keys, chars)
		if detail then
			reject(CUSTOM_PATH, "delimiter " .. index .. ": " .. detail)
		else
			keys[record.key], chars[record.char] = true, true
			settings.custom[#settings.custom + 1] = { key = record.key, char = record.char, label = record.label,
				consume = record.consume }
		end
	end
	if mark and custom ~= nil and (#settings.custom > 0 or #custom == 0) then mark(CUSTOM_PATH[1], CUSTOM_PATH[2]) end
	for key, enabled in pairs(states or {}) do
		local path = { STATES_PATH[1], STATES_PATH[2], tostring(key) }
		if type(key) ~= "string" or (not shipped[key] and not keys[key]) then
			reject(path, "no built-in or custom delimiter has this key")
		elseif type(enabled) ~= "boolean" then
			reject(path, "the value is not a boolean")
		else
			settings.states[key] = enabled
			if mark then mark(path[1], path[2], path[3]) end
		end
	end
	return settings
end

--- The default a delimiter has when config.toml says nothing about it.
--- @param key string Delimiter identity.
--- @param shipped table Result of builtins().
--- @return boolean
local function default_for(key, shipped)
	if shipped[key] then return shipped[key].default end
	return CUSTOM_DEFAULT
end




-- =========================================
-- =========================================
-- ======= 2/ Document =====================
-- =========================================
-- =========================================

local function file() return ConfigPaths.config("config.toml") end

--- Reads the delimiter settings of a decoded configuration.
--- @param document table Decoded config.toml.
--- @param mark function|nil Cleanup mark(...segments).
--- @return table settings { states, custom }
local function resolve(document, mark)
	assert(type(document) == "table", "word-delimiter settings need a decoded configuration")
	local hotstrings = ConfigOutdated.settings_table(document.hotstrings, { "hotstrings" }, Logger) or {}
	local states = ConfigOutdated.settings_table(hotstrings.terminator_states, STATES_PATH, Logger)
	local custom = hotstrings.terminators
	if custom ~= nil and (type(custom) ~= "table" or (next(custom) ~= nil and #custom == 0)) then
		ConfigOutdated.report(CUSTOM_PATH, "a list of delimiters is expected here", Logger)
		custom = nil
	end
	return keep_usable(states, custom, function(path, detail) ConfigOutdated.report(path, detail, Logger) end, mark)
end

--- Reads config.toml as it is now.
--- @return table document
--- @return table source Exact classified source for a conditional write.
local function read()
	local content, status, detail = Writer.read_classified(file())
	assert(status == "ok" or status == "absent", "word-delimiter settings are unreadable: " .. tostring(detail))
	local document = Codec.decode(content or "")
	assert(type(document) == "table", "word-delimiter settings are malformed")
	return document, { status = status, content = content }
end




-- =========================================
-- =========================================
-- ======= 3/ Runtime ======================
-- =========================================
-- =========================================

--- Makes the shared catalogue hold exactly these settings: the user's own
--- delimiters replaced, then every delimiter's state set in one publication.
--- @param settings table { states = key -> boolean, custom = records }
--- @return boolean applied
local function apply(settings)
	local stale = {}
	for _, def in ipairs(Terminators.get_terminator_defs()) do
		if def.key and def.custom == true then stale[#stale + 1] = def.key end
	end
	for _, key in ipairs(stale) do
		if Terminators.remove_custom_terminator(key) ~= true then return false end
	end
	for _, record in ipairs(settings.custom) do
		if Terminators.add_custom_terminator(record.key, record.char, record.label, record.consume) ~= true then
			return false
		end
	end
	local shipped, changes = builtins(), {}
	for _, def in ipairs(Terminators.get_terminator_defs()) do
		if def.key then
			local enabled = settings.states[def.key]
			if enabled == nil then enabled = default_for(def.key, shipped) end
			changes[def.key] = enabled
		end
	end
	return Terminators.set_terminators_enabled(changes) == true
end

--- The catalogue's current settings, every delimiter's state included.
--- @return table snapshot { states = key -> boolean, custom = records }
function M.snapshot()
	local snapshot = { states = {}, custom = {} }
	for _, def in ipairs(Terminators.get_terminator_defs()) do
		if def.key then
			snapshot.states[def.key] = Terminators.is_terminator_enabled(def.key)
			if def.custom == true then
				snapshot.custom[#snapshot.custom + 1] = { key = def.key, char = (def.chars or {})[1],
					label = def.label, consume = def.consume == true }
			end
		end
	end
	return snapshot
end

--- Reads config.toml into the catalogue. An unreadable or malformed file
--- leaves the catalogue as it is and returns false.
--- @return boolean loaded
function M.load()
	local called, settings = pcall(function() return resolve((read())) end)
	if not called then
		Logger.error(LOG, "Word-delimiter settings were not loaded: %s.", tostring(settings))
		return false
	end
	if not apply(settings) then
		Logger.error(LOG, "The word-delimiter catalogue refused the configured settings.")
		return false
	end
	local count = 0
	for _ in pairs(settings.states) do count = count + 1 end
	Logger.info(LOG, "Loaded %d word-delimiter state(s) and %d custom delimiter(s).", count, #settings.custom)
	return true
end

--- Makes a scope's validated candidate effective before its file is published.
--- @param document table Decoded configuration candidate.
--- @return boolean adopted
function M.adopt_configuration(document)
	local called, settings = pcall(resolve, document)
	if not called then
		Logger.error(LOG, "Candidate word-delimiter settings were refused: %s.", tostring(settings))
		return false
	end
	if not apply(settings) then
		Logger.error(LOG, "The word-delimiter catalogue refused the candidate settings.")
		return false
	end
	return true
end

--- Restores the exact runtime a scope captured before a refused publication.
--- @param snapshot table Result of M.snapshot().
--- @return boolean restored
function M.restore_configuration(snapshot)
	if type(snapshot) ~= "table" or type(snapshot.states) ~= "table" or type(snapshot.custom) ~= "table" then
		return false
	end
	return apply(snapshot)
end

--- Marks the delimiter settings the owner reads, for the unused-key cleanup.
--- @param document table Decoded config.toml.
--- @param mark function mark(...segments).
function M.mark_config_reads(document, mark)
	resolve(document, mark)
end

--- The leaves a document holds that return the delimiters to the catalogue
--- once removed: the state of every built-in or listed custom delimiter, and
--- the custom list. A state no delimiter owns is outdated configuration and is
--- left for the cleanup, like any other unknown entry.
--- @param document table Decoded config.toml.
--- @return table paths Array of path segments.
function M.owned_leaves(document)
	assert(type(document) == "table", "word-delimiter leaves need a decoded configuration")
	local hotstrings = type(document.hotstrings) == "table" and document.hotstrings or {}
	local custom = hotstrings.terminators
	local listed = type(custom) == "table" and (next(custom) == nil or #custom > 0)
	local owned = builtins()
	for _, record in ipairs(listed and custom or {}) do
		if type(record) == "table" and type(record.key) == "string" then owned[record.key] = true end
	end
	local paths, keys = {}, {}
	local states = hotstrings.terminator_states
	if type(states) == "table" and (next(states) == nil or #states == 0) then
		for key in pairs(states) do
			if type(key) == "string" and owned[key] then keys[#keys + 1] = key end
		end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do paths[#paths + 1] = { STATES_PATH[1], STATES_PATH[2], key } end
	if listed then paths[#paths + 1] = { CUSTOM_PATH[1], CUSTOM_PATH[2] } end
	return paths
end




-- =========================================
-- =========================================
-- ======= 4/ Persistence ==================
-- =========================================
-- =========================================

--- Whether two custom lists hold the same records in the same order.
--- @param left any Stored value.
--- @param right table Records.
--- @return boolean
local function same_records(left, right)
	if type(left) ~= "table" or #left ~= #right then return false end
	for index, record in ipairs(right) do
		local other = left[index]
		if type(other) ~= "table" then return false end
		for _, field in ipairs({ "key", "char", "label", "consume" }) do
			if other[field] ~= record[field] then return false end
		end
	end
	return true
end

--- The leaf operations that make a document hold the catalogue's settings.
--- @param document table Decoded config.toml.
--- @return table operations LeafRows operations.
local function plan(document)
	local current, shipped = M.snapshot(), builtins()
	local hotstrings = type(document.hotstrings) == "table" and document.hotstrings or {}
	local stored = type(hotstrings.terminator_states) == "table" and hotstrings.terminator_states or {}
	local owned, operations = {}, {}
	for key in pairs(current.states) do owned[key] = true end
	-- A custom delimiter the user removed still owns the state it left behind.
	for _, record in ipairs(type(hotstrings.terminators) == "table" and hotstrings.terminators or {}) do
		if type(record) == "table" and type(record.key) == "string" and record.key ~= "" then owned[record.key] = true end
	end
	local keys = {}
	for key in pairs(owned) do keys[#keys + 1] = key end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local wanted = current.states[key]
		if wanted == default_for(key, shipped) then wanted = nil end
		if stored[key] ~= wanted then
			local path = { STATES_PATH[1], STATES_PATH[2], key }
			if wanted == nil then
				operations[#operations + 1] = { path = path, delete = true }
			else
				operations[#operations + 1] = { path = path, value = wanted }
			end
		end
	end
	if #current.custom == 0 then
		if hotstrings.terminators ~= nil then operations[#operations + 1] = { path = CUSTOM_PATH, delete = true } end
	elseif not same_records(hotstrings.terminators, current.custom) then
		operations[#operations + 1] = { path = CUSTOM_PATH, value = current.custom }
	end
	return operations
end

--- Publishes the catalogue's current settings to config.toml, sparsely and
--- only over the exact bytes they were prepared from.
--- @return boolean committed
function M.persist()
	-- The hotstrings scope owns these leaves while it holds the preferences.
	if Preferences.is_acquired() then
		Logger.error(LOG, "Word-delimiter settings refused: a hotstring configuration scope is still pending.")
		return false
	end
	local called, committed, detail = pcall(function()
		local document, source = read()
		local operations = plan(document)
		if #operations == 0 then return true end
		local rows = LeafRows.prepare(source.content or "", operations)
		local directory = file():match("^(.*)/[^/]+$")
		if source.status == "absent" and not Shell.run("mkdir -p " .. Shell.quote(directory) .. " 2>/dev/null") then
			return false, "the configuration folder cannot be created"
		end
		return Writer.batch_write(file(), rows, nil, source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "Word-delimiter settings were not persisted: %s.", tostring(called and detail or committed))
		return false
	end
	return true
end

--- The config.toml leaves one set of delimiter settings amounts to, for an
--- import from an older store: sparse against the catalogue defaults, the
--- custom list first. Unusable entries are named through `reject`.
--- @param states table Key -> enabled.
--- @param custom table Array of { key, char, label, consume } records.
--- @param reject function reject(path_segments, detail).
--- @return table leaves Array of `{ path = segments, value, custom = boolean }`;
---   `custom` marks a leaf that only holds with the custom list it came with.
function M.leaves(states, custom, reject)
	assert(type(states) == "table" and type(custom) == "table" and type(reject) == "function",
		"word-delimiter leaves need states, custom records and a reject port")
	local settings, shipped = keep_usable(states, custom, reject), builtins()
	local leaves = {}
	if #settings.custom > 0 then
		leaves[#leaves + 1] = { path = { CUSTOM_PATH[1], CUSTOM_PATH[2] }, value = settings.custom, custom = true }
	end
	local keys = {}
	for key in pairs(settings.states) do keys[#keys + 1] = key end
	table.sort(keys)
	for _, key in ipairs(keys) do
		if settings.states[key] ~= default_for(key, shipped) then
			leaves[#leaves + 1] = { path = { STATES_PATH[1], STATES_PATH[2], key }, value = settings.states[key],
				custom = shipped[key] == nil }
		end
	end
	return leaves
end

return M
