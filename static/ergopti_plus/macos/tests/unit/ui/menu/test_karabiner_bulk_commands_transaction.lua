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

local PICKER_ROUTE_CASES = {
	{
		setter = "set_tap_action",
		parent_prefix = "tap_hold.group.left_shift  :",
		picker_label = "menu.tapholds.tap_arrow",
		expected_id = "left_shift",
	},
	{
		setter = "set_hold_action",
		parent_prefix = "tap_hold.group.left_shift  :",
		picker_label = "menu.tapholds.hold_arrow",
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

-- Escape is reachable only through MenuUtils.build_action_picker's grouped,
-- non-Spécial branch; using it prevents a direct-row false green.
local GROUPED_PICKER_ACTION = { label = "Escape", id = "escape" }
-- None is reachable only through menu_remap's direct, ungrouped Spécial branch
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
			if case.request then
				local sent = observations.arguments[case.method]
				helpers.assert_eq(sent.scope, case.request.scope)
				helpers.assert_eq(sent.mode, case.request.mode)
				helpers.assert_true(sent.backup_path:find("^/remap/config_karabiner%.toml%.tap_holds%-") ~= nil,
					"the backup sits beside the remap file: " .. tostring(sent.backup_path))
			end
			helpers.assert_eq(count_logs(observations, "success"), 0,
				case.id .. " request acceptance must not claim terminal success")
			helpers.assert_eq(observations.refreshes, 0,
				case.id .. " must not refresh a success-looking menu before terminal settlement")

			observations.terminals[case.method](true, "ready", 3)
			helpers.assert_eq(count_logs(observations, "success"), 1)
			helpers.assert_eq(observations.refreshes, 1)
		end
	end)

	-- The restore row asked until restore-recommended-no-confirm, the clear row
	-- until the maintainer retired its question too on 2026-09-30: the backup
	-- each request writes first is the way back.
	helpers.it("W1 runs both scope rows at once, without a question", function()
		for _, case in ipairs({ COMMAND_CASES[1], COMMAND_CASES[2] }) do
			local built, observations = build_menu("pending")
			local asked = CONFIRMATION.asked
			CONFIRMATION.answer = "no"
			local ok, result = pcall(row_action(find_item(built, case.label)))
			CONFIRMATION.answer = "yes"
			helpers.assert_true(ok, tostring(result))
			helpers.assert_eq(result, true)
			helpers.assert_eq(CONFIRMATION.asked, asked, case.id .. " must not ask")
			helpers.assert_eq(observations.calls.apply_scope, 1, case.id .. " runs at once")
			helpers.assert_true(row_action(find_item(built, case.label))())
			local first = observations.arguments.apply_scope.backup_path
			helpers.assert_true(row_action(find_item(built, case.label))())
			helpers.assert_true(observations.arguments.apply_scope.backup_path ~= first,
				"each request names a new backup")
		end
	end)

	-- The maintainer's first group (2026-09-30): the switch, the restore, the
	-- clear, then a separator, and no scope row below it.
	helpers.it("draws the switch, the restore and the clear as the first group", function()
		local built = build_menu("pending")
		local rows = built.submenu or built.menu or built.items or {}
		local titles = {}
		for index = 1, 4 do titles[index] = rows[index] and (rows[index].title or rows[index].label) end
		helpers.assert_eq(table.concat(titles, " | "),
			"menu.tapholds.enable | common.restore_recommended | common.clear_to_system | -")
		for index = 5, #rows do
			local title = rows[index].title or rows[index].label
			helpers.assert_true(title ~= "common.restore_recommended" and title ~= "common.clear_to_system",
				"no scope row may follow the first group")
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

	helpers.it("reports the refusal reason the remap engine gave (bulk-refusal-reason)", function()
		for _, case in ipairs(COMMAND_CASES) do
			local built, observations = build_menu("sync-busy-false")
			helpers.assert_eq(row_action(find_item(built, case.label))(), false)
			local reported = nil
			for _, record in ipairs(observations.logs) do
				if record.level == "error" and record.message:find("Karabiner bulk command", 1, true) then
					reported = record.message
				end
			end
			helpers.assert_eq(reported, "Karabiner bulk command '" .. case.method
				.. "' failed: bulk-settings-busy.",
				case.id .. " must not overwrite the engine's reason with request-refused")
		end
	end)

	helpers.it("announces a bulk edit saved until the guardian is ready (guardian-bulk-settle)", function()
		local saved_notifications = package.loaded["infra.notifications"]
		local notices = {}
		package.loaded["infra.notifications"] = {
			notify = function(message, detail, kind, on_click)
				notices[#notices + 1] = { message = message, detail = detail, kind = kind, on_click = on_click }
				return true
			end,
		}
		local ok, err = pcall(function()
			local opened = 0
			local built, observations = build_menu("pending", function(remap)
				remap.open_login_items = function(on_done)
					opened = opened + 1
					on_done(true, "opened")
					return true
				end
			end)
			helpers.assert_true(row_action(find_item(built, COMMAND_CASES[2].label))())
			observations.terminals.apply_scope(true, "persisted-guardian-requires_approval", 3)
			helpers.assert_eq(count_logs(observations, "success"), 1,
				"a saved edit is a success for the user")
			helpers.assert_eq(#notices, 1, "the user learns why nothing applies yet")
			helpers.assert_eq(notices[1].message, "menu.tapholds.saved_until_guardian")
			helpers.assert_type(notices[1].on_click, "function")
			helpers.assert_true(notices[1].on_click())
			helpers.assert_eq(opened, 1, "the notice opens Login Items")

			helpers.assert_true(row_action(find_item(built, COMMAND_CASES[2].label))())
			observations.terminals.apply_scope(true, "ready", 3)
			helpers.assert_eq(count_logs(observations, "success"), 2)
			helpers.assert_eq(#notices, 1, "an exact deploy needs no notice")
		end)
		package.loaded["infra.notifications"] = saved_notifications
		if not ok then error(err, 0) end
	end)

	helpers.it("tells to reopen ErgoptiPlus when the saved edit waits on an unregistered helper"
		.. " (saved-notice-unavailable)", function()
		local saved_notifications = package.loaded["infra.notifications"]
		local notices = {}
		package.loaded["infra.notifications"] = {
			notify = function(message, _, _, on_click)
				notices[#notices + 1] = { message = message, on_click = on_click }
				return true
			end,
		}
		local ok, err = pcall(function()
			local opened = 0
			local built, observations = build_menu("pending", function(remap)
				remap.open_login_items = function(on_done)
					opened = opened + 1
					on_done(true, "opened")
					return true
				end
			end)
			helpers.assert_true(row_action(find_item(built, COMMAND_CASES[2].label))())
			observations.terminals.apply_scope(true, "persisted-guardian-unavailable", 3)
			helpers.assert_eq(#notices, 1)
			-- The helper registers once per launch: Login Items alone fixes nothing.
			helpers.assert_true(english_text(notices[1].message):find("quit and reopen", 1, true) ~= nil,
				"the notice must say to reopen ErgoptiPlus: " .. english_text(notices[1].message))
			helpers.assert_true(notices[1].on_click())
			helpers.assert_eq(opened, 1, "the notice still opens Login Items")
		end)
		package.loaded["infra.notifications"] = saved_notifications
		if not ok then error(err, 0) end
	end)

	helpers.it("says once, localized, that the saved notice's Login Items did not open"
		.. " (login-items-open-failed)", function()
		local saved_notifications = package.loaded["infra.notifications"]
		local notices = {}
		package.loaded["infra.notifications"] = {
			notify = function(message, _, kind, on_click)
				notices[#notices + 1] = { message = message, kind = kind, on_click = on_click }
				return true
			end,
		}
		local ok, err = pcall(function()
			local built, observations = build_menu("pending", function(remap)
				remap.open_login_items = function(on_done)
					on_done(false, "open-request-rejected")
					return false
				end
			end)
			helpers.assert_true(row_action(find_item(built, COMMAND_CASES[2].label))())
			observations.terminals.apply_scope(true, "persisted-guardian-requires_approval", 3)
			helpers.assert_eq(notices[1].on_click(), false)
			helpers.assert_eq(#notices, 2)
			helpers.assert_eq(notices[2].message, "karabiner.guardian_settings_open_failed")
			helpers.assert_eq(count_logs(observations, "error"), 0,
				"no raw developer error on top of the localized notice")
		end)
		package.loaded["infra.notifications"] = saved_notifications
		if not ok then error(err, 0) end
	end)

	helpers.it("sends no one to Login Items when the helper only failed to answer"
		.. " (saved-notice-probe-failed)", function()
		local saved_notifications = package.loaded["infra.notifications"]
		local notices = {}
		package.loaded["infra.notifications"] = {
			notify = function(message, _, _, on_click)
				notices[#notices + 1] = { message = message, on_click = on_click }
				return true
			end,
		}
		local ok, err = pcall(function()
			local built, observations = build_menu("pending", function(remap)
				remap.open_login_items = function() return true end
			end)
			for _, status in ipairs({ "probe-failed", "not_requested" }) do
				helpers.assert_true(row_action(find_item(built, COMMAND_CASES[2].label))())
				observations.terminals.apply_scope(true, "persisted-guardian-" .. status, 3)
				local notice = notices[#notices]
				helpers.assert_eq(notice.message, "menu.tapholds.saved_until_helper",
					status .. " proves nothing about Login Items")
				helpers.assert_nil(english_text(notice.message):find("Login Items", 1, true))
				helpers.assert_nil(notice.on_click, "no Login Items click for " .. status)
			end
			helpers.assert_eq(#notices, 2)
		end)
		package.loaded["infra.notifications"] = saved_notifications
		if not ok then error(err, 0) end
	end)

	helpers.it("names no single submenu in the saved notice a combo command shows (saved-notice-wording)",
		function()
			local saved_notifications = package.loaded["infra.notifications"]
			local notices = {}
			package.loaded["infra.notifications"] = {
				notify = function(message)
					notices[#notices + 1] = message
					return true
				end,
			}
			local ok, err = pcall(function()
				local built, observations = build_menu("pending", function(remap)
					remap.open_login_items = function() return true end
				end)
				helpers.assert_true(row_action(find_item(built, COMMAND_CASES[3].label))())
				observations.terminals.copy_tap_actions_to_combos(true,
					"persisted-guardian-requires_approval", 1)
				helpers.assert_eq(#notices, 1)
				local text = english_text(notices[1])
				helpers.assert_nil(text:lower():find("tap%-hold"),
					"key-combination commands announce it too: " .. text)
			end)
			package.loaded["infra.notifications"] = saved_notifications
			if not ok then error(err, 0) end
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
				label = "menu.tapholds.nothing_tap_hold",
				method = "clear_tap_hold_binding",
				expected_id = "left_shift",
				configure = function(remap)
					remap.get_tap_action = function() return "escape" end
					remap.get_hold_action = function() return "layer" end
				end,
			},
			{
				label = "menu.tapholds.nothing_combo",
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

-- The guardian status rows

--- Builds the menu over one guardian state, recording which opener runs.
--- @param state string guardian_state() answer.
--- @param options table|nil { tap_holds_on = boolean, enabled = boolean }.
--- @return table built
--- @return table opened Counts per opener name.
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

helpers.describe("the Tap-Hold submenu says when the remap guardian holds its rules", function()
	local CASES = {
		{ state = "requires_approval", key = "menu.tapholds.guardian_requires_approval",
			opener = "open_guardian_settings" },
		{ state = "unavailable", key = "menu.tapholds.guardian_unavailable",
			opener = "open_login_items" },
	}
	for _, case in ipairs(CASES) do
		helpers.it("shows why and opens Login Items while the guardian is " .. case.state
			.. " (guardian-status-row)", function()
			local built, opened = build_guardian_menu(case.state)
			local status = find_descendant(built, case.key)
			helpers.assert_not_nil(status, "the reason must be visible without reading the log")
			helpers.assert_true(status.disabled == true, "the reason row is informative only")
			local action = row_action(find_descendant(built, "menu.tapholds.open_login_items"))
			helpers.assert_type(action, "function")
			helpers.assert_true(action())
			helpers.assert_eq(opened[case.opener], 1)
		end)
	end

	helpers.it("says to reopen ErgoptiPlus while its helper is unregistered (saved-notice-unavailable)",
		function()
			local built = build_guardian_menu("unavailable")
			local status = find_descendant(built, "menu.tapholds.guardian_unavailable")
			helpers.assert_not_nil(status)
			-- It registers once per launch: Login Items alone changes nothing.
			helpers.assert_true(english_text(status.title or status.label):find("quit and reopen", 1, true) ~= nil,
				"the row must name the step that registers the helper again")
		end)

	helpers.it("says once, localized, that Login Items did not open (login-items-open-failed)", function()
		local saved_notifications = package.loaded["infra.notifications"]
		local notices = {}
		package.loaded["infra.notifications"] = {
			notify = function(message, _, kind)
				notices[#notices + 1] = { message = message, kind = kind }
				return true
			end,
		}
		local ok, err = pcall(function()
			for _, case in ipairs(CASES) do
				local before = #notices
				local built, _, observations = build_guardian_menu(case.state, { open_fails = true })
				local action = row_action(find_descendant(built, "menu.tapholds.open_login_items"))
				helpers.assert_eq(action(), false)
				helpers.assert_eq(#notices, before + 1, case.state .. " must tell the user once")
				helpers.assert_eq(notices[#notices].message, "karabiner.guardian_settings_open_failed")
				helpers.assert_eq(notices[#notices].kind, "error")
				-- Each error line raises a developer notification; the opener logged it.
				helpers.assert_eq(count_logs(observations, "error"), 0,
					"no raw developer error on top of the localized notice")
			end
		end)
		package.loaded["infra.notifications"] = saved_notifications
		if not ok then error(err, 0) end
	end)

	-- The steps open by themselves once per launch; the row is where they
	-- stay afterwards (guardian-approval-steps).
	helpers.it("reopens the Login Items steps while approval is missing (guardian-approval-steps)", function()
		local saved_guide = package.loaded["ui.permission_dialog.login_items_guide"]
		local reopened = {}
		package.loaded["ui.permission_dialog.login_items_guide"] = {
			reopen = function(remap)
				reopened[#reopened + 1] = remap
				return true
			end,
		}
		local ok, err = pcall(function()
			local built = build_guardian_menu("requires_approval")
			local action = row_action(find_descendant(built, "menu.tapholds.show_login_items_steps"))
			helpers.assert_type(action, "function")
			helpers.assert_true(action())
			helpers.assert_eq(#reopened, 1, "the row reopens the steps dialog")
			helpers.assert_eq(type(reopened[1].guardian_state), "function",
				"the guide reads the same remap facade as the row")
			helpers.assert_not_nil(find_descendant(built, "menu.tapholds.open_login_items"),
				"the direct Login Items row stays")

			local unavailable = build_guardian_menu("unavailable")
			helpers.assert_nil(find_descendant(unavailable, "menu.tapholds.show_login_items_steps"),
				"the approval steps cannot register a missing helper")
		end)
		package.loaded["ui.permission_dialog.login_items_guide"] = saved_guide
		if not ok then error(err, 0) end
	end)

	helpers.it("shows no guardian row when nothing waits on it (guardian-status-row)", function()
		for _, variant in ipairs({
			{ state = "ready" },
			{ state = "not_used" },
			{ state = "unknown" },
			{ state = "unavailable", options = { tap_holds_on = false } },
			{ state = "requires_approval", options = { enabled = false } },
		}) do
			local built = build_guardian_menu(variant.state, variant.options)
			helpers.assert_nil(find_descendant(built, "menu.tapholds.open_login_items"),
				"no Login Items row for " .. variant.state)
			helpers.assert_nil(find_descendant(built, "menu.tapholds.show_login_items_steps"),
				"no steps row for " .. variant.state)
			for _, case in ipairs(CASES) do
				helpers.assert_nil(find_descendant(built, case.key))
			end
		end
	end)
end)

-- The legacy rules row

helpers.describe("the Tap-Hold submenu offers the legacy rules cleanup (karabiner-legacy-cleanup)", function()
	local PENDING = { count = 25, descriptions = { "CapsWord — toggle and deactivation" } }
	local ROW = "menu.tapholds.legacy_rules_pending"

	helpers.it("shows the row only while legacy rules block the deploy (karabiner-legacy-cleanup)", function()
		for _, variant in ipairs({
			{ pending = PENDING, shown = true },
			{ pending = PENDING, shown = true, tap_holds_on = false },
			{ pending = nil, shown = false },
		}) do
			local built = build_menu("pending", function(remap)
				remap.legacy_rule_conflicts = function() return variant.pending end
				remap.get_tap_holds_enabled = function() return variant.tap_holds_on ~= false end
			end)
			local row = find_descendant(built, ROW)
			helpers.assert_eq(row ~= nil, variant.shown,
				"the row follows the pending rules, Tap-Holds " .. tostring(variant.tap_holds_on ~= false))
		end
		helpers.assert_nil(find_descendant(build_menu("pending"), ROW),
			"a facade without legacy rules shows no row")
	end)

	helpers.it("the row reopens the cleanup dialog (karabiner-legacy-cleanup)", function()
		local saved_cleanup = package.loaded["ui.legacy_rules_cleanup"]
		local opened = {}
		package.loaded["ui.legacy_rules_cleanup"] = {
			open = function(remap)
				opened[#opened + 1] = remap
				return true
			end,
		}
		local ok, err = pcall(function()
			local built, observations = build_menu("pending", function(remap)
				remap.legacy_rule_conflicts = function() return PENDING end
				remap.remove_legacy_rules = function() return true end
			end)
			local action = row_action(find_descendant(built, ROW))
			helpers.assert_type(action, "function")
			helpers.assert_true(action())
			helpers.assert_eq(#opened, 1, "the row shows the same dialog the bridge offers")
			helpers.assert_eq(type(opened[1].remove_legacy_rules), "function",
				"the dialog reads the same remap facade as the row")
			helpers.assert_eq(count_logs(observations, "error"), 0)
		end)
		package.loaded["ui.legacy_rules_cleanup"] = saved_cleanup
		if not ok then error(err, 0) end
	end)
end)

package.loaded["infra.dialog_util"] = SAVED_DIALOGS
package.loaded["infra.config_paths"] = SAVED_PATHS

--- Mutates actual decoded shared metadata and always restores original rows.
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

helpers.describe("shared Tap-Hold guidance retains actual native admission and owners", function()
	helpers.it("keeps the handwritten native guardian state order (tap-hold-guidance)", function()
		local file = assert(io.open(helpers.shared("tests/corpus/menus/tap_hold_guidance.json"), "r"))
		local corpus = require("json").decode(file:read("*a")); file:close()
		local known = {}
		for _, key in ipairs({ "menu.tapholds.guardian_requires_approval", "menu.tapholds.guardian_unavailable",
			"menu.tapholds.show_login_items_steps", "menu.tapholds.open_login_items" }) do known[key] = true end
		for _, case in ipairs(corpus.states) do
			local built, opened = build_guardian_menu(case.state)
			local actual = {}
			for _, row in ipairs(row_children(built)) do
				local label = row.title or row.label
				if known[label] then actual[#actual + 1] = label end
			end
			helpers.assert_eq(actual, case.expected, case.state)
			helpers.assert_eq(opened, { open_guardian_settings = 0, open_login_items = 0 }, "building is inert")
		end
	end)

	helpers.it("actual approval provider follows shared label and row-order mutations (tap-hold-guidance)", function()
		with_guidance_declaration("tap_hold_guardian_approval_rows", function(rows)
			rows[1].i18n = "menu.shortcuts.title"
			rows[1], rows[2] = rows[2], rows[1]
		end, function(built)
			local found = {}
			for _, row in ipairs(row_children(built)) do
				local label = row.title or row.label
				if label == "menu.shortcuts.title" or label == "menu.tapholds.show_login_items_steps" then
					found[#found + 1] = label
				end
			end
			helpers.assert_eq(found, { "menu.tapholds.show_login_items_steps", "menu.shortcuts.title" })
			local label = assert(find_descendant(built, "menu.shortcuts.title"))
			helpers.assert_true(label.disabled)
			helpers.assert_nil(row_action(label), "changed caption retains inert-label policy")
			helpers.assert_type(row_action(find_descendant(built, "menu.tapholds.show_login_items_steps")), "function")
		end)
	end)

	helpers.it("actual steps platform hiding preserves status and Login Items owner (tap-hold-guidance)", function()
		with_guidance_declaration("tap_hold_guardian_approval_rows", function(rows)
			rows[2].platforms = { "ahk", "linux" }
		end, function(built, opened)
			helpers.assert_nil(find_descendant(built, "menu.tapholds.show_login_items_steps"))
			helpers.assert_true(find_descendant(built, "menu.tapholds.guardian_requires_approval").disabled)
			helpers.assert_true(row_action(find_descendant(built, "menu.tapholds.open_login_items"))())
			helpers.assert_eq(opened.open_guardian_settings, 1)
		end)
	end)

	helpers.it("missing or failed native admission never fabricates guidance actions (tap-hold-guidance)", function()
		for _, configure in ipairs({
			function(remap) remap.guardian_state = nil end,
			function(remap) remap.guardian_state = function() error("controlled status refusal") end end,
			function(remap) remap.guardian_state = function() return "ready" end end,
		}) do
			local built = build_menu("pending", configure)
			helpers.assert_nil(find_descendant(built, "menu.tapholds.open_login_items"))
			helpers.assert_nil(find_descendant(built, "menu.tapholds.show_login_items_steps"))
		end
		local built = build_menu("pending", function(remap)
			remap.get_tap_holds_enabled = function() return true end
			remap.guardian_state = function() return "requires_approval" end
			remap.open_guardian_settings = nil
		end)
		helpers.assert_not_nil(find_descendant(built, "menu.tapholds.guardian_requires_approval"))
		helpers.assert_not_nil(find_descendant(built, "menu.tapholds.show_login_items_steps"))
		helpers.assert_nil(find_descendant(built, "menu.tapholds.open_login_items"), "status survives absent native opener")
		for _, value in ipairs({ false, "unclassified" }) do
			built = build_menu("pending", function(remap) remap.legacy_rule_conflicts = function() return value end end)
			helpers.assert_nil(find_descendant(built, "menu.tapholds.legacy_rules_pending"))
		end
		built = build_menu("pending", function(remap) remap.legacy_rule_conflicts = function() error("controlled read refusal") end end)
		helpers.assert_nil(find_descendant(built, "menu.tapholds.legacy_rules_pending"))
	end)

	for _, case in ipairs({
		{ name = "steps", module = "ui.permission_dialog.login_items_guide", method = "reopen",
			label = "menu.tapholds.show_login_items_steps" },
		{ name = "legacy", module = "ui.legacy_rules_cleanup", method = "open",
			label = "menu.tapholds.legacy_rules_pending" },
	}) do
		for _, receipt in ipairs({ { name = "false", value = false }, { name = "nil" },
			{ name = "truthy", value = "accepted" }, { name = "throw", throws = true } }) do
			helpers.it("retains " .. case.name .. " native " .. receipt.name .. " refusal and retry (tap-hold-guidance)", function()
				local saved = package.loaded[case.module]
				local calls, accepted = {}, false
				package.loaded[case.module] = { [case.method] = function(remap)
					calls[#calls + 1] = remap
					if accepted then return true end
					if receipt.throws then error("controlled native action refusal") end
					return receipt.value
				end }
				local ok, err = pcall(function()
					local built, observations, ignored
					if case.name == "steps" then built, ignored, observations = build_guardian_menu("requires_approval")
					else built, observations = build_menu("pending", function(remap)
						remap.legacy_rule_conflicts = function() return { count = 25 } end
					end) end
					local callback = assert(row_action(find_descendant(built, case.label)))
					helpers.assert_eq(#calls, 0)
					helpers.assert_eq(callback(), false, "only literal native true is success")
					helpers.assert_eq(#calls, 1)
					accepted = true
					helpers.assert_eq(callback(), true, "same retained native capability retries")
					helpers.assert_eq(#calls, 2)
					helpers.assert_true(calls[1] == calls[2], "native facade identity stays attached")
					helpers.assert_eq(observations.refreshes, 0, "guidance actions do not acknowledge settings mutation")
				end)
				package.loaded[case.module] = saved
				if not ok then error(err, 0) end
			end)
		end
	end
end)

helpers.describe("shared Tap-Hold guidance independent locale/platform projection", function()
	helpers.it("preserves all six captions and inert/action policy in all21 languages (tap-hold-guidance)", function()
		local Json = require("json")
		local function read(relative)
			local file = assert(io.open(helpers.shared(relative), "r"))
			local value = Json.decode(file:read("*a")); file:close(); return value
		end
		local corpus, locales = read("tests/corpus/menus/tap_hold_guidance.json"), read("data/locale_order.json").order
		helpers.assert_eq(#locales, 21)
		for _, code in ipairs(locales) do
			local strings = read("data/locales/" .. code .. ".json")
			for _, platform in ipairs({ "ahk", "hs", "linux" }) do
				local renderer = assert(require("menu.renderer").new({ platform = platform,
					manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
					json_decode = Json.decode, i18n = { get = function(key) return assert(strings[key]) end,
						section = function(key) return assert(strings[key]) end },
					logger = { error = function() end, warn = function() end, debug = function() end } }))
				for section, expected in pairs(corpus.declarations) do
					local calls = {}
					local rows = assert(renderer.template_rows(section, {
						tap_hold_login_items_steps = function() calls[#calls + 1] = "tap_hold_login_items_steps"; return true end,
						tap_hold_login_items_open = function() calls[#calls + 1] = "tap_hold_login_items_open"; return true end,
						tap_hold_legacy_rules_cleanup = function() calls[#calls + 1] = "tap_hold_legacy_rules_cleanup"; return true end,
					}))
					helpers.assert_eq(#rows, platform == "hs" and #expected or 0, code .. ": " .. platform .. ": " .. section)
					helpers.assert_eq(#calls, 0)
					for index, row in ipairs(rows) do
						local descriptor = expected[index]
						helpers.assert_eq(row.label, strings[descriptor.i18n])
						helpers.assert_true(row.label ~= descriptor.i18n and row.label ~= "", "real translated caption")
						if descriptor.type == "label" then
							helpers.assert_true(row.disabled)
							helpers.assert_nil(row.action)
						else
							helpers.assert_true(row.action())
							helpers.assert_eq(calls[#calls], descriptor.id, "declared caption retains native command identity")
						end
					end
				end
			end
		end
	end)
end)

helpers.describe("declared guidance refuses missing native capability", function()
	helpers.it("actual approval fragment cannot fabricate a changed command owner (tap-hold-guidance)", function()
		with_guidance_declaration("tap_hold_guardian_approval_rows", function(rows)
			rows[2].id = "unowned_guidance"
		end, function(built, opened)
			helpers.assert_nil(find_descendant(built, "menu.tapholds.guardian_requires_approval"), "broken fragment is refused together")
			helpers.assert_nil(find_descendant(built, "menu.tapholds.show_login_items_steps"))
			helpers.assert_nil(find_descendant(built, "menu.tapholds.open_login_items"))
			helpers.assert_eq(opened, { open_guardian_settings = 0, open_login_items = 0 })
		end)
	end)
end)
