--- tests/unit/menu/ui/tray/test_shortcut_hint.lua

--- ==============================================================================
--- MODULE: Tray Shortcut Hints
--- DESCRIPTION:
--- The tray shows, beside « Suspendre », « Recharger » and « Quitter », the
--- chord bound to the same action (maintainer, 2026-11-24), named as the
--- Shortcuts submenu names it, in the secondary label colour; no hint when no
--- chord runs the action. Replays the shared hint vectors first.
---
--- ROOT CAUSE ENCODED: the three rows showed their caption only, so the chord
--- that pauses, reloads or quits was written nowhere in the tray.
--- ==============================================================================

local helpers = require("tests.helpers")
require("tests.lua.keyboard.script_chord_hint_contract").register(helpers,
	require("core.text.engine.json"), helpers.shared(""))

-- A styled text double: the spans it was built from, concatenated by `..`.
local Styled = {}
Styled.__index = Styled
Styled.__concat = function(left, right)
	local spans = {}
	for _, span in ipairs(left.spans) do spans[#spans + 1] = span end
	for _, span in ipairs(right.spans) do spans[#spans + 1] = span end
	return setmetatable({ spans = spans }, Styled)
end
Styled.__tostring = function(self)
	local parts = {}
	for index, span in ipairs(self.spans) do parts[index] = span.text end
	return table.concat(parts)
end

--- Builds the real tray root with recorded styled titles.
--- @param control table The script-control double.
--- @param paused boolean|nil
--- @param spy function|nil Receives the badge module the builder holds and
---   returns the function that restores it.
--- @return table rows
local function root(control, paused, spy)
	-- The hint and its adapter read the hs stub of this load, not an earlier one.
	package.loaded["core.ui.adapters.styled_title"] = nil
	package.loaded["menu.ui.builder.shortcut_hint"] = nil
	local builder = helpers.load_with_stubs("menu.ui.builder.builder")
	local i18n = require("core.i18n.engine.i18n")
	i18n.build_language_menu_items = function() return {} end
	local saved = hs.styledtext.new
	hs.styledtext.new = function(text, attributes)
		return setmetatable({ spans = { { text = text, attributes = attributes } } }, Styled)
	end
	local restore = spy and spy(package.loaded["menu.ui.builder.canvas_badge"]) or nil
	local ok, rows = pcall(builder.generate, { paused = paused == true, script_control = control }, {},
		{ reload = function() end, quit = function() end })
	if restore then restore() end
	hs.styledtext.new = saved
	if not ok then error(rows, 0) end
	return rows
end

--- A script-control double whose chords hold `assignments` under the real rule.
--- @param assignments table Slot id -> action id.
--- @param chords_on boolean|nil The switch, on by default.
--- @return table control
local function control(assignments, chords_on)
	local ScriptChords = require("keyboard.engine.layers.script_chords")
	local catalogue = require("infra.script_chord_catalogue").get()
	return {
		toggle_script_control = function() return true end,
		script_chord_hint_slot = function(action)
			return ScriptChords.hint_slot(catalogue, assignments, chords_on ~= false, action)
		end,
	}
end

local PRESETS = {
	script_altgr_enter = "script_pause_toggle", script_altgr_backspace = "script_reload",
	script_altgr_delete = "open_personal_shortcuts", script_altgr_escape = "script_quit",
}

--- The root row whose title starts with a locale key's caption.
--- @param rows table
--- @param key string
--- @return table|nil row
local function row_for(rows, key)
	local caption = require("core.i18n.engine.i18n").get(key)
	for _, row in ipairs(rows) do
		local text = type(row.title) == "string" and row.title or (type(row.title) == "table" and tostring(row.title))
		if text and text:sub(1, #caption) == caption then return row end
	end
	return nil
end

helpers.describe("macOS tray shortcut hints (script-chord-tray-hint)", function()
	helpers.it("names each preset chord as the Shortcuts submenu does, in the secondary colour", function()
		local rows = root(control(PRESETS))
		local i18n = require("core.i18n.engine.i18n")
		for key, label in pairs({
			["menu.global.suspend"] = "sg_labels.script_ropt_return",
			["menu.global.reload_macos"] = "sg_labels.script_ropt_backspace",
			["menu.global.quit_macos"] = "sg_labels.script_ropt_escape",
		}) do
			local row = row_for(rows, key)
			helpers.assert_true(row ~= nil, key .. " is drawn")
			helpers.assert_eq(type(row.title), "table", key .. " carries a styled title")
			local spans = row.title.spans
			helpers.assert_eq(#spans, 2, key .. ": the caption, then the hint")
			helpers.assert_eq(spans[1].text, i18n.get(key))
			helpers.assert_true(spans[2].text:find(i18n.get(label), 1, true) ~= nil, key .. " names its chord")
			helpers.assert_eq(spans[2].attributes.color.name, "secondaryLabelColor")
			helpers.assert_eq(spans[1].attributes.color, nil, "the caption keeps the label colour")
			helpers.assert_eq(spans[1].attributes.font.name, spans[2].attributes.font.name, "one menu font")
			helpers.assert_eq(type(row.fn), "function", "the row still runs its action")
		end
	end)

	helpers.it("keeps Suspendre's checkmark beside its hint", function()
		local row = row_for(root(control(PRESETS), true), "menu.global.suspend")
		helpers.assert_eq(row.checked, true)
		helpers.assert_eq(type(row.title), "table")
	end)

	helpers.it("follows a chord moved to another slot and shows the first of two", function()
		local rows = root(control({ script_altgr_enter = "script_quit", script_altgr_escape = "script_quit",
			script_altgr_backspace = "none", script_altgr_delete = "none" }))
		local quit = row_for(rows, "menu.global.quit_macos")
		local i18n = require("core.i18n.engine.i18n")
		helpers.assert_true(quit.title.spans[2].text:find(i18n.get("sg_labels.script_ropt_return"), 1, true) ~= nil)
		helpers.assert_eq(type(row_for(rows, "menu.global.reload_macos").title), "string", "an unbound action has no hint")
	end)

	helpers.it("shows no hint while the chords' switch is off", function()
		local rows = root(control(PRESETS, false))
		for _, key in ipairs({ "menu.global.suspend", "menu.global.reload_macos", "menu.global.quit_macos" }) do
			helpers.assert_eq(row_for(rows, key).title, require("core.i18n.engine.i18n").get(key))
		end
	end)

	helpers.it("greys the whole styled title of a disabled row", function()
		package.loaded["core.ui.adapters.styled_title"] = nil
		local Hint = helpers.load_with_stubs("menu.ui.builder.shortcut_hint")
		local saved = hs.styledtext.new
		hs.styledtext.new = function(text, attributes)
			return setmetatable({ spans = { { text = text, attributes = attributes } } }, Styled)
		end
		local ok, title = pcall(Hint.title, "Reload", "Hint", true)
		hs.styledtext.new = saved
		helpers.assert_true(ok, tostring(title))
		helpers.assert_eq(title.spans[1].attributes.color.name, "disabledControlTextColor")
		helpers.assert_eq(title.spans[2].attributes.color.name, "disabledControlTextColor")
	end)

	-- v1.0.10 field photo of 2026-11-26: the header pill sat right of the menu's
	-- middle because it measured « Suspendre » before its hint made it the
	-- widest row (canvas_badge.lua, « Measured As Drawn »).
	helpers.it("hands the header pill the hinted titles before they are drawn", function()
		local seen
		local ok, rows = pcall(root, control(PRESETS), false, function(badge)
			local prepend = badge.prepend_to
			badge.prepend_to = function(items, ctx, on_click, drawn_titles)
				local suspend = row_for(items, "menu.global.suspend")
				seen = { suspend = suspend, title = suspend and suspend.title,
					drawn = type(drawn_titles) == "table" and suspend and drawn_titles[suspend] or nil }
				return prepend(items, ctx, on_click, drawn_titles)
			end
			return function() badge.prepend_to = prepend end
		end)
		helpers.assert_true(ok, tostring(rows))
		helpers.assert_true(seen ~= nil and seen.suspend ~= nil, "the badge sees the Suspend row")
		helpers.assert_eq(seen.title, require("core.i18n.engine.i18n").get("menu.global.suspend"),
			"the row still holds its plain caption when the badge measures it")
		helpers.assert_eq(type(seen.drawn), "table", "the badge receives the hinted title")
		helpers.assert_eq(tostring(seen.drawn), tostring(row_for(rows, "menu.global.suspend").title),
			"the measured title is the one the menu draws")
	end)

	helpers.it("previews the hinted titles without changing the rows", function()
		package.loaded["core.ui.adapters.styled_title"] = nil
		package.loaded["menu.ui.builder.shortcut_hint"] = nil
		local Hint = helpers.load_with_stubs("menu.ui.builder.shortcut_hint")
		local i18n = require("core.i18n.engine.i18n")
		local saved = hs.styledtext.new
		hs.styledtext.new = function(text, attributes)
			return setmetatable({ spans = { { text = text, attributes = attributes } } }, Styled)
		end
		local suspend = { title = i18n.get("menu.global.suspend") }
		local other = { title = "Other" }
		local ok, titles = pcall(Hint.preview, { suspend, other, { title = "-" } }, control(PRESETS))
		hs.styledtext.new = saved
		helpers.assert_true(ok, tostring(titles))
		helpers.assert_eq(suspend.title, i18n.get("menu.global.suspend"), "the row keeps its caption")
		helpers.assert_eq(type(titles[suspend]), "table", "the hinted row has its drawn title")
		helpers.assert_true(tostring(titles[suspend]):find(i18n.get("sg_labels.script_ropt_return"), 1, true) ~= nil)
		helpers.assert_eq(titles[other], nil, "a row without a hint has no preview")
	end)
end)
