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
local MODULES = {
	"adapters.file_system", "adapters.hotkey_registrar", "infra.config_paths",
	"infra.preferences", "infra.deferred_work", "infra.dialog_util", "infra.logger",
	"modules.shortcuts", "modules.shortcuts.bindings", "modules.shortcuts.keyboard_shortcuts",
	"modules.shortcuts.tap_keys", "modules.shortcuts.script_control", "modules.gestures.actions",
	"ui.action_picker", "ui.menu.menu_keyboard_slots", "ui.menu.shortcut_utils",
	"tests.support.keyboard_config_fixture",
}

--- Owns the real facade and its canonical persistence boundary for one UI case.
local function it(name, callback)
	helpers.it(name, function()
		return helpers.with_stub_scope(MODULES, callback)
	end)
end




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
			get_sg_names = function() return { "#header", "lookup", "select_line" } end,
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
	local files = helpers.load_with_stubs("adapters.file_system")
	local read_resource = files.read_with_status
	local persisted = {}
	require("tests.support.keyboard_config_fixture").install(persisted)
	local read_config = files.read_with_status
	files.read_with_status = function(path, ...)
		if path == "keyboard-fixture-config" then return read_config(path, ...) end
		return read_resource(path, ...)
	end
	package.loaded["infra.deferred_work"] = {
		after = function(_, callback)
			callback()
			return true
		end,
	}
	local ui = require("ui.menu.menu_keyboard_slots")
	local shortcuts = require("modules.shortcuts")
	local picker = require("ui.action_picker")

	picker.opened = {}
	picker.open = function(opts, on_confirm)
		picker.opened[#picker.opened + 1] = { opts = opts, confirm = on_confirm }
	end

	return ui, shortcuts, picker, persisted
end




-- ==========================================
-- ==========================================
-- ======= 2/ Row Data ======================
-- ==========================================
-- ==========================================

helpers.describe("menu_keyboard_slots: provided rows", function()
	it("returns one row per group, each carrying nested rows", function()
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

	it("hands over DATA, never hs.menubar rows", function()
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

	it("offers an add row in every group even when nothing is bound", function()
		local ui = fresh()
		local ctx = make_ctx()
		for _, row in ipairs(ui.provide_rows(ctx, nil)) do
			helpers.assert_true(#row.items >= 1,
				"a group with no assignments must still offer a way to create one")
			local last = row.items[#row.items]
			helpers.assert_eq(type(last.action), "function", "the add row must be actionable")
		end
	end)

	it("propagates the disabled flag to every row", function()
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
	it("offers the free slots of the group, and only those", function()
		local ui, shortcuts, picker, persisted = fresh()
		local ctx = make_ctx()
		local group = shortcuts.get_keyboard_slot_groups()[1]
		local taken = group.prefix .. FIRST_KEY
		helpers.assert_true(shortcuts.set_keyboard_action(taken, "lookup"))

		local rows = ui.provide_rows(ctx, nil)
		rows[1].items[#rows[1].items].action()

		helpers.assert_eq(#picker.opened, 1, "the add row must open the slot picker")
		local offered = {}
		for _, item in ipairs(picker.opened[1].opts.items) do offered[item.id] = true end
		helpers.assert_true(not offered[taken],
			"an already-bound slot must not be offered again — picking it would overwrite silently")
		helpers.assert_true(offered[group.prefix .. "b"],
			"but every free slot of the group must be")

		helpers.assert_true(shortcuts.set_keyboard_action(taken, "none"))
	end)

	it("chains the action picker and persists what was chosen", function()
		local ui, shortcuts, picker, persisted = fresh()
		local ctx, updates = make_ctx()
		local group = shortcuts.get_keyboard_slot_groups()[2]
		local slot = group.prefix .. "j"

		local rows = ui.provide_rows(ctx, nil)
		rows[2].items[#rows[2].items].action()
		picker.opened[1].confirm(slot)

		helpers.assert_eq(#picker.opened, 2, "picking a slot must then ask what it should do")
		picker.opened[2].confirm("select_line")

		helpers.assert_eq(shortcuts.get_keyboard_action(slot), "select_line",
			"the assignment must be persisted, not merely displayed")
		helpers.assert_true(updates.count > 0, "and the menu must be rebuilt so the new row shows")
		helpers.assert_eq(persisted[slot], "select_line", "the real conditional writer must publish the chosen action")

		helpers.assert_true(shortcuts.set_keyboard_action(slot, "none"))
	end)

	it("does nothing when the slot picker is dismissed", function()
		local ui, shortcuts, picker, persisted = fresh()
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
	it("lists an assigned slot with its action label", function()
		local ui, shortcuts = fresh()
		local ctx = make_ctx()
		local group = shortcuts.get_keyboard_slot_groups()[1]
		local slot = group.prefix .. "m"
		helpers.assert_true(shortcuts.set_keyboard_action(slot, "lookup"))

		local rows = ui.provide_rows(ctx, nil)
		local found = nil
		for _, inner in ipairs(rows[1].items) do
			if inner.label:find("Label:lookup", 1, true) then found = inner end
		end
		helpers.assert_true(found ~= nil,
			"an assigned slot must appear in its group, labelled with what it does")

		helpers.assert_true(shortcuts.set_keyboard_action(slot, "none"))
	end)

	it("opens the action picker on the slot's current action", function()
		local ui, shortcuts, picker, persisted = fresh()
		local ctx = make_ctx()
		local group = shortcuts.get_keyboard_slot_groups()[1]
		local slot = group.prefix .. "m"
		helpers.assert_true(shortcuts.set_keyboard_action(slot, "lookup"))

		local rows = ui.provide_rows(ctx, nil)
		rows[1].items[1].action()

		helpers.assert_eq(picker.opened[1].opts.current, "lookup",
			"the picker must open on what the slot holds, not on 'none'")

		helpers.assert_true(shortcuts.set_keyboard_action(slot, "none"))
	end)

	it("removes the binding when 'none' is chosen", function()
		local ui, shortcuts, picker, persisted = fresh()
		local ctx = make_ctx()
		local group = shortcuts.get_keyboard_slot_groups()[1]
		local slot = group.prefix .. "m"
		helpers.assert_true(shortcuts.set_keyboard_action(slot, "lookup"))

		local rows = ui.provide_rows(ctx, nil)
		rows[1].items[1].action()
		picker.opened[1].confirm("none")

		helpers.assert_eq(shortcuts.get_keyboard_action(slot), "none",
			"choosing the disabled row must clear the slot, not bind an action called 'none'")
		helpers.assert_nil(persisted[slot], "the neutral assignment must be sparsely deleted")
		local still_listed = false
		for _, inner in ipairs(ui.provide_rows(ctx, nil)[1].items) do
			if inner.label:find(shortcuts.get_keyboard_slot_label(slot), 1, true) then still_listed = true end
		end
		helpers.assert_eq(still_listed, false, "and the row must disappear from the group")
	end)

	it("does not refresh the menu when the shortcut transaction refuses", function()
		local ui, shortcuts, picker, persisted = fresh()
		local ctx, updates = make_ctx()
		local group = shortcuts.get_keyboard_slot_groups()[1]
		local slot = group.prefix .. "m"
		local original_set = shortcuts.set_keyboard_action
		shortcuts.set_keyboard_action = function() return false end

		local ok, err = xpcall(function()
			local rows = ui.provide_rows(ctx, nil)
			rows[1].items[#rows[1].items].action()
			picker.opened[1].confirm(slot)
			picker.opened[2].confirm("lookup")
			helpers.assert_eq(updates.count, 0,
				"a refused native/persistence transaction must not publish a success refresh")
		end, debug.traceback)
		shortcuts.set_keyboard_action = original_set
		if not ok then error(err, 0) end
	end)
end)


it("menu_keyboard_slots: conditional publication refusal keeps the old choice", function()
	local ui, shortcuts, picker, persisted = fresh()
	local ctx, updates = make_ctx()
	local group = shortcuts.get_keyboard_slot_groups()[1]
	local slot = group.prefix .. "j"
	local files = package.loaded["adapters.file_system"]
	local writes = 0
	files.write_if_unchanged = function()
		writes = writes + 1
		return false, "injected conditional refusal"
	end
	local rows = ui.provide_rows(ctx, nil)
	rows[1].items[#rows[1].items].action()
	picker.opened[1].confirm(slot)
	picker.opened[2].confirm("select_line")
	helpers.assert_eq(writes, 1, "the real writer must attempt one conditional publication")
	helpers.assert_nil(persisted[slot])
	helpers.assert_eq(shortcuts.get_keyboard_action(slot), "none")
	helpers.assert_eq(updates.count, 0, "a refused publication must not report a successful edit")
end)




-- ==========================================
-- ==========================================
-- ======= 5/ Parameterized Actions =========
-- ==========================================
-- ==========================================

--- A context whose gesture registry declares wrap_selection's wrap_pair
--- parameter and records where a value is stored.
--- @return table ctx, table stored
local function parameter_ctx()
	local ctx = make_ctx()
	local stored = {}
	ctx.gestures.get_sg_names = function() return { "#header", "lookup", "select_line", "send_key" } end
	ctx.gestures.get_action_parameter_spec = function(id)
		return ({ wrap_selection = "wrap_pair", send_key = "key" })[id]
	end
	ctx.gestures.get_action_parameter = function() return "" end
	ctx.gestures.validate_action_parameter = function(_, value) return value == "(" or value == "enter" end
	local vocabulary = { keys = {}, modifiers = {}, text_max_code_points = 500 }
	ctx.gestures.send_vocabulary = function() return vocabulary end
	ctx.gestures.parameter_prompt = function() return "prompt" end
	ctx.gestures.parameter_error = function() return "refused" end
	ctx.gestures.set_action_parameter = function(binding, action, value)
		stored[#stored + 1] = { binding = binding, action = action, value = value }
		return true
	end
	return ctx, stored
end

helpers.describe("menu_keyboard_slots: parameterized actions", function()
	-- A keyboard slot bound to wrap_selection (or open_url, search_web) did
	-- nothing: the picker stored the action and never asked for its parameter,
	-- which the handler reads under the slot's dispatch binding.
	it("asks for the parameter under the slot's dispatch binding before binding", function()
		local ui, shortcuts, picker, persisted = fresh()
		local ctx, stored = parameter_ctx()
		local dialog = package.loaded["infra.dialog_util"]
		helpers.assert_eq(type(dialog), "table",
			"the slot menu must reach the shared parameter prompt (ui.menu.shortcut_utils)")
		local saved_prompt = dialog.text_prompt
		dialog.text_prompt = function(_title, _prompt, _prior, confirm) return confirm, "(" end
		local group = shortcuts.get_keyboard_slot_groups()[1]
		local slot = group.prefix .. "w"

		local ok, err = xpcall(function()
			local rows = ui.provide_rows(ctx, nil)
			rows[1].items[#rows[1].items].action()
			picker.opened[1].confirm(slot)
			picker.opened[2].confirm("wrap_selection")
			helpers.assert_eq(#stored, 1, "the pair must be asked for and stored")
			helpers.assert_eq(stored[1].binding, shortcuts.keyboard_binding_id(slot),
				"under the binding the dispatcher passes, not the bare slot id")
			helpers.assert_eq(stored[1].value, "(")
			helpers.assert_eq(shortcuts.get_keyboard_action(slot), "wrap_selection",
				"and only then may the slot be bound")
			helpers.assert_eq(persisted[slot], "wrap_selection", "the canonical TOML candidate must contain the choice")
		end, debug.traceback)
		dialog.text_prompt = saved_prompt
		helpers.assert_true(shortcuts.set_keyboard_action(slot, "none"))
		if not ok then error(err, 0) end
	end)

	-- The picker's own editor collects a send_* value before the pick: the
	-- page must be given what it edits with, and the value it collected must be
	-- stored without the native prompt asking for it again.
	it("hands the picker its editor and stores the value it collected without a prompt", function()
		local ui, shortcuts, picker, persisted = fresh()
		local ctx, stored = parameter_ctx()
		local dialog = package.loaded["infra.dialog_util"]
		local saved_prompt = dialog.text_prompt
		dialog.text_prompt = function() error("the value the picker's editor collected must not be asked again") end
		local group = shortcuts.get_keyboard_slot_groups()[1]
		local slot = group.prefix .. "w"

		local ok, err = xpcall(function()
			local rows = ui.provide_rows(ctx, nil)
			rows[1].items[#rows[1].items].action()
			picker.opened[1].confirm(slot)
			local opts = picker.opened[2].opts
			helpers.assert_eq(opts.send_vocabulary, ctx.gestures.send_vocabulary(),
				"the page validates with the drivers' own vocabulary")
			local marked = nil
			for _, item in ipairs(opts.items) do
				if item.id == "send_key" then marked = item end
			end
			helpers.assert_eq(marked and marked.parameter, "key", "the send_key row names its kind")
			helpers.assert_eq(opts.parameter_strings.prompts.key, "prompt",
				"the editor shows the native prompt's text")
			picker.opened[2].confirm("send_key", "enter")
			helpers.assert_eq(#stored, 1, "the collected value is stored")
			helpers.assert_eq(stored[1].binding, shortcuts.keyboard_binding_id(slot))
			helpers.assert_eq(stored[1].value, "enter")
			helpers.assert_eq(shortcuts.get_keyboard_action(slot), "send_key", "and the slot is bound")
			helpers.assert_eq(persisted[slot], "send_key", "the canonical TOML candidate must contain the choice")
		end, debug.traceback)
		dialog.text_prompt = saved_prompt
		helpers.assert_true(shortcuts.set_keyboard_action(slot, "none"))
		if not ok then error(err, 0) end
	end)

	it("leaves the slot unbound when the parameter prompt is cancelled", function()
		local ui, shortcuts, picker, persisted = fresh()
		local ctx, stored = parameter_ctx()
		local dialog = package.loaded["infra.dialog_util"]
		helpers.assert_eq(type(dialog), "table",
			"the slot menu must reach the shared parameter prompt (ui.menu.shortcut_utils)")
		local saved_prompt = dialog.text_prompt
		dialog.text_prompt = function() return "cancel", nil end
		local group = shortcuts.get_keyboard_slot_groups()[1]
		local slot = group.prefix .. "w"

		local ok, err = xpcall(function()
			local rows = ui.provide_rows(ctx, nil)
			rows[1].items[#rows[1].items].action()
			picker.opened[1].confirm(slot)
			picker.opened[2].confirm("wrap_selection")
			helpers.assert_eq(#stored, 0)
			helpers.assert_eq(shortcuts.get_keyboard_action(slot), "none",
				"a binding without its pair would do nothing when pressed")
		end, debug.traceback)
		dialog.text_prompt = saved_prompt
		if not ok then error(err, 0) end
	end)
end)
