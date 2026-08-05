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

-- The collision-priority range the settings window offers. Mirrored from the
-- window's own `v >= 0 && v <= 100` guard, and re-checked here rather than
-- trusted: the page is the least trusted input the daemon has, and a priority
-- outside the tier range silently reorders every hotstring source against every
-- other with nothing on screen to say so.
local PRIORITY_MIN = 0
local PRIORITY_MAX = 100

-- Delays cross this bridge in milliseconds and are stored in seconds. The window
-- shows milliseconds because that is the unit a person means by "a bit longer";
-- the cascade, the category TOMLs and the engine all speak seconds. The
-- conversion belongs here, at the one boundary the two units meet.
local MS_PER_SEC = 1000

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
		local raw = state.config.get_groups()
		for _, g in ipairs(raw) do
			local enabled = false
			if type(state.config.is_group_enabled) == "function" then
				enabled = state.config.is_group_enabled(g)
			end
			groups[#groups + 1] = { name = g, enabled = enabled }
		end
	end

	local mapping_count = 0
	local error_count = 0
	if state.config then
		if type(state.config.mapping_count) == "function" then
			mapping_count = state.config.mapping_count()
		end
		if type(state.config.parse_error_count) == "function" then
			error_count = state.config.parse_error_count()
		end
	end

	return {
		groups = groups,
		mapping_count = mapping_count,
		parse_errors = error_count,
		config_dir = state.config and type(state.config.get_config_dir) == "function"
			and state.config.get_config_dir() or nil,
	}
end

--- Applies one override through the config module, if this driver has one.
---
--- Guarded rather than assumed: the harness supplies a config table with only
--- the functions a given case needs, and a bridge that called an absent one
--- would fail the test for the wrong reason.
--- @param state table Daemon state.
--- @param category string
--- @param section string|nil
--- @param field string
--- @param value any
local function set_override(state, category, section, field, value)
	if not state.config or type(state.config.set_override) ~= "function" then
		Logger.warn(LOG, "set_override unavailable — '%s' for '%s' was not applied.",
			tostring(field), tostring(category))
		return
	end
	state.config.set_override(category, section, field, value)
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

	-- The shared settings window speaks eleven actions; this bridge answered four
	-- of them, so every delay, colour and preview control in it was inert on this
	-- driver. They are not new controls — the window already draws them, and a
	-- user clicking one got silence.
	--
	-- The empty string is the window's spelling of "the category itself", not a
	-- section named "": it sends section: '' for a category-level edit, and
	-- passing that through would create an override under a section nothing has.
	--- @param payload table
	--- @return string|nil
	local function section_of(payload)
		local section = payload.section
		if type(section) ~= "string" or section == "" then return nil end
		return section
	end

	-- The window sends `ms`, `hex` and `show_tooltip` — never `value`. This bridge
	-- read `payload.value` for all three until 2026-08-05, so every control did
	-- the OPPOSITE of what it looked like: typing 500 into a delay field passed
	-- tonumber(nil) and CLEARED that category's delay, picking a colour cleared
	-- the colour, and ticking "show the preview" wrote show_tooltip = false
	-- because `nil and true or false` is false. Nothing reported it, because the
	-- bridge answers with a refreshed payload either way.
	if action == "set_delay" and payload.category then
		-- Milliseconds on the wire, seconds in the store: the cascade, the TOMLs
		-- and the engine all speak seconds, and the conversion belongs at this
		-- boundary rather than in the resolver.
		local ms = tonumber(payload.ms)
		if not ms or ms < 0 then
			Logger.warn(LOG, "Refusing delay %s for '%s' — not a non-negative number of milliseconds.",
				tostring(payload.ms), tostring(payload.category))
			return _build_initial_payload(state)
		end
		set_override(state, payload.category, section_of(payload), "delay", ms / MS_PER_SEC)
		return _build_initial_payload(state)
	end

	if action == "clear_delay" and payload.category then
		set_override(state, payload.category, section_of(payload), "delay", nil)
		return _build_initial_payload(state)
	end

	if action == "set_color" and payload.category then
		-- Guarded like both references: an empty select is the page's "no choice",
		-- and writing it as an override would pin the category to nothing.
		local hex = payload.hex
		if type(hex) ~= "string" or hex == "" then
			Logger.warn(LOG, "Refusing colour %s for '%s' — not a colour string.",
				tostring(hex), tostring(payload.category))
			return _build_initial_payload(state)
		end
		set_override(state, payload.category, section_of(payload), "color", hex)
		return _build_initial_payload(state)
	end

	if action == "clear_color" and payload.category then
		set_override(state, payload.category, section_of(payload), "color", nil)
		return _build_initial_payload(state)
	end

	if action == "set_tooltip" and payload.category then
		-- Coerced rather than passed through: the window sends a JSON boolean,
		-- and a string "false" is truthy in Lua — which would turn the preview on
		-- for a user who had just turned it off.
		local value = payload.show_tooltip
		if type(value) == "string" then value = (value == "true") end
		set_override(state, payload.category, section_of(payload), "show_tooltip", value == true)
		return _build_initial_payload(state)
	end

	if action == "clear_tooltip" and payload.category then
		set_override(state, payload.category, section_of(payload), "show_tooltip", nil)
		return _build_initial_payload(state)
	end

	-- Collision priority. The window validates 0-100 before sending, and this
	-- re-validates rather than trusting it: the page is the least trusted input the
	-- daemon has, and a priority outside the tier range silently reorders every
	-- source against every other.
	if action == "set_priority" and payload.category then
		local value = tonumber(payload.priority)
		if not value or value < PRIORITY_MIN or value > PRIORITY_MAX then
			Logger.warn(LOG, "Refusing priority %s for '%s' — outside %d-%d.",
				tostring(payload.priority), tostring(payload.category), PRIORITY_MIN, PRIORITY_MAX)
			return _build_initial_payload(state)
		end
		set_override(state, payload.category, section_of(payload), "priority", value)
		return _build_initial_payload(state)
	end

	if action == "clear_priority" and payload.category then
		set_override(state, payload.category, section_of(payload), "priority", nil)
		return _build_initial_payload(state)
	end

	if action == "set_all_grey" then
		-- Every category's own colour set to the neutral shade, and every per-section
		-- colour override wiped so the neutral actually cascades down. Clearing the
		-- sections is the half that matters: leaving them would repaint the headings
		-- and leave the rows underneath in their old colours, which looks like the
		-- button half-worked.
		--
		-- Delays are deliberately untouched — the button is about colour, and a user
		-- who wants their timing back has no way to ask for it here.
		local config = state and state.config
		if type(config) == "table" and type(config.get_categories) == "function"
			and type(config.get_neutral_color) == "function" then
			-- No `or "#……"` here. The colour comes from the shared defaults, which
			-- the config module loads fail-fast; substituting a literal would repaint
			-- the user's categories a shade nothing else in the product uses.
			local neutral = config.get_neutral_color()
			for id, category in pairs(config.get_categories()) do
				set_override(state, id, nil, "color", neutral)
				for _, section in ipairs(type(category) == "table" and category.sections_order or {}) do
					set_override(state, id, section, "color", nil)
				end
			end
		else
			Logger.error(LOG, "'set_all_grey' needs get_categories and get_neutral_color — nothing changed.")
		end
		return _build_initial_payload(state)
	end

	if action == "reset_all" then
		-- Overrides only. This used to call config.reset_defaults() first, and on
		-- this driver that is `return M.enable_all()` — so a user who had switched
		-- off, say, autocorrection and rolls, and then clicked reset to undo a
		-- colour experiment, silently got every disabled pack switched back on and
		-- thousands of expansions firing again. Neither reference driver touches
		-- enablement here: macOS clears overrides category by category and section
		-- by section, and that is the whole contract of this button.
		if state.config and type(state.config.get_categories) == "function"
			and type(state.config.clear_override) == "function" then
			for id, category in pairs(state.config.get_categories()) do
				state.config.clear_override(id, nil)
				-- Sections too: a per-section delay left behind after "reset
				-- everything" is a setting the user cannot see and did not keep.
				for _, section in ipairs(type(category) == "table" and category.sections_order or {}) do
					state.config.clear_override(id, section)
				end
			end
		end
		return _build_initial_payload(state)
	end

	if action == "close" then
		-- The window's own close button. Answered so the host can tear the webview
		-- down; a window whose X does nothing is one the user force-quits, and on a
		-- webview host that can leave the process running with no visible window.
		Logger.info(LOG, "Hotstrings settings window closed.")
		if type(state) == "table" and type(state.close_webview) == "function" then
			pcall(state.close_webview, "hotstrings_config")
		end
		return nil
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
