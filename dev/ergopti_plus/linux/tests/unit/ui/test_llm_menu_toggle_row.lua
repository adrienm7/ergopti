--- tests/unit/ui/test_llm_menu_toggle_row.lua

--- ==============================================================================
--- MODULE: The AI Master Toggle Row And The Keyboard Slot Groups (Linux tray)
--- DESCRIPTION:
--- The AI submenu's first row is the manifest's `llm_toggle`: this driver
--- registers the command, and the shared renderer draws the row with its own
--- two translated labels. Nothing pinned that the row exists, reads the live
--- state and reaches the engine, so a rename on either side would have left the
--- AI with no switch in the tray.
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
	helpers.it("draws the enable label first while the AI is off", function()
		local llm = fake_llm(false)
		local rows = submenu_of(build(llm), "menu.llm.title")
		helpers.assert_true(rows ~= nil and rows[1] ~= nil, "the AI submenu must be drawn")
		helpers.assert_eq(rows[1].title, require("infra.i18n").get("menu.llm.toggle_enable"))
		helpers.assert_eq(type(rows[1].fn), "function", "the toggle row must act")
	end)

	helpers.it("draws the disable label while the AI is on", function()
		local llm = fake_llm(true)
		local rows = submenu_of(build(llm), "menu.llm.title")
		helpers.assert_eq(rows[1].title, require("infra.i18n").get("menu.llm.toggle_disable"))
	end)

	helpers.it("clicking it toggles the engine and redraws the tray", function()
		local llm, calls = fake_llm(false)
		local changed = { count = 0 }
		local rows = submenu_of(build(llm, changed), "menu.llm.title")
		rows[1].fn()
		helpers.assert_eq(calls.toggle, 1, "the row must reach llm.toggle")
		helpers.assert_eq(changed.count, 1, "the tray must be rebuilt so the label follows the state")
	end)
end)

helpers.describe("tray (linux): keyboard slot groups need a key catalogue", function()
	-- The positive case, so the absence assertion below cannot pass by looking
	-- in the wrong submenu.
	helpers.it("draws every slot group when the catalogue is readable", function()
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

	helpers.it("draws no empty slot group when the catalogue cannot be read", function()
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
				local label = i18n.get(group.group_key)
				for _, row in ipairs(rows) do
					helpers.assert_true(row.title ~= label,
						"slot group '" .. label .. "' was drawn with no slot in it")
				end
			end
		end)
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = saved_kbd
		if not ok then error(err, 0) end
	end)
end)
