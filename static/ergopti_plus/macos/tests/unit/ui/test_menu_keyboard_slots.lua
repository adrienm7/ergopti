--- tests/unit/ui/test_menu_keyboard_slots.lua

--- ==============================================================================
--- MODULE: Menu Keyboard Slots Tests (Hammerspoon)
--- DESCRIPTION:
--- Exercises the binding UI the keyboard-slot module never had: the row data it
--- provides to the manifest renderer, and the two picker flows that create and
--- edit a binding.
---
--- COVERAGE:
--- 1. Row data, not menu rows — the provider must hand over labels and callbacks
---    and never the hs.menubar shape, or menu rows are being built outside the
---    renderer again.
--- 2. A group lists what is bound plus one "add" row, in catalogue order, so the
---    rows do not reshuffle between two openings of the same menu.
--- 3. The slot picker offers only FREE slots — offering a bound one would let a
---    row that looks like a fresh binding silently overwrite an existing one.
--- 4. Picking a slot then an action actually persists the assignment and binds it.
--- 5. Picking "none" removes the binding rather than binding an action literally
---    named "none".
--- ==============================================================================

local helpers = require("tests.helpers")
local original_deferred_work = package.loaded["infra.deferred_work"]
local original_subject = package.loaded["ui.menu.menu_keyboard_slots"]
local DeferredWork = {}
package.loaded["infra.deferred_work"] = DeferredWork




-- ==========================================
-- ==========================================
-- ======= 1/ Harness =======================
-- ==========================================
-- ==========================================

-- The catalogue's first alphabetic key, used wherever a case needs "some slot"
-- and its identity does not matter.
local FIRST_KEY = "a"

--- Builds a menu context with a gesture registry the picker can offer.
--- @return table ctx, table updates A counter table the context increments.
local function make_ctx()
	local updates = { count = 0 }
	local ctx = {
		gestures = {
			get_sg_names = function() return { "#header", "copy_selection", "paste_plain" } end,
			get_action_label = function(id) return "Label:" .. id end,
		},
		updateMenu = function() updates.count = updates.count + 1 end,
	}
	return ctx, updates
end

--- Loads the UI module together with a recording ActionPicker.
--- The picker is replaced rather than stubbed at the hs layer because these
--- cases are about WHAT is offered and what is done with the answer, not about
--- whether a webview opens.
--- @return table ui, table shortcuts, table picker
local function fresh()
	DeferredWork.after = function(_, callback)
		callback()
		return true
	end
	local ui = helpers.load_with_stubs("ui.menu.menu_keyboard_slots")
	local shortcuts = require("modules.shortcuts")
	local picker = require("ui.action_picker")

	picker.opened = {}
	picker.open = function(opts, on_confirm)
		picker.opened[#picker.opened + 1] = { opts = opts, confirm = on_confirm }
	end

	return ui, shortcuts, picker
end




-- ==========================================
-- ==========================================
-- ======= 2/ Row Data ======================
-- ==========================================
-- ==========================================

helpers.describe("menu_keyboard_slots: provided rows", function()
	helpers.it("returns one row per group, each carrying nested rows", function()
		local ui, shortcuts = fresh()
		local ctx = make_ctx()
		local rows = ui.provide_rows(ctx, nil)

		helpers.assert_eq(#rows, #shortcuts.get_keyboard_slot_groups(),
			"every configurable group must be offered")
		for _, row in ipairs(rows) do
			helpers.assert_eq(type(row.label), "string", "a group row must carry a label")
			helpers.assert_eq(type(row.items), "table", "a group row must carry its own rows")
		end
	end)

	helpers.it("hands over DATA, never hs.menubar rows", function()
		-- A provider returning { title = …, fn = … } would be building menu rows
		-- outside the renderer, which is exactly what the list type exists to stop.
		local ui = fresh()
		local ctx = make_ctx()
		for _, row in ipairs(ui.provide_rows(ctx, nil)) do
			helpers.assert_nil(row.title, "a provided row must not carry a menubar title")
			helpers.assert_nil(row.fn, "a provided row must not carry a menubar fn")
			for _, inner in ipairs(row.items) do
				helpers.assert_nil(inner.title, "a nested row must not carry a menubar title")
				helpers.assert_nil(inner.fn, "a nested row must not carry a menubar fn")
			end
		end
	end)

	helpers.it("offers an add row in every group even when nothing is bound", function()
		local ui = fresh()
		local ctx = make_ctx()
		for _, row in ipairs(ui.provide_rows(ctx, nil)) do
			helpers.assert_true(#row.items >= 1,
				"a group with no assignments must still offer a way to create one")
			local last = row.items[#row.items]
			helpers.assert_eq(type(last.action), "function", "the add row must be actionable")
		end
	end)

	helpers.it("propagates the disabled flag to every row", function()
		local ui = fresh()
		local ctx = make_ctx()
		for _, row in ipairs(ui.provide_rows(ctx, true)) do
			helpers.assert_eq(row.disabled, true, "a disabled section must grey its group rows")
			for _, inner in ipairs(row.items) do
				helpers.assert_eq(inner.disabled, true, "and the rows inside them")
			end
		end
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 3/ Creating A Binding ============
-- ==========================================
-- ==========================================

helpers.describe("menu_keyboard_slots: adding a binding", function()
	helpers.it("offers the free slots of the group, and only those", function()
		local ui, shortcuts, picker = fresh()
		local ctx = make_ctx()
		local group = shortcuts.get_keyboard_slot_groups()[1]
		local taken = group.prefix .. FIRST_KEY
		shortcuts.set_keyboard_action(taken, "copy_selection")

		local rows = ui.provide_rows(ctx, nil)
		rows[1].items[#rows[1].items].action()

		helpers.assert_eq(#picker.opened, 1, "the add row must open the slot picker")
		local offered = {}
		for _, item in ipairs(picker.opened[1].opts.items) do offered[item.id] = true end
		helpers.assert_true(not offered[taken],
			"an already-bound slot must not be offered again — picking it would overwrite silently")
		helpers.assert_true(offered[group.prefix .. "b"],
			"but every free slot of the group must be")

		shortcuts.set_keyboard_action(taken, "none")
	end)

	helpers.it("chains the action picker and persists what was chosen", function()
		local ui, shortcuts, picker = fresh()
		local ctx, updates = make_ctx()
		local group = shortcuts.get_keyboard_slot_groups()[2]
		local slot = group.prefix .. "j"

		local rows = ui.provide_rows(ctx, nil)
		rows[2].items[#rows[2].items].action()
		picker.opened[1].confirm(slot)

		helpers.assert_eq(#picker.opened, 2, "picking a slot must then ask what it should do")
		picker.opened[2].confirm("paste_plain")

		helpers.assert_eq(shortcuts.get_keyboard_action(slot), "paste_plain",
			"the assignment must be persisted, not merely displayed")
		helpers.assert_true(updates.count > 0, "and the menu must be rebuilt so the new row shows")

		shortcuts.set_keyboard_action(slot, "none")
	end)

	helpers.it("does nothing when the slot picker is dismissed", function()
		local ui, shortcuts, picker = fresh()
		local ctx = make_ctx()
		local before = 0
		for _ in pairs(shortcuts.get_keyboard_assignments()) do before = before + 1 end

		local rows = ui.provide_rows(ctx, nil)
		rows[1].items[#rows[1].items].action()
		picker.opened[1].confirm(nil)

		helpers.assert_eq(#picker.opened, 1, "a dismissed slot picker must not chain to the action picker")
		local after = 0
		for _ in pairs(shortcuts.get_keyboard_assignments()) do after = after + 1 end
		helpers.assert_eq(after, before, "and must not touch the assignments")
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 4/ Editing A Binding =============
-- ==========================================
-- ==========================================

helpers.describe("menu_keyboard_slots: editing a binding", function()
	helpers.it("lists an assigned slot with its action label", function()
		local ui, shortcuts = fresh()
		local ctx = make_ctx()
		local group = shortcuts.get_keyboard_slot_groups()[1]
		local slot = group.prefix .. "m"
		shortcuts.set_keyboard_action(slot, "copy_selection")

		local rows = ui.provide_rows(ctx, nil)
		local found = nil
		for _, inner in ipairs(rows[1].items) do
			if inner.label:find("Label:copy_selection", 1, true) then found = inner end
		end
		helpers.assert_true(found ~= nil,
			"an assigned slot must appear in its group, labelled with what it does")

		shortcuts.set_keyboard_action(slot, "none")
	end)

	helpers.it("opens the action picker on the slot's current action", function()
		local ui, shortcuts, picker = fresh()
		local ctx = make_ctx()
		local group = shortcuts.get_keyboard_slot_groups()[1]
		local slot = group.prefix .. "m"
		shortcuts.set_keyboard_action(slot, "copy_selection")

		local rows = ui.provide_rows(ctx, nil)
		rows[1].items[1].action()

		helpers.assert_eq(picker.opened[1].opts.current, "copy_selection",
			"the picker must open on what the slot holds, not on 'none'")

		shortcuts.set_keyboard_action(slot, "none")
	end)

	helpers.it("removes the binding when 'none' is chosen", function()
		local ui, shortcuts, picker = fresh()
		local ctx = make_ctx()
		local group = shortcuts.get_keyboard_slot_groups()[1]
		local slot = group.prefix .. "m"
		shortcuts.set_keyboard_action(slot, "copy_selection")

		local rows = ui.provide_rows(ctx, nil)
		rows[1].items[1].action()
		picker.opened[1].confirm("none")

		helpers.assert_eq(shortcuts.get_keyboard_action(slot), "none",
			"choosing the disabled row must clear the slot, not bind an action called 'none'")
		local still_listed = false
		for _, inner in ipairs(ui.provide_rows(ctx, nil)[1].items) do
			if inner.label:find(shortcuts.get_keyboard_slot_label(slot), 1, true) then still_listed = true end
		end
		helpers.assert_eq(still_listed, false, "and the row must disappear from the group")
	end)

	helpers.it("does not refresh the menu when the shortcut transaction refuses", function()
		local ui, shortcuts, picker = fresh()
		local ctx, updates = make_ctx()
		local group = shortcuts.get_keyboard_slot_groups()[1]
		local slot = group.prefix .. "m"
		local original_set = shortcuts.set_keyboard_action
		shortcuts.set_keyboard_action = function() return false end

		local ok, err = xpcall(function()
			local rows = ui.provide_rows(ctx, nil)
			rows[1].items[#rows[1].items].action()
			picker.opened[1].confirm(slot)
			picker.opened[2].confirm("copy_selection")
			helpers.assert_eq(updates.count, 0,
				"a refused native/persistence transaction must not publish a success refresh")
		end, debug.traceback)
		shortcuts.set_keyboard_action = original_set
		if not ok then error(err, 0) end
	end)
end)

package.loaded["infra.deferred_work"] = original_deferred_work
package.loaded["ui.menu.menu_keyboard_slots"] = original_subject
