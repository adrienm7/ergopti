--- tests/support/ui/menu/keyboard_layout/karabiner_bulk_commands_transaction_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_karabiner_bulk_commands_transaction
--- DESCRIPTION:
--- Prelude shared by the test_karabiner_bulk_commands_transaction_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

local COMMAND_CASES = {
	{
		id = "scope_clear",
		label = "common.clear_to_system",
		method = "apply_scope",
		request = { scope = "tap_holds", mode = "clear" },
	},
	{
		id = "scope_restore",
		label = "common.restore_recommended",
		method = "apply_scope",
		request = { scope = "tap_holds", mode = "recommended" },
	},
	{
		id = "copy_tap_to_combo",
		label = "menu.tapholds.copy_tap_to_combo",
		method = "copy_tap_actions_to_combos",
	},
}

-- Every remap slot row: it opens the shared action picker, and a pick there
-- reaches the slot's own setter.
local PICKER_ROUTE_CASES = {
	{
		setter = "set_tap_action",
		parent_prefix = "tap_hold.group.left_shift  :",
		picker_label = "tap_hold.picker.tap",
		expected_id = "left_shift",
	},
	{
		setter = "set_hold_action",
		parent_prefix = "tap_hold.group.left_shift  :",
		picker_label = "tap_hold.picker.hold",
		expected_id = "left_shift",
	},
	{
		setter = "set_combo_combo_action",
		parent_prefix = "tap_hold.group.left_shift + tap_hold.group.right_shift  :",
		picker_label = "menu.shortcuts.key_combinations_chord",
		expected_id = "shift_pair",
	},
	{
		setter = "set_combo_tap_action",
		parent_prefix = "tap_hold.group.left_shift + tap_hold.group.right_shift  :",
		picker_label = "menu.shortcuts.key_combinations_hold_tap",
		expected_id = "shift_pair",
	},
	{
		setter = "set_combo_hold_action",
		parent_prefix = "tap_hold.group.left_shift + tap_hold.group.right_shift  :",
		picker_label = "menu.shortcuts.key_combinations_hold_hold",
		expected_id = "shift_pair",
	},
}

-- Escape is a catalogue action the picker lists; None is the picker's own
-- clearing row, which the catalogue's entry is not listed beside.
local GROUPED_PICKER_ACTION = { label = "Escape", id = "escape" }
local SPECIAL_PICKER_ACTION = { label = "None", id = "none" }
local PICKER_ACTION_CASES = { SPECIAL_PICKER_ACTION, GROUPED_PICKER_ACTION }

-- Transaction test harness

-- Neither scope row asks (a question would be counted here) and both name a
-- backup under the remap file; both boundaries are doubles for the whole
-- module, restored at its end.
local SAVED_DIALOGS = package.loaded["infra.dialog_util"]
local SAVED_PATHS = package.loaded["infra.config_paths"]
local CONFIRMATION = { answer = "yes", asked = 0 }
package.loaded["infra.dialog_util"] = {
	block_alert = function(_, _, no, yes)
		CONFIRMATION.asked = CONFIRMATION.asked + 1
		return CONFIRMATION.answer == "yes" and yes or no
	end,
}
package.loaded["infra.config_paths"] = {
	get = function(key)
		assert(key == "KarabinerConfigPath", "unexpected path key " .. tostring(key))
		return "/remap/config_karabiner.toml"
	end,
}

--- Finds a rendered row without coupling the test to one menu-table dialect.
--- @param item table Built top-level item.
--- @param label string Exact i18n-key label.
--- @return table|nil row
local function find_item(item, label)
	for _, row in ipairs(item.submenu or item.menu or item.items or {}) do
		if row.title == label or row.label == label then return row end
		local nested = find_item(row, label)
		if nested then return nested end
	end
	return nil
end

--- Returns the callback carried by a rendered command row.
--- @param row table|nil Rendered row.
--- @return function|nil action
local function row_action(row)
	if type(row) ~= "table" then return nil end
	return row.fn or row.action
end

--- Returns the rendered children of one row in either supported dialect.
--- @param row table|nil Rendered row.
--- @return table children
local function row_children(row)
	if type(row) ~= "table" then return {} end
	return row.submenu or row.menu or row.items or {}
end

--- Finds a rendered descendant by exact title or label.
--- @param row table Root row.
--- @param label string Exact label.
--- @return table|nil match
local function find_descendant(row, label)
	if row.title == label or row.label == label then return row end
	for _, child in ipairs(row_children(row)) do
		local match = find_descendant(child, label)
		if match then return match end
	end
	return nil
end

--- Finds a rendered descendant whose title starts with one stable prefix.
--- @param row table Root row.
--- @param prefix string Title prefix.
--- @return table|nil match
local function find_descendant_prefix(row, prefix)
	local label = row.title or row.label
	if type(label) == "string" and label:sub(1, #prefix) == prefix then return row end
	for _, child in ipairs(row_children(row)) do
		local match = find_descendant_prefix(child, prefix)
		if match then return match end
	end
	return nil
end

--- Resolves one real slot row down to a pick in the shared action picker it
--- opens: the returned function opens the picker through the row, under a
--- recording stand-in for the window, and confirms the action there.
--- @param built table Built top-level Karabiner menu.
--- @param case table Picker route descriptor.
--- @param action_label string Exact concrete action label.
--- @return function|nil action
local function find_picker_action(built, case, action_label)
	local parent = find_descendant_prefix(built, case.parent_prefix)
	if not parent then return nil end
	local open = row_action(find_descendant(parent, case.picker_label))
	if type(open) ~= "function" then return nil end
	local action_id = nil
	for _, candidate in ipairs(PICKER_ACTION_CASES) do
		if candidate.label == action_label then action_id = candidate.id end
	end
	if action_id == nil then return nil end
	return function()
		local saved = package.loaded["ui.action_picker"]
		local offered, confirm = nil, nil
		package.loaded["ui.action_picker"] = {
			open = function(opts, on_confirm) offered, confirm = opts, on_confirm; return true end,
		}
		local ok, opened = pcall(open)
		package.loaded["ui.action_picker"] = saved
		if not ok then error(opened, 0) end
		helpers.assert_true(opened, "the slot row opens the shared action picker")
		helpers.assert_type(confirm, "function")
		if action_id ~= "none" then
			local listed = false
			for _, item in ipairs(offered.items) do listed = listed or item.id == action_id end
			helpers.assert_true(listed, "the picker lists " .. action_label)
		end
		return confirm(action_id)
	end
end

--- Builds a logger whose level records make premature SUCCESS observable.
--- @param observations table Mutable test observations.
--- @return table logger
local function recording_logger(observations)
	local logger = {}
	for _, level in ipairs({ "debug", "done", "error", "info", "start", "success", "trace", "warn" }) do
		local captured_level = level
		logger[level] = function(_, message, ...)
			local ok, formatted = pcall(string.format, tostring(message), ...)
			observations.logs[#observations.logs + 1] = {
				level = captured_level,
				message = ok and formatted or tostring(message),
			}
		end
	end
	return logger
end

--- Returns the shipped English text of one i18n key: the unit i18n echoes
--- keys, and a notice's wording is what these cases are about.
--- @param key string i18n key.
--- @return string text
local function english_text(key)
	local file = assert(io.open(helpers.shared("data/locales/en.json"), "rb"))
	local english = hs.json.decode(file:read("*a"))
	file:close()
	local text = english[key]
	helpers.assert_type(text, "string", "the key must exist in en.json: " .. tostring(key))
	return text
end

--- Counts logger records at one exact level.
--- @param observations table Mutable test observations.
--- @param level string Logger level.
--- @return number count
local function count_logs(observations, level)
	local count = 0
	for _, record in ipairs(observations.logs) do
		if record.level == level then count = count + 1 end
	end
	return count
end

--- Builds the minimum enabled remap facade consumed by menu_remap.
--- @param observations table Mutable test observations.
--- @param mode string Bulk request behavior.
--- @return table remap
local function make_remap(observations, mode)
	local remap = {
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None", category = "Spécial", holdable = true, tappable = true },
			{ id = "escape", label = "Escape", category = "Navigation", holdable = true, tappable = true },
		},
		TAP_HOLD_KEYS = { { id = "left_shift", label = "Left Shift" } },
		MOD_COMBOS = { { id = "shift_pair", label = "Shift pair", group = "Shift",
			from = { simultaneous = { { key_code = "left_shift" }, { key_code = "right_shift" } } } } },
		NON_CANONICAL_COMBOS = {},
		get_enabled = function() return true end,
		set_enabled = function() return true end,
		get_combo_symmetric = function() return false end,
		set_combo_symmetric = function() return true end,
		get_mod_combos_enabled = function() return true end,
		set_mod_combos_enabled = function() return true end,
		get_tap_action = function() return "none" end,
		set_tap_action = function()
			observations.calls.set_tap_action = observations.calls.set_tap_action + 1
			return true
		end,
		get_hold_action = function() return "none" end,
		set_hold_action = function()
			observations.calls.set_hold_action = observations.calls.set_hold_action + 1
			return true
		end,
		get_tap_timeout = function() return nil end,
		set_tap_timeout = function() return true end,
		get_combo_combo_action = function() return "none" end,
		set_combo_combo_action = function()
			observations.calls.set_combo_combo_action =
				observations.calls.set_combo_combo_action + 1
			return true
		end,
		get_combo_tap_action = function() return "none" end,
		set_combo_tap_action = function()
			observations.calls.set_combo_tap_action =
				observations.calls.set_combo_tap_action + 1
			return true
		end,
		get_combo_hold_action = function() return "none" end,
		set_combo_hold_action = function()
			observations.calls.set_combo_hold_action =
				observations.calls.set_combo_hold_action + 1
			return true
		end,
		get_tap_hold_timeout = function() return 200 end,
		set_tap_hold_timeout = function() return true end,
		get_sticky_timeout = function() return 1000 end,
		set_sticky_timeout = function() return true end,
		get_simultaneous_threshold = function() return 50 end,
		set_simultaneous_threshold = function() return true end,
		open_gui = function() return true end,
		open_guardian_settings = function() return true end,
		regenerate = function() return true end,
		stop_lease = function() return true end,
	}
	local function bulk_method(method_name)
		return function(...)
			local arguments = { ... }
			local on_done = arguments[#arguments]
			if #arguments > 1 then observations.arguments[method_name] = arguments[1] end
			observations.calls[method_name] = observations.calls[method_name] + 1
			observations.terminals[method_name] = on_done
			if mode == "throw" then error("synthetic bulk request failure") end
			if mode == "false" then return false end
			if mode == "sync-busy-false" then
				on_done(false, "bulk-settings-busy", 0)
				return false
			end
			if mode == "nil" then return nil end
			if mode == "sync-true-false" or mode == "sync-true-nil"
				or mode == "sync-true-throw" then
				on_done(true, "ready", 3)
				if mode == "sync-true-throw" then
					error("synthetic post-callback bulk request failure")
				end
				if mode == "sync-true-nil" then return nil end
				return false
			end
			return true
		end
	end
	for _, case in ipairs(COMMAND_CASES) do
		remap[case.method] = bulk_method(case.method)
	end
	remap.clear_tap_hold_binding = function(key_id, on_done)
		observations.calls.clear_tap_hold_binding =
			observations.calls.clear_tap_hold_binding + 1
		observations.arguments.clear_tap_hold_binding = key_id
		observations.terminals.clear_tap_hold_binding = on_done
		return true
	end
	remap.clear_combo_binding = function(combo_id, on_done)
		observations.calls.clear_combo_binding = observations.calls.clear_combo_binding + 1
		observations.arguments.clear_combo_binding = combo_id
		observations.terminals.clear_combo_binding = on_done
		return true
	end
	return remap
end

--- Builds menu_remap through the real manifest and returns its observations.
--- @param mode string Bulk-method behavior.
--- @param configure function|nil Optional remap customization.
--- @return table built
--- @return table observations
--- @return table remap
local function build_menu(mode, configure)
	local observations = {
		calls = {
			apply_scope = 0,
			copy_tap_actions_to_combos = 0,
			clear_tap_hold_binding = 0,
			clear_combo_binding = 0,
			set_tap_action = 0,
			set_hold_action = 0,
			set_combo_combo_action = 0,
			set_combo_tap_action = 0,
			set_combo_hold_action = 0,
			regenerate = 0,
		},
		arguments = {},
		terminals = {},
		logs = {},
		refreshes = 0,
	}
	local saved_logger = package.loaded["infra.logger"]
	local saved_controller = package.loaded["platform.remap.lease_controller"]
	local saved_manifest = package.loaded["infra.manifest_menu"]
	package.loaded["infra.logger"] = recording_logger(observations)
	package.loaded["platform.remap.lease_controller"] = {
		status = function() return "active", { phase = "active" } end,
		stop = function() return true end,
	}
	package.loaded["infra.manifest_menu"] = nil
	local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
	local remap = make_remap(observations, mode)
	if type(configure) == "function" then configure(remap, observations) end
	local ctx = {
		karabiner = remap,
		updateMenu = function() observations.refreshes = observations.refreshes + 1 end,
	}
	local built = menu.build(ctx)
	-- The modifier combinations and their bulk copy live in the « Combinaisons
	-- de touches » group under Shortcuts, which the same module builds; both
	-- trees are searched as one.
	local group = menu.build_key_combinations(ctx)
	-- Preserve the second group's boundary: its scope rows belong to that
	-- group, not to the Tap-Holds first-row contract asserted below.
	built.submenu[#built.submenu + 1] = { title = "menu.shortcuts.key_combinations", submenu = group }
	package.loaded["infra.logger"] = saved_logger
	package.loaded["platform.remap.lease_controller"] = saved_controller
	package.loaded["infra.manifest_menu"] = saved_manifest
	return built, observations, remap
end

-- Exact manifest command contracts


local function build_guardian_menu(state, options)
	options = options or {}
	local opened = { open_guardian_settings = 0, open_login_items = 0 }
	local built, observations = build_menu("pending", function(remap)
		remap.get_enabled = function() return options.enabled ~= false end
		remap.get_tap_holds_enabled = function() return options.tap_holds_on ~= false end
		remap.guardian_state = function() return state end
		for name in pairs(opened) do
			remap[name] = function(on_done)
				opened[name] = opened[name] + 1
				if options.open_fails then
					on_done(false, "open-request-rejected")
					return false
				end
				on_done(true, "opened")
				return true
			end
		end
	end)
	return built, opened, observations
end

local function with_guidance_declaration(section, mutate, body)
	local declaration, saved = nil, {}
	local opened = { open_guardian_settings = 0, open_login_items = 0 }
	local ok, err = pcall(function()
		local built = build_menu("pending", function(remap)
			remap.get_tap_holds_enabled = function() return true end
			remap.guardian_state = function() return "requires_approval" end
			for name in pairs(opened) do
				remap[name] = function(on_done)
					opened[name] = opened[name] + 1
					on_done(true, "opened")
					return true
				end
			end
			declaration = require("infra.manifest_menu").get_array(section)
			for index, row in ipairs(declaration) do
				saved[index] = {}
				for key, value in pairs(row) do saved[index][key] = value end
			end
			mutate(declaration)
		end)
		body(built, opened)
	end)
	if declaration then
		for index = #declaration, 1, -1 do declaration[index] = nil end
		for index, row in ipairs(saved) do declaration[index] = row end
	end
	if not ok then error(err, 0) end
end

return {
	COMMAND_CASES = COMMAND_CASES,
	CONFIRMATION = CONFIRMATION,
	GROUPED_PICKER_ACTION = GROUPED_PICKER_ACTION,
	PICKER_ACTION_CASES = PICKER_ACTION_CASES,
	PICKER_ROUTE_CASES = PICKER_ROUTE_CASES,
	SAVED_DIALOGS = SAVED_DIALOGS,
	SAVED_PATHS = SAVED_PATHS,
	SPECIAL_PICKER_ACTION = SPECIAL_PICKER_ACTION,
	build_guardian_menu = build_guardian_menu,
	build_menu = build_menu,
	count_logs = count_logs,
	english_text = english_text,
	find_descendant = find_descendant,
	find_descendant_prefix = find_descendant_prefix,
	find_item = find_item,
	find_picker_action = find_picker_action,
	make_remap = make_remap,
	recording_logger = recording_logger,
	row_action = row_action,
	row_children = row_children,
	with_guidance_declaration = with_guidance_declaration,
}
