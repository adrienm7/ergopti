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
	"tests.support.keyboard_config_fixture", "infra.manifest_menu", "menu.renderer", "infra.i18n",
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

--- Separates physical Add flows from the fixed contextual editor row.
--- @param shortcuts table Real shortcut facade.
--- @return table groups
local function physical_groups(shortcuts)
	local groups = {}
	for _, group in ipairs(shortcuts.get_keyboard_slot_groups()) do
		if not group.fixed then groups[#groups + 1] = group end
	end
	return groups
end

--- Finds the corresponding physical rows without depending on contextual placement.
--- @param rows table Complete group rows.
--- @param shortcuts table Real shortcut facade.
--- @return table physical
local function physical_rows(rows, shortcuts)
	local physical = {}
	for index, group in ipairs(shortcuts.get_keyboard_slot_groups()) do
		if not group.fixed then physical[#physical + 1] = rows[index] end
	end
	return physical
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

	it("keeps the fixed contextual row editable after an explicit none choice", function()
		local ui, shortcuts, picker = fresh()
		local ctx = make_ctx()
		helpers.assert_eq(shortcuts.set_keyboard_action("magic_editor", "none"), true)
		local groups = shortcuts.get_keyboard_slot_groups()
		local rows = ui.provide_rows(ctx, nil)
		local contextual
		for index, group in ipairs(groups) do
			if group.prefix == "contextual" then contextual = rows[index] end
		end
		helpers.assert_not_nil(contextual)
		helpers.assert_eq(#contextual.items, 1, "one fixed logical slot needs no redundant Add flow")
		local row = contextual.items[1]
		helpers.assert_true(row.label:find("Label:none", 1, true) ~= nil)
		helpers.assert_nil(row.disabled, "source proof does not disable ordinary action editing")
		row.action()
		helpers.assert_eq(picker.opened[#picker.opened].opts.current, "none")
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

	it("offers creation or fixed-row editing when no physical binding is active", function()
		local ui = fresh()
		local ctx = make_ctx()
		for _, row in ipairs(ui.provide_rows(ctx, nil)) do
			helpers.assert_true(#row.items >= 1,
				"each group must retain its ordinary assignment editor")
			local last = row.items[#row.items]
			helpers.assert_eq(type(last.action), "function", "the group editor must be actionable")
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
		local group = physical_groups(shortcuts)[1]
		local taken = group.prefix .. FIRST_KEY
		helpers.assert_true(shortcuts.set_keyboard_action(taken, "lookup"))

		local rows = ui.provide_rows(ctx, nil)
		physical_rows(rows, shortcuts)[1].items[#physical_rows(rows, shortcuts)[1].items].action()

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
		local group = physical_groups(shortcuts)[2]
		local slot = group.prefix .. "j"

		local rows = ui.provide_rows(ctx, nil)
		physical_rows(rows, shortcuts)[2].items[#physical_rows(rows, shortcuts)[2].items].action()
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
		physical_rows(rows, shortcuts)[1].items[#physical_rows(rows, shortcuts)[1].items].action()
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
		local group = physical_groups(shortcuts)[1]
		local slot = group.prefix .. "m"
		helpers.assert_true(shortcuts.set_keyboard_action(slot, "lookup"))

		local rows = ui.provide_rows(ctx, nil)
		local found = nil
		for _, inner in ipairs(physical_rows(rows, shortcuts)[1].items) do
			if inner.label:find("Label:lookup", 1, true) then found = inner end
		end
		helpers.assert_true(found ~= nil,
			"an assigned slot must appear in its group, labelled with what it does")

		helpers.assert_true(shortcuts.set_keyboard_action(slot, "none"))
	end)

	it("opens the action picker on the slot's current action", function()
		local ui, shortcuts, picker, persisted = fresh()
		local ctx = make_ctx()
		local group = physical_groups(shortcuts)[1]
		local slot = group.prefix .. "m"
		helpers.assert_true(shortcuts.set_keyboard_action(slot, "lookup"))

		local rows = ui.provide_rows(ctx, nil)
		physical_rows(rows, shortcuts)[1].items[1].action()

		helpers.assert_eq(picker.opened[1].opts.current, "lookup",
			"the picker must open on what the slot holds, not on 'none'")

		helpers.assert_true(shortcuts.set_keyboard_action(slot, "none"))
	end)

	it("removes the binding when 'none' is chosen", function()
		local ui, shortcuts, picker, persisted = fresh()
		local ctx = make_ctx()
		local group = physical_groups(shortcuts)[1]
		local slot = group.prefix .. "m"
		helpers.assert_true(shortcuts.set_keyboard_action(slot, "lookup"))

		local rows = ui.provide_rows(ctx, nil)
		physical_rows(rows, shortcuts)[1].items[1].action()
		picker.opened[1].confirm("none")

		helpers.assert_eq(shortcuts.get_keyboard_action(slot), "none",
			"choosing the disabled row must clear the slot, not bind an action called 'none'")
		helpers.assert_eq(persisted[slot], "none", "choosing None must preserve explicit personal intent")
		local still_listed = false
		for _, inner in ipairs(physical_rows(ui.provide_rows(ctx, nil), shortcuts)[1].items) do
			if inner.label:find(shortcuts.get_keyboard_slot_label(slot), 1, true) then still_listed = true end
		end
		helpers.assert_eq(still_listed, false, "and the row must disappear from the group")
	end)

	it("does not refresh the menu when the shortcut transaction refuses", function()
		local ui, shortcuts, picker, persisted = fresh()
		local ctx, updates = make_ctx()
		local group = physical_groups(shortcuts)[1]
		local slot = group.prefix .. "m"
		local original_set = shortcuts.set_keyboard_action
		shortcuts.set_keyboard_action = function() return false end

		local ok, err = xpcall(function()
			local rows = ui.provide_rows(ctx, nil)
			physical_rows(rows, shortcuts)[1].items[#physical_rows(rows, shortcuts)[1].items].action()
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
	local group = physical_groups(shortcuts)[1]
	local slot = group.prefix .. "j"
	local files = package.loaded["adapters.file_system"]
	local writes = 0
	files.write_if_unchanged = function()
		writes = writes + 1
		return false, "injected conditional refusal"
	end
	local rows = ui.provide_rows(ctx, nil)
	physical_rows(rows, shortcuts)[1].items[#physical_rows(rows, shortcuts)[1].items].action()
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
	ctx.gestures.get_sg_names = function()
		return { "#header", "lookup", "select_line", "send_key", "wrap_selection", "llm_prompt_prediction",
			"llm_screen_region", "llm_translate_selection" }
	end
	ctx.gestures.get_action_parameter_spec = function(id)
		return ({
			wrap_selection = "wrap_pair", send_key = "key", llm_prompt_prediction = "llm_prompt",
			llm_screen_region = "llm_vision", llm_translate_selection = "llm_language",
		})[id]
	end
	ctx.gestures.get_action_parameter = function(_, action)
		return ({
			wrap_selection = "(", llm_prompt_prediction = "rewrite|2", llm_screen_region = "openai|gpt-4.1-mini",
			llm_translate_selection = "ja",
		})[action] or ""
	end
	ctx.gestures.llm_prompt_choices = function()
		return { { value = "basic", label = "Basic" }, { value = "rewrite", label = "Rewrite" } }
	end
	ctx.gestures.llm_prompt_default_count = function() return 3 end
	local vision_choices = {
		{ value = "local", label = "Local", defaultModel = "qwen2.5vl:3b" },
		{ value = "cerebras", label = "Cerebras", defaultModel = "" },
	}
	ctx.gestures.llm_vision_choices = function() return vision_choices end
	local language_choices = { { value = "ui", label = "Menu language (English)" }, { value = "ja", label = "日本語" } }
	ctx.gestures.llm_language_choices = function() return language_choices end
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
		local group = physical_groups(shortcuts)[1]
		local slot = group.prefix .. "w"

		local ok, err = xpcall(function()
			local rows = ui.provide_rows(ctx, nil)
			physical_rows(rows, shortcuts)[1].items[#physical_rows(rows, shortcuts)[1].items].action()
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
		local group = physical_groups(shortcuts)[1]
		local slot = group.prefix .. "w"

		local ok, err = xpcall(function()
			local rows = ui.provide_rows(ctx, nil)
			physical_rows(rows, shortcuts)[1].items[#physical_rows(rows, shortcuts)[1].items].action()
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
			-- Every parameterized row carries its kind and stored value, so the
			-- page's "edit the current action" can reopen any of them
			local by_id = {}
			for _, item in ipairs(opts.items) do
				if item.id then by_id[item.id] = item end
			end
			helpers.assert_eq(by_id.wrap_selection and by_id.wrap_selection.parameter, "wrap_pair")
			helpers.assert_eq(by_id.wrap_selection and by_id.wrap_selection.parameterValue, "(")
			helpers.assert_eq(by_id.llm_prompt_prediction and by_id.llm_prompt_prediction.parameter, "llm_prompt")
			helpers.assert_eq(by_id.llm_prompt_prediction and by_id.llm_prompt_prediction.parameterValue,
				"rewrite|2")
			helpers.assert_eq(opts.prompt_choices, ctx.gestures.llm_prompt_choices(),
				"the llm_prompt editor offers the AI menu's prompts")
			helpers.assert_eq(opts.default_count, 3, "and names the AI menu's prediction count")
			helpers.assert_eq(opts.edit_current_label,
				package.loaded["infra.i18n"].get("dialog.action_picker.edit_current"))
			helpers.assert_eq(opts.parameter_strings.prompts.llm_prompt, "prompt")
			helpers.assert_eq(opts.parameter_strings.errors.llm_prompt, "refused")
			helpers.assert_type(opts.parameter_strings.countDefault, "string")
			-- The llm_vision editor: the backends with their default model, and its texts
			helpers.assert_eq(by_id.llm_screen_region and by_id.llm_screen_region.parameter, "llm_vision")
			helpers.assert_eq(by_id.llm_screen_region and by_id.llm_screen_region.parameterValue,
				"openai|gpt-4.1-mini")
			helpers.assert_eq(opts.vision_choices, ctx.gestures.llm_vision_choices(),
				"the llm_vision editor offers the vision backends")
			helpers.assert_eq(opts.parameter_strings.prompts.llm_vision, "prompt")
			helpers.assert_eq(opts.parameter_strings.errors.llm_vision, "refused")
			local i18n = package.loaded["infra.i18n"]
			for field, key in pairs({
				visionProviderLabel = "dialog.action_picker.vision_provider_label",
				visionModelLabel = "dialog.action_picker.vision_model_label",
				visionModelDefault = "dialog.action_picker.vision_model_default",
				visionModelRequired = "dialog.action_picker.vision_model_required",
			}) do
				helpers.assert_eq(opts.parameter_strings[field], i18n.get(key), field)
			end
			-- The llm_language editor: the target languages, and its texts
			helpers.assert_eq(by_id.llm_translate_selection and by_id.llm_translate_selection.parameter,
				"llm_language")
			helpers.assert_eq(by_id.llm_translate_selection and by_id.llm_translate_selection.parameterValue, "ja")
			helpers.assert_eq(opts.language_choices, ctx.gestures.llm_language_choices(),
				"the llm_language editor offers the target languages")
			helpers.assert_eq(opts.parameter_strings.prompts.llm_language, "prompt")
			helpers.assert_eq(opts.parameter_strings.errors.llm_language, "refused")
			helpers.assert_eq(opts.parameter_strings.languageLabel, i18n.get("dialog.action_picker.language_label"))
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
		local group = physical_groups(shortcuts)[1]
		local slot = group.prefix .. "w"

		local ok, err = xpcall(function()
			local rows = ui.provide_rows(ctx, nil)
			physical_rows(rows, shortcuts)[1].items[#physical_rows(rows, shortcuts)[1].items].action()
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
	it("preserves independently specified fixed, assigned and Add row order", function()
		local ui, shortcuts = fresh()
		local ctx = make_ctx()
		local group = physical_groups(shortcuts)[1]
		local slot = group.prefix .. "a"
		local fixed = { label = "Independent fixed row", action = function() error("a fixed row must not run during build") end }
		local add_label = require("infra.i18n").get("menu.shortcuts.alt_add")
		local assigned_label = shortcuts.get_keyboard_slot_label(slot) .. " : Label:lookup"
		local cases = {
			{ fixed = false, assigned = false, labels = { add_label } },
			{ fixed = true, assigned = false, labels = { fixed.label, "-", add_label } },
			{ fixed = false, assigned = true, labels = { assigned_label, add_label } },
			{ fixed = true, assigned = true, labels = { fixed.label, "-", assigned_label, add_label } },
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
			if case.fixed then helpers.assert_true(rawequal(rows[1], fixed), "borrowed fixed child identity is retained") end
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
