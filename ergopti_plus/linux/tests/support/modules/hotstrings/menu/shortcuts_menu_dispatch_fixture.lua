--- tests/support/modules/hotstrings/menu/shortcuts_menu_dispatch_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_shortcuts_menu_dispatch
--- DESCRIPTION:
--- Prelude shared by the test_shortcuts_menu_dispatch_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A shortcuts module with the surface the menu reads.
--- @param log table|nil Records what the rows called.
--- @return table
local function fake_shortcuts(log)
	log = log or {}
	local enabled, caps = true, false
	return {
		is_enabled          = function() return enabled end,
		toggle              = function() enabled = not enabled ; log.toggled = true end,
		is_caps_word_active = function() return caps end,
		toggle_caps_word    = function() caps = not caps ; log.caps = true end,
		transform_uppercase = function() log.upper = true end,
		transform_lowercase = function() log.lower = true end,
		transform_titlecase = function() log.title = true end,
		select_word         = function() log.word = true end,
		select_line         = function() log.line = true end,
		paste_plain         = function() log.paste = true end,
		wrap_selection      = function(l, r) log.wrapped = l .. r end,
		get_wrap_pairs      = function()
			return {
				["("] = { left = "(", right = ")" },
				[")"] = { left = "(", right = ")" },
				["«"] = { left = "«", right = "»" },
				["»"] = { left = "«", right = "»" },
			}
		end,
	}
end

--- The shortcuts submenu, as the tray builder returns it.
--- @param ctx_extra table|nil
--- @return table|nil rows
local function shortcuts_menu(ctx_extra)
	local mb = helpers.load_module("ui.menu.menu_builder")
	local ctx = { _version = "9.9.9", shortcuts = fake_shortcuts() }
	for k, v in pairs(ctx_extra or {}) do ctx[k] = v end

	local wanted = require("infra.i18n").get("menu.shortcuts.select_word")
	for _, item in ipairs(mb.build(ctx)) do
		if type(item.menu) == "table" then
			for _, row in ipairs(item.menu) do
				if row.title == wanted then return item.menu end
			end
		end
	end
	return nil
end

--- Finds a row recursively in the tray adapter's rendered dialect.
--- @param rows table
--- @param title string
--- @return table|nil
local function find_row(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title then return row end
		local nested = find_row(row.menu, title)
		if nested then return nested end
	end
	return nil
end

--- Finds the first row, at any depth, whose title starts with a prefix.
--- @param rows table|nil
--- @param prefix string
--- @return table|nil
local function find_row_prefix(rows, prefix)
	for _, row in ipairs(rows or {}) do
		if type(row.title) == "string" and row.title:sub(1, #prefix) == prefix then return row end
		local nested = find_row_prefix(row.menu, prefix)
		if nested then return nested end
	end
	return nil
end

-- =================================================================
-- =================================================================
-- ======= 2/ The rows the manifest owns ===========================
-- =================================================================
-- =================================================================

--- Keeps the genuine config/parameter/assignment owners alive through confirmation.
--- Only the picker/editor presentation and prompt boundary are controlled.
--- @param prompt function|nil Controlled prompt; nil uses the application chooser.
--- @param body function Assertions while the actual owners and private source remain live.
local function with_keyboard_slot_picker(prompt, body)
	local Sandbox = require("test.config_unused_keys_contract").sandbox
	local Writer = require("toml_codec.writer")
	local loaded = {}; for name, value in pairs(package.loaded) do loaded[name] = value end
	local source = '[shortcuts.keyboard]\nctrl_k = "none"\n[gesture_parameters]\nkeyboard__ctrl_k__open_url = "https://old.example"\n[unrelated]\nkeep = 42\n'
	local ok, failure = pcall(function()
		Sandbox.with_config(source, function(path)
			for _, name in ipairs({ "modules.gestures.manager", "modules.shortcuts.keyboard_shortcuts",
				"modules.shortcuts.manager", "modules.hotstrings.magic_key", "infra.program_binding_transaction",
				"infra.manifest_menu" }) do package.loaded[name] = nil end
			package.loaded["logger.shim"] = helpers.make_logger_stub()
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["adapters.storage"] = { get = function(_, default) return default end }
			package.loaded["ui.gesture_conflicts"] = { notify_boot = function() end, rows = function() return {} end }
			package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", close = function() error("menu fixture must not close input") end }
			local scene = { events = {} }
			local events, backups, publications = scene.events, {}, 0
			package.loaded["adapters.file_system"] = {
				read = function(target) return Writer.read_classified(target) end,
				read_with_status = function(target) return Writer.read_classified(target) end,
				write = function() error("menu fixture forbids unconditional publication") end,
				write_if_unchanged = function(target, content, expected)
					if target ~= path then backups[#backups + 1] = target end
					local accepted, detail, receipt = Writer.publish_if_unchanged(target, content, nil, expected)
					if accepted == true and target == path then publications = publications + 1 end
					return accepted, detail, receipt
				end,
			}
			local called, result = pcall(function()
				local gestures = require("modules.gestures.manager")
				gestures.init({ persist = true, config_path = path, enabled = false })
				local keyboard = require("modules.shortcuts.keyboard_shortcuts")
				-- A one-row presentation still delegates all ownership/domain policy.
				keyboard.SLOT_GROUPS = { { prefix = "ctrl_", group_key = "menu.shortcuts.mod_ctrl" } }
				keyboard.available_slots = function() return { "ctrl_k" } end
				keyboard.get_slot_label = function() return "Ctrl+K" end
				scene.items = { { type = "action", id = "open_url", label = "Open URL" } }
				scene.editor = { send_vocabulary = { keys = {} }, parameter_strings = { save = "Save" } }
				gestures.get_action_label = function(action) return action == "open_url" and "Open URL" or "None" end
				gestures.get_action_parameter_prompt = function(action) return "prompt:" .. action end
				local original_parameter = gestures.get_action_parameter
				gestures.get_action_parameter = function(binding, action)
					events[#events + 1] = "prior:" .. binding .. ":" .. action
					return original_parameter(binding, action)
				end
				gestures.get_picker_items = function() return scene.items end
				gestures.get_picker_parameter_fields = function(items, binding)
					helpers.assert_eq(items, scene.items, "the editor marks the items the picker shows")
					events[#events + 1] = "editor:" .. tostring(binding)
					return scene.editor
				end
				local original_parameters = gestures.apply_parameter_configuration
				gestures.apply_parameter_configuration = function(token, state)
					local prior = gestures.parameter_configuration_snapshot(token)
					local accepted = original_parameters(token, state)
					if accepted == true then
						for key, value in pairs(state) do
							if prior[key] ~= value then
								local binding, action = gestures.split_action_parameter_key(key)
								events[#events + 1] = "parameter:" .. binding .. ":" .. action .. ":" .. value
							end
						end
					end
					return accepted
				end
				local original_assignment = keyboard.apply_configuration
				keyboard.apply_configuration = function(token, state)
					local prior = keyboard.configuration_snapshot(token)
					local accepted = original_assignment(token, state)
					if accepted == true and prior.assignments.ctrl_k ~= state.assignments.ctrl_k then
						events[#events + 1] = "assign:ctrl_k:" .. state.assignments.ctrl_k
					end
					return accepted
				end
				package.loaded["ui.action_picker.bridge"] = { open = function(options, confirm)
					scene.picker = { opts = options, on_confirm = confirm }
					return true
				end }
				local ctx = { gestures = gestures, is_paused = function() return false end }
				if prompt then ctx.prompt_action_parameter = function(binding, action, spec, prior)
					scene.prompt_args = { binding, action, spec, prior }
					return prompt(binding, action, spec, prior)
				end end
				local built = shortcuts_menu(ctx)
				local picker_label = require("infra.i18n").get("dialog.action_picker.label") .. "…"
				local slot_row = find_row_prefix(built, "Ctrl+K")
				helpers.assert_not_nil(slot_row, "the keyboard slot must be drawn")
				local picker_choice = find_row(slot_row.menu, picker_label)
				helpers.assert_not_nil(picker_choice,
					"the shared searchable picker must be reachable from a keyboard slot")
				helpers.assert_true(type(picker_choice.fn) == "function")
				for index = #events, 1, -1 do events[index] = nil end
				picker_choice.fn()
				helpers.assert_not_nil(scene.picker, "clicking the production row must open the picker host")
				body(scene)
				helpers.assert_eq(publications, 1, "the actual retained owner publishes the joint candidate once")
				local document = require("toml_codec").decode(Sandbox.read_bytes(path))
				helpers.assert_eq(document.shortcuts.keyboard.ctrl_k, keyboard.get_action("ctrl_k"))
				for key, value in pairs(gestures.get_all_action_parameters()) do
					helpers.assert_eq(document.gesture_parameters[key], value, "disk and actual parameter owner agree")
				end
				helpers.assert_eq(document.unrelated.keep, 42)
			end)
			for _, backup in ipairs(backups) do os.remove(backup); os.remove(backup .. ".tmp") end
			if not called then error(result, 0) end
		end)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(failure, 0) end
end

-- Own the genuine native translation cohort while exercising cold and warm trays.
local function with_shortcut_locale(code, scenario)
	local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu", "ui.menu.menu_builder" }
	local prior = {}; for _, name in ipairs(names) do prior[name] = rawget(package.loaded, name) end
	local native, owner, receipt, acquired
	local ok, detail = xpcall(function()
		for _, name in ipairs(names) do rawset(package.loaded, name, nil) end
		native = require("infra.i18n")
		native.init()
		owner = { pending = function() return false end }
		assert(native.scope_acquire(owner))
		acquired = true
		receipt = assert(native.scope_capture(owner))
		assert(native.scope_apply(owner, receipt, code))
		return scenario()
	end, debug.traceback)
	local restored = not receipt or native.scope_restore(owner, receipt)
	local released = not acquired or native.scope_release(owner)
	local forgotten = not receipt or (released and native.scope_forget(owner, receipt))
	for _, name in ipairs(names) do rawset(package.loaded, name, prior[name]) end
	assert(restored and released and forgotten, "genuine locale inverse or lease finalization refused")
	for _, name in ipairs(names) do helpers.assert_true(rawequal(rawget(package.loaded, name), prior[name]), name) end
	if not ok then error(detail, 0) end
end

return {
	helpers = helpers,
	fake_shortcuts = fake_shortcuts,
	shortcuts_menu = shortcuts_menu,
	find_row = find_row,
	find_row_prefix = find_row_prefix,
	with_keyboard_slot_picker = with_keyboard_slot_picker,
	with_shortcut_locale = with_shortcut_locale,
}
