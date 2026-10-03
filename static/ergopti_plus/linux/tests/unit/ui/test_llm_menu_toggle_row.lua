--- tests/unit/ui/test_llm_menu_toggle_row.lua

--- ==============================================================================
--- MODULE: The AI Master Toggle Row And The Keyboard Slot Groups (Linux tray)
--- DESCRIPTION:
--- The AI submenu's first row is the manifest's `llm_toggle`: this driver
--- registers the command, and the shared renderer draws it as a checkbox with
--- one translated label, ticked from the live state; the parent row carries the
--- same tick. Nothing pinned that the row exists, reads the live state and
--- reaches the engine, so a rename on either side would have left the AI with no
--- switch in the tray.
---
--- The Shortcuts submenu drew one submenu per keyboard slot group even when the
--- shared key catalogue could not be read, so the tray showed three groups that
--- opened onto nothing; they are now left out and the failure is logged.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The submenu of the top-level row whose title contains the translation of `key`.
--- @param items table
--- @param key string
--- @return table|nil
local function submenu_of(items, key)
	local label = require("infra.i18n").get(key)
	for _, item in ipairs(items) do
		if type(item.title) == "string" and item.title:find(label, 1, true) then return item.menu end
	end
	return nil
end

--- The top-level row whose title contains the translation of `key`.
--- @param items table
--- @param key string
--- @return table|nil
local function parent_of(items, key)
	local label = require("infra.i18n").get(key)
	for _, item in ipairs(items) do
		if type(item.title) == "string" and item.title:find(label, 1, true) then return item end
	end
	return nil
end

--- An LLM engine double.
--- @param enabled boolean
--- @return table engine, table calls
local function fake_llm(enabled)
	local calls = { toggle = 0 }
	local engine = {
		is_enabled = function() return enabled end,
		toggle = function() calls.toggle = calls.toggle + 1 enabled = not enabled return true end,
	}
	return engine, calls
end

--- Builds the tray around one LLM double.
--- @param llm table
--- @param changed table|nil Receives a `count` of on_menu_changed calls.
--- @return table items
local function build(llm, changed)
	local mb = helpers.load_module("ui.menu.menu_builder")
	return mb.build({
		_version = "0.0.0-dev.12",
		llm = llm,
		on_quit = function() end,
		on_menu_changed = function() if changed then changed.count = changed.count + 1 end end,
	})
end

helpers.describe("tray (linux): the AI master toggle row", function()
	helpers.it("draws an unticked switch first while the AI is off", function()
		local llm = fake_llm(false)
		local items = build(llm)
		local rows = submenu_of(items, "menu.llm.title")
		helpers.assert_true(rows ~= nil and rows[1] ~= nil, "the AI submenu must be drawn")
		helpers.assert_eq(rows[1].title, require("infra.i18n").get("menu.llm.enable"))
		helpers.assert_eq(rows[1].checked, false, "the switch is a checkbox, unticked while off")
		helpers.assert_eq(type(rows[1].fn), "function", "the toggle row must act")
		helpers.assert_eq(parent_of(items, "menu.llm.title").checked, false, "the parent is unticked too")
	end)

	helpers.it("ticks the same switch, and its parent, while the AI is on", function()
		local llm = fake_llm(true)
		local items = build(llm)
		local rows = submenu_of(items, "menu.llm.title")
		helpers.assert_eq(rows[1].title, require("infra.i18n").get("menu.llm.enable"))
		helpers.assert_eq(rows[1].checked, true, "the switch is ticked while on")
		helpers.assert_eq(parent_of(items, "menu.llm.title").checked, true, "the parent row is ticked too")
	end)

	helpers.it("clicking it toggles the engine and redraws the tray", function()
		local llm, calls = fake_llm(false)
		local changed = { count = 0 }
		local rows = submenu_of(build(llm, changed), "menu.llm.title")
		rows[1].fn()
		helpers.assert_eq(calls.toggle, 1, "the row must reach llm.toggle")
		helpers.assert_eq(changed.count, 1, "the tray must be rebuilt so the label follows the state")
	end)

	-- ai-menu-no-clear: « Tout effacer (comportement du système) » sat under the
	-- switch and cleared a section with nothing for the system to do in its
	-- place; the maintainer retired it. « Restaurer les valeurs conseillées »
	-- stays the one row between the switch and the separator.
	helpers.it("draws the restore row under the switch and no clear row", function()
		local i18n = require("infra.i18n")
		local rows = submenu_of(build(fake_llm(true)), "menu.llm.title")
		helpers.assert_true(rows ~= nil and #rows > 3, "the AI submenu must be drawn")
		helpers.assert_eq(rows[2].title, i18n.get("common.restore_recommended"), "the restore row follows the switch")
		helpers.assert_eq(type(rows[2].fn), "function", "the restore row must act")
		helpers.assert_eq(rows[3].title, "-", "a separator closes the switch's group")
		local clear = i18n.get("common.clear_to_system")
		helpers.assert_true(clear ~= "common.clear_to_system", "the clear label must be translated to be looked for")
		for index, row in ipairs(rows) do
			helpers.assert_true(row.title ~= clear, "row " .. index .. " of the AI submenu is a clear row")
		end
	end)
end)

helpers.describe("tray (linux): keyboard slot groups need a key catalogue", function()
	--- Menu inventory stays editable when its native source is unavailable.
	--- This fixture owns that dependency rather than inheriting another test's
	--- initialized physical-source owner or its expired private config path.
	local function with_unavailable_source(body)
		local saved_source = package.loaded["modules.hotstrings.magic_key_source"]
		local saved_magic = package.loaded["modules.hotstrings.magic_key"]
		package.loaded["modules.hotstrings.magic_key_source"] = {
			editor_source = function() return { generation = 1, status = "unavailable", candidates = {} } end,
			known_codes = function() return {} end,
		}
		package.loaded["modules.hotstrings.magic_key"] = { get = function() return "★" end, is_customised = function() return false end }
		local ok, err = pcall(body)
		package.loaded["modules.hotstrings.magic_key_source"] = saved_source
		package.loaded["modules.hotstrings.magic_key"] = saved_magic
		if not ok then error(err, 0) end
	end

	-- The positive case, so the absence assertion below cannot pass by looking
	-- in the wrong submenu.
	helpers.it("draws every slot group when the catalogue is readable", function()
		with_unavailable_source(function()
			local kbd = helpers.load_module("modules.shortcuts.keyboard_shortcuts")
			kbd._reset()
			local mb = helpers.load_module("ui.menu.menu_builder")
			local rows = submenu_of(mb.build({
				_version = "0.0.0-dev.12",
				shortcuts = require("modules.shortcuts.manager"),
				on_quit = function() end,
			}), "menu.shortcuts.title")
			local i18n = require("infra.i18n")
			for _, group in ipairs(kbd.SLOT_GROUPS) do
				local label, found = i18n.get(group.group_key), nil
				for _, row in ipairs(rows or {}) do
					if row.title == label then found = row end
				end
				helpers.assert_true(found ~= nil and type(found.menu) == "table" and #found.menu > 0,
					"slot group '" .. label .. "' must be drawn with its slots")
			end
		end)
	end)

	helpers.it("draws no empty slot group when the catalogue cannot be read", function()
		with_unavailable_source(function()
			local saved_paths = package.loaded["infra.paths"]
			local saved_kbd = package.loaded["modules.shortcuts.keyboard_shortcuts"]
			local real_paths = require("infra.paths")
			local blind = setmetatable({ shared = function() return nil end }, { __index = real_paths })
			package.loaded["infra.paths"] = blind
			package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
			local ok_kbd, kbd = pcall(require, "modules.shortcuts.keyboard_shortcuts")
			package.loaded["infra.paths"] = saved_paths
			local ok, err = pcall(function()
				helpers.assert_true(ok_kbd, tostring(kbd))
				kbd._reset()
				helpers.assert_eq(#kbd.available_slots("ctrl_"), 0, "the blind catalogue offers no slot")
				local mb = helpers.load_module("ui.menu.menu_builder")
				local items = mb.build({
					_version = "0.0.0-dev.12",
					shortcuts = require("modules.shortcuts.manager"),
					on_quit = function() end,
				})
				local rows = submenu_of(items, "menu.shortcuts.title")
				helpers.assert_true(rows ~= nil, "the shortcuts submenu must be drawn")
				local i18n = require("infra.i18n")
				for _, group in ipairs(kbd.SLOT_GROUPS) do
					local label, found = i18n.get(group.group_key), nil
					for _, row in ipairs(rows) do
						if group.prefix == "contextual" and row.title == label then found = row
						else helpers.assert_true(row.title ~= label,
							"slot group '" .. label .. "' was drawn with no slot in it") end
					end
					if group.prefix == "contextual" then
						helpers.assert_type(found, "table", "the logical contextual slot does not depend on the modifier key catalogue")
						helpers.assert_eq(#found.menu, 1, "its one stable editable slot must remain visible")
						helpers.assert_type(found.menu[1].menu[1].fn, "function", "unavailable native evidence never removes the ordinary action picker")
					end
				end
		end)
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = saved_kbd
		if not ok then error(err, 0) end
		end)
	end)
end)
