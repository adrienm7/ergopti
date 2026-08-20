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
local Extensions = require("hotstrings.extensions")
local LOG = "bridge.hotstrings_config"

-- The page's directory under _shared/ui/, which is both where its HTML is read
-- from and the key eval_js finds a live webview by.
local APP_NAME = "hotstrings_config_window"

-- The category id holding the user's own hotstrings, which the window puts in a
-- group of its own rather than among the shipped packs.
local PERSONAL_CATEGORY = "personal"

-- The colour palette the window offers. Deliberately identical to
-- macos/ui/hotstrings_config_window/init.lua COLOR_PRESETS, and duplicated rather
-- than shared because the shared hotstrings TOML reader parses scalars only — it
-- has no array support, so an ordered palette cannot be expressed in
-- _shared/modules/hotstrings/defaults.toml the way the three single colours are.
-- tools/test/test-color-presets-parity.cjs is what keeps the two lists equal;
-- without it this is exactly the second source rule 5.2 forbids.
local COLOR_PRESETS = {
	{ i18n = "hs_config.color_red",    hex = "#e53935" },
	{ i18n = "hs_config.color_green",  hex = "#43a047" },
	{ i18n = "hs_config.color_orange", hex = "#fb8c00" },
	{ i18n = "hs_config.color_blue",   hex = "#1e88e5" },
	{ i18n = "hs_config.color_purple", hex = "#8e44ad" },
	{ i18n = "hs_config.color_cyan",   hex = "#00838f" },
	{ i18n = "hs_config.color_yellow", hex = "#fdd835" },
	{ i18n = "hs_config.color_gray",   hex = "#6e6e73" },
}

--- Translates a key, falling back to the key itself.
---
--- pcall'd for the same reason the menu's i18n_safe is: this window must still
--- draw when the shared locale tree is unreachable, which is a real partial
--- install rather than a hypothetical.
--- @param key string
--- @return string
local function i18n_label(key)
	local ok, i18n = pcall(require, "infra.i18n")
	if not ok or type(i18n.get) ~= "function" then return key end
	local value = i18n.get(key)
	return (type(value) == "string" and value ~= "") and value or key
end

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

--- Converts seconds to the milliseconds the window shows.
--- @param seconds number|nil
--- @return integer|nil
local function to_ms(seconds)
	if type(seconds) ~= "number" then return nil end
	return math.floor(seconds * MS_PER_SEC + 0.5)
end

--- The localised display name of a category, or its file stem.
--- @param id string
--- @param category table|nil
--- @return string
local function category_title(id, category)
	local description = category and category.description or nil
	if type(description) ~= "table" then return id end
	local locale = "en"
	local ok_i18n, i18n = pcall(require, "infra.i18n")
	if ok_i18n and type(i18n.get_locale) == "function" then
		local current = i18n.get_locale()
		if type(current) == "string" and current ~= "" then locale = current end
	end
	return description[locale] or description.en or id
end

--- Builds one category entry in the shape the page destructures.
--- @param config table The hotstrings config module.
--- @param id string
--- @param category table Loader metadata.
--- @param group string "common" | "personal" | "ext:<id>"
--- @return table
local function build_category_entry(config, id, category, group)
	--- @param section string|nil
	--- @return table
	local function fields_for(section)
		local effective = config.resolve(id, section) or {}
		local declared  = config.get_toml_defaults(id, section) or {}
		local override  = config.get_user_override(id, section) or {}

		-- show_tooltip defaults to shown; the cascade already applied that, so a
		-- nil here means the resolver could not answer at all.
		local shown = effective.show_tooltip
		if shown == nil then shown = true end

		return {
			delay_ms                = to_ms(effective.delay),
			delay_default_ms        = to_ms(declared.delay),
			delay_overridden        = override.delay ~= nil,
			color                   = effective.color,
			color_default           = declared.color,
			color_overridden        = override.color ~= nil,
			show_tooltip            = shown,
			show_tooltip_overridden = override.show_tooltip ~= nil,
			priority                = override.priority or declared.priority,
			priority_default        = declared.priority,
			priority_overridden     = override.priority ~= nil,
		}
	end

	local entry = fields_for(nil)
	entry.name     = id
	entry.group    = group
	entry.title    = category_title(id, category)
	entry.sections = {}

	for _, name in ipairs(category and category.sections_order or {}) do
		local section = fields_for(name)
		section.name  = name
		section.title = name
		entry.sections[#entry.sections + 1] = section
	end

	return entry
end

--- Builds the payload the settings page renders from.
---
--- Every key here is one `_shared/ui/hotstrings_config_window/script.js` reads.
--- It used to return `{ groups = {{ name, enabled }}, mapping_count,
--- parse_errors, config_dir }` — four keys, not one of which the page destructures.
--- `render()` walks `state.categories` and `state.presets`, and the group selector
--- wants `{ key, label }`, so the window drew an empty page with a selector full of
--- blank entries even on the one call site that reached it with a bridge attached.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local config = state and state.config
	-- The page wants { label, hex }; the constant holds the i18n key so the label
	-- is resolved in the user's language at build time rather than baked in.
	local presets = {}
	for _, preset in ipairs(COLOR_PRESETS) do
		presets[#presets + 1] = { label = i18n_label(preset.i18n), hex = preset.hex }
	end

	local out = {
		categories              = {},
		groups                  = {},
		presets                 = presets,
		global_default_delay_ms = 0,
	}

	if type(config) ~= "table" or type(config.resolve) ~= "function" then
		Logger.error(LOG, "No hotstrings config module — the settings window has nothing to show.")
		return out
	end

	if type(config.get_global_default_delay_ms) == "function" then
		out.global_default_delay_ms = config.get_global_default_delay_ms()
	end

	-- One group per family, and only when it has members: the selector shows every
	-- key it is given, so an empty "Extensions" entry is a dead option.
	local seen_group = {}
	--- @param key string
	--- @param label_key string
	local function ensure_group(key, label_key)
		if seen_group[key] then return end
		seen_group[key] = true
		out.groups[#out.groups + 1] = { key = key, label = i18n_label(label_key) }
	end

	local order = type(config.get_category_order) == "function" and config.get_category_order() or nil
	if type(order) ~= "table" or #order == 0 then
		order = {}
		for id in pairs(config.get_categories() or {}) do order[#order + 1] = id end
		table.sort(order)
	end

	local categories = config.get_categories() or {}
	for _, id in ipairs(order) do
		local category = categories[id]
		if category then
			local extension_id = Extensions.parse_category_key(id)
			local group, label_key
			if extension_id then
				group, label_key = "ext:" .. extension_id, "hs_config.group_extensions"
			elseif id == PERSONAL_CATEGORY then
				group, label_key = "personal", "hs_config.group_personal"
			else
				group, label_key = "common", "hs_config.group_common"
			end
			ensure_group(group, label_key)
			out.categories[#out.categories + 1] = build_category_entry(config, id, category, group)
		end
	end

	return out
end

--- Pushes the payload into the page by calling its own entry point.
---
--- The page has no reader for a bridge response: `makeHostBridge` is
--- fire-and-forget, and only two of the fourteen shared pages define
--- `window.__hostBridgeResponse` at all — this is not one of them. So a returned
--- payload reached nobody. macOS pushes `setData(...)`; so does this now.
--- @param state table Daemon state.
--- @return boolean
local function push_state(state)
	local ok_json, json_mod = pcall(require, "json")
	if not ok_json or type(json_mod.encode) ~= "function" then
		Logger.error(LOG, "Cannot push setData(): the shared json module is unavailable.")
		return false
	end
	local ok_payload, encoded = pcall(function()
		return json_mod.encode(_build_initial_payload(state))
	end)
	if not ok_payload or type(encoded) ~= "string" then
		Logger.error(LOG, "Cannot push setData(): payload encoding failed (%s).", tostring(encoded))
		return false
	end

	local ok_mgr, Manager = pcall(require, "ui.webview_manager")
	if not ok_mgr or type(Manager.eval_js) ~= "function" then
		Logger.error(LOG, "Cannot push setData(): webview_manager.eval_js is unavailable.")
		return false
	end
	return Manager.eval_js(APP_NAME, "if(window.setData)setData(" .. encoded .. ")")
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
			return push_state(state)
		end
		if payload == "refresh" then
			return push_state(state)
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
			return push_state(state)
		end
		set_override(state, payload.category, section_of(payload), "delay", ms / MS_PER_SEC)
		return push_state(state)
	end

	if action == "clear_delay" and payload.category then
		set_override(state, payload.category, section_of(payload), "delay", nil)
		return push_state(state)
	end

	if action == "set_color" and payload.category then
		-- Guarded like both references: an empty select is the page's "no choice",
		-- and writing it as an override would pin the category to nothing.
		local hex = payload.hex
		if type(hex) ~= "string" or hex == "" then
			Logger.warn(LOG, "Refusing colour %s for '%s' — not a colour string.",
				tostring(hex), tostring(payload.category))
			return push_state(state)
		end
		set_override(state, payload.category, section_of(payload), "color", hex)
		return push_state(state)
	end

	if action == "clear_color" and payload.category then
		set_override(state, payload.category, section_of(payload), "color", nil)
		return push_state(state)
	end

	if action == "set_tooltip" and payload.category then
		-- Coerced rather than passed through: the window sends a JSON boolean,
		-- and a string "false" is truthy in Lua — which would turn the preview on
		-- for a user who had just turned it off.
		local value = payload.show_tooltip
		if type(value) == "string" then value = (value == "true") end
		set_override(state, payload.category, section_of(payload), "show_tooltip", value == true)
		return push_state(state)
	end

	if action == "clear_tooltip" and payload.category then
		set_override(state, payload.category, section_of(payload), "show_tooltip", nil)
		return push_state(state)
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
			return push_state(state)
		end
		set_override(state, payload.category, section_of(payload), "priority", value)
		return push_state(state)
	end

	if action == "clear_priority" and payload.category then
		set_override(state, payload.category, section_of(payload), "priority", nil)
		return push_state(state)
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
		return push_state(state)
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
		return push_state(state)
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
