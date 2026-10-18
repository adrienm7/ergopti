--- tests/unit/ui/menu/keyboard_layout/test_menu_keyboard_layout_reaches_tray_install_state.lua

--- ==============================================================================
--- MODULE: Regression — the Keyboard layout submenu reaches the tray populated
--- DESCRIPTION:
--- The tray root is rendered as provider DATA: a component row hands over
--- `items` (rows to materialise) or `submenu` (a tree already materialised).
--- menu_keyboard_layout returned the rows ManifestMenu.build had ALREADY turned
--- into `title`/`fn` rows under `items`, so the tray renderer dropped every one
--- of them and the submenu opened empty on the real menu bar.
---
--- The same builder also asked the renderer for the pause/resume pickers before
--- it had collected them, so `layout_switching` always rendered nothing.
---
--- Both cases go through the exact render call Builder.generate makes.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.keyboard_layout.menu_keyboard_layout_reaches_tray_fixture"] = nil
local Fixture = require("tests.support.ui.menu.keyboard_layout.menu_keyboard_layout_reaches_tray_fixture")
local switch_row = Fixture.switch_row
local with_switch_frame = Fixture.with_switch_frame





helpers.describe("Layout owns install-state choices, bundle truth and every frozen original caption", function()
	for _, state in ipairs({"fresh", "older", "current"}) do
		helpers.it("retains system/user/status order for " .. state .. " actual native installation state", function()
			local Json, Paths = require("json"), require("infra.paths")
			local file = assert(io.open(Paths.shared("data/locales/en.json"), "rb"))
			local labels = assert(Json.decode(assert(file:read("*a")))); assert(file:close())
			with_switch_frame(function(build, fixture)
				fixture.latest = "Ergopti_v2.2.2.bundle"
				if state ~= "fresh" then
					local version = state == "older" and {2, 2, 1} or {2, 2, 2}
					fixture.system = {name = "Ergopti.bundle", version = version}
					fixture.user = {name = "Ergopti.bundle", version = version}
				end
				if state == "current" then fixture.variants = {{name = "Ergopti_v2_2_2_plus", tis_id = "stable.plus", keylayout = "/actual/plus.keylayout"}} end
				local rows = assert(build())
				local expected = {
					fresh = {"🔐 Install Ergopti (system) v2.2.2", "📥 Install Ergopti (user) v2.2.2", "Install the bundle first"},
					older = {"Update Ergopti (system) v2.2.1 → v2.2.2", "Update Ergopti (user) v2.2.1 → v2.2.2", "Install the bundle first"},
					current = {"Ergopti (system) v2.2.2 — up to date ✅", "Ergopti (user) v2.2.2 — up to date ✅", "Add Ergopti v2.2.2 to input sources…"},
				}
				local index
				for i, row in ipairs(rows) do if row.title == expected[state][1] then index = i end end
				helpers.assert_not_nil(index)
				for offset, caption in ipairs(expected[state]) do helpers.assert_eq(rows[index + offset - 1].title, caption) end
				helpers.assert_eq(rows[index].disabled, state == "current" and true or nil)
				helpers.assert_eq(rows[index + 1].disabled, state == "current" and true or nil)
				helpers.assert_eq(fixture.effects, 0)
			end, labels)
		end)
	end
	for _, state in ipairs({"all_active", "legacy_installed", "legacy_missing", "variants", "absent"}) do
		helpers.it("publishes only the genuine " .. state .. " bundle status family", function()
			local Json, Paths = require("json"), require("infra.paths")
			local file = assert(io.open(Paths.shared("data/locales/en.json"), "rb"))
			local labels = assert(Json.decode(assert(file:read("*a")))); assert(file:close())
			with_switch_frame(function(build, fixture)
				fixture.latest = "Ergopti_v2.2.2.bundle"
				fixture.records = {{id = "French", name = "French", selected = false}}
				if state ~= "legacy_missing" and state ~= "absent" then
					fixture.system = {name = "Ergopti_v2.2.2.bundle", version = {2, 2, 2}}
					fixture.variants = {{name = "Ergopti_v2_2_2_plus", tis_id = "stable.plus", keylayout = "/actual/plus.keylayout"}}
				end
				if state == "all_active" then
					fixture.records = {{id = "Ergopti_v2_2_2_plus", name = "Ergopti+", selected = true}}
					fixture.mapping = {Ergopti_v2_2_2_plus = "stable.plus"}
				elseif state == "legacy_installed" or state == "legacy_missing" then
					fixture.records = {{id = "Ergopti_v2_2_1_plus", name = "Ergopti+", selected = false}}
				end
				local expected = {all_active = "All Ergopti variants active v2.2.2 ✅", legacy_installed = "Upgrade active list v2.2.1 → v2.2.2",
					legacy_missing = "Upgrade active list to v2.2.2 (install v2.2.2 first)", variants = "Add Ergopti v2.2.2 to input sources…", absent = "Install the bundle first"}
				local row = switch_row(assert(build()), expected[state])
				helpers.assert_not_nil(row)
				if state == "legacy_installed" then helpers.assert_true(type(row.fn) == "function")
				elseif state == "variants" then
					helpers.assert_eq(#row.menu, 1)
					helpers.assert_eq(row.menu[1].title, "Ergopti+ v2.2.2")
					helpers.assert_true(type(row.menu[1].fn) == "function")
				else helpers.assert_eq(row.disabled, true) end
				helpers.assert_eq(fixture.effects, 0)
			end, labels)
		end)
	end
	for _, language in ipairs({"da", "de", "en", "es", "fr", "it", "nl", "no", "pl", "pt", "sv", "tr", "cs", "ar", "he", "hi", "uk", "ru", "zh", "ja", "ko"}) do
		helpers.it("retains the independently frozen complete original caption family in " .. language, function()
			local Json, Paths = require("json"), require("infra.paths")
			local function load(relative)
				local file = assert(io.open(Paths.shared(relative), "rb"))
				local value = assert(Json.decode(assert(file:read("*a")))); assert(file:close()); return value
			end
			local expected = load("tests/corpus/menus/layout_complete_captions.json")[language]
			with_switch_frame(function(_, _, binding)
				local getters = {
					layout_install_scope = function() return "scope" end,
					layout_install_emoji = function() return "🔐" end,
					layout_install_latest = function() return "2.2.2" end,
					layout_install_old = function() return "2.2.1" end,
					layout_bundle_version = function() return "2.2.2" end,
					layout_bundle_old_version = function() return "2.2.1" end,
					layout_variant_label = function() return "Independent Variant" end,
				}
				local commands = {layout_install = function() return false end, layout_upgrade_list = function() return false end, layout_enable_variant = function() return false end}
				for _, case in ipairs({{"layout_bundle_installed", "installed"}, {"layout_bundle_install", "install"}, {"layout_bundle_update", "update"},
					{"layout_bundle_in_list", "in_list"}, {"layout_bundle_update_install_first", "update_install_first"}, {"layout_bundle_upgrade", "update_list"},
					{"layout_bundle_upgrade_to", "update_list_to"}, {"layout_bundle_variant_added", "already_added"}, {"layout_bundle_variant_add", "native_variant"},
					{"layout_bundle_variant_parent", "add_to_list"}, {"layout_bundle_install_first", "install_first"}, {"layout_native_parent", "parent"}}) do
					local rows = assert(binding.template_rows(case[1], commands, getters, {layout_variant_choices = {}, layout_parent_content = {}}))
					helpers.assert_eq(#rows, 1)
					helpers.assert_eq(rows[1].label, expected[case[2]])
				end
			end, load("data/locales/" .. language .. ".json"))
		end)
	end
end)

helpers.describe("Layout native choices retain data identity and declared state", function()
	helpers.it("retains custom registry record spelling, check and native selector without performing selection", function()
		with_switch_frame(function(build, fixture)
			fixture.custom = {layouts = {{id = "private.layout", name = "Custom 100%s && 🦀"}}, active = "private.layout"}
			local row = switch_row(assert(build()), "Custom 100%s && 🦀")
			helpers.assert_not_nil(row)
			helpers.assert_eq(row.checked, true)
			helpers.assert_nil(row.disabled)
			helpers.assert_true(type(row.fn) == "function")
			helpers.assert_eq(fixture.effects, 0)
		end)
	end)
	helpers.it("retains added and available variants in actual installed-bundle order", function()
		local Json, Paths = require("json"), require("infra.paths")
		local file = assert(io.open(Paths.shared("data/locales/en.json"), "rb"))
		local labels = assert(Json.decode(assert(file:read("*a")))); assert(file:close())
		with_switch_frame(function(build, fixture)
			fixture.latest = "Ergopti_v2.2.2.bundle"
			fixture.system = {name = "Ergopti_v2.2.2.bundle", version = {2, 2, 2}}
			fixture.variants = {{name = "Ergopti_v2_2_2", tis_id = "stable.base", keylayout = "/actual/base.keylayout"},
				{name = "Ergopti_v2_2_2_plus", tis_id = "stable.plus", keylayout = "/actual/plus.keylayout"}}
			fixture.records = {{id = "Ergopti_v2_2_2", name = "Ergopti", selected = true}}
			fixture.mapping = {Ergopti_v2_2_2 = "stable.base"}
			local parent = switch_row(assert(build()), "Add Ergopti v2.2.2 to input sources…")
			helpers.assert_not_nil(parent)
			helpers.assert_eq(#parent.menu, 2)
			helpers.assert_eq(parent.menu[1].title, "✅ Ergopti v2.2.2 — already added")
			helpers.assert_eq(parent.menu[1].disabled, true)
			helpers.assert_eq(parent.menu[2].title, "Ergopti+ v2.2.2")
			helpers.assert_true(type(parent.menu[2].fn) == "function")
			helpers.assert_eq(fixture.effects, 0)
		end, labels)
	end)
end)

helpers.describe("Layout installation state remains native per scope", function()
	helpers.it("does not borrow the user installation when the system scope is absent", function()
		local Json, Paths = require("json"), require("infra.paths")
		local file = assert(io.open(Paths.shared("data/locales/en.json"), "rb"))
		local labels = assert(Json.decode(assert(file:read("*a")))); assert(file:close())
		with_switch_frame(function(build, fixture)
			fixture.latest = "Ergopti_v2.2.2.bundle"
			fixture.user = {name = "Ergopti_v2.2.2.bundle", version = {2, 2, 2}}
			fixture.variants = {{name = "Ergopti_v2_2_2_plus", tis_id = "stable.plus", keylayout = "/actual/plus.keylayout"}}
			local rows = assert(build())
			local index
			for i, row in ipairs(rows) do if row.title == "🔐 Install Ergopti (system) v2.2.2" then index = i end end
			helpers.assert_not_nil(index)
			helpers.assert_true(type(rows[index].fn) == "function")
			helpers.assert_eq(rows[index + 1].title, "Ergopti (user) v2.2.2 — up to date ✅")
			helpers.assert_eq(rows[index + 1].disabled, true)
			helpers.assert_eq(fixture.effects, 0)
		end, labels)
	end)
end)
