--- tests/unit/ui/menu/shortcuts_and_gestures/test_menu_keyboard_slots_declared_group_frames.lua

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
package.loaded["tests.support.ui.menu.shortcuts_and_gestures.menu_keyboard_slots_fixture"] = nil
local Fixture = require("tests.support.ui.menu.shortcuts_and_gestures.menu_keyboard_slots_fixture")
local fresh = Fixture.fresh
local it = Fixture.it
local make_ctx = Fixture.make_ctx
local physical_groups = Fixture.physical_groups
local physical_rows = Fixture.physical_rows





-- ==========================================
-- ==========================================
-- ======= 6/ Declared Group Frames =========
-- ==========================================
-- ==========================================

--- Reads a real shared JSON catalogue without deriving expected rows from the frame.
--- @param relative string Shared resource path.
--- @return table decoded
local function keyboard_frame_json(relative)
	local file = assert(io.open(helpers.shared(relative), "rb"))
	local text = assert(file:read("*a"))
	assert(file:close())
	return assert(require("adapters.json_codec").decode(text))
end

helpers.describe("menu_keyboard_slots: complete declared group frame", function()
	it("preserves independently specified scope, fixed, assigned and Add row order", function()
		local ui, shortcuts = fresh()
		local ctx = make_ctx()
		local group = physical_groups(shortcuts)[1]
		local slot = group.prefix .. "a"
		local fixed = { label = "Independent fixed row", action = function() error("a fixed row must not run during build") end }
		local i18n = require("infra.i18n")
		local add_label = i18n.get("menu.shortcuts.alt_add")
		local restore_label = i18n.get("common.restore_recommended")
		local clear_label = i18n.get("common.clear_to_system")
		local assigned_label = shortcuts.get_keyboard_slot_label(slot) .. " : Label:lookup"
		local cases = {
			{ fixed = false, assigned = false, labels = { restore_label, clear_label, "-", add_label } },
			{ fixed = true, assigned = false, labels = { restore_label, clear_label, "-", fixed.label, "-", add_label } },
			{ fixed = false, assigned = true, labels = { restore_label, clear_label, "-", assigned_label, add_label } },
			{ fixed = true, assigned = true,
				labels = { restore_label, clear_label, "-", fixed.label, "-", assigned_label, add_label } },
		}
		for _, case in ipairs(cases) do
			helpers.assert_true(shortcuts.set_keyboard_action(slot, case.assigned and "lookup" or "none"))
			local fixed_by_prefix = case.fixed and { [group.prefix] = { fixed } } or nil
			local rows = physical_rows(ui.provide_rows(ctx, nil, fixed_by_prefix), shortcuts)[1].items
			helpers.assert_eq(#rows, #case.labels, "the independently specified frame keeps its complete shape")
			for index, expected in ipairs(case.labels) do
				helpers.assert_eq(rows[index].separator and "-" or rows[index].label, expected,
					"the fixed/dynamic boundary must be in its original position")
			end
			if case.fixed then helpers.assert_true(rawequal(rows[4], fixed), "borrowed fixed child identity is retained") end
		end
	end)

	it("preserves contextual editing without a physical Add command", function()
		local ui, shortcuts, picker = fresh()
		local ctx = make_ctx()
		helpers.assert_true(shortcuts.set_keyboard_action("magic_editor", "none"))
		local fixed = { label = "Independent contextual fixed row", action = function() end }
		local rows = ui.provide_rows(ctx, nil, { contextual = { fixed } })
		local contextual
		for index, group in ipairs(shortcuts.get_keyboard_slot_groups()) do
			if group.prefix == "contextual" then contextual = rows[index].items end
		end
		helpers.assert_eq(#contextual, 3, "fixed row, boundary and the genuine contextual editor, without Add")
		helpers.assert_true(rawequal(contextual[1], fixed))
		helpers.assert_eq(contextual[2].separator, true)
		helpers.assert_true(contextual[3].label:find("Label:none", 1, true) ~= nil)
		contextual[3].action()
		helpers.assert_eq(#picker.opened, 1, "contextual editing still opens the genuine action picker")
		helpers.assert_eq(picker.opened[1].opts.current, "none")
	end)

	it("retains the five translated physical Add labels in all twenty-one catalogues", function()
		local ui, shortcuts = fresh()
		local ctx = make_ctx()
		local i18n = require("infra.i18n")
		local locales = keyboard_frame_json("data/locale_order.json").order
		helpers.assert_eq(#locales, 21, "this assertion covers every actual supported catalogue")
		local add_keys = {
			"menu.shortcuts.alt_add", "menu.shortcuts.ctrl_add", "menu.shortcuts.ctrl_shift_add",
			"menu.shortcuts.cmd_add", "menu.shortcuts.cmd_shift_add",
		}
		local previous_get = i18n.get
		local ok, detail = xpcall(function()
			for _, locale in ipairs(locales) do
				local catalogue = keyboard_frame_json("data/locales/" .. locale .. ".json")
				i18n.get = function(key) return catalogue[key] or key end
				local rows = physical_rows(ui.provide_rows(ctx, nil), shortcuts)
				helpers.assert_eq(#rows, 5)
				for index, key in ipairs(add_keys) do
					helpers.assert_type(catalogue[key], "string", locale .. " supplies the real Add caption")
					helpers.assert_eq(rows[index].items[#rows[index].items].label, catalogue[key],
						locale .. " retains the independent canonical caption")
				end
			end
		end, debug.traceback)
		i18n.get = previous_get
		if not ok then error(detail, 0) end
	end)

	it("refuses a retained physical Add callback while the actual context is paused", function()
		local ui, shortcuts, picker = fresh()
		local ctx = make_ctx()
		local rows = physical_rows(ui.provide_rows(ctx, nil), shortcuts)
		local action = rows[1].items[#rows[1].items].action
		ctx.paused = true
		helpers.assert_eq(action(), false, "retained Add must recheck the current pause owner")
		helpers.assert_eq(#picker.opened, 0, "refused Add opens no lazy picker")
		ctx.paused = false
		action()
		helpers.assert_eq(#picker.opened, 1, "resume retains the real native slot picker")
	end)

	it("refuses Add callbacks captured from an explicitly disabled group", function()
		local ui, shortcuts, picker = fresh()
		local ctx = make_ctx()
		local rows = physical_rows(ui.provide_rows(ctx, true), shortcuts)
		for _, group in ipairs(rows) do
			local add = group.items[#group.items]
			helpers.assert_eq(add.disabled, true)
			helpers.assert_eq(add.action(), false)
		end
		helpers.assert_eq(#picker.opened, 0, "disabled groups open no lazy picker")
	end)

	for _, control in ipairs({ "missing", "withdrawn", "malformed", "withdrawn_add" }) do
		it("refuses a " .. control .. " actual frame before publishing any group", function()
			local ui, _, picker = fresh()
			local ctx = make_ctx()
			local root = require("infra.manifest_menu").get_root()
			if control == "missing" then root.keyboard_group_frame = nil
			elseif control == "withdrawn" then root.keyboard_group_frame = {}
			elseif control == "malformed" then root.keyboard_group_frame[1].type = "unrecognized"
			else root.keyboard_group_add_option_control = {} end
			helpers.assert_eq(ui.provide_rows(ctx, nil), {}, "an incomplete frame cannot publish partial native groups")
			helpers.assert_eq(#picker.opened, 0, "invalid declarations open no lazy picker")
		end)
	end

	for _, control in ipairs({ "missing", "non_boolean", "raises" }) do
		it("refuses a " .. control .. " actual boundary getter without a lazy action", function()
			local ui, shortcuts, picker = fresh()
			local ctx = make_ctx()
			local renderer = require("infra.manifest_menu")
			local actual_template_rows = renderer.template_rows
			renderer.template_rows = function(key, commands, getters, children)
				if key == "keyboard_group_frame" then
					if control == "missing" then getters.keyboard_group_has_fixed = nil
					elseif control == "non_boolean" then getters.keyboard_group_has_fixed = function() return 1 end
					else getters.keyboard_group_has_fixed = function() error("independent boundary refusal", 0) end end
				end
				return actual_template_rows(key, commands, getters, children)
			end
			local group = physical_groups(shortcuts)[1]
			local fixed = { label = "Independent fixed child", action = function() error("a refused build must not run this child") end }
			helpers.assert_eq(ui.provide_rows(ctx, nil, { [group.prefix] = { fixed } }), {})
			helpers.assert_eq(#picker.opened, 0, "invalid getters open no lazy picker")
		end)
	end
end)

helpers.describe("menu_keyboard_slots: admission precedes real source reads", function()
	--- Counts actual facade and parameter-label reads without inventing their values.
	--- @param shortcuts table Real native facade.
	--- @param ctx table Actual menu context.
	--- @return table calls
	local function count_source_reads(shortcuts, ctx)
		local calls = { assigned = 0, labels = 0 }
		local assigned = shortcuts.assigned_keyboard_slots
		shortcuts.assigned_keyboard_slots = function(...)
			calls.assigned = calls.assigned + 1
			return assigned(...)
		end
		local label = ctx.gestures.get_action_label
		ctx.gestures.get_action_label = function(...)
			calls.labels = calls.labels + 1
			return label(...)
		end
		return calls
	end

	it("proves source counters observe genuine valid assignments after admission", function()
		local ui, shortcuts, picker = fresh()
		local ctx = make_ctx()
		local group = physical_groups(shortcuts)[1]
		helpers.assert_true(shortcuts.set_keyboard_action(group.prefix .. "a", "lookup"))
		local calls = count_source_reads(shortcuts, ctx)
		local rows = ui.provide_rows(ctx, nil)
		helpers.assert_eq(#rows, #shortcuts.get_keyboard_slot_groups())
		helpers.assert_true(calls.assigned > 0, "the positive control reads actual assignments")
		helpers.assert_true(calls.labels > 0, "the positive control reads actual action captions")
		helpers.assert_eq(#picker.opened, 0, "data construction still performs no native picker action")
	end)

	for _, control in ipairs({ "missing", "withdrawn", "late_add" }) do
		it("rejects " .. control .. " declarations before any real assignment or caption read", function()
			local ui, shortcuts, picker = fresh()
			local ctx = make_ctx()
			local calls = count_source_reads(shortcuts, ctx)
			local root = require("infra.manifest_menu").get_root()
			if control == "missing" then root.keyboard_group_frame = nil
			elseif control == "withdrawn" then root.keyboard_group_frame = {}
			else root.keyboard_group_add_option_control = {} end
			local rows = ui.provide_rows(ctx, nil)
			helpers.assert_eq(calls.assigned, 0, "invalid declaration refuses before the genuine facade getter")
			helpers.assert_eq(calls.labels, 0, "invalid declaration refuses before action caption getters")
			helpers.assert_eq(rows, {}, "invalid source cannot publish a partial group set")
			helpers.assert_eq(#picker.opened, 0)
		end)
	end

	for _, control in ipairs({ "missing", "non_boolean", "raises" }) do
		it("rejects " .. control .. " boundary predicates before real assignment or caption reads", function()
			local ui, shortcuts, picker = fresh()
			local ctx = make_ctx()
			local calls = count_source_reads(shortcuts, ctx)
			local renderer = require("infra.manifest_menu")
			local actual_template_rows = renderer.template_rows
			renderer.template_rows = function(key, commands, getters, children)
				if key == "keyboard_group_frame" then
					if control == "missing" then getters.keyboard_group_has_fixed = nil
					elseif control == "non_boolean" then getters.keyboard_group_has_fixed = function() return 1 end
					else getters.keyboard_group_has_fixed = function() error("independent source-read refusal", 0) end end
				end
				return actual_template_rows(key, commands, getters, children)
			end
			local rows = ui.provide_rows(ctx, nil)
			helpers.assert_eq(calls.assigned, 0, "invalid predicate refuses before the genuine facade getter")
			helpers.assert_eq(calls.labels, 0, "invalid predicate refuses before action caption getters")
			helpers.assert_eq(rows, {}, "no groups publish after predicate refusal")
			helpers.assert_eq(#picker.opened, 0)
		end)
	end
end)

helpers.describe("keyboard slot selection declared presentation", function()
	it("delivers the real fixed slot picker context without caller-owned captions", function()
		local ui, shortcuts, picker = fresh()
		local ctx = make_ctx()
		local rows = ui.provide_rows(ctx, nil)
		physical_rows(rows, shortcuts)[1].items[#physical_rows(rows, shortcuts)[1].items].action()
		helpers.assert_eq(#picker.opened, 1)
		local opts = picker.opened[1].opts
		helpers.assert_eq(opts.presentation_id, "keyboard_slot_selection")
		helpers.assert_nil(opts.title)
		helpers.assert_nil(opts.label)
		helpers.assert_eq(opts.current, "none")
		helpers.assert_type(picker.opened[1].confirm, "function")
	end)
end)
