--- tests/unit/ui/menu/shortcuts/test_menu_caps_word.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off Menu Tests
--- DESCRIPTION:
--- Renders caps_word_auto_off_group through the real manifest renderer: the
--- delay choice offers the manifest presets, the delimiter checkboxes are the
--- hotstring catalogue in its order, each declared pointer kind has its row,
--- and a click applies, saves, and restores the state when the save fails.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Flattens rendered items (and their submenus) into a title -> item map.
local function index_items(items, out)
	out = out or {}
	for _, item in ipairs(items or {}) do
		if type(item.title) == "string" then out[#out + 1] = item end
		if type(item.menu) == "table" then index_items(item.menu, out) end
	end
	return out
end

local function fresh(save_result)
	package.loaded["ui.menu.menu_caps_word"] = nil
	package.loaded["infra.capsword_auto_off"] = nil
	local Owner = require("infra.capsword_auto_off")
	local state = {}
	for key, value in pairs(Owner.DEFAULT_STATE) do state[key] = value end
	local h = { saves = 0, updates = 0, state = state, owner = Owner }
	h.ctx = {
		state = state,
		state_getters = {},
		applyTriggerChar = function(text) return text end,
		save_prefs = function() h.saves = h.saves + 1; return save_result ~= false end,
		updateMenu = function() h.updates = h.updates + 1 end,
	}
	h.rows = require("ui.menu.menu_caps_word").build(h.ctx)
	helpers.assert_type(h.rows, "table", "the group must render")
	h.items = index_items(h.rows)
	return h
end

local function find(items, title)
	for _, item in ipairs(items) do
		if item.title == title then return item end
	end
	return nil
end

helpers.describe("CapsWord auto-off menu (caps_word_auto_off_group)", function()
	helpers.it("draws the presets, the delimiter catalogue and every pointer kind", function()
		local h = fresh()
		local i18n = require("infra.i18n")
		local Policy = require("caps_word.auto_off")
		for _, row in ipairs(Policy.terminator_rows()) do
			if not row.separator then
				helpers.assert_true(find(h.items, i18n.get(row.label_key)) ~= nil, row.key .. " has its checkbox")
			end
		end
		local space = find(h.items, i18n.get("terminators.label_space"))
		helpers.assert_true(space.checked == true, "Space is checked by default")
		local previous = 0
		for _, entry in ipairs(require("infra.manifest_reader").declared_section_entries("shortcuts.caps_word.pointer")) do
			local item, position = nil, nil
			for index, candidate in ipairs(h.items) do
				if candidate.title == i18n.get(entry.description_key) then item, position = candidate, index end
			end
			helpers.assert_true(item ~= nil, entry.id .. " has its checkbox")
			helpers.assert_true(item.checked == true, entry.id .. " is on by default")
			helpers.assert_true(position > previous, entry.id .. " follows the manifest order")
			previous = position
		end
		helpers.assert_true(find(h.items, i18n.get("menu.caps_word.idle_timeout_never")) ~= nil,
			"the delay offers never")
	end)

	helpers.it("a pointer and a delimiter click apply and save; a refused save restores", function()
		local h = fresh()
		local i18n = require("infra.i18n")
		find(h.items, i18n.get("menu.caps_word.pointer.middle_click")).fn()
		helpers.assert_eq(h.state.caps_word_pointer.middle_click, false)
		helpers.assert_eq(h.saves, 1)
		find(h.items, i18n.get("terminators.label_nbsp")).fn()
		helpers.assert_eq(h.state.caps_word_terminators, { "space", "nbsp", "tab", "enter" },
			"the list is stored in catalogue order")
		helpers.assert_true(require("caps_word.auto_off").ends_on_text(h.owner.policy(), "\xC2\xA0"),
			"the watcher's policy follows at once")

		local refused = fresh(false)
		find(refused.items, i18n.get("menu.caps_word.pointer.left_click")).fn()
		helpers.assert_eq(refused.state.caps_word_pointer.left_click, true, "a refused save restores the state")
		helpers.assert_true(require("caps_word.auto_off").ends_on_pointer(refused.owner.policy(), "left_click"),
			"and the policy in force")
	end)
end)
