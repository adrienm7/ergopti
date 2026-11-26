--- tests/unit/menu/ui/tray/test_reading_font_titles.lua

--- ==============================================================================
--- MODULE: Tray Menu Drawn in the Reading Font
--- DESCRIPTION:
--- The reading font chosen in Configuration > Accessibility draws the tray
--- menu as well as the windows (maintainer decision 2026-11-24): every plain
--- title of the finished tree becomes styled text in the face menu_faces.json
--- names, at the system menu size, a disabled row in the disabled text colour
--- AppKit no longer applies to a styled title; a shortcut hint row keeps its
--- grey hint span and takes the face; separators and the pill's empty title
--- stay as they are. The pass runs after the root compositions and the hints,
--- and the pill measures the rows in the face. The default font leaves the
--- tree untouched, and a face AppKit does not know changes nothing and is
--- reported. A click path names a styled row by its characters.
---
--- ROOT CAUSE ENCODED: the menu builder drew every title as a plain string, so
--- the tray stayed in the system font whatever the reader chose.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A stand-in for hs.styledtext: spans of text with their attributes, which
--- concatenate and restyle (setStyle merges) as the real object does.
--- @param valid boolean Whether the face is known.
--- @return table styledtext
local function fake_styledtext(valid)
	local styled = {}
	local Meta = {}
	local function make(spans)
		local object = { spans = spans }
		function object.getString(self)
			local parts = {}
			for _, span in ipairs(self.spans) do parts[#parts + 1] = span.text end
			return table.concat(parts)
		end
		function object.setStyle(self, attributes)
			local copy = {}
			for index, span in ipairs(self.spans) do
				local merged = {}
				for key, value in pairs(span.attributes) do merged[key] = value end
				for key, value in pairs(attributes) do merged[key] = value end
				copy[index] = { text = span.text, attributes = merged }
			end
			return make(copy)
		end
		return setmetatable(object, Meta)
	end
	Meta.__concat = function(left, right)
		local spans = {}
		for _, span in ipairs(left.spans) do spans[#spans + 1] = span end
		for _, span in ipairs(right.spans) do spans[#spans + 1] = span end
		return make(spans)
	end
	styled.defaultFonts = { menu = { name = ".AppleSystemUIFont", size = 14 } }
	styled.validFont = function(name) return valid and name == "OpenDyslexic-Regular" end
	styled.new = function(text, attributes) return make({ { text = text, attributes = attributes or {} } }) end
	return styled
end

--- Runs a callback with hs.styledtext replaced.
local function with_styledtext(styled, callback)
	local saved = hs.styledtext
	hs.styledtext = styled
	local ok, err = pcall(callback)
	hs.styledtext = saved
	if not ok then error(err, 0) end
end

--- Runs a callback with some package.loaded entries replaced.
local function with_loaded(entries, callback)
	local saved = {}
	for name, value in pairs(entries) do
		saved[name] = package.loaded[name]
		package.loaded[name] = value
	end
	local ok, err = pcall(callback)
	for name in pairs(entries) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

local FACE = { name = "OpenDyslexic-Regular", size = 14 }

--- A finished tree with every kind of row the restyler meets.
local function sample_tree()
	return {
		{ title = "", image = "pill", fn = function() end },
		{ title = "-" },
		{ title = "Configuration 🟡", menu = {
			{ title = "— Accessibility —", disabled = true },
			{ title = "Font of the windows and menus: OpenDyslexic", checked = true, fn = function() end },
		} },
		{ title = "Quit", fn = function() end },
	}
end

helpers.describe("macOS tray menu drawn in the reading font (reading-font-menus)", function()
	helpers.it("styles every plain title in the face, the disabled ones in the disabled colour", function()
		local Adapter = helpers.load_with_stubs("tray.adapters.menu_font")
		local tree = sample_tree()
		with_styledtext(fake_styledtext(true), function()
			local count, err = Adapter.restyle(tree, FACE)
			helpers.assert_nil(err)
			helpers.assert_eq(count, 4)
		end)
		helpers.assert_eq(tree[1].title, "", "the pill keeps its empty title")
		helpers.assert_eq(tree[1].image, "pill")
		helpers.assert_eq(tree[2].title, "-", "a separator stays a separator")
		local parent = tree[3].title.spans[1]
		helpers.assert_eq(parent.text, "Configuration 🟡", "the status dot stays in the text")
		helpers.assert_eq(parent.attributes.font.name, "OpenDyslexic-Regular")
		helpers.assert_eq(parent.attributes.font.size, 14, "the system menu size")
		helpers.assert_eq(parent.attributes.color.name, "labelColor")
		local header = tree[3].menu[1]
		helpers.assert_eq(header.title.spans[1].attributes.color.name, "disabledControlTextColor",
			"a disabled row is drawn grey by its title")
		helpers.assert_eq(header.disabled, true, "the row stays disabled")
		local choice = tree[3].menu[2]
		helpers.assert_eq(choice.checked, true, "the check mark is the item's, untouched")
		helpers.assert_eq(type(tree[3].menu), "table", "the submenu stays")
	end)

	helpers.it("gives a shortcut hint row the face and keeps its grey hint", function()
		local Adapter = helpers.load_with_stubs("tray.adapters.menu_font")
		local ShortcutHint = require("menu.ui.builder.shortcut_hint")
		with_styledtext(fake_styledtext(true), function()
			local rows = { { title = ShortcutHint.title("Reload", "AltGr+R", false), fn = function() end } }
			helpers.assert_eq(Adapter.restyle(rows, FACE), 1)
			local spans = rows[1].title.spans
			helpers.assert_eq(rows[1].title:getString(), "Reload    AltGr+R", "the label and its hint stay one title")
			helpers.assert_eq(spans[1].attributes.font.name, "OpenDyslexic-Regular", "the label takes the face")
			helpers.assert_eq(spans[2].attributes.font.name, "OpenDyslexic-Regular", "the hint takes the face")
			helpers.assert_eq(spans[2].attributes.color.name, "secondaryLabelColor", "the hint stays grey")
		end)
	end)

	helpers.it("refuses a face AppKit does not know, and the titles stay", function()
		local ReadingFont = helpers.load_with_stubs("menu.ui.builder.reading_font")
		-- Loaded last: each load installs a fresh hs stub, here with the double.
		local Adapter = helpers.load_with_stubs("tray.adapters.menu_font", { styledtext = fake_styledtext(false) })
		local font, err = Adapter.font_attributes("OpenDyslexic-Regular")
		helpers.assert_nil(font)
		helpers.assert_true(tostring(err):find("OpenDyslexic-Regular", 1, true) ~= nil, tostring(err))
		local tree = sample_tree()
		helpers.assert_nil(ReadingFont.font({ font = "dyslexic", adapter = Adapter }), "a refused face draws the system font")
		helpers.assert_eq(ReadingFont.apply(tree, { font = "dyslexic", adapter = Adapter }), 0)
		helpers.assert_eq(tree[4].title, "Quit")
	end)

	helpers.it("names the chosen font's face from menu_faces.json and leaves the default alone", function()
		local ReadingFont = helpers.load_with_stubs("menu.ui.builder.reading_font")
		local asked = {}
		local adapter = {
			read_file = require("tray.adapters.menu_font").read_file,
			font_attributes = function(postscript) asked[#asked + 1] = postscript; return { name = postscript, size = 13 } end,
			restyle = function() return 7 end,
		}
		helpers.assert_nil(ReadingFont.font({ font = "default", adapter = adapter }))
		helpers.assert_eq(ReadingFont.apply({}, { font = "default", adapter = adapter }), 0)
		helpers.assert_eq(#asked, 0, "the default font names no face")
		helpers.assert_eq(ReadingFont.font({ font = "dyslexic", adapter = adapter }).name, "OpenDyslexic-Regular")
		helpers.assert_eq(ReadingFont.apply({}, { font = "hyperlegible", adapter = adapter }), 7)
		helpers.assert_eq(table.concat(asked, ","), "OpenDyslexic-Regular,AtkinsonHyperlegible-Regular")
		helpers.assert_nil(ReadingFont.font({ font = "dyslexic", adapter = adapter, fonts_dir = "/nonexistent/fonts" }),
			"an unreadable face manifest is an error")
	end)

	helpers.it("draws the real tray tree in the chosen font, last, and the pill measures in it", function()
		local events, measured = {}, {}
		local adapter = {
			read_file = require("tray.adapters.menu_font").read_file,
			font_attributes = function(postscript)
				events[#events + 1] = "face"
				return { name = postscript, size = 14 }
			end,
			restyle = function(items, font)
				events[#events + 1] = { items = items, font = font }
				return #items
			end,
		}
		local function build(font)
			local rows
			with_loaded({
				["tray.adapters.menu_font"] = adapter,
				["core.ui.engine.webview.reading_font"] = { get = function() return font end },
			}, function()
				local builder = helpers.load_with_stubs("menu.ui.builder.builder")
				local i18n = require("core.i18n.engine.i18n")
				i18n.build_language_menu_items = function() return {} end
				-- The badge module the builder holds, spied for this build.
				local badge = package.loaded["menu.ui.builder.canvas_badge"]
				local measure = badge.measure_rows_in
				badge.measure_rows_in = function(face)
					measured[#measured + 1] = face and face.name or false
					return measure(face)
				end
				local ok, err = pcall(function()
					rows = builder.generate({ paused = false }, {}, { reload = function() end, quit = function() end })
				end)
				badge.measure_rows_in = measure
				if not ok then error(err, 0) end
			end)
			return rows
		end
		local plain = build("default")
		helpers.assert_eq(#events, 0, "the default font names no face and restyles nothing")
		helpers.assert_true(#plain > 0)
		local rows = build("dyslexic")
		helpers.assert_eq(#events, 2, "the face is named once per build; one restyle")
		helpers.assert_eq(events[1], "face")
		helpers.assert_eq(events[2].font.name, "OpenDyslexic-Regular", "the restyle comes last")
		helpers.assert_true(rawequal(events[2].items, rows), "the published tree is the restyled one")
		helpers.assert_eq(measured[#measured], "OpenDyslexic-Regular", "the pill measures the rows in the face")
		helpers.assert_eq(measured[#measured - 1], false, "the default font measures in the system font")
	end)

	helpers.it("names a styled row by its characters in a click path", function()
		local ClickIntent = require("menu.engine.click_intent")
		local styled = fake_styledtext(true).new("Quit", {})
		helpers.assert_eq(ClickIntent.title_text(styled), "Quit")
		helpers.assert_eq(ClickIntent.child_path({ "Configuration" }, styled)[2], "Quit")
	end)
end)
