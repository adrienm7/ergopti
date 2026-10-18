--- tests/unit/ui/menu/keyboard_layout/test_karabiner_bulk_commands_transaction_tap_hold_guidance.lua

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
local SAVED_DIALOGS = Fixture.SAVED_DIALOGS
local SAVED_PATHS = Fixture.SAVED_PATHS
local build_guardian_menu = Fixture.build_guardian_menu
local build_menu = Fixture.build_menu
local find_descendant = Fixture.find_descendant
local row_action = Fixture.row_action
local row_children = Fixture.row_children
local with_guidance_declaration = Fixture.with_guidance_declaration





package.loaded["infra.dialog_util"] = SAVED_DIALOGS
package.loaded["infra.config_paths"] = SAVED_PATHS

--- Mutates actual decoded shared metadata and always restores original rows.

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
