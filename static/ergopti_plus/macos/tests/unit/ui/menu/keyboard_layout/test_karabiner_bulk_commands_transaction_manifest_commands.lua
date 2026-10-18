--- tests/unit/ui/menu/keyboard_layout/test_karabiner_bulk_commands_transaction_manifest_commands.lua

--- ==============================================================================
--- MODULE: Karabiner Manifest Bulk Commands Are Exact Transactions
--- DESCRIPTION:
--- Behaviorally exercises the three destructive command IDs through the real
--- shared-manifest renderer. Request acceptance never becomes a success claim;
--- only the exact terminal callback may refresh the menu and publish SUCCESS.
--- False, nil, throw, and negative-terminal paths remain visibly failed.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.keyboard_layout.karabiner_bulk_commands_transaction_fixture"] = nil
local Fixture = require("tests.support.ui.menu.keyboard_layout.karabiner_bulk_commands_transaction_fixture")
local COMMAND_CASES = Fixture.COMMAND_CASES
local CONFIRMATION = Fixture.CONFIRMATION
local PICKER_ACTION_CASES = Fixture.PICKER_ACTION_CASES
local PICKER_ROUTE_CASES = Fixture.PICKER_ROUTE_CASES
local build_guardian_menu = Fixture.build_guardian_menu
local build_menu = Fixture.build_menu
local count_logs = Fixture.count_logs
local english_text = Fixture.english_text
local find_descendant = Fixture.find_descendant
local find_item = Fixture.find_item
local find_picker_action = Fixture.find_picker_action
local row_action = Fixture.row_action





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
