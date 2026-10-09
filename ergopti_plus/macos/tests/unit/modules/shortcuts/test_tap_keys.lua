--- tests/unit/modules/shortcuts/test_tap_keys.lua

--- ==============================================================================
--- MODULE: Number-row tap keys (macOS)
--- DESCRIPTION:
--- The key left of 1 (keycode 50 on ANSI and behind Karabiner, 10 on a bare ISO
--- keyboard) and the two right of 0 (27, 24) as tap keys: the assignments over
--- the manifest defaults, the in-memory decision the eventtap asks on every
--- press, and the label each menu row shows, read from the current input source.
---
--- ROOT CAUSE ENCODED:
--- The key left of 1 was hard-wired to an instant capture and labelled "@ / #"
--- whatever the input source; the keys right of 0 could not be assigned at all.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A fresh tap_keys module over canonical in-memory TOML and a stubbed input source.
--- @param stored table|nil Canonical key -> value.
--- @param characters table Keycode -> the character the input source puts there.
--- @return table TapKeys, function restore
local function fresh(stored, characters)
	local content = stored and require("toml_codec").encode({ shortcuts = { tap_keys = stored } }) or nil
	local owned = { "adapters.storage", "infra.keycodes", "adapters.file_system",
		"infra.paths", "infra.preferences", "infra.config_paths", "modules.shortcuts.tap_keys" }
	local saved = {}
	for _, name in ipairs(owned) do saved[name] = package.loaded[name] end
	package.loaded["adapters.storage"] = nil
	package.loaded["infra.config_paths"] = { get = function() return "tap-key-test-config" end }
	package.loaded["infra.keycodes"] = {
		character_for = function(code) return characters and characters[code] or nil end,
	}
	package.loaded["infra.paths"] = { shared = function(rel) return helpers.shared(rel) end }
	package.loaded["adapters.file_system"] = {
		read_with_status = function() return content, content and "ok" or "absent" end,
		write = function() error("conditional publication required") end,
		write_if_unchanged = function(_, candidate, expected)
			if expected.content ~= content then return false end
			content = candidate; return true
		end,
		read = function(path)
			local handle = assert(io.open(path, "r"))
			local body = handle:read("*a")
			handle:close()
			return body
		end,
	}
	package.loaded["infra.preferences"], package.loaded["modules.shortcuts.tap_keys"] = nil, nil
	local TapKeys = require("modules.shortcuts.tap_keys")
	local function restore()
		for _, name in ipairs(owned) do package.loaded[name] = saved[name] end
	end
	return TapKeys, restore
end

local function is_assignable(id)
	return id == "screen_capture" or id == "send_text" or id == "send_shortcut"
end

local I18N = { get = function(key) return "<" .. key .. ">" end }

helpers.describe("macOS number-row tap keys (tap-keys)", function()
	helpers.it("an absent configuration leaves every tap key native", function()
		local TapKeys, restore = fresh()
		local ok, err = pcall(function()
			TapKeys.load(is_assignable)
			for _, code in ipairs({ 50, 10 }) do
				local action, binding = TapKeys.decide(code)
				helpers.assert_eq(action, nil, "keycode " .. code)
				helpers.assert_eq(binding, nil)
			end
			helpers.assert_eq(TapKeys.decide(27), nil, "the keys right of 0 have no default")
			helpers.assert_eq(TapKeys.decide(24), nil)
			helpers.assert_eq(TapKeys.decide(0), nil, "keycode 0 (A) is no tap key")
			helpers.assert_eq(TapKeys.has_assignments(), false)
		end)
		restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("an assignment is stored and decided, an unknown one leaves the key alone", function()
		local TapKeys, restore = fresh({ number_row_right_2 = "no_such_action" })
		local ok, err = pcall(function()
			TapKeys.load(is_assignable)
			helpers.assert_eq(TapKeys.get_action("number_row_right_2"), "none")
			helpers.assert_eq(TapKeys.set_action("number_row_right_1", "send_text", is_assignable), true)
			local action, binding = TapKeys.decide(27)
			helpers.assert_eq(action, "send_text")
			helpers.assert_eq(binding, "tap_key__number_row_right_1")
			helpers.assert_eq(TapKeys.has_assignments(), true)
			helpers.assert_eq(TapKeys.set_action("number_row_right_1", "no_such_action", is_assignable), false)
			helpers.assert_eq(TapKeys.set_action("number_row_left", "none", is_assignable), true)
			helpers.assert_eq(TapKeys.decide(50), nil, "none gives the key back to the input source")
		end)
		restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("the labels follow the current input source", function()
		local ok, err = true, nil
		for _, case in ipairs({
			{ name = "French", chars = { [50] = "@", [10] = "<", [27] = ")", [24] = "-" }, expected = "<menu.shortcuts.tap_keys.number_row_left> ) -" },
			{ name = "US", chars = { [50] = "`", [10] = "§", [27] = "-", [24] = "=" }, expected = "<menu.shortcuts.tap_keys.number_row_left> - =" },
		}) do
			local TapKeys, restore = fresh(nil, case.chars)
			ok, err = pcall(function()
				local names = {}
				for _, key in ipairs(TapKeys.keys()) do names[#names + 1] = TapKeys.display_name(key.id, I18N) end
				helpers.assert_eq(table.concat(names, " "), case.expected, case.name)
			end)
			restore()
			if not ok then break end
		end
		helpers.assert_true(ok, tostring(err))
		local TapKeys, restore = fresh(nil, {})
		ok, err = pcall(function()
			helpers.assert_eq(TapKeys.display_name("number_row_left", I18N),
				"<menu.shortcuts.tap_keys.number_row_left>", "no character: the position name")
		end)
		restore()
		helpers.assert_true(ok, tostring(err))
	end)
end)
