--- tests/unit/ui/menu/test_karabiner_bulk_commands_transaction.lua

--- ==============================================================================
--- MODULE: Karabiner Manifest Bulk Commands Are Exact Transactions
--- DESCRIPTION:
--- Behaviorally exercises the three destructive command IDs through the real
--- shared-manifest renderer. Request acceptance never becomes a success claim;
--- only the exact terminal callback may refresh the menu and publish SUCCESS.
--- False, nil, throw, and negative-terminal paths remain visibly failed.
--- ==============================================================================

local helpers = require("tests.helpers")

local COMMAND_CASES = {
	{
		id = "karabiner_clear_all",
		label = "menu.karabiner.clear_all",
		method = "clear_all_bindings",
	},
	{
		id = "karabiner_restore_defaults",
		label = "menu.karabiner.restore_defaults",
		method = "reset_to_defaults",
	},
	{
		id = "karabiner_copy_tap_to_combo",
		label = "menu.karabiner.copy_tap_to_combo",
		method = "copy_tap_actions_to_combos",
	},
}

local PICKER_ROUTE_CASES = {
	{
		setter = "set_tap_action",
		parent_prefix = "Left Shift  :",
		picker_label = "menu.karabiner.tap_arrow",
		expected_id = "left_shift",
	},
	{
		setter = "set_hold_action",
		parent_prefix = "Left Shift  :",
		picker_label = "menu.karabiner.hold_arrow",
		expected_id = "left_shift",
	},
	{
		setter = "set_combo_combo_action",
		parent_prefix = "Shift pair  :",
		picker_label = "menu.karabiner.combo_arrow",
		expected_id = "shift_pair",
	},
	{
		setter = "set_combo_tap_action",
		parent_prefix = "Shift pair  :",
		picker_label = "menu.karabiner.tap_colon",
		expected_id = "shift_pair",
	},
	{
		setter = "set_combo_hold_action",
		parent_prefix = "Shift pair  :",
		picker_label = "menu.karabiner.hold_colon",
		expected_id = "shift_pair",
	},
}

-- Escape is reachable only through MenuUtils.build_action_picker's grouped,
-- non-Spécial branch; using it prevents a direct-row false green.
local GROUPED_PICKER_ACTION = { label = "Escape", id = "escape" }
-- None is reachable only through menu_remap's direct, ungrouped Spécial branch
local SPECIAL_PICKER_ACTION = { label = "None", id = "none" }
local PICKER_ACTION_CASES = { SPECIAL_PICKER_ACTION, GROUPED_PICKER_ACTION }

-- Transaction test harness

--- Finds a rendered row without coupling the test to one menu-table dialect.
--- @param item table Built top-level item.
--- @param label string Exact i18n-key label.
--- @return table|nil row
local function find_item(item, label)
	for _, row in ipairs(item.menu or item.items or {}) do
		if row.title == label or row.label == label then return row end
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
	return row.menu or row.items or {}
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

--- Resolves one real picker route down to its concrete action callback.
--- @param built table Built top-level Karabiner menu.
--- @param case table Picker route descriptor.
--- @param action_label string Exact concrete action label.
--- @return function|nil action
local function find_picker_action(built, case, action_label)
	local parent = find_descendant_prefix(built, case.parent_prefix)
	if not parent then return nil end
	local picker = find_descendant(parent, case.picker_label)
	if not picker then return nil end
	return row_action(find_descendant(picker, action_label))
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
		MOD_COMBOS = { { id = "shift_pair", label = "Shift pair", group = "Shift" } },
		NON_CANONICAL_COMBOS = {},
		get_enabled = function() return true end,
		set_enabled = function() return true end,
		get_combo_symmetric = function() return false end,
		set_combo_symmetric = function() return true end,
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
		return function(on_done)
			observations.calls[method_name] = observations.calls[method_name] + 1
			observations.terminals[method_name] = on_done
			if mode == "throw" then error("synthetic bulk request failure") end
			if mode == "false" then return false end
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
			clear_all_bindings = 0,
			reset_to_defaults = 0,
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
	local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
	local remap = make_remap(observations, mode)
	if type(configure) == "function" then configure(remap, observations) end
	local built = menu.build({
		karabiner = remap,
		updateMenu = function() observations.refreshes = observations.refreshes + 1 end,
	})
	package.loaded["infra.logger"] = saved_logger
	package.loaded["platform.remap.lease_controller"] = saved_controller
	package.loaded["infra.manifest_menu"] = saved_manifest
	return built, observations, remap
end

-- Exact manifest command contracts

helpers.describe("karabiner manifest bulk commands wait for exact settlement", function()
	helpers.it("HS-019 routes all three manifest IDs and withholds success until terminal true", function()
		for _, case in ipairs(COMMAND_CASES) do
			local built, observations = build_menu("pending")
			local row = find_item(built, case.label)
			helpers.assert_not_nil(row,
				case.id .. " must be rendered from the real shared menu manifest")
			helpers.assert_type(row_action(row), "function")

			helpers.assert_true(row_action(row)())
			helpers.assert_eq(observations.calls[case.method], 1)
			helpers.assert_eq(count_logs(observations, "success"), 0,
				case.id .. " request acceptance must not claim terminal success")
			helpers.assert_eq(observations.refreshes, 0,
				case.id .. " must not refresh a success-looking menu before terminal settlement")

			observations.terminals[case.method](true, "ready", 3)
			helpers.assert_eq(count_logs(observations, "success"), 1)
			helpers.assert_eq(observations.refreshes, 1)
		end
	end)

	helpers.it("HS-019 rejects false, nil, and throw without a success claim", function()
		for index, mode in ipairs({ "false", "nil", "throw" }) do
			local case = COMMAND_CASES[index]
			local built, observations = build_menu(mode)
			local action = row_action(find_item(built, case.label))
			helpers.assert_eq(action(), false)
			helpers.assert_eq(observations.calls[case.method], 1)
			helpers.assert_eq(count_logs(observations, "success"), 0)
			helpers.assert_true(count_logs(observations, "error") >= 1)
		end
	end)

	helpers.it("HS-019 rejects a negative terminal for every manifest command", function()
		for _, case in ipairs(COMMAND_CASES) do
			local built, observations = build_menu("pending")
			local action = row_action(find_item(built, case.label))
			helpers.assert_true(action())
			observations.terminals[case.method](false, "activation-failed", 0)
			helpers.assert_eq(count_logs(observations, "success"), 0)
			helpers.assert_true(count_logs(observations, "error") >= 1)
			helpers.assert_eq(observations.refreshes, 1)
		end
	end)

	helpers.it("HS-019 rejects synchronous true callbacks followed by false, nil, or throw", function()
		for _, mode in ipairs({ "sync-true-false", "sync-true-nil", "sync-true-throw" }) do
			local built, observations = build_menu(mode)
			local action = row_action(find_item(built, COMMAND_CASES[1].label))
			helpers.assert_eq(action(), false)
			helpers.assert_eq(count_logs(observations, "success"), 0,
				"the request result and terminal callback are separate exact contracts: " .. mode)
			helpers.assert_true(count_logs(observations, "error") >= 1)
		end
	end)
end)

-- Concrete picker commit routes

helpers.describe("karabiner picker routes preserve exact setter results", function()
	helpers.it("HS-019 refuses regeneration for every false, nil, or throwing setter", function()
		for _, case in ipairs(PICKER_ROUTE_CASES) do
			for _, picker_action in ipairs(PICKER_ACTION_CASES) do
				for _, mode in ipairs({ "false", "nil", "throw" }) do
					local built, observations = build_menu("pending", function(remap, route_observations)
						remap[case.setter] = function(id, action_id)
							route_observations.calls[case.setter] =
								route_observations.calls[case.setter] + 1
							route_observations.arguments[case.setter] = {
								id = id,
								action_id = action_id,
							}
							if mode == "throw" then error("synthetic setter failure") end
							if mode == "nil" then return nil end
							return false
						end
						remap.regenerate = function()
							route_observations.calls.regenerate =
								route_observations.calls.regenerate + 1
							return true
						end
					end)
					local action = find_picker_action(built, case, picker_action.label)
					helpers.assert_type(action, "function",
						case.setter .. " must reach " .. picker_action.label .. " through the real picker tree")
					helpers.assert_eq(action(), false,
						case.setter .. " must expose its exact " .. mode .. " result")
					helpers.assert_eq(observations.calls[case.setter], 1)
					helpers.assert_eq(observations.arguments[case.setter].id, case.expected_id)
					helpers.assert_eq(observations.arguments[case.setter].action_id,
						picker_action.id)
					helpers.assert_eq(observations.calls.regenerate, 0,
						case.setter .. " refusal must not deploy stale persisted state")
					helpers.assert_eq(observations.refreshes, 0)
				end
			end
		end
	end)

	helpers.it("HS-019 regenerates only after every picker setter publishes", function()
		for _, case in ipairs(PICKER_ROUTE_CASES) do
			for _, picker_action in ipairs(PICKER_ACTION_CASES) do
				local published = nil
				local deployed = nil
				local built, observations = build_menu("pending", function(remap, route_observations)
					remap[case.setter] = function(id, action_id)
						route_observations.calls[case.setter] =
							route_observations.calls[case.setter] + 1
						published = { id = id, action_id = action_id }
						return true
					end
					remap.regenerate = function()
						route_observations.calls.regenerate =
							route_observations.calls.regenerate + 1
						deployed = published and {
							id = published.id,
							action_id = published.action_id,
						} or nil
						return true
					end
				end)
				local action = find_picker_action(built, case, picker_action.label)
				helpers.assert_type(action, "function")
				helpers.assert_true(action())
				helpers.assert_eq(observations.calls[case.setter], 1)
				helpers.assert_eq(observations.calls.regenerate, 1)
				helpers.assert_true(helpers.deep_equal(deployed, {
					id = case.expected_id,
					action_id = picker_action.id,
				}), case.setter .. " regeneration must observe the committed "
					.. picker_action.label .. " publication")
				helpers.assert_eq(observations.refreshes, 1)
			end
		end
	end)
end)

-- Concrete local clear routes

helpers.describe("karabiner local clear rows use one bulk transaction", function()
	helpers.it("HS-019 routes tap/hold and combo clears without sequential setters", function()
		local cases = {
			{
				label = "menu.karabiner.nothing_tap_hold",
				method = "clear_tap_hold_binding",
				expected_id = "left_shift",
				configure = function(remap)
					remap.get_tap_action = function() return "escape" end
					remap.get_hold_action = function() return "layer" end
				end,
			},
			{
				label = "menu.karabiner.nothing_combo",
				method = "clear_combo_binding",
				expected_id = "shift_pair",
				configure = function(remap)
					remap.get_combo_combo_action = function() return "escape" end
					remap.get_combo_tap_action = function() return "escape" end
					remap.get_combo_hold_action = function() return "layer" end
				end,
			},
		}
		for _, case in ipairs(cases) do
			local built, observations = build_menu("pending", case.configure)
			local action = row_action(find_descendant(built, case.label))
			helpers.assert_type(action, "function")
			helpers.assert_true(action())
			helpers.assert_eq(observations.calls[case.method], 1)
			helpers.assert_eq(observations.arguments[case.method], case.expected_id)
			helpers.assert_eq(observations.calls.set_tap_action, 0)
			helpers.assert_eq(observations.calls.set_hold_action, 0)
			helpers.assert_eq(observations.calls.set_combo_combo_action, 0)
			helpers.assert_eq(observations.calls.set_combo_tap_action, 0)
			helpers.assert_eq(observations.calls.set_combo_hold_action, 0)
			helpers.assert_eq(count_logs(observations, "success"), 0)
			helpers.assert_eq(observations.refreshes, 0)

			observations.terminals[case.method](true, "ready", 1)
			helpers.assert_eq(count_logs(observations, "success"), 1)
			helpers.assert_eq(observations.refreshes, 1)
		end
	end)
end)
