--- tests/unit/menu/structure/test_tray_shortcut_hint.lua

--- ==============================================================================
--- MODULE: Tray Shortcut Hints (Linux)
--- DESCRIPTION:
--- The tray shows, beside « Suspendre », « Recharger » and « Quitter », the
--- chord bound to the same action (maintainer, 2026-11-24), named as the
--- Shortcuts submenu names it, in the label text: the tray adapter exports no
--- dbusmenu `shortcut`. No hint when no chord runs the action. Replays the
--- shared hint vectors first.
---
--- ROOT CAUSE ENCODED: the three rows showed their caption only, so the chord
--- that pauses, reloads or quits was written nowhere in the tray.
--- ==============================================================================

local helpers = require("tests.helpers")
require("tests.lua.keyboard.script_chord_hint_contract").register(helpers,
	require("core.text.engine.json"), helpers.driver_root() .. "/../_shared")

local CHORDS = "modules.shortcuts.script_chords"

local PRESETS = {
	script_altgr_enter = "script_pause_toggle", script_altgr_backspace = "script_reload",
	script_altgr_delete = "open_personal_shortcuts", script_altgr_escape = "script_quit",
}

--- Builds the real tray root through the tray build (timed_build, which adds
--- the hints) over chords holding `assignments` under the real rule and the
--- real catalogue.
--- @param assignments table|nil Slot id -> action id; nil makes the owner raise.
--- @param chords_on boolean|nil The switch, on by default.
--- @param paused boolean|nil
--- @return table rows
local function build(assignments, chords_on, paused)
	local ScriptChords = require("keyboard.engine.layers.script_chords")
	local real = require(CHORDS)
	local catalogue = real.catalogue()
	local saved = package.loaded[CHORDS]
	package.loaded[CHORDS] = {
		hint_slot = function(action)
			if assignments == nil then error("configuration unreadable") end
			return ScriptChords.hint_slot(catalogue, assignments, chords_on ~= false, action)
		end,
	}
	local ok, rows = pcall(function()
		local builder = helpers.load_module("menu.ui.builder.builder")
		package.loaded["menu.ui.builder.timed_build"] = nil
		return require("menu.ui.builder.timed_build").run(builder.build, { _version = "9.9.9",
			paused = paused == true, on_quit = function() end, on_toggle_pause = function() return true end })
	end)
	package.loaded[CHORDS] = saved
	if not ok then error(rows, 0) end
	return rows
end

--- The root row whose title starts with a locale key's caption.
--- @param rows table
--- @param key string
--- @return table|nil row
local function row_for(rows, key)
	local caption = require("core.i18n.engine.i18n").get(key)
	for _, row in ipairs(rows) do
		if type(row.title) == "string" and row.title:sub(1, #caption) == caption then return row end
	end
	return nil
end

--- The title the hint template gives a caption and a chord label.
--- @param key string Caption key.
--- @param label string Chord label key.
--- @return string
local function hinted(key, label)
	local i18n = require("core.i18n.engine.i18n")
	return (i18n.get("menu.global.shortcut_hint"):gsub("{1}", i18n.get(key)):gsub("{2}", i18n.get(label)))
end

helpers.describe("Linux tray shortcut hints (script-chord-tray-hint)", function()
	helpers.it("(script-chord-tray-hint) names each preset chord as the Shortcuts submenu does", function()
		local rows = build(PRESETS)
		for key, label in pairs({
			["menu.global.suspend"] = "sg_labels.script_altgr_enter",
			["menu.global.reload"] = "sg_labels.script_altgr_backspace",
			["menu.global.quit"] = "sg_labels.script_altgr_escape",
		}) do
			local row = row_for(rows, key)
			helpers.assert_true(row ~= nil, key .. " is drawn")
			helpers.assert_eq(row.title, hinted(key, label))
			helpers.assert_eq(type(row.fn), "function", key .. " still runs its action")
		end
	end)

	helpers.it("(script-chord-tray-hint) keeps Suspendre's checkmark beside its hint", function()
		local row = row_for(build(PRESETS, true, true), "menu.global.suspend")
		helpers.assert_eq(row.checked, true)
		helpers.assert_eq(row.title, hinted("menu.global.suspend", "sg_labels.script_altgr_enter"))
	end)

	helpers.it("(script-chord-tray-hint) follows a chord moved to another slot and shows the first of two", function()
		local rows = build({ script_altgr_enter = "script_quit", script_altgr_escape = "script_quit",
			script_altgr_backspace = "none", script_altgr_delete = "none" })
		helpers.assert_eq(row_for(rows, "menu.global.quit").title,
			hinted("menu.global.quit", "sg_labels.script_altgr_enter"))
		helpers.assert_eq(row_for(rows, "menu.global.reload").title,
			require("core.i18n.engine.i18n").get("menu.global.reload"), "an unbound action has no hint")
	end)

	helpers.it("(script-chord-tray-hint) shows no hint while the chords' switch is off", function()
		local rows = build(PRESETS, false)
		for _, key in ipairs({ "menu.global.suspend", "menu.global.reload", "menu.global.quit" }) do
			helpers.assert_eq(row_for(rows, key).title, require("core.i18n.engine.i18n").get(key))
		end
	end)

	helpers.it("(script-chord-tray-hint) keeps the rows, without a hint, when the chords cannot be read", function()
		local rows = build(nil)
		helpers.assert_eq(row_for(rows, "menu.global.reload").title,
			require("core.i18n.engine.i18n").get("menu.global.reload"))
	end)

	helpers.it("(script-chord-tray-hint) refuses a template without both places", function()
		local Hint = require("menu.ui.builder.shortcut_hint")
		helpers.assert_eq(pcall(Hint.compose, function() return "{1}" end, "Reload", "AltGr"), false)
		helpers.assert_eq(Hint.compose(function() return "{1} [{2}]" end, "Reload", "AltGr + %1"), "Reload [AltGr + %1]")
	end)
end)

return true
