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
--- 3. Only what the menu changed is written. A save compares the catalogue with
---    its state at the last read or write of config.toml and touches only the
---    leaves that differ, so a hand edit since then and an outdated entry left
---    for the cleanup survive an unrelated change.
--- 4. Outdated entries warn, never refuse. A state for an unknown key, a
---    non-boolean value or an unusable custom record is reported once through
---    the shared rule, read as absent and left for the config cleanup.
--- 5. Scope ownership. The hotstrings scope adopts its candidate document here
---    and restores the exact runtime snapshot on rollback; ordinary writes wait
---    while it holds the hotstring preferences.
--- ==============================================================================

local M = {}
local Terminators = require("keymap.terminators")
local TerminatorScope = require("hotstrings.terminator_scope")
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

-- The fields of one custom delimiter record, in the order they are compared.
local RECORD_FIELDS = { "key", "char", "label", "consume" }

-- The catalogue's settings at the last read or write of config.toml; nil until
-- the first read, when no save can know what the menu changed.
local _synced = nil




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
--- @return table admitted_indices Stored list positions owned by usable custom records.
local function keep_usable(states, custom, reject, mark)
	local shipped = builtins()
	local settings, keys, chars, admitted = { states = {}, custom = {} }, {}, {}, {}
	for index, record in ipairs(custom or {}) do
		local detail = custom_refusal(record, shipped, keys, chars)
		if detail then
			-- The record alone: reporting the list would offer every delimiter in
			-- it, the usable ones included, to the cleanup.
			reject({ CUSTOM_PATH[1], CUSTOM_PATH[2], index }, detail)
		else
			keys[record.key], chars[record.char], admitted[index] = true, true, true
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
	return settings, admitted
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
--- @return table admitted_indices Stored list positions owned by usable custom records.
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

--- Records the catalogue as config.toml now holds it, for the next save.
local function mark_synced()
	_synced = M.snapshot()
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
	local called, settings = pcall(function()
		local document = read()
		return resolve(document)
	end)
	if not called then
		Logger.error(LOG, "Word-delimiter settings were not loaded: %s.", tostring(settings))
		mark_synced()
		return false
	end
	if not apply(settings) then
		Logger.error(LOG, "The word-delimiter catalogue refused the configured settings.")
		mark_synced()
		return false
	end
	mark_synced()
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
	mark_synced()
	return true
end

--- Restores the exact runtime a scope captured before a refused publication.
--- @param snapshot table Result of M.snapshot().
--- @return boolean restored
function M.restore_configuration(snapshot)
	if type(snapshot) ~= "table" or type(snapshot.states) ~= "table" or type(snapshot.custom) ~= "table" then
		return false
	end
	if not apply(snapshot) then return false end
	mark_synced()
	return true
end

--- Marks the delimiter settings the owner reads, for the unused-key cleanup.
--- @param document table Decoded config.toml.
--- @param mark function mark(...segments).
function M.mark_config_reads(document, mark)
	resolve(document, mark)
end

--- The state leaves of the shipped delimiters a document holds: removing them
--- returns every built-in delimiter to its catalogue default. The user's own
--- delimiters and their states are user data and are never listed, like a
--- state no delimiter owns, which is outdated configuration for the cleanup.
--- @param document table Decoded config.toml.
--- @return table paths Array of path segments.
function M.builtin_state_leaves(document)
	return TerminatorScope.builtin_state_leaves(document)
end




-- =========================================
-- =========================================
-- ======= 4/ Persistence ==================
-- =========================================
-- =========================================

--- Whether two custom delimiter records are the same.
--- @param left any
--- @param right any
--- @return boolean
local function same_record(left, right)
	if type(left) ~= "table" or type(right) ~= "table" then return false end
	for _, field in ipairs(RECORD_FIELDS) do
		if left[field] ~= right[field] then return false end
	end
	return true
end

--- Whether a stored custom list already holds these entries, in order.
--- @param stored any Stored value.
--- @param list table Entries to write.
--- @return boolean
local function same_list(stored, list)
	if type(stored) ~= "table" or #stored ~= #list then return false end
	for index, entry in ipairs(list) do
		if stored[index] ~= entry and not same_record(stored[index], entry) then return false end
	end
	return true
end

--- Indexes custom delimiter records by key.
--- @param records table
--- @return table
local function by_key(records)
	local out = {}
	for _, record in ipairs(records) do out[record.key] = record end
	return out
end

--- The leaf operations that write what changed in the catalogue since config.toml
--- was last read or written, and nothing else.
--- @param document table Decoded config.toml as it is now.
--- @param current table The catalogue now (M.snapshot()).
--- @param synced table The catalogue at the last sync.
--- @return table operations LeafRows operations.
local function plan(document, current, synced)
	local shipped = builtins()
	local hotstrings = type(document.hotstrings) == "table" and document.hotstrings or {}
	local stored_states = type(hotstrings.terminator_states) == "table" and hotstrings.terminator_states or {}
	local operations, keys, seen = {}, {}, {}
	for _, states in ipairs({ current.states, synced.states }) do
		for key in pairs(states) do
			if not seen[key] and current.states[key] ~= synced.states[key] then
				seen[key] = true
				keys[#keys + 1] = key
			end
		end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		-- A removed user delimiter takes its state with it; a default leaves no key.
		local wanted = current.states[key]
		if wanted == default_for(key, shipped) then wanted = nil end
		if stored_states[key] ~= wanted then
			local path = { STATES_PATH[1], STATES_PATH[2], key }
			if wanted == nil then
				operations[#operations + 1] = { path = path, delete = true }
			else
				operations[#operations + 1] = { path = path, value = wanted }
			end
		end
	end
	local was, now = by_key(synced.custom), by_key(current.custom)
	local changed = #synced.custom ~= #current.custom
	for _, record in ipairs(current.custom) do
		if not same_record(was[record.key], record) then changed = true end
	end
	if not changed then return operations end
	local stored = hotstrings.terminators
	local listed = type(stored) == "table" and (next(stored) == nil or #stored > 0)
	local _, admitted = resolve(document)
	local list, placed = {}, {}
	for index, entry in ipairs(listed and stored or {}) do
		local key = type(entry) == "table" and entry.key or nil
		if admitted[index] and type(key) == "string" and was[key] then
			-- Only the occurrence admitted by the reader belongs to the catalogue.
			-- A delimiter the catalogue holds: dropped if the menu removed it,
			-- rewritten if the menu changed it, otherwise kept as written.
			if now[key] and not placed[key] then
				list[#list + 1] = same_record(was[key], now[key]) and entry or now[key]
				placed[key] = true
			end
		else
			-- An unusable record, or one added by hand since, stays as written.
			list[#list + 1] = entry
			-- An unusable same-key record cannot hide its admitted neighbor.
			if type(key) == "string" and not was[key] then placed[key] = true end
		end
	end
	for _, record in ipairs(current.custom) do
		if not placed[record.key] and not same_record(was[record.key], record) then list[#list + 1] = record end
	end
	-- Retaining a formerly unusable occurrence can hide a pending Add, either
	-- by key or by character. Prove the delta against the real reader before
	-- an empty plan acknowledges it or the writer publishes a masked record.
	local candidate, candidate_hotstrings = {}, {}
	for key, value in pairs(document) do candidate[key] = value end
	for key, value in pairs(hotstrings) do candidate_hotstrings[key] = value end
	candidate_hotstrings.terminators = list
	candidate.hotstrings = candidate_hotstrings
	local effective = by_key(resolve(candidate).custom)
	for _, record in ipairs(current.custom) do
		if not same_record(was[record.key], record) then
			assert(same_record(effective[record.key], record),
				"the pending custom delimiter is hidden by a retained record")
		end
	end
	if #list == 0 then
		if stored ~= nil then operations[#operations + 1] = { path = CUSTOM_PATH, delete = true } end
	elseif not same_list(stored, list) then
		operations[#operations + 1] = { path = CUSTOM_PATH, value = list }
	end
	return operations
end

--- Publishes what the menu changed in the catalogue since config.toml was last
--- read or written, sparsely and only over the exact bytes it was prepared from.
--- @return boolean committed
function M.persist()
	-- The hotstrings scope owns these leaves while it holds the preferences.
	if Preferences.is_acquired() then
		Logger.error(LOG, "Word-delimiter settings refused: a hotstring configuration scope is still pending.")
		return false
	end
	if _synced == nil then
		Logger.error(LOG, "Word-delimiter settings refused: they were never read from config.toml.")
		return false
	end
	local current = M.snapshot()
	local called, committed, detail = pcall(function()
		local document, source = read()
		local operations = plan(document, current, _synced)
		if #operations == 0 then return true end
		-- The shared writer replaces the complete list, including a table-array
		-- spelling; it still rejects attempts to address an individual element.
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
	_synced = current
	return true
end

--- The config.toml leaves one set of delimiter settings amounts to, for an
--- import from an older store: sparse against the catalogue defaults, the
--- custom list first. Unusable entries are named through `reject`. A custom
--- delimiter whose character a shipped delimiter now owns cannot be kept, but
--- its state belongs to that character: the shipped delimiter takes it, unless
--- the store recorded a state for the shipped delimiter too.
--- @param states table Key -> enabled.
--- @param custom table Array of { key, char, label, consume } records.
--- @param reject function reject(path_segments, detail).
--- @return table leaves Array of `{ path = segments, value, custom = boolean }`;
---   `custom` marks a leaf that only holds with the custom list it came with.
function M.leaves(states, custom, reject)
	assert(type(states) == "table" and type(custom) == "table" and type(reject) == "function",
		"word-delimiter leaves need states, custom records and a reject port")
	local shipped, carried, owner_of = builtins(), {}, {}
	for key, entry in pairs(shipped) do
		for _, char in ipairs(entry.chars) do owner_of[char] = key end
	end
	for key, enabled in pairs(states) do carried[key] = enabled end
	for _, record in ipairs(custom) do
		local owner = type(record) == "table" and owner_of[record.char] or nil
		if owner and not shipped[record.key] and carried[owner] == nil and type(states[record.key]) == "boolean" then
			carried[owner] = states[record.key]
		end
	end
	local settings = keep_usable(carried, custom, reject)
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
