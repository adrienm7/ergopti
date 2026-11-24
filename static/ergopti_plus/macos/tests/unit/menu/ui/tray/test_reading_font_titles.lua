--- tests/unit/menu/ui/tray/test_reading_font_titles.lua

--- ==============================================================================
--- MODULE: Tray Menu Drawn in the Reading Font
--- DESCRIPTION:
--- The reading font chosen in Configuration > Accessibility draws the tray
--- menu as well as the windows (maintainer decision 2026-11-24): every plain
--- title of the finished tree becomes styled text in the face menu_faces.json
--- names, at the system menu size, a disabled row in the disabled text colour
--- AppKit no longer applies to a styled title; separators, the pill's empty
--- title and already-styled titles stay as they are. The default font leaves
--- the tree untouched, and a face AppKit does not know changes nothing and is
--- reported. A click path names a styled row by its characters.
---
--- ROOT CAUSE ENCODED: the menu builder drew every title as a plain string, so
--- the tray stayed in the system font whatever the reader chose.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A stand-in for hs.styledtext: records the attributes of each styled title.
--- @param valid boolean Whether the face is known.
--- @return table styledtext
local function fake_styledtext(valid)
	local styled = {}
	styled.defaultFonts = { menu = { name = ".AppleSystemUIFont", size = 14 } }
	styled.validFont = function(name) return valid and name == "OpenDyslexic-Regular" end
	styled.new = function(text, attributes)
		return { text = text, attributes = attributes, getString = function(self) return self.text end }
	end
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

--- A finished tree with every kind of row the restyler meets.
local function sample_tree(already_styled)
	return {
		{ title = "", image = "pill", fn = function() end },
		{ title = "-" },
		{ title = "Configuration 🟡", menu = {
			{ title = "— Accessibility —", disabled = true },
			{ title = "Font of the windows and menus: OpenDyslexic", checked = true, fn = function() end },
		} },
		{ title = already_styled },
		{ title = "Quit", fn = function() end },
	}
end

helpers.describe("macOS tray menu drawn in the reading font (reading-font-menus)", function()
	helpers.it("styles every plain title in the face, the disabled ones in the disabled colour", function()
		local Adapter = helpers.load_with_stubs("tray.adapters.menu_font")
		local kept = { "already styled" }
		local tree = sample_tree(kept)
		with_styledtext(fake_styledtext(true), function()
			local count, err = Adapter.restyle(tree, "OpenDyslexic-Regular")
			helpers.assert_nil(err)
			helpers.assert_eq(count, 4)
		end)
		helpers.assert_eq(tree[1].title, "", "the pill keeps its empty title")
		helpers.assert_eq(tree[1].image, "pill")
		helpers.assert_eq(tree[2].title, "-", "a separator stays a separator")
		helpers.assert_true(rawequal(tree[4].title, kept), "a styled title keeps its own look")
		local parent = tree[3].title
		helpers.assert_eq(parent.text, "Configuration 🟡", "the status dot stays in the text")
		helpers.assert_eq(parent.attributes.font.name, "OpenDyslexic-Regular")
		helpers.assert_eq(parent.attributes.font.size, 14, "the system menu size")
		helpers.assert_eq(parent.attributes.color.name, "labelColor")
		local header = tree[3].menu[1]
		helpers.assert_eq(header.title.attributes.color.name, "disabledControlTextColor",
			"a disabled row is drawn grey by its title")
		helpers.assert_eq(header.disabled, true, "the row stays disabled")
		local choice = tree[3].menu[2]
		helpers.assert_eq(choice.checked, true, "the check mark is the item's, untouched")
		helpers.assert_eq(choice.title.attributes.color.name, "labelColor")
		helpers.assert_eq(type(tree[3].menu), "table", "the submenu stays")
	end)

	helpers.it("changes nothing and says why when AppKit does not know the face", function()
		local Adapter = helpers.load_with_stubs("tray.adapters.menu_font")
		local tree = sample_tree("x")
		with_styledtext(fake_styledtext(false), function()
			local count, err = Adapter.restyle(tree, "OpenDyslexic-Regular")
			helpers.assert_nil(count)
			helpers.assert_true(tostring(err):find("OpenDyslexic-Regular", 1, true) ~= nil, tostring(err))
		end)
		helpers.assert_eq(tree[5].title, "Quit")
	end)

	helpers.it("names the chosen font's face from menu_faces.json and leaves the default alone", function()
		local ReadingFont = helpers.load_with_stubs("menu.ui.builder.reading_font")
		local asked = {}
		local adapter = {
			read_file = require("tray.adapters.menu_font").read_file,
			restyle = function(_, postscript) asked[#asked + 1] = postscript; return 7 end,
		}
		helpers.assert_eq(ReadingFont.apply({}, { font = "default", adapter = adapter }), 0)
		helpers.assert_eq(#asked, 0, "the default font restyles nothing")
		helpers.assert_eq(ReadingFont.apply({}, { font = "dyslexic", adapter = adapter }), 7)
		helpers.assert_eq(ReadingFont.apply({}, { font = "hyperlegible", adapter = adapter }), 7)
		helpers.assert_eq(table.concat(asked, ","), "OpenDyslexic-Regular,AtkinsonHyperlegible-Regular")
		local missing = ReadingFont.apply({}, {
			font = "dyslexic", adapter = adapter, fonts_dir = "/nonexistent/fonts",
		})
		helpers.assert_nil(missing, "an unreadable face manifest is an error")
		helpers.assert_eq(#asked, 2)
	end)

	helpers.it("draws the real tray tree in the chosen font, and the default font keeps plain titles", function()
		local restyled = {}
		local adapter = {
			read_file = require("tray.adapters.menu_font").read_file,
			restyle = function(items, postscript)
				restyled[#restyled + 1] = { items = items, postscript = postscript }
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
				rows = builder.generate({ paused = false }, {}, { reload = function() end, quit = function() end })
			end)
			return rows
		end
		local plain = build("default")
		helpers.assert_eq(#restyled, 0, "the default font draws the system menu font")
		helpers.assert_true(#plain > 0)
		local rows = build("dyslexic")
		helpers.assert_eq(#restyled, 1, "one restyle per build")
		helpers.assert_eq(restyled[1].postscript, "OpenDyslexic-Regular")
		helpers.assert_true(rawequal(restyled[1].items, rows), "the published tree is the restyled one")
	end)

	helpers.it("names a styled row by its characters in a click path", function()
		local ClickIntent = require("menu.engine.click_intent")
		local styled = fake_styledtext(true).new("Quit", {})
		helpers.assert_eq(ClickIntent.title_text(styled), "Quit")
		helpers.assert_eq(ClickIntent.child_path({ "Configuration" }, styled)[2], "Quit")
	end)
end)
