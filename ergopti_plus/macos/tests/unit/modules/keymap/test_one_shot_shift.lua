--- tests/unit/modules/keymap/test_one_shot_shift.lua

--- ==============================================================================
--- MODULE: One-shot Shift State Tests
--- DESCRIPTION:
--- Exercises the real shared result table, consume/keep policy, expiry, Unicode
--- title casing, and physical repeat/release ownership without posting input.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")
local Json = require("json")
local OneShot = require("modules.keymap.one_shot_shift")
local data = assert(Json.decode(SourceFile.read(helpers.shared("tap_hold/one_shot_shift.json"))))

local function armed()
	local owner = OneShot.new(data)
	owner:arm(10, 2)
	return owner
end

helpers.describe("one-shot Shift state", function()
	helpers.it("spends a fresh arm while a previous shifted key remains held", function()
		for _, control in ipairs({ "backspace", "enter", "delete", "tab", "escape" }) do
			local owner = armed()
			owner:commit(1, "shift")
			owner:arm(11, 2)
			helpers.assert_eq(owner:take(1, nil, "a", 11, "★", function() return true end), "shift-held")
			helpers.assert_eq(owner.deadline, 13, "an owned repeat must not spend the new arm")
			owner:take(2, control, "", 11, "★", function() return true end)
			helpers.assert_nil(owner.deadline, "editing controls must spend the new arm")
			owner:release(1)
			helpers.assert_nil(owner:take(3, nil, "b", 12, "★", function() return true end))
		end
	end)
	helpers.it("uses every shared special and gives the magic key priority (one-shot-policy)", function()
		for _, entry in ipairs(data.results) do
			local owner = armed()
			local kind, result = owner:take(1, nil, entry.char, 11, "★", function() error("special must not probe") end)
			helpers.assert_eq(kind, "text")
			helpers.assert_eq(result, entry.result)
			owner = armed()
			kind, result = owner:take(1, nil, entry.char, 11, entry.char, function() return false end)
			helpers.assert_eq(result, data.magic_key_result)
		end
	end)
	helpers.it("keeps modifiers, navigation and dead keys but spends editing controls (one-shot-policy)", function()
		for _, control in ipairs({ "modifier", "capslock", "left", "home", "f1" }) do
			local owner = armed()
			helpers.assert_eq(owner:take(1, control, "x", 11, "★", function() return true end), nil)
			helpers.assert_eq(owner.deadline, 12)
		end
		for _, control in ipairs({ "backspace", "enter", "delete", "tab", "escape" }) do
			local owner = armed()
			helpers.assert_eq(owner:take(1, control, "x", 11, "★", function() return true end), nil)
			helpers.assert_eq(owner.deadline, nil)
		end
		local owner = armed()
		helpers.assert_eq(owner:take(1, nil, "", 11, "★", function() return true end), nil)
		helpers.assert_eq(owner.deadline, 12)
	end)
	helpers.it("uses Unicode title casing and the live same-key Shift verdict (one-shot-policy)", function()
		for _, entry in ipairs({ { "a", "A" }, { "é", "É" }, { "ß", "Ss" }, { "я", "Я" } }) do
			local owner = armed()
			local kind, result = owner:take(1, nil, entry[1], 11, "★", function(title)
				helpers.assert_eq(title, entry[2])
				return entry[1] == "a"
			end)
			helpers.assert_eq(kind, entry[1] == "a" and "shift" or "text")
			helpers.assert_eq(result, entry[2])
		end
		local owner = armed()
		helpers.assert_eq(owner:take(1, nil, "1", 11, "★", function() error("uncased key must not probe") end), nil)
		helpers.assert_eq(owner.deadline, nil)
	end)
	helpers.it("expires on the next text key and refreshes on another tap (one-shot-policy)", function()
		local owner = armed()
		helpers.assert_eq(owner:take(1, nil, "a", 13, "★", function() return true end), nil)
		owner:arm(14, 3)
		owner:arm(16, 3)
		helpers.assert_eq(owner:take(1, nil, "a", 18, "★", function() return true end), "shift")
	end)
	helpers.it("owns repeats only after output commits and settles every release (one-shot-policy)", function()
		local owner = armed()
		helpers.assert_eq(owner:take(1, nil, " ", 11, "★", function() return false end), "text")
		helpers.assert_eq(owner:release(1), nil, "a refused emission cannot claim the key")
		owner:commit(1, "text")
		owner:disarm()
		helpers.assert_eq(owner:take(1, nil, " ", 14, "★", function() return false end), "consume")
		helpers.assert_eq(owner:release(1), "consume")
		owner:commit(2, "shift")
		helpers.assert_eq(owner:take(3, nil, "b", 14, "★", function() return false end), "shift-held")
		helpers.assert_eq(owner:release(2), "shift")
		helpers.assert_eq(owner:release(3), nil, "other keys must not extend the original Shift hold")
		helpers.assert_eq(owner:active(), false)
		owner:commit(1, "text")
		owner:reset()
		helpers.assert_eq(owner:active(), false, "a stopped tap cannot retain a future press's identity")
	end)
end)
