--- diagnostics/adapters/tray_check_ports.lua

--- ==============================================================================
--- MODULE: Tray Check Ports (Linux)
--- DESCRIPTION:
--- The native side of the field run's « tray » check
--- (diagnostics/engine/field_check/tray_check.lua): this daemon's unique name
--- on the session bus, the busctl requests (diagnostics/adapters/bus_query.lua),
--- the event loop's timer, the labels the menu must show in the user's
--- language, the running layout emulation and config.toml's bytes.
---
--- FEATURES & RATIONALE:
--- 1. Every expected label comes from where the tray takes it: the shared menu
---    declaration (_shared/menu/data/menu.toml) for the captions and section
---    titles, the shortcut hint owner for the chords beside « Suspendre »,
---    « Recharger » and « Quitter », the component status for the red rows.
--- 2. A request is bounded by a share of the step's deadline, so the check's
---    requests together never outlast it.
--- ==============================================================================

local M = {}

-- The check's requests share its step's deadline: about forty run one after
-- the other, most answering in milliseconds; this bound leaves a hung one
-- room to fail by name before the step's own deadline (constants.toml [adapters]).
M.REQUEST_SHARE = require("core.timing.engine.timings").count("adapters", "field_tray_request_share")

--- Whether a declared row is drawn on Linux.
local function for_linux(item)
	if type(item) ~= "table" then return false end
	if type(item.platforms) ~= "table" then return true end
	for _, name in ipairs(item.platforms) do
		if name == "linux" then return true end
	end
	return false
end

--- The caption of a top-level row, in the user's language.
local function caption(top_level, id, t)
	for _, item in ipairs(top_level) do
		if item.id == id and for_linux(item) and type(item.i18n) == "string" then return t(item.i18n) end
	end
	error("tray check: the menu declares no Linux top-level row " .. id)
end

--- The section titles of a declared submenu, in order.
local function section_titles(rows, I18n)
	local titles = {}
	for _, item in ipairs(rows) do
		if for_linux(item) and item.type == "section_header" then titles[#titles + 1] = I18n.section(item.i18n) end
	end
	return titles
end

--- The check rows that open a declared section, in order.
local function section_switches(rows, header_key, t)
	local switches, inside = {}, false
	for _, item in ipairs(rows) do
		if inside then
			if item.type ~= "check" then break end
			if for_linux(item) then switches[#switches + 1] = t(item.i18n) end
		elseif item.type == "section_header" and item.i18n == header_key then
			inside = true
		end
	end
	return switches
end

--- The labels, captions and states the live menu must show.
--- @return table expect
local function expectations()
	local I18n = require("core.i18n.engine.i18n")
	local t = I18n.get
	local Manifest = require("menu.engine.manifest_menu")
	local TrayHints = require("menu.engine.tray_shortcut_hints")
	local ShortcutHint = require("menu.ui.builder.shortcut_hint")
	local ScriptChords = require("modules.shortcuts.script_chords")
	local top = Manifest.get_array("top_level")
	local function script_row(id)
		local base = caption(top, id, t)
		local slot = ScriptChords.hint_slot(TrayHints.ACTIONS[id])
		return { id = id, base = base, label = slot and ShortcutHint.compose(t, base, t("sg_labels." .. slot)) or base }
	end
	local configuration = Manifest.get_array("configuration_menu")
	local reading_font = nil
	for _, item in ipairs(configuration) do
		if item.id == "reading_font" and for_linux(item) then reading_font = t(item.i18n) end
	end
	local debug_rows = Manifest.get_array("debug_menu")
	local logs_header = "menu.debug.header_logs"
	local LevelSetting = require("core.logger.engine.level_setting")
	local log_entry = require("menu.engine.manifest_reader").find_entry_by_path(
		require("settings.engine.keys").KEY.SCRIPT_LOG_LEVEL)
	local dot = nil
	for _, item in ipairs(top) do
		if item.id == "llm" and type(item.health_dot) == "table" then dot = item.health_dot.unreachable end
	end
	return {
		indicator_id = require("tray.adapters.menu").INDICATOR_ID,
		suspend = script_row("suspend"), reload = script_row("reload"), quit = script_row("quit"),
		checkable_groups = { caption(top, "hotstrings", t), caption(top, "shortcuts", t) },
		layout_group = caption(top, "keyboard_layout", t),
		emulated = t("menu.layout.emulated_layout"),
		configuration = caption(top, "configuration", t),
		configuration_titles = section_titles(configuration, I18n),
		reading_font = reading_font or error("tray check: the menu declares no Linux reading font row"),
		debug = caption(top, "debug", t),
		console = t("menu.debug.console"),
		logs_title = I18n.section(logs_header),
		logs_switches = section_switches(debug_rows, logs_header, t),
		detailed_log = LevelSetting.is_detailed(require("settings.engine.scope.script_settings").current(), log_entry,
			require("core.logger.engine")),
		problem_dot = dot,
		problem_count = #require("core.ui.engine.component_status").current(),
	}
end

--- config.toml as it is now.
local function config_snapshot()
	local Writer = require("core.text.engine.toml_codec.writer")
	local path = require("settings.engine.paths").config("config.toml")
	local content, status = Writer.read_classified(path)
	return { path = path, status = status, content = content }
end

--- Puts config.toml back to a snapshot when the writer left other bytes.
--- @param snapshot table From config_snapshot().
--- @return boolean restored True when the file holds the snapshot's bytes.
local function config_restore(snapshot)
	local Writer = require("core.text.engine.toml_codec.writer")
	local Logger = require("core.logger.engine.shim")
	local now = config_snapshot()
	if snapshot.status ~= "ok" and snapshot.status ~= "absent" then return false end
	if now.status == snapshot.status and now.content == snapshot.content then return true end
	if now.status ~= "ok" and now.status ~= "absent" then return false end
	local committed, why
	if snapshot.status == "absent" then
		committed, why = Writer.remove_if_unchanged(snapshot.path, nil, { status = "ok", content = now.content })
	else
		committed, why = Writer.publish_if_unchanged(snapshot.path, snapshot.content, nil,
			{ status = now.status, content = now.content })
	end
	if committed ~= true then
		Logger.error("diagnostics.adapters.tray_check_ports",
			"config.toml could not be put back after the tray check: %s.", tostring(why))
		return false
	end
	Logger.info("diagnostics.adapters.tray_check_ports", "config.toml put back as it was before the tray check.")
	return true
end

--- Builds the ports.
--- @param check string The check's id in the field run declaration.
--- @return table ports
function M.new(check)
	local deadline_ms = require("diagnostics.adapters.setup_check_ports").step_deadline_ms(check)
	local Loop = require("core.events.loop")
	return {
		bus_name = function() return require("tray.adapters.status_notifier_host").own_bus_name() end,
		bus = require("diagnostics.adapters.bus_query").new(deadline_ms / M.REQUEST_SHARE),
		after = function(ms, fn)
			if not Loop.defer(fn, ms) then error("tray check: the event loop refused a timer") end
			return true
		end,
		expect = expectations,
		emulation_state = function()
			local status = require("modules.keymap.layout_emulation").status()
			return status.active == true and tostring(status.id) or "none"
		end,
		config_snapshot = config_snapshot,
		config_restore = config_restore,
	}
end

return M
