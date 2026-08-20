--- tests/unit/ui/menu/test_hotstring_mutation_commit_gate.lua

--- ==============================================================================
--- MODULE: Hotstring Menu Mutation Commit Gate
--- DESCRIPTION:
--- Clicks callbacks that are actually reachable below rendered submenu parents.
--- A false, nil, or throwing registry mutation must not publish menu state,
--- persistence, success notifications, or a rebuilt checkmark.
--- ==============================================================================

local helpers = require("tests.helpers")

local FAILURE_OUTCOMES = { "false", "nil", "throw" }


--- Finds one reachable provider action recursively by exact label.
--- @param rows table|nil
--- @param label string
--- @return function|nil
local function find_action(rows, label)
	for _, row in ipairs(type(rows) == "table" and rows or {}) do
		if row.label == label and type(row.action) == "function" then return row.action end
		local nested = find_action(row.items, label)
		if nested then return nested end
	end
	return nil
end


--- Installs an inspectable notification port and loads the real provider.
--- @param calls table
--- @return table hotstrings
--- @return any previous_notifications
local function load_provider(calls)
	local previous_notifications = package.loaded["infra.notifications"]
	package.loaded["infra.notifications"] = {
		notify = function(_title, _body, kind)
			helpers.assert_eq(kind, "error")
			calls.error_notices = calls.error_notices + 1
		end,
	}
	local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
	return hotstrings, previous_notifications
end


--- Returns one exact-return mutation double.
--- @param outcome string
--- @param calls table
--- @return function
local function mutation_for(outcome, calls)
	return function()
		calls.mutations = calls.mutations + 1
		if outcome == "throw" then error("injected registry mutation failure") end
		if outcome == "false" then return false end
		if outcome == "nil" then return nil end
		return true
	end
end


--- Builds and clicks the reachable category-gate row under a submenu parent.
--- @param outcome string
--- @return table calls
--- @return table state
local function click_category_gate(outcome)
	local calls = {
		mutations = 0,
		saves = 0,
		success_notices = 0,
		error_notices = 0,
		updates = 0,
	}
	local hotstrings, previous_notifications = load_provider(calls)
	local state = {
		hotstrings = { alpha = true },
		keymap = true,
		sections_order_overrides = {},
	}
	local ctx = {
		paused = false,
		hotfiles = { "alpha.toml" },
		get_group_name = function() return "alpha" end,
		applyTriggerChar = function(value) return value end,
		state = state,
		keymap = {
			is_group_enabled = function() return true end,
			get_meta_description = function() return "Alpha" end,
			get_sections = function() return { { name = "one", description = "One" } } end,
			is_section_enabled = function() return true end,
			disable_group = mutation_for(outcome, calls),
		},
		save_prefs = function() calls.saves = calls.saves + 1; return true end,
		notify_feature = function() calls.success_notices = calls.success_notices + 1 end,
		updateMenu = function() calls.updates = calls.updates + 1 end,
	}

	local rows = hotstrings.build_groups(ctx, nil, { group_counts = {} })
	local gate = rows[1] and rows[1].items and rows[1].items[1]
	helpers.assert_eq(type(gate and gate.action), "function",
		"the category gate below the submenu parent must be user-reachable")
	local ok, err = pcall(gate.action)
	package.loaded["infra.notifications"] = previous_notifications
	package.loaded["ui.menu.keymap_lifecycle"] = nil
	helpers.assert_true(ok, "a reachable menu callback must contain mutation throws: " .. tostring(err))
	return calls, state
end


helpers.describe("hotstring menu mutations: publish only exact commitments", function()
	helpers.it("rejects false, nil, and throw from the reachable category gate", function()
		for _, outcome in ipairs(FAILURE_OUTCOMES) do
			local calls, state = click_category_gate(outcome)
			helpers.assert_eq(calls.mutations, 1, outcome .. " must attempt one registry mutation")
			helpers.assert_eq(state.hotstrings.alpha, true,
				outcome .. " must preserve the last committed menu state")
			helpers.assert_eq(calls.saves, 0, outcome .. " must not persist a lie")
			helpers.assert_eq(calls.success_notices, 0, outcome .. " must not announce success")
			helpers.assert_eq(calls.updates, 0, outcome .. " must not render a false checkmark")
			helpers.assert_eq(calls.error_notices, 1, outcome .. " must surface one visible failure")
		end
	end)

	helpers.it("rejects false, nil, and throw from a reachable custom-section row", function()
		for _, outcome in ipairs(FAILURE_OUTCOMES) do
			local calls = {
				mutations = 0,
				saves = 0,
				success_notices = 0,
				error_notices = 0,
				updates = 0,
			}
			local previous_notifications = package.loaded["infra.notifications"]
			package.loaded["infra.notifications"] = {
				notify = function(_title, _body, kind)
					helpers.assert_eq(kind, "error")
					calls.error_notices = calls.error_notices + 1
				end,
			}
			local Custom = helpers.load_with_stubs("ui.menu.menu_hotstrings_custom")
			local state = {
				keymap = true,
				hotstrings = { personal = true, custom = true },
				trigger_char = "★",
				custom_editor_shortcut = false,
				custom_default_section = false,
				custom_close_on_add = false,
			}
			local ctx = {
				paused = false,
				state = state,
				hotfiles = { "personal.toml" },
				get_group_name = function() return "personal" end,
				applyTriggerChar = function(value) return value end,
				keymap = {
					is_group_enabled = function() return true end,
					is_section_enabled = function() return true end,
					get_sections = function(group)
						if group == "custom" then
							return { { name = "target", description = "TARGET_CUSTOM_SECTION" } }
						end
						return nil
					end,
					disable_section = mutation_for(outcome, calls),
				},
				hotstring_editor = { open = function() end },
				save_prefs = function() calls.saves = calls.saves + 1; return true end,
				notify_feature = function() calls.success_notices = calls.success_notices + 1 end,
				updateMenu = function() calls.updates = calls.updates + 1 end,
			}

			local built = Custom.build_custom(ctx, { group_counts = {} })
			local action = find_action(built.items, "TARGET_CUSTOM_SECTION")
			helpers.assert_eq(type(action), "function",
				"the custom section row must be reachable below the submenu parent")
			local ok, err = pcall(action)
			package.loaded["infra.notifications"] = previous_notifications
			package.loaded["ui.menu.keymap_lifecycle"] = nil
			helpers.assert_true(ok, "custom section callback must contain mutation throws: " .. tostring(err))
			helpers.assert_eq(calls.mutations, 1)
			helpers.assert_eq(calls.saves, 0)
			helpers.assert_eq(calls.success_notices, 0)
			helpers.assert_eq(calls.updates, 0)
			helpers.assert_eq(calls.error_notices, 1)
		end
	end)

	helpers.it("publishes the reachable category gate after exact true", function()
		local calls, state = click_category_gate("true")
		helpers.assert_eq(state.hotstrings.alpha, false)
		helpers.assert_eq(calls.saves, 1)
		helpers.assert_eq(calls.success_notices, 1)
		helpers.assert_eq(calls.updates, 1)
		helpers.assert_eq(calls.error_notices, 0)
	end)

	helpers.it("routes the reachable whole-tree action through one atomic registry call", function()
		local calls = {
			mutations = 0,
			legacy = 0,
			saves = 0,
			success_notices = 0,
			error_notices = 0,
			updates = 0,
		}
		local hotstrings, previous_notifications = load_provider(calls)
		local ctx = {
			paused = false,
			hotfiles = { "alpha.toml", "beta.toml" },
			get_group_name = function(path) return path:gsub("%.toml$", "") end,
			state = { hotstrings = { alpha = true, beta = true }, keymap = true },
			keymap = {
				get_sections = function(group) return { { name = group .. "_one" } } end,
				set_groups_sections_enabled = function(changes, enabled)
					calls.mutations = calls.mutations + 1
					helpers.assert_eq(#changes, 2)
					helpers.assert_eq(enabled, false)
					return false
				end,
				disable_section = function() calls.legacy = calls.legacy + 1; return false end,
			},
			save_prefs = function() calls.saves = calls.saves + 1; return true end,
			notify_feature = function() calls.success_notices = calls.success_notices + 1 end,
			updateMenu = function() calls.updates = calls.updates + 1 end,
		}

		local action = hotstrings.build_bulk_actions(ctx)[2].action
		local ok, err = pcall(action)
		package.loaded["infra.notifications"] = previous_notifications
		package.loaded["ui.menu.keymap_lifecycle"] = nil
		helpers.assert_true(ok, "whole-tree callback must contain a failed batch: " .. tostring(err))
		helpers.assert_eq(calls.mutations, 1,
			"one click must present the full plan to one registry transaction")
		helpers.assert_eq(calls.legacy, 0,
			"per-section fallbacks make an all-or-nothing contract impossible")
		helpers.assert_eq(calls.saves, 0)
		helpers.assert_eq(calls.updates, 0)
		helpers.assert_eq(calls.error_notices, 1)
	end)
end)
