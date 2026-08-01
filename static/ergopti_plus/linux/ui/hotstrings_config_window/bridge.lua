--- ui/hotstrings_config_window/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Hotstrings Config Window
--- Handles JS→Lua messages from _shared/ui/hotstrings_config_window/.
--- Bridge name: "hotstrings_config_bridge"
--- Persists add/delete operations via the shared toml_codec.writer.
--- ==============================================================================

local M = {}
M.bridge_name = "hotstrings_config_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.hotstrings_config"

-- Lazy-loaded writer for hotstring TOML persistence.
local _writer = nil
local function _get_writer()
	if _writer then return _writer end
	local ok, mod = pcall(require, "toml_codec.writer")
	if ok and type(mod) == "table" and type(mod.write) == "function" then _writer = mod end
	return _writer
end

-- Lazy-loaded reader for merging into the existing on-disk set before writing.
local _reader = nil
local function _get_reader()
	if _reader then return _reader end
	local ok, mod = pcall(require, "toml_codec.reader")
	if ok and type(mod) == "table" and type(mod.parse) == "function" then _reader = mod end
	return _reader
end

--- Reads the group's TOML, applies `mutate` to its entry list, then writes the
--- whole merged set back so a single-entry add/delete never clobbers the other
--- hotstrings already stored in that group file.
--- @param config_dir string Absolute hotstrings config directory.
--- @param group      string Target group (the TOML file's basename).
--- @param mutate     function Receives the section's entry list; edits it in place.
--- @return boolean, string|nil True on success, or false and an error string.
local function _persist_group(config_dir, group, mutate)
	local reader = _get_reader()
	local writer = _get_writer()
	if not reader or not writer then return false, "toml_codec unavailable" end

	local path = config_dir .. "/" .. group .. ".toml"

	-- Read the current set so we merge into it; a missing file parses to an
	-- empty structure, which is exactly a first-time add.
	local ok_read, existing = pcall(reader.parse, path)
	if not ok_read or type(existing) ~= "table" then
		existing = { meta = {}, sections_order = {}, sections = {} }
	end
	existing.meta           = type(existing.meta) == "table" and existing.meta or {}
	existing.sections_order = type(existing.sections_order) == "table" and existing.sections_order or {}
	existing.sections       = type(existing.sections) == "table" and existing.sections or {}
	if existing.meta.description == nil or existing.meta.description == "" then
		existing.meta.description = group
	end

	-- Ensure the target section exists and is tracked in the write order.
	local section = existing.sections[group]
	if type(section) ~= "table" then
		section = { description = group, entries = {} }
		existing.sections[group] = section
		existing.sections_order[#existing.sections_order + 1] = group
	end
	if type(section.entries) ~= "table" then section.entries = {} end

	mutate(section.entries)

	return writer.write(path, existing)
end

--- Builds the initial data payload for the config UI.
--- @param state table Daemon state.
--- @return table Data the JS UI expects.
local function _build_initial_payload(state)
	local groups = {}
	if state.config and type(state.config.get_groups) == "function" then
		local raw = state.config:get_groups()
		for _, g in ipairs(raw) do
			local enabled = false
			if type(state.config.is_group_enabled) == "function" then
				enabled = state.config:is_group_enabled(g)
			end
			groups[#groups + 1] = { name = g, enabled = enabled }
		end
	end

	local mapping_count = 0
	local error_count = 0
	if state.config then
		if type(state.config.mapping_count) == "function" then
			mapping_count = state.config:mapping_count()
		end
		if type(state.config.parse_error_count) == "function" then
			error_count = state.config:parse_error_count()
		end
	end

	return {
		groups = groups,
		mapping_count = mapping_count,
		parse_errors = error_count,
		config_dir = state.config and type(state.config.get_config_dir) == "function"
			and state.config:get_config_dir() or nil,
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keylogger, config, llm, layout }.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Hotstrings config UI ready.")
			return _build_initial_payload(state)
		end
		if payload == "refresh" then
			return _build_initial_payload(state)
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "toggle_group" and payload.group then
		if state.config and type(state.config.toggle_group) == "function" then
			state.config:toggle_group(payload.group)
		end
		return _build_initial_payload(state)
	end

	if action == "reload" then
		if state.config and type(state.config.reload) == "function" then
			state.config:reload()
		end
		return _build_initial_payload(state)
	end

	if action == "add_hotstring" and payload.trigger and payload.replacement then
		local group = payload.group or "default"
		Logger.info(LOG, "Add hotstring: %s → %s (group=%s)",
			payload.trigger, payload.replacement, group)

		local config_dir = state.config and type(state.config.get_config_dir) == "function"
			and state.config:get_config_dir() or nil
		local added = false
		if config_dir then
			local entry = {
				trigger           = payload.trigger,
				output            = payload.replacement,
				is_word           = payload.is_word ~= false,
				auto_expand       = payload.auto_expand == true,
				is_case_sensitive = payload.is_case_sensitive == true,
				final_result      = payload.final_result == true,
			}
			local ok, err = _persist_group(config_dir, group, function(entries)
				-- Upsert by trigger so editing an existing hotstring never
				-- appends a duplicate.
				for i, e in ipairs(entries) do
					if e.trigger == entry.trigger then entries[i] = entry return end
				end
				entries[#entries + 1] = entry
			end)
			added = ok == true
			if added then
				Logger.success(LOG, "Hotstring persisted: %s → %s", payload.trigger, payload.replacement)
			else
				Logger.error(LOG, "Failed to persist hotstring: %s", tostring(err))
			end
		else
			Logger.warn(LOG, "Add hotstring: no config directory — nothing persisted.")
		end
		return { added = added }
	end

	if action == "delete_hotstring" and payload.trigger then
		local group = payload.group or "default"
		Logger.info(LOG, "Delete hotstring: %s (group=%s)", payload.trigger, group)

		local config_dir = state.config and type(state.config.get_config_dir) == "function"
			and state.config:get_config_dir() or nil
		local deleted = false
		if config_dir then
			local ok, err = _persist_group(config_dir, group, function(entries)
				-- Drop only the matching trigger; every sibling entry survives.
				for i = #entries, 1, -1 do
					if entries[i].trigger == payload.trigger then table.remove(entries, i) end
				end
			end)
			deleted = ok == true
			if deleted then
				Logger.success(LOG, "Hotstring deleted: %s", payload.trigger)
			else
				Logger.error(LOG, "Failed to delete hotstring: %s", tostring(err))
			end
		else
			Logger.warn(LOG, "Delete hotstring: no config directory — nothing persisted.")
		end
		return { deleted = deleted }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
