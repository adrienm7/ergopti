--- modules/keymap/registry_groups.lua

--- ==============================================================================
--- MODULE: Keymap Registry — Group Loaders & Lifecycle
--- DESCRIPTION:
--- Handles group registration, file loading (Lua and TOML), group enable/disable,
--- and group-context management for the keymap registry.
--- Initialized by registry.lua via Groups.init(state, callbacks) so that all
--- group-level operations share the same CoreState and rebuild helpers without
--- circular dependencies.
---
--- FEATURES & RATIONALE:
--- 1. Extraction: Keeps the heavy group-loading logic (TOML parser, section
---    enable/disable, priority cascade) out of the monolithic registry.lua so
---    each concern lives in a focused module.
--- 2. Callback Bridge: Receives sort_mappings, add, is_section_enabled,
---    resolve_priority, rebuild_lookup, and rebuild_tail_indexes as callbacks
---    from registry.lua so the extracted functions keep identical behaviour
---    without introducing a reverse dependency.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

local PersonalFiles = require("hotstrings.personal_files")
local LOG = "keymap.registry"

local _delay_resolver = nil
local _state     = nil
local _callbacks = nil  -- {add, sort_mappings, is_section_enabled, resolve_priority, rebuild_lookup, rebuild_tail_indexes}
local _publication_epoch = 0
local _publication_owner
local _owned_rebuild

--- Advances a token that journal rollback never rewinds.
--- @param kind string|nil Exact derived callback, or a committed source mutation.
function M.note_registry_mutation(kind)
	if _owned_rebuild ~= nil and kind == _owned_rebuild then return end
	_publication_epoch = _publication_epoch + 1
end

--- Guard: verifies that M.init() was called before any public function.
--- @param func_name string Name of the calling function (for error messages).
--- @return boolean True if _state is ready, false otherwise.
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end

--- Receives the shared state and rebuild callbacks from registry.lua.
--- Must be called exactly once, from within registry.lua'·s M.init().
--- @param state table The shared CoreState.
--- @param callbacks table {add, sort_mappings, is_section_enabled, resolve_priority, rebuild_lookup, rebuild_tail_indexes}.
--- Required callback names. Validated once at init rather than checked at each
--- call site: every caller of disable_group wraps it in pcall, so a missing
--- callback would throw AFTER the group was marked disabled and its mappings
--- purged, leaving exactly the half-disabled state this module's guards exist to
--- forbid — and the pcall would swallow the reason. A guard per call site would
--- also be the silent fallback convention 5.3/5.4 forbids.
local REQUIRED_CALLBACKS = {
	"add", "sort_mappings", "is_section_enabled", "resolve_priority",
	"rebuild_lookup", "rebuild_tail_indexes", "drop_classify_cache",
}

--- Copies one array without cloning the mapping objects it owns.
--- Reloads replace a group's mapping objects; mappings owned by other groups are
--- immutable during the transaction and must retain their identity on rollback.
--- @param source table
--- @return table
local function copy_array(source)
	local out = {}
	for i, value in ipairs(source or {}) do out[i] = value end
	return out
end

--- Returns string keys in deterministic byte order.
--- Modern TOML sections may arrive as plain maps, so their hash iteration order
--- must never feed the registry sequence used to break otherwise-equal ties.
--- @param source table
--- @return table
local function sorted_string_keys(source)
	local keys = {}
	for key in pairs(source or {}) do
		if type(key) == "string" then keys[#keys + 1] = key end
	end
	table.sort(keys)
	return keys
end

--- Copies a map one level deep.
--- @param source table
--- @return table
local function copy_map(source)
	local out = {}
	for key, value in pairs(source or {}) do out[key] = value end
	return out
end

--- Copies a two-level ownership map without retaining mutable child aliases.
--- @param source table|nil
--- @return table
local function copy_nested_map(source)
	local out = {}
	for owner, values in pairs(source or {}) do
		out[owner] = type(values) == "table" and copy_map(values) or values
	end
	return out
end

--- Copies group records while retaining their immutable section descriptors.
--- @param source table
--- @return table
local function copy_groups(source)
	local out = {}
	for name, group in pairs(source or {}) do
		out[name] = copy_map(group)
	end
	return out
end

--- Captures every registry field a loader or lifecycle hook may mutate.
--- @return table
local function snapshot_registry()
	local mapping_values = {}
	for _, mapping in ipairs(_state.mappings or {}) do
		mapping_values[mapping] = copy_map(mapping)
	end
	return {
		mappings                   = copy_array(_state.mappings),
		mapping_values             = mapping_values,
		groups                     = copy_groups(_state.groups),
		group_post_load_hooks      = copy_map(_state.group_post_load_hooks),
		section_delays             = copy_nested_map(_state.SECTION_DELAYS),
		seq_counter                = _state.seq_counter,
		group_order_counter        = _state.group_order_counter,
		current_group              = _state.current_group,
		word_timeout               = _state.WORD_TIMEOUT_SEC,
		delay_resolver             = _delay_resolver,
	}
end

--- Restores a registry snapshot after a failed transaction.
--- @param snapshot table
local function restore_registry(snapshot, strict)
	-- A direct loader can refresh an existing entry in place before a later
	-- entry throws. Restore those table values before reattaching the old indexes,
	-- because every index intentionally points at the same mapping objects.
	for mapping, values in pairs(snapshot.mapping_values) do
		for key in pairs(mapping) do mapping[key] = nil end
		for key, value in pairs(values) do mapping[key] = value end
	end
	_state.mappings                   = snapshot.mappings
	_state.groups                     = snapshot.groups
	_state.group_post_load_hooks      = snapshot.group_post_load_hooks
	_state.SECTION_DELAYS             = snapshot.section_delays
	_state.seq_counter                = snapshot.seq_counter
	_state.group_order_counter        = snapshot.group_order_counter
	_state.current_group              = snapshot.current_group
	_state.WORD_TIMEOUT_SEC           = snapshot.word_timeout
	_delay_resolver                  = snapshot.delay_resolver
	-- Failed helpers may replace any index table before failing. Rebuild every
	-- derived structure from the restored corpus instead of retaining aliases to
	-- tables that the attempted mutation could have modified in place.
	local function rebuild(kind, callback)
		if strict then _owned_rebuild = kind end
		local called, accepted = pcall(callback)
		_owned_rebuild = nil
		return called and (not strict or accepted == true), accepted
	end
	local lookup_ok, lookup_err = rebuild("lookup", _callbacks.rebuild_lookup)
	local tail_ok, tail_err = rebuild("tail", _callbacks.rebuild_tail_indexes)
	if not lookup_ok or not tail_ok then
		Logger.error(LOG, "Registry rollback could not rebuild indexes: %s / %s.",
			tostring(lookup_err), tostring(tail_err))
	end
	-- A cache cleared by the failed mutation is harmless; a cache populated for
	-- its temporary corpus is not. Always discard it after restoring the corpus.
	local ok, err = rebuild("cache", _callbacks.drop_classify_cache)
	if not ok then
		Logger.error(LOG, "Registry rollback could not clear the classification cache: %s.", tostring(err))
	end
	return lookup_ok and tail_ok and ok
end

local function copy_image(value, seen)
	if type(value) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local copy = {}; seen[value] = copy
	for key, child in pairs(value) do copy[key] = copy_image(child, seen) end
	return copy
end

local function same_image(actual, expected, seen)
	if type(actual) ~= type(expected) then return false end
	if type(actual) ~= "table" then return actual == expected end
	seen = seen or {}
	if seen[expected] then return seen[expected] == actual end
	seen[expected] = actual
	for key, value in pairs(expected) do if not same_image(actual[key], value, seen) then return false end end
	for key in pairs(actual) do if expected[key] == nil then return false end end
	return true
end

--- Captures native image evidence independently of the rollback's copied roots.
local function image_guard(include_indexes)
	local state, epoch = _state, _publication_epoch
	local mappings, groups = state.mappings, state.groups
	local group_objects, values = copy_map(groups), copy_image(snapshot_registry())
	local mapping_objects = copy_array(mappings)
	local magic, lifecycle = state.magic_key, state.lifecycle_generation
	local indexes = include_indexes and { state.mappings_lookup, state.mappings_by_tail_char,
		state.mappings_by_star_tail_char, state.mappings_by_first_char, state.mappings_by_literal_magic_tail } or nil
	return function()
		if _state ~= state or _publication_epoch ~= epoch or state.mappings ~= mappings or state.groups ~= groups
			or state.magic_key ~= magic or state.lifecycle_generation ~= lifecycle then return false end
		for name, group in pairs(group_objects) do if groups[name] ~= group then return false end end
		for name in pairs(groups) do if group_objects[name] == nil then return false end end
		for index, mapping in ipairs(mapping_objects) do if mappings[index] ~= mapping then return false end end
		if #mappings ~= #mapping_objects or not same_image(snapshot_registry(), values) then return false end
		if indexes then
			return indexes[1] == state.mappings_lookup and indexes[2] == state.mappings_by_tail_char
				and indexes[3] == state.mappings_by_star_tail_char and indexes[4] == state.mappings_by_first_char
				and indexes[5] == state.mappings_by_literal_magic_tail
		end
		return true
	end
end

--- Owns one personal publication journal and its acknowledged private inverse.
--- Captured image equality checks revocation; only this journal's actual restore
--- acknowledgement admits copied rollback records to the returned owner.
--- @return table|nil owner Bound run/capture_current/current/retry_inverse methods.
function M.capture_publication_owner()
	if not require_state("capture_publication_owner") or _publication_owner ~= nil then return nil end
	local original_current = image_guard(true)
	local original = snapshot_registry()
	original.groups = copy_image(original.groups)
	for mapping, values in pairs(original.mapping_values) do original.mapping_values[mapping] = copy_image(values) end
	local owner = { state = _state, original = original, phase = "captured", used = false }
	local function current()
		return _state == owner.state and owner.guard ~= nil and owner.guard() == true
	end
	local function inverse()
		if not owner.used then return owner.phase == "captured" end
		if owner.phase == "restored" then return current() end
		if _publication_owner ~= owner or not current() then return false end
		owner.phase = "restoring"
		M.note_registry_mutation()
		local token = _publication_epoch
		local restored = restore_registry(owner.original, true)
		-- No callback may attach a foreign generation, even when its visible
		-- result happens to equal the private preimage.
		if _state ~= owner.state or _publication_epoch ~= token then owner.guard = nil; return false end
		if not same_image(snapshot_registry(), owner.original) then owner.guard = nil; return false end
		owner.guard = image_guard(restored)
		if restored ~= true then return false end
		owner.phase = "restored"
		return current()
	end
	local function capture_current()
		if _publication_owner ~= owner or owner.phase ~= "staging" then return false end
		owner.guard, owner.phase = image_guard(true), "publishing"
		return current()
	end
	local function run(mutation)
		if owner.used or owner.phase ~= "captured" or type(mutation) ~= "function"
			or _publication_owner ~= nil or not original_current() then return false end
		owner.used, owner.phase, _publication_owner = true, "staging", owner
		local called, committed = xpcall(mutation, debug.traceback)
		if owner.phase == "staging" then capture_current() end
		if called and committed == true and not owner.refused and current() then
			owner.phase = "committed"
			return true
		end
		inverse()
		return false
	end
	local function release()
		if not owner.used and owner.phase == "captured" then owner.phase = "released"; return true end
		if _publication_owner ~= owner or (owner.phase ~= "restored" and owner.phase ~= "committed")
			or not current() then return false end
		_publication_owner, owner.guard, owner.phase = nil, nil, "released"
		M.note_registry_mutation()
		return true
	end
	return { run = run, capture_current = capture_current, current = current, retry_inverse = inverse, release = release }
end

--- Executes one all-or-nothing registry mutation.
--- The callback must return exact true; nil is a refusal, never implicit success.
--- @param label string
--- @param mutation function
--- @return boolean committed
local function run_transaction(label, mutation)
	M.note_registry_mutation()
	if _publication_owner and _publication_owner.phase == "staging" then
		local ok, committed = xpcall(mutation, debug.traceback)
		if ok and committed == true then return true end
		_publication_owner.refused = true
		return false
	end
	local snapshot = snapshot_registry()
	local ok, committed = xpcall(mutation, debug.traceback)
	if ok and committed == true then return true end
	restore_registry(snapshot)
	Logger.error(LOG, "Registry mutation '%s' rolled back "
		.. "(details withheld; terminal type: %s).", tostring(label), type(committed))
	return false
end

--- Projects one committed override source onto registered TOML delay owners.
--- The existing registry transaction restores its caches when publication refuses.
--- @param resolve function Resolves (group, section, corpus metadata) to seconds.
--- @param publish function Publishes the exact candidate source, returning true.
--- @return boolean committed
function M.with_hotstring_delays(resolve, publish)
	if not require_state("with_hotstring_delays") then return false end
	if type(resolve) ~= "function" or type(publish) ~= "function" then return false end
	local owned = _publication_owner and _publication_owner.phase == "staging" and _publication_owner
	local committed = run_transaction("hotstring delay projection", function()
		for name, group in pairs(_state.groups) do
			if group.enabled and group.kind == "toml" then
				local delays = {}
				for _, section in ipairs(group.sections or {}) do
					if section.name ~= "-" and not section.is_module_placeholder then
						local delay = resolve(name, section.name, group.delay_metadata or {})
						assert(type(delay) == "number" and delay == delay and delay >= 0 and delay < math.huge,
							"hotstring delay projection must be finite and non-negative")
						delays[section.name] = delay
					end
				end
				_state.SECTION_DELAYS[name] = delays
				group.delay_resolved = true
			end
		end
		_state.recompute_word_timeout()
		return publish() == true
	end)
	if committed then
		local admitted = owned and _publication_owner == owned and owned.phase == "publishing" and owned.guard() == true
		_delay_resolver = resolve
		if admitted then owned.guard = image_guard(true) else M.note_registry_mutation() end
	end
	return committed
end


--- Deep-copies corpus metadata so a caller cannot reach the registered record.
--- @param value any Plain Lua data.
--- @return any copy
local function copy_plain(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for key, child in pairs(value) do out[key] = copy_plain(child) end
	return out
end

--- Returns the delay inputs of every registered TOML group, detached: its
--- section names (separators and placeholders excluded) and the corpus
--- metadata the delay projection resolves against. A disabled group keeps the
--- metadata of its last registration, which is what re-enabling it reads.
--- @return table|nil inventory { [name] = { sections = { string }, metadata = table } }
function M.hotstring_delay_inventory()
	if not require_state("hotstring_delay_inventory") then return nil end
	local inventory = {}
	for name, group in pairs(_state.groups) do
		if group.kind == "toml" then
			local sections = {}
			for _, section in ipairs(group.sections or {}) do
				if section.name ~= "-" and not section.is_module_placeholder then sections[#sections + 1] = section.name end
			end
			inventory[name] = { sections = sections, metadata = copy_plain(group.delay_metadata or {}) }
		end
	end
	return inventory
end

--- Replaces one group's complete section-delay ownership and resizes the word timeout.
--- Passing nil removes the owner; outer multi-step mutations provide rollback.
--- @param name string
--- @param delays table|nil
local function replace_group_section_delays(name, delays)
	_state.SECTION_DELAYS[name] = delays
	if type(_state.recompute_word_timeout) == "function" then
		_state.recompute_word_timeout()
	end
end

--- Injects the shared state and the registry's callback table.
--- @param state table The shared CoreState.
--- @param callbacks table Must provide every name in REQUIRED_CALLBACKS.
--- @return boolean committed True only when the requested dependencies are active.
function M.init(state, callbacks)
	if _state then
		local same_dependencies = state == _state and type(callbacks) == "table"
		for _, name in ipairs(REQUIRED_CALLBACKS) do
			same_dependencies = same_dependencies and callbacks[name] == _callbacks[name]
		end
		if same_dependencies then
			Logger.warn(LOG, "M.init() called more than once with the active dependencies — ignoring duplicate call.")
			return true
		end
		Logger.error(LOG, "M.init(): different dependencies are already active — replacement refused.")
		return false
	end
	if type(state) ~= "table" then
		Logger.error(LOG, "M.init(): state must be a table — initialization refused.")
		return false
	end
	local missing = {}
	for _, name in ipairs(REQUIRED_CALLBACKS) do
		if type(callbacks) ~= "table" or type(callbacks[name]) ~= "function" then
			table.insert(missing, name)
		end
	end
	if #missing > 0 then
		Logger.error(LOG, "M.init(): missing callback(s) %s — initialization refused.",
			table.concat(missing, ", "))
		return false
	end
	_state     = state
	_callbacks = callbacks
	return true
end

--- Runs a multi-step mutation against one shared registry snapshot.
--- Used by section batches so settings and every affected group commit together.
--- @param label string
--- @param mutation function
--- @return boolean committed
function M.transaction(label, mutation)
	if not require_state("transaction") then return false end
	if type(mutation) ~= "function" then
		Logger.error(LOG, "transaction: mutation must be a function.")
		return false
	end
	return run_transaction(label, mutation)
end





-- ================================
-- ================================
-- ======= 1/ Group Loaders =======
-- ================================
-- ================================

--- Records the group entry after a successful load, preserving the stable
--- group_order across reload cycles so sort tiebreaker stays stable (B3.6):
--- disable_group + enable_group must not change the relative priority of
--- same-length triggers.
--- @param name string Group identifier.
--- @param path string|nil File path (nil for programmatic groups).
--- @param kind string "lua" or "toml".
local function record_group(name, path, kind)
	local existing = _state.groups[name]
	local group_order = (existing and existing.group_order)
		or (_state.group_order_counter or 0) + 1
	if not existing or not existing.group_order then
		_state.group_order_counter = group_order
	end
	_state.groups[name] = {
		path        = path,
		enabled     = true,
		kind        = kind or "lua",
		group_order = group_order,
	}
end

--- Ensures a group entry exists with a stable `group_order` before any of
--- its mappings are added via add_raw. Called from the start of load_file /
--- load_toml so that each entry can store the stable order at insertion time
--- instead of having to back-fill it after record_group runs. Preserves any
--- existing group_order on reload.
--- @param name string Group identifier.
local function ensure_group_order(name)
	if not _state or not name or name == "" then return end
	_state.group_order_counter = _state.group_order_counter or 0
	local g = _state.groups[name]
	if g and g.group_order then return end
	_state.group_order_counter = _state.group_order_counter + 1
	if g then
		g.group_order = _state.group_order_counter
	else
		_state.groups[name] = {
			path        = nil,
			enabled     = true,
			kind        = "pending",
			group_order = _state.group_order_counter,
		}
	end
end

--- Loads mappings from a Lua file via dofile and records the group.
--- @param name string Group identifier used as the key in _state.groups.
--- @param path string Absolute path to the Lua hotstring file.
function M.load_file(name, path)
	if not require_state("load_file") then return false end
	if type(name) ~= "string" or name == "" then
		Logger.error(LOG, "load_file: name must be a non-empty string."); return false
	end
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "load_file: path must be a non-empty string."); return false
	end

	return run_transaction("load_file:" .. name, function()
		Logger.start(LOG, "Loading Lua mapping file '%s'…", name)
		ensure_group_order(name)
		_state.current_group = name

		local ok, err = pcall(dofile, path)
		if not ok then
			Logger.error(LOG, "Error loading '%s': %s.", path, tostring(err))
			return false
		end

		_state.current_group = nil
		record_group(name, path, "lua")
		replace_group_section_delays(name, nil)
		_callbacks.sort_mappings()
		Logger.success(LOG, "Lua mapping file '%s' loaded (%d total mapping(s)).", name, #_state.mappings)
		return true
	end)
end

--- Whether a section-source list has the shape load_toml takes.
--- @param section_sources any
--- @return boolean
local function valid_section_sources(section_sources)
	if section_sources == nil then return true end
	if type(section_sources) ~= "table" then return false end
	for _, source in ipairs(section_sources) do
		if type(source) ~= "table" or type(source.path) ~= "string" or source.path == ""
			or type(source.sections) ~= "table" or #source.sections == 0 then
			return false
		end
		for _, section in ipairs(source.sections) do
			if type(section) ~= "string" or section == "" then return false end
		end
	end
	return true
end

--- A parse whose sections other files supply: a layout extension binds some
--- sections of a bundled category to its own file. The category's general
--- metadata stays the bundled file's; each bound section, with its own section
--- metadata, comes from the extension file. The parse is copied, never edited:
--- the reader may hand back a cached snapshot shared with other readers.
--- @param data table Parse of the bundled file.
--- @param section_sources table Array of { path, sections }.
--- @param toml_reader table The TOML reader.
--- @return table|nil merged
--- @return string|nil err
local function merge_section_sources(data, section_sources, toml_reader)
	local meta = {}
	for key, value in pairs(type(data.meta) == "table" and data.meta or {}) do meta[key] = value end
	local meta_sections, section_delays = {}, {}
	for key, value in pairs(type(meta.sections) == "table" and meta.sections or {}) do meta_sections[key] = value end
	for key, value in pairs(type(meta.section_delays) == "table" and meta.section_delays or {}) do
		section_delays[key] = value
	end
	meta.sections, meta.section_delays = meta_sections, section_delays
	local sections, order, placed = {}, {}, {}
	for key, value in pairs(type(data.sections) == "table" and data.sections or {}) do sections[key] = value end
	local declared = (data.sections_order and #data.sections_order > 0) and data.sections_order
		or (type(data.meta) == "table" and data.meta.sections_order or {})
	for _, name in ipairs(declared) do
		order[#order + 1] = name
		placed[name] = true
	end
	for _, source in ipairs(section_sources) do
		local ok, bound, committed = pcall(toml_reader.parse, source.path)
		if not ok or type(bound) ~= "table" or committed ~= true then
			return nil, "cannot parse the bound file '" .. source.path .. "': " .. tostring(bound)
		end
		local bound_meta = type(bound.meta) == "table" and bound.meta or {}
		for _, name in ipairs(source.sections) do
			local section = type(bound.sections) == "table" and bound.sections[name] or nil
			if section == nil then
				return nil, "the bound file '" .. source.path .. "' carries no section '" .. name .. "'"
			end
			sections[name] = section
			meta_sections[name] = type(bound_meta.sections) == "table" and bound_meta.sections[name] or nil
			section_delays[name] = type(bound_meta.section_delays) == "table" and bound_meta.section_delays[name] or nil
			if not placed[name] then
				order[#order + 1] = name
				placed[name] = true
			end
		end
	end
	-- Bound files retain the existing binding owner's declared section order.
	-- This is ephemeral provenance, never a TOML metadata or preference field.
	return { meta = meta, sections = sections, sections_order = order, registration_order = "sections" }
end

--- Loads and parses mappings from a TOML configuration file.
--- Skips sections the user has disabled, per _callbacks.is_section_enabled
--- (the persisted enable/disable state itself is owned by registry_index.lua).
--- @param name string Group identifier used as the key in _state.groups.
--- @param path string Absolute path to the TOML file.
--- @param section_sources table|nil Sections other files supply, as { path,
---   sections } records; kept with the group so every reload reads them again.
function M.load_toml(name, path, section_sources, personal_source, source_content, resolution)
	if not require_state("load_toml") then return false end
	if type(name) ~= "string" or name == "" then
		Logger.error(LOG, "load_toml: name must be a non-empty string."); return false
	end
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "load_toml: path must be a non-empty string."); return false
	end
	if not valid_section_sources(section_sources) then
		Logger.error(LOG, "load_toml: section sources must be { path, sections } records."); return false
	end

	if personal_source ~= nil and not PersonalFiles.is_descriptor(personal_source) then
		Logger.error(LOG, "load_toml: personal source descriptor is invalid.")
		return false
	end
	local owned_source = personal_source and PersonalFiles.copy(personal_source) or nil
	if source_content ~= nil then
		local current = _state.groups[name]
		if type(source_content) ~= "string" or not PersonalFiles.components(name) or not current
			or current.path ~= path or not PersonalFiles.is_descriptor(current.personal_source)
			or current.personal_source.id ~= name then return false end
	end
	if resolution ~= nil and (source_content == nil or type(resolution) ~= "table"
		or type(resolution.priority_reader) ~= "function" or type(resolution.delay_resolver) ~= "function") then return false end
	return run_transaction("load_toml:" .. name, function()
		Logger.start(LOG, "Loading TOML mapping file '%s'…", name)

		local toml_reader       = require("infra.toml.reader")
		local ok, data, committed
		if source_content ~= nil then
			ok, data, committed = pcall(require("toml_codec.reader").parse_text, source_content)
		else
			ok, data, committed = pcall(toml_reader.parse, path)
		end
		if not ok or type(data) ~= "table" or committed ~= true then
			Logger.error(LOG, "Failed to parse TOML '%s': %s.", path, tostring(data))
			return false
		end
		if section_sources ~= nil then
			local merged, merge_err = merge_section_sources(data, section_sources, toml_reader)
			if not merged then
				Logger.error(LOG, "TOML group '%s' cannot take its bound sections: %s.", name, merge_err)
				return false
			end
			data = merged
		end
		if name == "autocorrection" then
			local ok_owner, owner = pcall(require, "modules.hotstrings.hotstrings_config")
			if ok_owner and type(owner.common_autocorrection_admitted) == "function"
				and owner.common_autocorrection_admitted() == false then
				for section in pairs(data.sections or {}) do
					if _callbacks.is_section_enabled(name, section) then
						Logger.error(LOG, "Common autocorrection overrides are unadmitted; the registry was not replaced.")
						return false
					end
				end
			end
		end

	ensure_group_order(name)
	-- Snapshot before registering so the success line can report what THIS file
	-- contributed rather than the size of the whole corpus.
	local mappings_before = #_state.mappings
	_state.current_group = name
	local sections_info  = {}
	local registrations = {}

	-- Collision-priority cascade inputs (individual > section > file > source).
	-- The shared user-override file (hotstrings_config.toml) sits ABOVE the TOML
	-- [_meta], mirroring how the AHK engine reads HotstringsResolve: the order is
	-- user-section > user-file > meta-section > meta-file > source default. The
	-- override module is required lazily (it does not require us, but stay defensive
	-- against load order / headless tests where it may be absent — gotcha G6).
	local ok_hcfg, hcfg = pcall(require, "modules.hotstrings.hotstrings_config")
	local hotstrings_config = ok_hcfg and hcfg or nil
	local function user_priority(section_name)
		if resolution then return resolution.priority_reader(section_name) end
		if not hotstrings_config or type(hotstrings_config.get_user_override) ~= "function" then
			return nil
		end
		local ok_ov, ov = pcall(hotstrings_config.get_user_override, name, section_name)
		return (ok_ov and type(ov) == "table") and ov.priority or nil
	end
	local file_user_priority = user_priority(nil)
	local file_meta_priority = (type(data.meta) == "table" and type(data.meta.priority) == "number")
		and data.meta.priority or nil
	local meta_sections = (type(data.meta) == "table" and type(data.meta.sections) == "table")
		and data.meta.sections or {}

	local sections_order = (data.sections_order and #data.sections_order > 0)
		and data.sections_order
		or  (data.meta and data.meta.sections_order or {})

	for _, sec_name in ipairs(sections_order) do
		if sec_name == "-" then
			table.insert(sections_info, { name = "-", description = "-", count = 0 })
			goto continue_sec
		end

		local sec = data.sections and data.sections[sec_name]
		if not sec then goto continue_sec end

		if sec.is_placeholder then
			table.insert(sections_info, {
				name                = sec_name,
				description         = sec.description,
				count               = 0,
				is_module_placeholder = true,
			})
			goto continue_sec
		end

		local entries = {}
		local count = 0
		if type(sec.entries) == "table" then
			-- Legacy format: [[section]] entries = [...]
			entries = sec.entries
			count = #entries
		else
			-- Modern format: [[section]] followed by key = value pairs
			-- or [section] table.
			for _, k in ipairs(sorted_string_keys(sec)) do
				local v = sec[k]
				if type(k) == "string" and k ~= "description" and k ~= "is_placeholder" then
					count = count + 1
					if type(v) == "table" then
						table.insert(entries, {
							trigger           = k,
							output            = v.output,
							is_word           = v.is_word,
							auto_expand       = v.auto_expand,
							is_case_sensitive = v.is_case_sensitive,
							-- Selects EXACT matching, where is_case_sensitive above only
							-- selects literal registration. Omitting it here left the
							-- registry unable to tell the two apart.
							is_case_sensitive_strict = v.is_case_sensitive_strict,
							final_result      = v.final_result,
							priority          = v.priority,
						})
					else
						table.insert(entries, {
							trigger = k,
							output  = tostring(v),
						})
					end
				end
			end
		end

		if _callbacks.is_section_enabled(name, sec_name) then
			-- Flatten the user/TOML layers into one effective override priority so
			-- the order matches AHK exactly (user-section > user-file > meta-section
			-- > meta-file). The individual per-entry priority and the source default
			-- are applied above/below it by resolve_priority.
			local sec_meta = meta_sections[sec_name]
			local sec_meta_priority = (type(sec_meta) == "table" and type(sec_meta.priority) == "number")
				and sec_meta.priority or nil
			local override_priority = user_priority(sec_name) or file_user_priority
				or sec_meta_priority or file_meta_priority
			registrations[sec_name] = {}
			for index, entry in ipairs(entries) do
				registrations[sec_name][index] = { entry = entry, options = {
					is_word           = entry.is_word,
					auto_expand       = entry.auto_expand,
					is_case_sensitive = entry.is_case_sensitive,
					is_case_sensitive_strict = entry.is_case_sensitive_strict,
					final_result      = entry.final_result,
					section           = sec_name,
					personal_source   = owned_source,
					priority          = _callbacks.resolve_priority(entry.priority, override_priority, nil, name),
				} }
			end
		else
			Logger.debug(LOG, "Section '%s/%s' skipped (disabled in hs.settings).", name, sec_name)
		end

		table.insert(sections_info, {
			name        = sec_name,
			description = sec.description or sec_name,
			count       = count,
		})

		::continue_sec::
	end

	for _, record in ipairs(require("toml_codec.reader").registration_order(data, name, registrations)) do
		local section = registrations[record.section]
		local registration = section and section[record.index]
		if registration then
			_callbacks.add(registration.entry.trigger, registration.entry.output, registration.options)
		end
	end

	_state.current_group = nil
	_callbacks.sort_mappings()

	-- Per-section delay overrides from [_meta.section_delays] (seconds). Replace
	-- this group's complete ownership so colliding section names in other files
	-- stay independent and removed overrides cannot survive a same-file reload.
	local group_section_delays = {}
	if type(data.meta) == "table" and type(data.meta.section_delays) == "table" then
		for sec_name, secs in pairs(data.meta.section_delays) do
			if type(secs) == "number" then
				group_section_delays[sec_name] = secs
			end
		end
	end
	local delay_resolver = resolution and resolution.delay_resolver or _delay_resolver
	if delay_resolver then
		for _, section in ipairs(sections_info) do
			if section.name ~= "-" and not section.is_module_placeholder then
				local delay = delay_resolver(name, section.name, data.meta or {})
				assert(type(delay) == "number" and delay == delay and delay >= 0 and delay < math.huge,
					"registered hotstring delay must be finite and non-negative")
				group_section_delays[section.name] = delay
			end
		end
	end
	replace_group_section_delays(name, group_section_delays)

	-- Preserve group_order across reloads: ensure_group_order() stamped it earlier,
	-- but overwriting the table would silently drop the value and break sort stability
	local existing_order = _state.groups[name] and _state.groups[name].group_order or nil
	_state.groups[name] = {
		path             = path,
		section_sources  = section_sources,
		personal_source  = owned_source and PersonalFiles.copy(owned_source) or nil,
		enabled          = true,
		kind             = "toml",
		meta_description = data.meta and data.meta.description or nil,
		delay_metadata   = data.meta or {},
		delay_resolved   = _delay_resolver ~= nil,
		sections         = sections_info,
		group_order      = existing_order,
	}

	-- Report THIS group's contribution, not the global corpus size. The shared
	-- reader never raises and returns an empty table for a missing or unreadable
	-- file, so a group that registered nothing still reached this line and paired
	-- its Logger.start with a success whose count came from every OTHER group —
	-- the one number guaranteed to look healthy. A group that loads zero entries
	-- is almost always a path or permission problem, and it now says so.
	local added = #_state.mappings - mappings_before
	if added == 0 then
		Logger.warn(LOG, "TOML mapping file '%s' registered ZERO mappings — check the path and its contents.", name)
	else
		Logger.success(LOG, "TOML mapping file '%s' loaded (%d mapping(s); %d total).",
			name, added, #_state.mappings)
	end
	return true
	end)
end

--- Replaces one enabled TOML group against a single registry snapshot.
--- A failed parser/loader restores the exact previously-live corpus and every
--- derived index. A group the user deliberately disabled stays disabled; its
--- on-disk file will be loaded only if the user enables it later.
--- @param name string Existing group identifier.
--- @param path string Absolute TOML path.
--- @return boolean committed
function M.reload_toml(name, path)
	if not require_state("reload_toml") then return false end
	if type(name) ~= "string" or name == "" then
		Logger.error(LOG, "reload_toml: name must be a non-empty string.")
		return false
	end
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "reload_toml: path must be a non-empty string.")
		return false
	end

	return run_transaction("reload_toml:" .. name, function()
		local group = _state.groups[name]
		if not group then
			Logger.error(LOG, "reload_toml: unknown group '%s'.", name)
			return false
		end
		if group.enabled ~= true then
			if path ~= group.path then group.personal_source = nil end
			group.path = path
			group.kind = "toml"
			return true
		end
		if M.disable_group(name) ~= true then return false end
		return M.load_toml(name, path, group.section_sources, path == group.path and group.personal_source or nil) == true
	end)
end

--- Stages an admitted personal source before its final conditional publication.
--- The existing registry journal preserves mappings, indexes and disabled gates
--- whenever candidate parsing, native adoption or the publisher refuses.
--- @param name string Canonical owner already registered by the native loader.
--- @param path string Exact registered source route.
--- @param candidate string Proposed source bytes, never a temporary source path.
--- @param publish function Exact conditional source publication acknowledgement.
--- @return boolean committed
function M.replace_personal_source(name, path, candidate, publish, resolution)
	if not require_state("replace_personal_source") or type(publish) ~= "function" then return false end
	local group = _state.groups[name]
	if not group or group.path ~= path or not PersonalFiles.components(name)
		or not PersonalFiles.is_descriptor(group.personal_source) or group.personal_source.id ~= name then return false end
	local parsed, committed = require("toml_codec.reader").parse_text(candidate)
	if committed ~= true or type(parsed) ~= "table" then return false end
	local enabled, source = group.enabled, PersonalFiles.copy(group.personal_source)
	return run_transaction("replace_personal_source:" .. name, function()
		if M.disable_group(name) ~= true then return false end
		if M.load_toml(name, path, nil, source, candidate, resolution) ~= true then return false end
		if enabled ~= true and M.disable_group(name) ~= true then return false end
		return publish() == true
	end)
end





-- =============================================
-- =============================================
-- ======= 2/ Group Lifecycle Management =======
-- =============================================
-- =============================================

--- Manually sets the current group context used by M.add() to tag new entries.
--- Must be reset to nil after the relevant block of M.add() calls. When a
--- non-nil group name is supplied, ensure_group_order stamps a stable
--- group_order on the group so subsequent add_raw calls tag their entries
--- with the same priority value that would survive a later reload.
--- @param name string|nil Group name.
function M.set_group_context(name)
	if not require_state("set_group_context") then return end
	M.note_registry_mutation()
	if name and name ~= "" then ensure_group_order(name) end
	_state.current_group = name
end

--- Registers a callback invoked after a group is enabled or re-loaded.
--- @param name string Group identifier.
--- @param f function The post-load hook.
function M.set_post_load_hook(name, f)
	if not require_state("set_post_load_hook") then return end
	M.note_registry_mutation()
	if type(f) ~= "function" then
		Logger.error(LOG, "set_post_load_hook: f must be a function."); return
	end
	_state.group_post_load_hooks[name] = f
end

--- Disables a group: removes its mappings from the live database.
--- No-op when the group is already disabled or unknown.
--- @param name string Group identifier.
function M.disable_group(name)
	if not require_state("disable_group") then return false end
	local g = _state.groups[name]
	if not g then
		Logger.warn(LOG, "disable_group: unknown group '%s'.", tostring(name))
		return false
	end
	if not g.enabled then M.note_registry_mutation(); return true end

	return run_transaction("disable_group:" .. tostring(name), function()
		g.enabled = false

		-- Purge all mappings belonging to this group from the live list.
		-- Programmatic groups (g.path == nil, e.g. "dynamichotstrings") must be
		-- purged too — their mappings are re-created by enable_group's post-load
		-- hook, so leaving them here would fire disabled hotstrings indefinitely.
		-- rebuild_tail_indexes() is required after the purge so the O(1) buckets
		-- used by the hot-path (mappings_by_tail_char) no longer point at the
		-- removed entries; previously only rebuild_lookup() was called, leaving
		-- stale bucket pointers that caused disabled hotstrings to still trigger.
		local kept = {}
		for _, mapping in ipairs(_state.mappings) do
			if mapping.group ~= name then table.insert(kept, mapping) end
		end
		_state.mappings = kept
		_callbacks.rebuild_lookup()
		_callbacks.rebuild_tail_indexes()
		-- The third structure this purge invalidates. The classify_trigger memo is a
		-- pure function of (string, corpus), and the corpus just shrank; sort_mappings
		-- is the only other place it is dropped and this path deliberately does not
		-- sort. Without this the disabled group's triggers keep classifying as present.
		_callbacks.drop_classify_cache()
		replace_group_section_delays(name, nil)

		Logger.debug(LOG, "Group '%s' disabled (%d mapping(s) remaining).", name, #_state.mappings)
		return true
	end)
end

--- Returns true when the named group exists and is currently enabled.
--- @param name string Group identifier.
--- @return boolean
function M.is_group_enabled(name)
	return _state and _state.groups[name] ~= nil and _state.groups[name].enabled or false
end

--- Captures one actual TOML owner without exposing its mutable group record.
--- @param name string Registered native group identity.
--- @return table|nil binding Owned provenance and current-owner predicate.
function M.personal_file_scope_binding(name)
	if not require_state("personal_file_scope_binding") then return nil end
	local group = _state.groups[name]
	if not group or group.kind ~= "toml" or not PersonalFiles.is_descriptor(group.personal_source) then return nil end
	return { source = PersonalFiles.copy(group.personal_source), path = group.path,
		current = function() return _publication_owner == nil and _state.groups[name] == group end }
end

--- Returns a flat table of {name → enabled} for all registered groups.
--- @return table
function M.list_groups()
	if not _state then return {} end
	local out = {}
	for name, g in pairs(_state.groups) do out[name] = g.enabled end
	return out
end

--- Registers a programmatic (non-file) group with an optional metadata block.
--- Used by Lua modules that call M.add() directly instead of loading a file.
--- @param name string Group identifier.
--- @param meta_description string|nil Prose description for the menu.
--- @param sections table|nil Array of section descriptor tables.
function M.register_lua_group(name, meta_description, sections)
	if not require_state("register_lua_group") then return end
	M.note_registry_mutation()
	if type(name) ~= "string" or name == "" then
		Logger.error(LOG, "register_lua_group: name must be a non-empty string."); return
	end
	_state.groups[name] = {
		path             = nil,
		enabled          = true,
		kind             = "lua",
		meta_description = meta_description,
		sections         = type(sections) == "table" and sections or {},
	}
	replace_group_section_delays(name, nil)
	Logger.debug(LOG, "Lua group '%s' registered.", name)
end

--- Enables a previously disabled group by reloading its file (or re-running its hook).
--- No-op when the group is already enabled.
--- @param name string Group identifier.
function M.enable_group(name)
	if not require_state("enable_group") then return false end
	local g = _state.groups[name]
	if not g then
		Logger.warn(LOG, "enable_group: unknown group '%s'.", tostring(name))
		return false
	end
	if g.enabled then M.note_registry_mutation(); return true end

	return run_transaction("enable_group:" .. tostring(name), function()
		Logger.debug(LOG, "Enabling group '%s' (kind: %s)…", name, g.kind or "?")

		if g.path == nil then
			-- Programmatic group: mark enabled and run the post-load hook if any.
			g.enabled = true
			local hook = _state.group_post_load_hooks[name]
			if type(hook) == "function" then hook() end
			_callbacks.sort_mappings()
			return true
		end

		local loaded
		if g.kind == "toml" then
			loaded = M.load_toml(name, g.path, g.section_sources, g.personal_source)
		else
			loaded = M.load_file(name, g.path)
		end
		if loaded ~= true then return false end

		local hook = _state.group_post_load_hooks[name]
		if type(hook) == "function" then hook() end
		_callbacks.sort_mappings()
		return true
	end)
end

return M
