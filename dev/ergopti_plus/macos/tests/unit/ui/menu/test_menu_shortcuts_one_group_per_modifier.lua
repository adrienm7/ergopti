--- tests/unit/ui/menu/test_menu_shortcuts_one_group_per_modifier.lua

--- ==============================================================================
--- MODULE: Regression — the Shortcuts submenu has one group per modifier
--- DESCRIPTION:
--- The built-in Ctrl and Cmd shortcuts were drawn as their own "Ctrl" and "Cmd"
--- groups beside the configurable keyboard-slot groups of the same modifiers,
--- so the packaged tray showed two Ctrl and two Cmd submenus, the slot one
--- holding nothing but its "add" row. The wrap-text toggle, prepended as row
--- data after the manifest section was already rendered, reached the tray with
--- no title and was not drawn at all. This renders the real Shortcuts row with
--- one shortcut of each kind and checks both.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Renders the real Shortcuts submenu over a shortcut engine listing a wrap
--- toggle, a Ctrl shortcut and a Cmd shortcut.
--- @return table rows
local function render_shortcuts_submenu()
	local shortcuts = helpers.load_with_stubs("ui.menu.menu_shortcuts")
	local ManifestMenu = require("infra.manifest_menu")
	local item = shortcuts.build({
		state      = { shortcuts = true },
		save_prefs = function() return true end,
		updateMenu = function() end,
		applyTriggerChar = function(text) return text end,
		shortcuts  = {
			list_shortcuts = function()
				return {
					{ id = "wrap_text_if_selected", label = "Wrap", enabled = true },
					{ id = "ctrl_a", label = "Select line", enabled = true },
					{ id = "cmd_star", label = "Star", enabled = true },
				}
			end,
			is_enabled            = function() return true end,
			set_wrap_pairs_getter = function() end,
		},
	})
	local row = ManifestMenu.render_rows({ item }, "top_level")[1]
	helpers.assert_true(type(row) == "table" and type(row.menu) == "table", "Shortcuts must render a submenu")
	return row.menu
end

--- Returns the rendered child whose title is the given key.
--- @param rows table
--- @param title string
--- @return table|nil
local function find(rows, title)
	for _, entry in ipairs(rows) do
		if entry.title == title then return entry end
	end
	return nil
end

--- Reports whether any row of a submenu has a title containing the text.
--- @param rows table
--- @param text string
--- @return boolean
local function has_row_containing(rows, text)
	for _, entry in ipairs(rows or {}) do
		if type(entry.title) == "string" and entry.title:find(text, 1, true) then return true end
	end
	return false
end

helpers.describe("the Shortcuts submenu has one group per modifier", function()
	helpers.it("draws no separate built-in Ctrl or Cmd group", function()
		local rows = render_shortcuts_submenu()
		helpers.assert_nil(find(rows, "menu.shortcuts.submenu_ctrl"), "a second Ctrl group is drawn")
		helpers.assert_nil(find(rows, "menu.shortcuts.submenu_cmd"), "a second Cmd group is drawn")
	end)

	helpers.it("puts the built-in Ctrl and Cmd shortcuts in their modifier's group", function()
		local rows = render_shortcuts_submenu()
		local ctrl = find(rows, "menu.shortcuts.ctrl_group")
		local cmd = find(rows, "menu.shortcuts.cmd_group")
		helpers.assert_true(ctrl ~= nil and type(ctrl.menu) == "table", "the Ctrl group must render")
		helpers.assert_true(cmd ~= nil and type(cmd.menu) == "table", "the Cmd group must render")
		helpers.assert_true(has_row_containing(ctrl.menu, "Select line"), "ctrl_a must sit in the Ctrl group")
		helpers.assert_true(has_row_containing(cmd.menu, "Star"), "cmd_star must sit in the Cmd group")
		helpers.assert_true(has_row_containing(ctrl.menu, "menu.shortcuts.ctrl_add"),
			"the Ctrl group keeps its add row")
	end)

	helpers.it("draws the wrap-text toggle with a title", function()
		local rows = render_shortcuts_submenu()
		helpers.assert_eq(rows[1].title, "menu.shortcuts.enable", "the submenu opens with its category switch")
		-- The first group (2026-09-30): the restore and the clear follow the
		-- switch, greyed here because the Shortcuts scope is not yet ported to
		-- macOS, then a separator sets the group apart.
		for index, key in ipairs({ "common.restore_recommended", "common.clear_to_system" }) do
			local row = rows[index + 1]
			helpers.assert_true(type(row.title) == "string" and row.title:find(key, 1, true) == 1,
				key .. " must follow the switch, got " .. tostring(row.title))
			helpers.assert_eq(row.disabled, true, key .. " is greyed on macOS")
			helpers.assert_nil(row.fn, key .. " runs nothing on macOS")
		end
		helpers.assert_eq(rows[4].title, "-", "a separator closes the first group")
		-- The number-row tap keys follow the category switch and replace the fixed
		-- screenshot key; the wrap-text toggle is the first row after them.
		local wrap = nil
		for _, entry in ipairs(rows) do
			if type(entry.title) == "string" and entry.title:find("Wrap", 1, true) then
				wrap = entry
				break
			end
		end
		helpers.assert_true(wrap ~= nil, "the wrap-text toggle must be drawn with its title")
		helpers.assert_true(type(wrap.fn) == "function", "the wrap-text toggle must be clickable")
		-- A section header is drawn with its dash decoration around the label.
		helpers.assert_true(type(rows[5].title) == "string"
			and rows[5].title:find("menu.shortcuts.header_tap_keys", 1, true) ~= nil,
			"the tap keys follow the first group under their header")
	end)

	-- The maintainer's request of 2026-09-30: the wrap-text toggle reads as its
	-- behaviour alone (no « AltGr + symbole » trigger: the symbols need not be on
	-- AltGr), and « Symboles encadrants » follows it with no line between them.
	helpers.it("draws the wrap-text toggle as its behaviour, grouped with its symbols", function()
		local rows = render_shortcuts_submenu()
		local at = nil
		for index, entry in ipairs(rows) do
			if entry.title == "Wrap" then at = index end
		end
		helpers.assert_true(at ~= nil, "the wrap-text toggle is labelled by its behaviour alone")
		helpers.assert_eq(rows[at + 1].title, "menu.shortcuts.wrap_symbols",
			"the wrapping symbols follow the toggle with no separator between them")
		for _, entry in ipairs(rows) do
			helpers.assert_true(type(entry.title) ~= "string" or not entry.title:find("altgr", 1, true),
				"no row names the retired AltGr trigger: " .. tostring(entry.title))
		end
	end)
end)
