--- tests/unit/ui/menu/shortcuts/test_tap_hold_menu_native_per_key.lua

--- ==============================================================================
--- MODULE: The Linux Tap-Holds Tray Menu
--- DESCRIPTION:
--- The menu Windows has: the feature switch, reset and disable-all, and one row
--- per key with its tap picker, hold picker and delay. Before, this driver had
--- a « Kanata » submenu whose tap prompt took free text that broke kanata's
--- whole configuration, whose hold rows could not clear a default hold, and
--- which started a process the daemon never supervised.
--- ==============================================================================

package.loaded["tests.support.ui.menu.shortcuts.tap_hold_menu_fixture"] = nil
local Fixture = require("tests.support.ui.menu.shortcuts.tap_hold_menu_fixture")
local helpers, WRITER, build, restore, key_rows, find =
	Fixture.helpers, Fixture.WRITER, Fixture.build, Fixture.restore, Fixture.key_rows, Fixture.find




helpers.describe("native per-key delay acknowledgement", function()
	for _, receipt in ipairs({ { name = "false", value = false }, { name = "nil" },
		{ name = "truthy", value = "accepted" }, { name = "throw", throws = true } }) do
		helpers.it("refuses " .. receipt.name .. " and retries the retained native owner (tap-hold-key-delay)", function()
			local section, Manager = build({}, {})
			local TextPrompt = require("ui.text_prompt")
			local original_ask, original_execute = TextPrompt.ask, os.execute
			local i18n = require("infra.i18n")
			local calls, notices = {}, 0
			local current = receipt
			local ok, err = pcall(function()
				TextPrompt.ask = function() return "375.5" end
				os.execute = function(command)
					if command:find("zenity --error", 1, true) then notices = notices + 1; return 1 end
					return original_execute(command)
				end
				package.loaded[WRITER].set_threshold = function(key, seconds)
					calls[#calls + 1] = { key, seconds }
					if current.throws then error("controlled native threshold refusal") end
					return current.value
				end
				local key = assert(find(key_rows(section), i18n.get("tap_hold.group.left_shift")))
				local callback = key.menu[5].menu[1].fn
				helpers.assert_eq(callback(), false)
				helpers.assert_eq(calls, { { "left_shift", 0.376 } })
				helpers.assert_eq(notices, 1, "the existing native failure notification remains visible")
				current = { value = true }
				helpers.assert_eq(callback(), true)
				helpers.assert_eq(calls, { { "left_shift", 0.376 }, { "left_shift", 0.376 } })
				helpers.assert_eq(notices, 1, "accepted retry adds no false failure notification")
			end)
			TextPrompt.ask, os.execute = original_ask, original_execute
			restore(Manager)
			if not ok then error(err, 0) end
		end)
	end
	for _, value in ipairs({ "0.49", "0", "-1", "1e309", "nan" }) do
		helpers.it("refuses invalid " .. value .. " before the native threshold writer (tap-hold-key-delay)", function()
			local calls = {}
			local section, Manager = build(calls, {})
			local TextPrompt = require("ui.text_prompt")
			local original_ask, original_execute = TextPrompt.ask, os.execute
			local ok, err = pcall(function()
				TextPrompt.ask = function() return value end
				os.execute = function(command)
					if command:find("zenity --error", 1, true) then return 1 end
					return original_execute(command)
				end
				local key = assert(find(key_rows(section), require("infra.i18n").get("tap_hold.group.left_shift")))
				helpers.assert_eq(key.menu[5].menu[1].fn(), false)
				helpers.assert_eq(#calls, 0, "invalid input reaches no mutation owner")
			end)
			TextPrompt.ask, os.execute = original_ask, original_execute
			restore(Manager)
			if not ok then error(err, 0) end
		end)
	end
end)




helpers.describe("inert existing-provider status data", function()
	local function status_definition(Menu)
		for _, item in ipairs(Menu.get_array("llm_menu")) do
			if item.id == "llm_backend" then return item.status_rows.unavailable end
		end
		error("Canonical backend status declaration is missing")
	end
	local function assert_inert_rows(Menu, Mutate)
		local definition = status_definition(Menu)
		helpers.assert_eq(#definition, 3)
		local header, unavailable = definition[2], definition[3]
		local old_caption = unavailable.i18n
		local ok, err = pcall(function()
			if Mutate then
				unavailable.i18n = "menu.llm.local_servers.rescan"
				definition[2], definition[3] = unavailable, header
			end
			local rows = Menu.status_rows("llm_menu", "llm_backend", "unavailable")
			helpers.assert_type(rows, "table")
			helpers.assert_eq(#rows, 3)
			helpers.assert_true(rows[1].separator)
			local tr = require("infra.i18n").get
			helpers.assert_eq(rows[2].label, tr(Mutate and "menu.llm.local_servers.rescan" or "menu.llm.local_servers.header"))
			helpers.assert_eq(rows[3].label, tr(Mutate and "menu.llm.local_servers.header" or "menu.llm.unavailable"))
			for index = 2, 3 do
				helpers.assert_eq(rows[index].disabled, true)
				helpers.assert_nil(rows[index].action)
				helpers.assert_nil(rows[index].items)
				helpers.assert_nil(rows[index].submenu)
			end
		end)
		definition[2], definition[3] = header, unavailable
		unavailable.i18n = old_caption
		if not ok then error(err, 0) end
	end

	helpers.it("returns actual canonical inactive data without command owners", function()
		assert_inert_rows(require("infra.manifest_menu"), false)
	end)
	helpers.it("reads actual canonical caption and order mutations", function()
		assert_inert_rows(require("infra.manifest_menu"), true)
	end)
	helpers.it("refuses a malformed actual header without partial template data", function()
		local Menu = require("infra.manifest_menu")
		local item = status_definition(Menu)[3]
		local saved = item.i18n
		item.i18n = ""
		local ok, err = pcall(function()
			helpers.assert_nil(Menu.status_rows("llm_menu", "llm_backend", "unavailable"))
		end)
		item.i18n = saved
		if not ok then error(err, 0) end
	end)
end)

