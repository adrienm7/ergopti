--- tests/unit/modules/llm/prediction/test_prediction_diff_budget.lua
local helpers = require("tests.helpers")
local Parser = helpers.load_with_stubs("llm.parser")

local function bounded(full, corrected)
	local instructions = 0
	debug.sethook(function()
		instructions = instructions + 10000
		if instructions > 5000000 then error("prediction exceeded instruction budget") end
	end, "", 10000)
	local ok, result = pcall(Parser.process_prediction, full, full,
		"TAIL_CORRECTED: " .. corrected .. "\nNEXT_WORDS: merci")
	debug.sethook()
	helpers.assert_true(ok, tostring(result))
	return result
end

helpers.describe("prediction diff is bounded", function()
	helpers.it("keeps a long identical word without quadratic comparison", function()
		local word = ("a"):rep(2000)
		local result = bounded(word, word)
		helpers.assert_true(result ~= nil)
		helpers.assert_eq(result.deletes, 0)
		helpers.assert_eq(result.to_type, " merci")
	end)
	helpers.it("accepts a small correction to a long word", function()
		local word = ("a"):rep(2000)
		local result = bounded(word, ("a"):rep(1999) .. "b")
		helpers.assert_true(result ~= nil)
		helpers.assert_eq(result.deletes, 1)
		helpers.assert_eq(result.to_type, "b merci")
	end)
	helpers.it("refuses an excessively expensive unrelated correction", function()
		local word = ("a"):rep(2000)
		local result = bounded(word, ("b"):rep(2000))
		helpers.assert_nil(result)
	end)
	helpers.it("refuses token alignment that exceeds the shared work limit", function()
		local result = bounded(("a "):rep(300) .. "x", ("b "):rep(300) .. "x")
		helpers.assert_nil(result)
	end)
end)
