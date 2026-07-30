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
local Logger = require("lib.logger")

local LOG = "keymap.registry"

local _state     = nil
local _callbacks = nil  -- {add, sort_mappings, is_section_enabled, resolve_priority, rebuild_lookup, rebuild_tail_indexes}

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

--- Injects the shared state and the registry's callback table.
--- @param state table The shared CoreState.
--- @param callbacks table Must provide every name in REQUIRED_CALLBACKS.
function M.init(state, callbacks)
	_state     = state
	_callbacks = callbacks

	local missing = {}
	for _, name in ipairs(REQUIRED_CALLBACKS) do
		if type(callbacks) ~= "table" or type(callbacks[name]) ~= "function" then
			table.insert(missing, name)
		end
	end
	if #missing > 0 then
		Logger.error(LOG, "M.init(): missing callback(s) %s — group operations will be "
			.. "incomplete and their callers pcall the throw away.",
			table.concat(missing, ", "))
	end
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
	if not require_state("load_file") then return end
	if type(name) ~= "string" or name == "" then
		Logger.error(LOG, "load_file: name must be a non-empty string."); return
	end
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "load_file: path must be a non-empty string."); return
	end

	Logger.start(LOG, "Loading Lua mapping file '%s'…", name)
	ensure_group_order(name)
	_state.current_group = name

	local ok, err = pcall(dofile, path)
	if not ok then
		Logger.error(LOG, "Error loading '%s': %s.", path, tostring(err))
	end

	_state.current_group = nil
	record_group(name, path, "lua")
	_callbacks.sort_mappings()

	if ok then
		Logger.success(LOG, "Lua mapping file '%s' loaded (%d total mapping(s)).", name, #_state.mappings)
	end
end

--- Loads and parses mappings from a TOML configuration file.
--- Skips sections the user has disabled, per _callbacks.is_section_enabled
--- (the persisted enable/disable state itself is owned by registry_index.lua).
--- @param name string Group identifier used as the key in _state.groups.
--- @param path string Absolute path to the TOML file.
function M.load_toml(name, path)
	if not require_state("load_toml") then return end
	if type(name) ~= "string" or name == "" then
		Logger.error(LOG, "load_toml: name must be a non-empty string."); return
	end
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "load_toml: path must be a non-empty string."); return
	end

	Logger.start(LOG, "Loading TOML mapping file '%s'…", name)

	local toml_reader  = require("lib.toml.reader")
	local ok, data     = pcall(toml_reader.parse, path)
	if not ok or type(data) ~= "table" then
		Logger.error(LOG, "Failed to parse TOML '%s': %s.", path, tostring(data))
		return
	end

	ensure_group_order(name)
	-- Snapshot before registering so the success line can report what THIS file
	-- contributed rather than the size of the whole corpus.
	local mappings_before = #_state.mappings
	_state.current_group = name
	local sections_info  = {}

	-- Collision-priority cascade inputs (individual > section > file > source).
	-- The shared user-override file (hotstrings_config.toml) sits ABOVE the TOML
	-- [_meta], mirroring how the AHK engine reads HotstringsResolve: the order is
	-- user-section > user-file > meta-section > meta-file > source default. The
	-- override module is required lazily (it does not require us, but stay defensive
	-- against load order / headless tests where it may be absent — gotcha G6).
	local ok_hcfg, hcfg = pcall(require, "modules.hotstrings.hotstrings_config")
	local hotstrings_config = ok_hcfg and hcfg or nil
	local function user_priority(section_name)
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
			for k, v in pairs(sec) do
				if type(k) == "string" and k ~= "description" and k ~= "is_placeholder" then
					count = count + 1
					if type(v) == "table" then
						table.insert(entries, {
							trigger           = k,
							output            = v.output,
							is_word           = v.is_word,
							auto_expand       = v.auto_expand,
							is_case_sensitive = v.is_case_sensitive,
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
			for _, entry in ipairs(entries) do
				_callbacks.add(entry.trigger, entry.output, {
					is_word           = entry.is_word,
					auto_expand       = entry.auto_expand,
					is_case_sensitive = entry.is_case_sensitive,
					final_result      = entry.final_result,
					section           = sec_name,
					priority          = _callbacks.resolve_priority(entry.priority, override_priority, nil, name),
				})
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

	_state.current_group = nil
	_callbacks.sort_mappings()

	-- Per-section delay overrides from [_meta.section_delays] (seconds). Merge
	-- into the shared map so mapping_fires can apply them (precedence: user >
	-- section > group > base), then resize the word-inactivity timeout so a long
	-- per-section window (e.g. comma_j = 5 s) is not cut short by the timeout.
	if type(data.meta) == "table" and type(data.meta.section_delays) == "table" then
		for sec_name, secs in pairs(data.meta.section_delays) do
			if type(secs) == "number" then
				_state.SECTION_DELAYS[sec_name] = secs
			end
		end
		if type(_state.recompute_word_timeout) == "function" then
			_state.recompute_word_timeout()
		end
	end

	-- Preserve group_order across reloads: ensure_group_order() stamped it earlier,
	-- but overwriting the table would silently drop the value and break sort stability
	local existing_order = _state.groups[name] and _state.groups[name].group_order or nil
	_state.groups[name] = {
		path             = path,
		enabled          = true,
		kind             = "toml",
		meta_description = data.meta and data.meta.description or nil,
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
end





-- ==============================================
-- =============================================
-- ======= 2/ Group Lifecycle Management =======
-- =============================================
-- ==============================================

--- Manually sets the current group context used by M.add() to tag new entries.
--- Must be reset to nil after the relevant block of M.add() calls. When a
--- non-nil group name is supplied, ensure_group_order stamps a stable
--- group_order on the group so subsequent add_raw calls tag their entries
--- with the same priority value that would survive a later reload.
--- @param name string|nil Group name.
function M.set_group_context(name)
	if not require_state("set_group_context") then return end
	if name and name ~= "" then ensure_group_order(name) end
	_state.current_group = name
end

--- Registers a callback invoked after a group is enabled or re-loaded.
--- @param name string Group identifier.
--- @param f function The post-load hook.
function M.set_post_load_hook(name, f)
	if not require_state("set_post_load_hook") then return end
	if type(f) ~= "function" then
		Logger.error(LOG, "set_post_load_hook: f must be a function."); return
	end
	_state.group_post_load_hooks[name] = f
end

--- Disables a group: removes its mappings from the live database.
--- No-op when the group is already disabled or unknown.
--- @param name string Group identifier.
function M.disable_group(name)
	if not require_state("disable_group") then return end
	local g = _state.groups[name]
	if not g or not g.enabled then return end

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
	for _, m in ipairs(_state.mappings) do
		if m.group ~= name then table.insert(kept, m) end
	end
	_state.mappings = kept
	_callbacks.rebuild_lookup()
	_callbacks.rebuild_tail_indexes()
	-- The third structure this purge invalidates. The classify_trigger memo is a
	-- pure function of (string, corpus), and the corpus just shrank; sort_mappings
	-- is the only other place it is dropped and this path deliberately does not
	-- sort. Without this the disabled group's triggers keep classifying as present.
	_callbacks.drop_classify_cache()

	Logger.debug(LOG, "Group '%s' disabled (%d mapping(s) remaining).", name, #_state.mappings)
end

--- Returns true when the named group exists and is currently enabled.
--- @param name string Group identifier.
--- @return boolean
function M.is_group_enabled(name)
	return _state and _state.groups[name] ~= nil and _state.groups[name].enabled or false
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
	Logger.debug(LOG, "Lua group '%s' registered.", name)
end

--- Enables a previously disabled group by reloading its file (or re-running its hook).
--- No-op when the group is already enabled.
--- @param name string Group identifier.
function M.enable_group(name)
	if not require_state("enable_group") then return end
	local g = _state.groups[name]
	if not g then
		Logger.warn(LOG, "enable_group: unknown group '%s'.", tostring(name))
		return
	end
	if g.enabled then return end

	Logger.debug(LOG, "Enabling group '%s' (kind: %s)…", name, g.kind or "?")

	if g.path == nil then
		-- Programmatic group: mark enabled and run the post-load hook if any.
		g.enabled = true
		local hook = _state.group_post_load_hooks[name]
		if type(hook) == "function" then hook() end
		_callbacks.sort_mappings()
		return
	end

	if g.kind == "toml" then
		M.load_toml(name, g.path)
	else
		M.load_file(name, g.path)
	end

	local hook = _state.group_post_load_hooks[name]
	if type(hook) == "function" then hook() end
	_callbacks.sort_mappings()
end

return M
