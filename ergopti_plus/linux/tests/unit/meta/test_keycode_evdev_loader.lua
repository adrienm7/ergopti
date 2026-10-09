--- linux/tests/unit/meta/test_keycode_evdev_loader.lua

local helpers = require("tests.helpers")

helpers.describe("_shared/lua/keycodes/evdev.lua", function()
	helpers.it("module loads without error", function()
		local ok, mod = pcall(require, "keycodes.evdev")
		helpers.assert_true(ok, "require('keycodes.evdev') should succeed")
		helpers.assert_true(type(mod) == "table", "should return a table")
		helpers.assert_true(type(mod.load) == "function", "should expose load()")
	end)

	local evdev = require("keycodes.evdev")

	helpers.it("load returns nil+error on missing json_decode", function()
		local data, err = evdev.load(nil)
		helpers.assert_true(data == nil, "should return nil")
		helpers.assert_true(type(err) == "string", "should return error message")
	end)

	helpers.it("load succeeds with _shared/lua/json.lua decoder", function()
		-- Use the project's own pure-Lua JSON decoder
		local json = require("json")
		local ok, data = pcall(evdev.load, json.decode)
		helpers.assert_true(ok, "load should not error")
		if ok then
			helpers.assert_true(type(data) == "table", "should return a table")
		end
	end)

	helpers.it("loaded data has qwerty and azerty layouts", function()
		local json = require("json")
		local data, err = evdev.load(json.decode)
		helpers.assert_true(data ~= nil, "load should succeed")
		if data then
			helpers.assert_true(type(data.qwerty) == "table", "has qwerty layout")
			helpers.assert_true(type(data.azerty) == "table", "has azerty layout")
		end
	end)

	helpers.it("each layout has unshifted and shifted maps", function()
		local json = require("json")
		local data, err = evdev.load(json.decode)
		if data and data.qwerty then
			helpers.assert_true(type(data.qwerty.unshifted) == "table", "qwerty.unshifted is table")
			helpers.assert_true(type(data.qwerty.shifted) == "table", "qwerty.shifted is table")
		end
	end)

	helpers.it("keycode maps use integer keys", function()
		local json = require("json")
		local data, err = evdev.load(json.decode)
		if data and data.qwerty and data.qwerty.unshifted then
			local u = data.qwerty.unshifted
			-- KEY_A = 30 should map to 'a'
			helpers.assert_eq(u[30], "a", "KEY_A (30) → 'a'")
			-- KEY_1 = 2 should map to '1'
			helpers.assert_eq(u[2], "1", "KEY_1 (2) → '1'")
		end
	end)

	helpers.it("azerty layout differs from qwerty (KEY_A position)", function()
		local json = require("json")
		local data, err = evdev.load(json.decode)
		if data and data.azerty and data.qwerty then
			local a_qwerty = data.qwerty.unshifted[30] or ""
			local a_azerty = data.azerty.unshifted[30] or ""
			helpers.assert_eq(a_qwerty, "a", "qwerty KEY_A = 'a'")
			helpers.assert_eq(a_azerty, "q", "azerty KEY_A = 'q'")
		end
	end)
end)
