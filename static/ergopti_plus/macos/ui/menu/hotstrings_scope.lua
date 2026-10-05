--- ui/menu/hotstrings_scope.lua

--- ==============================================================================
--- MODULE: Hotstrings Scope (macOS)
--- DESCRIPTION:
--- Restores the recommended hotstring settings, or clears them to the neutral
--- state, across both files that hold them: config.toml (the engine switch, the
--- scalar options and the group and section choices) and hotstrings_config.toml
--- (delays, colours, previews and priorities). One menu command is one
--- transaction with one inverse, coordinated by the scoped-preferences owner.
---
--- FEATURES & RATIONALE:
--- 1. Measured delays. The shared planner writes an explicit delay wherever the
---    corpus inheritance this registry resolves differs from the manifest's
---    recommendation: deleting the override alone leaves autocorrection.caps on
---    its file-level 1.0 s where 0.5 s is recommended.
--- 2. Reader-verified candidate. The override candidate is parsed back by the
---    reader the engine uses and must say exactly what the plan wrote, so a
---    spelling the writer cannot address refuses the scope instead of surviving.
--- 3. Runtime with its files, exact inverse after. The override delays are
---    projected in the registry transaction that publishes their file; the group
---    choices, the scalar owners and the engine switch then adopt the candidate,
---    and every refusal restores the captured posture and both files.
--- 4. Only this driver's readers are written. A manifest row no macOS reader
---    consumes (a Windows or Linux feature row) is removed by both modes, and
---    the legacy per-category delay shadows of the override file are removed
---    too; every other hotstring table is left as the file holds it.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local Preferences = require("infra.preferences")
local Transaction = require("config_scope_transaction")
local Writer = require("toml_codec.writer")
local LeafRows = require("toml_codec.leaf_rows")
local KeyPath = require("toml_codec.key_path")
local Planner = require("hotstrings.scope_overrides")
local TerminatorScope = require("hotstrings.terminator_scope")
local Codec = require("toml_codec")
local ScopeFile = require("config_scope_file")
local Extensions = require("hotstrings.extensions")
local ConfigSchema = require("modules.hotstrings.hotstrings_config_schema")
local Logger = require("infra.logger")

local LOG = "menu.hotstrings_scope"

--- Native owner of each scalar the scope writes, by menu-state key. A setter
--- is absent where the menu state is the only reader on this driver, and a
--- getter is present where the native owner can read its value back.
local OWNERS = {
	{ key = "repeat_key_enabled", setter = "set_repeat_feature_enabled", getter = "is_repeat_feature_enabled" },
	{ key = "expansion_delay", setter = "set_base_delay", getter = "get_base_delay" },
	{ key = "trigger_char", setter = "set_trigger_char", getter = "get_trigger_char" },
	{ key = "magic_key_source", setter = "set_magic_key_source", getter = "get_magic_key_source" },
	{ key = "preview_star_enabled", setter = "set_preview_star_enabled" },
	{ key = "preview_autocorrect_enabled", setter = "set_preview_autocorrect_enabled" },
	{ key = "preview_colored_tooltips", setter = "set_preview_colored_tooltips" },
	{ key = "preview_ai_enabled", setter = "set_preview_ai_enabled" },
	{ key = "dynamichotstrings_enabled" },
}
local OWNER = {}
for _, owner in ipairs(OWNERS) do OWNER[owner.key] = owner end

--- Menu-state key of the typing-engine switch (hotstrings.enabled).
local ENGINE_KEY = "keymap"

local function clone(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = clone(child) end
	return copy
end

--- Whether a group or section identity can be named by a canonical path.
--- @param id string
--- @return boolean
local function addressable(id)
	return type(id) == "string" and id ~= "" and not id:find(".", 1, true)
end

--- The override-file table of one registered group, as the reader keys it.
--- @param name string Registered group identity.
--- @return table|nil segments Table path in hotstrings_config.toml.
--- @return string|nil key The reader's category key for the same table.
local function override_table(name)
	local extension_id = Extensions.parse_category_key(name)
	local key = ConfigSchema.normalize_category(extension_id and ("ext." .. extension_id) or name)
	if not key then return nil, nil end
	if extension_id then return { "ext", key:sub(#"ext." + 1) }, key end
	return { key }, key
end

--- Whether two override trees give one group different collision priorities.
--- @param before table Reader override tree.
--- @param after table Reader override tree.
--- @param key string The group's category key.
--- @return boolean
local function priority_changed(before, after, key)
	local left, right = before[key] or {}, after[key] or {}
	if left.priority ~= right.priority then return true end
	local sections = {}
	for section in pairs(left.sections or {}) do sections[section] = true end
	for section in pairs(right.sections or {}) do sections[section] = true end
	for section in pairs(sections) do
		local old = (left.sections or {})[section] or {}
		local new = (right.sections or {})[section] or {}
		if old.priority ~= new.priority then return true end
	end
	return false
end

--- Creates the Hotstrings scope over the running owners.
--- @param options table Scoped-preference ports (path, files, state, preferences,
---   checkpoint, demotions, capture_preferences, admission, paused, backup_path)
---   plus the hotstring owners: keymap, config (hotstrings_config),
---   start_engine / stop_engine (exact true), is_personal(name),
---   override_backup_path(), remove(path) for a created override file, and an
---   optional editor with set_trigger_char.
--- @return table owner apply(mode), revert(), release(), pending(), retry_restore(),
---   unavailable()
function M.new(options)
	assert(type(options) == "table", "hotstrings scope options are required")
	local keymap, Config, state = options.keymap, options.config, options.state
	assert(type(keymap) == "table" and type(Config) == "table" and type(state) == "table",
		"hotstrings scope needs the keymap, the override owner and the menu state")
	for _, name in ipairs({ "list_groups", "get_sections", "is_section_enabled", "is_group_enabled",
		"apply_hotstring_preferences", "hotstring_delay_inventory", "registry_transaction", "disable_group",
		"enable_group", "set_delay" }) do
		assert(type(keymap[name]) == "function", "hotstrings scope keymap port missing: " .. name)
	end
	for _, name in ipairs({ "get_terminator_defs", "is_terminator_enabled", "set_terminators_enabled" }) do
		assert(type(keymap[name]) == "function", "hotstrings scope delimiter port missing: " .. name)
	end
	for _, owner in ipairs(OWNERS) do
		for _, name in ipairs({ owner.setter, owner.getter }) do
			assert(type(keymap[name]) == "function", "hotstrings scope keymap port missing: " .. name)
		end
	end
	assert(type(keymap.DELAY_KEY_TO_CATEGORY) == "table", "hotstrings scope needs the legacy delay owners")
	for _, name in ipairs({ "scope_snapshot", "adopt_scope_source", "parse_override_content", "delay_projection",
		"get_override_path", "acquire", "release", "resolve" }) do
		assert(type(Config[name]) == "function", "hotstrings scope override port missing: " .. name)
	end
	for _, name in ipairs({ "start_engine", "stop_engine", "is_personal", "remove", "override_backup_path" }) do
		assert(type(options[name]) == "function", "hotstrings scope port missing: " .. name)
	end
	local fence = {}
	local owned, secondary, current_mode, active = nil, nil, nil, nil

	--- The current value of one owned scalar, read back where its owner can.
	--- @param key string Menu-state key.
	--- @return any
	local function current(key)
		if OWNER[key].getter then return keymap[OWNER[key].getter]() end
		return state[key]
	end

	--- The catalogue identities the running registry owns, as canonical paths.
	--- @return table paths
	local function inventory()
		local paths = {}
		for name in pairs(keymap.list_groups()) do
			if addressable(name) then
				paths[#paths + 1] = "hotstrings.groups." .. name
				for _, section in ipairs(keymap.get_sections(name) or {}) do
					if section.name ~= "-" and not section.is_module_placeholder and addressable(section.name) then
						paths[#paths + 1] = "hotstrings.modules." .. name .. "." .. section.name
					end
				end
			end
		end
		table.sort(paths)
		local selected = Manifest.scope_inventory("hotstrings", { catalogue = function() return paths end })
		owned = {}
		for _, path in ipairs(selected) do owned[path] = true end
		return selected
	end

	--- Prepares the override half of the plan and proves the reader agrees. It
	--- stores nothing: a transaction keeps what it returns, and a check that
	--- only asks never replaces the file a retained inverse still needs.
	--- @param mode string "recommended" or "clear".
	--- @return boolean prepared
	--- @return string|nil reason
	--- @return table|nil file The prepared override participant.
	--- @return table|nil parsed The candidate as the engine's reader parses it.
	local function prepare_overrides(mode)
		local committed = Config.scope_snapshot()
		if type(committed) ~= "table" then return false, "the override file was not read cleanly" end
		local registered, groups = keymap.hotstring_delay_inventory(), {}
		assert(type(registered) == "table", "hotstring delay inventory is unavailable")
		for name, entry in pairs(registered) do
			local segments = override_table(name)
			if segments then
				local sections = {}
				for _, section in ipairs(entry.sections) do sections[#sections + 1] = section end
				table.sort(sections)
				groups[#groups + 1] = { id = name, override = segments, sections = sections,
					bundled = Extensions.parse_category_key(name) == nil and options.is_personal(name) ~= true }
			end
		end
		table.sort(groups, function(left, right) return left.id < right.id end)
		local inherit = Config.delay_projection({})
		local changes = Planner.plan({ mode = mode, features = Manifest.features(), groups = groups,
			inherited = function(name, section) return inherit(name, section, registered[name].metadata) end,
			extra = { { override = { "dynamichotstrings" }, fields = Planner.FIELDS } } })
		local path = Config.get_override_path()
		local file = ScopeFile.new({ path = path, backup_path = options.override_backup_path(), files = options.files,
			remove = options.remove })
		local prepared, detail = file.prepare(Planner.writer_rows(changes))
		if prepared ~= true then return false, detail end
		local source = file.source()
		if source.status ~= committed.source.status
			or (source.status == "ok" and source.content ~= committed.source.content) then
			return false, "the override file changed since it was loaded"
		end
		local parsed = Config.parse_override_content(file.candidate() or "")
		for _, change in ipairs(changes) do
			local key = change.override[1] == "ext" and ("ext." .. change.override[2]) or change.override[1]
			local entry = parsed[key]
			local target = entry
			if entry and change.section then target = (entry.sections or {})[change.section:lower()] end
			local value = target and target[change.field]
			if value ~= change.value then
				return false, "the override file keeps a spelling the scope cannot address: " .. key
			end
		end
		return true, nil, file, parsed
	end

	--- Re-registers enabled groups so their collision priorities are read again.
	--- @param names table Group identities.
	--- @return boolean committed
	local function reload_groups(names)
		if #names == 0 then return true end
		return keymap.registry_transaction("hotstrings scope priorities", function()
			for _, name in ipairs(names) do
				if keymap.is_group_enabled(name) then
					if keymap.disable_group(name) ~= true or keymap.enable_group(name) ~= true then return false end
				end
			end
			return true
		end) == true
	end

	--- Pushes the legacy per-category delays the boot synchronisation derives.
	--- @param delays table Legacy `state.delays` to keep.
	--- @return boolean committed
	local function push_delays(delays)
		for key, category in pairs(keymap.DELAY_KEY_TO_CATEGORY) do
			local value = delays[key]
			if value == nil then value = Config.resolve(category, nil).delay end
			if keymap.set_delay(key, value) ~= true then return false end
		end
		state.delays = clone(delays)
		return true
	end

	--- Applies scalar values and the engine switch through their native owners.
	--- @param values table Menu-state key to value.
	--- @return boolean committed
	local function apply_values(values)
		for _, owner in ipairs(OWNERS) do
			local value = values[owner.key]
			if value ~= nil and owner.setter and current(owner.key) ~= value then
				if keymap[owner.setter](value) ~= true then return false end
				if owner.key == "trigger_char" and options.editor then options.editor.set_trigger_char(value) end
			end
		end
		for _, owner in ipairs(OWNERS) do
			if values[owner.key] ~= nil then state[owner.key] = clone(values[owner.key]) end
		end
		local engine = values[ENGINE_KEY]
		if engine ~= nil and engine ~= state[ENGINE_KEY] then
			if engine then
				if options.start_engine() ~= true then return false end
			elseif options.stop_engine() ~= true then
				return false
			end
			state[ENGINE_KEY] = engine
		end
		return true
	end

	local ports = {}
	for key, value in pairs(options) do ports[key] = value end
	ports.scope, ports.demotion_feature = "hotstrings", "hotstrings"
	ports.demotion_keys = function(rows)
		local keys = {}
		for _, row in ipairs(rows) do
			local key = Preferences.flat_key_for(row.section .. "." .. row.key)
			if key then keys[key] = true end
		end
		return keys
	end
	ports.transaction_factory = function(config)
		config.owned_paths = inventory
		config.prepare_batch = function(path, updates, files)
			local content, status, detail = Writer.read_classified(path, files)
			assert(status == "ok" or status == "absent", "hotstring preferences are unreadable: " .. tostring(detail))
			local source = { status = status, content = content }
			local operations = {}
			for _, row in ipairs(updates) do
				local segments = assert(KeyPath.parse(row.section, true), "scope row has an invalid table path")
				segments[#segments + 1] = row.key
				local text = row.section .. "." .. row.key
				if row.delete or not (owned[text] or Preferences.flat_key_for(text)) then
					operations[#operations + 1] = { path = segments, delete = true }
				else
					operations[#operations + 1] = { path = segments, value = row.value }
				end
			end
			-- Legacy per-category delays shadow the override file at boot; only
			-- the categories that file owns are removed, never the whole table.
			for key in pairs(keymap.DELAY_KEY_TO_CATEGORY) do
				operations[#operations + 1] = { path = { "hotstrings", "delays", key }, delete = true }
			end
			local document = assert(Codec.decode(content or ""), "hotstring preferences are malformed")
			for _, segments in ipairs(TerminatorScope.builtin_state_leaves(document)) do
				operations[#operations + 1] = { path = segments, delete = true }
			end
			local prepared, why, file, parsed = prepare_overrides(current_mode)
			if prepared ~= true then return false, "override file: " .. tostring(why) end
			secondary, active = file, { overrides = parsed }
			return Writer.prepare_batch(path, LeafRows.prepare(content or "", operations), files, source)
		end
		local transaction = Transaction.new(config)
		local held = false
		local function release()
			assert(Config.release(fence) == true, "hotstring override release refused")
			held = false
		end
		return {
			pending = transaction.pending,
			retry_restore = function()
				if transaction.retry_restore() ~= true then return false end
				if held then release() end
				return true
			end,
			apply = function(scope, mode)
				if Config.acquire(fence) ~= true then return false, "hotstring overrides are held" end
				held, current_mode = true, mode
				local committed, detail = transaction.apply(scope, mode)
				if not transaction.pending() then release() end
				return committed, detail
			end,
			-- A composed global scope reverts this commit when a later category
			-- refuses. Restoring the override file adopts its source again, which
			-- only the fence holder may do, so the revert holds it like an apply.
			revert = function()
				if held then return false, "the hotstrings scope is still held" end
				if Config.acquire(fence) ~= true then return false, "hotstring overrides are held" end
				held = true
				local reverted, detail = transaction.revert()
				if not transaction.pending() then release() end
				return reverted, detail
			end,
			release = transaction.release,
		}
	end
	ports.runtime = {
		capture = function()
			local config = Config.scope_snapshot()
			if type(config) ~= "table" or type(state.hotstrings) ~= "table" or type(state.delays) ~= "table" then
				return nil
			end
			local groups, sections = {}, {}
			for name, enabled in pairs(keymap.list_groups()) do
				groups[name] = enabled
				local chosen = {}
				for _, section in ipairs(keymap.get_sections(name) or {}) do
					if section.name ~= "-" and not section.is_module_placeholder then
						chosen[section.name] = keymap.is_section_enabled(name, section.name)
					end
				end
				sections[name] = chosen
			end
			local values = { [ENGINE_KEY] = state[ENGINE_KEY] }
			for _, owner in ipairs(OWNERS) do values[owner.key] = clone(current(owner.key)) end
			local terminators = {}
			for _, def in ipairs(keymap.get_terminator_defs()) do
				if def.key then terminators[def.key] = keymap.is_terminator_enabled(def.key) end
			end
			local snapshot = { config = config, groups = groups, sections = sections, values = values,
				hotstrings = clone(state.hotstrings), delays = clone(state.delays), reloaded = {},
				candidate = active.overrides, terminators = terminators,
				terminator_states = clone(state.terminator_states) }
			active = snapshot
			return snapshot
		end,
		apply = function(decoded, rows)
			local values = {}
			for _, row in ipairs(rows) do
				local path = row.section .. "." .. row.key
				local key = Preferences.flat_key_for(path)
				if key then
					assert(OWNER[key] ~= nil or key == ENGINE_KEY, "hotstrings scope has no runtime owner: " .. path)
					local value
					if row.delete then value = Manifest.default_for(path) else value = row.value end
					values[key] = Preferences.state_value_for(path, value)
				end
			end
			local backed, why = secondary.backup()
			if backed ~= true then
				Logger.error(LOG, "Override backup refused: %s.", tostring(why))
				return false
			end
			if Config.adopt_scope_source(fence, secondary.target(), secondary.publish) ~= true then return false end
			active.adopted = true
			local legacy = clone(state.delays)
			for key in pairs(keymap.DELAY_KEY_TO_CATEGORY) do legacy[key] = nil end
			if push_delays(legacy) ~= true then return false end
			if keymap.apply_hotstring_preferences(Preferences.flatten_document(decoded)) ~= true then return false end
			for name, enabled in pairs(keymap.list_groups()) do state.hotstrings[name] = enabled end
			for name in pairs(keymap.hotstring_delay_inventory()) do
				local _, key = override_table(name)
				if key and priority_changed(active.config.overrides, active.candidate, key) then
					active.reloaded[#active.reloaded + 1] = name
				end
			end
			table.sort(active.reloaded)
			if not reload_groups(active.reloaded) then return false end
			local defaults = TerminatorScope.defaults()
			if keymap.set_terminators_enabled(defaults) ~= true then return false end
			local retained = clone(state.terminator_states or {})
			for key in pairs(defaults) do retained[key] = nil end
			state.terminator_states = retained
			return apply_values(values)
		end,
		restore = function(snapshot)
			if snapshot.adopted or secondary.pending() then
				if Config.adopt_scope_source(fence, snapshot.config.source, secondary.restore) ~= true then return false end
				snapshot.adopted = false
			end
			if push_delays(snapshot.delays) ~= true then return false end
			if keymap.apply_hotstring_preferences({ hotstrings = snapshot.groups,
				section_states = snapshot.sections }) ~= true then return false end
			if not reload_groups(snapshot.reloaded) then return false end
			if keymap.set_terminators_enabled(snapshot.terminators) ~= true then return false end
			state.terminator_states = clone(snapshot.terminator_states)
			if apply_values(snapshot.values) ~= true then return false end
			state.hotstrings = clone(snapshot.hotstrings)
			return true
		end,
	}
	local owner = require("ui.menu.scoped_preferences").new(ports)
	--- Why this owner cannot serve a composed restore now, or nil. The global
	--- restore skips and names such a category instead of refusing every other
	--- one with it: an override file whose source did not read cleanly, one
	--- changed since it was loaded, or one keeping a spelling the plan cannot
	--- address. The check prepares both modes' candidates and writes nothing.
	--- @return string|nil reason
	function owner.unavailable()
		-- A retained inverse is the composition's to report: it refuses to start.
		if owner.pending() then return nil end
		if type(Config.scope_snapshot()) ~= "table" then return "the hotstring override file was not read cleanly" end
		for _, mode in ipairs({ "clear", "recommended" }) do
			local called, prepared, why = pcall(prepare_overrides, mode)
			if not called then return tostring(prepared) end
			if prepared ~= true then return tostring(why) end
		end
		return nil
	end
	return owner
end

return M
