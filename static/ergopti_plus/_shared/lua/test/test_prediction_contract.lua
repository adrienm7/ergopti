--- _shared/lua/test/test_prediction_contract.lua

--- ==============================================================================
--- MODULE: Test Prediction Contract
--- DESCRIPTION:
--- Proves the behaviour of the AI menu's « Test a prediction » the macOS and Linux
--- drivers share. Each driver replays it and adds its own test that its engine
--- feeds the ports and that the answer never becomes an offer.
--- ==============================================================================

return function(helpers)
	local TestPrediction = require("llm.test_prediction")

	local function fixture()
		local fx = { shown = {}, sent = {}, logged = {}, refusal = nil, live = true }
		fx.owner = TestPrediction.new({
			text = function(key)
				return ({
					["llm.test_prediction.sample"] = "SAMPLE",
					["llm.test_prediction.running"] = "RUNNING",
					["llm.test_prediction.result"] = "RESULT {1}",
					["llm.test_prediction.failed"] = "FAILED {1}",
				})[key] or key
			end,
			refusal = function() return fx.refusal end,
			may_publish = function() return fx.live end,
			send = function(sample, on_text, on_fail, current)
				if fx.raises then error(fx.raises, 0) end
				fx.sent[#fx.sent + 1] = { sample = sample, on_text = on_text, on_fail = on_fail, current = current }
			end,
			show = function(text) fx.shown[#fx.shown + 1] = text end,
			info = function(fmt, ...) fx.logged[#fx.logged + 1] = string.format(fmt, ...) end,
			warn = function(fmt, ...) fx.logged[#fx.logged + 1] = string.format(fmt, ...) end,
		})
		fx.last = function() return fx.shown[#fx.shown] end
		return fx
	end

	helpers.describe("Test prediction", function()
	helpers.it("a refusal says why and sends nothing", function()
		local fx = fixture()
		fx.refusal = "refused.key"
		helpers.assert_eq(fx.owner.run(), false)
		helpers.assert_eq(fx.last(), "refused.key")
		helpers.assert_eq(#fx.sent, 0)
	end)

	helpers.it("the trimmed answer of the sample is shown and stays out of the log", function()
		local fx = fixture()
		helpers.assert_eq(fx.owner.run(), true)
		helpers.assert_eq(fx.last(), "RUNNING", "at once visible")
		helpers.assert_eq(fx.sent[1].sample, "SAMPLE", "on the sample, never on what was typed")
		fx.sent[1].on_text("  mardi\n")
		helpers.assert_eq(fx.last(), "RESULT mardi")
		for _, line in ipairs(fx.logged) do
			helpers.assert_eq(line:find("mardi", 1, true), nil, "the answer is not logged")
		end
	end)

	helpers.it("a long answer is cut on a character with a mark", function()
		local fx = fixture()
		fx.owner.run()
		fx.sent[1].on_text(string.rep("é", TestPrediction.EXCERPT_CHARS + 5))
		helpers.assert_eq(fx.last(), "RESULT " .. string.rep("é", TestPrediction.EXCERPT_CHARS) .. "…")
	end)

	helpers.it("a failure says why, a blank answer is one", function()
		local fx = fixture()
		fx.owner.run()
		fx.sent[1].on_fail("quota exceeded")
		helpers.assert_eq(fx.last(), "FAILED quota exceeded")
		fx.owner.run()
		fx.sent[2].on_fail({ reason = "no model" })
		helpers.assert_eq(fx.last(), "FAILED no model")
		fx.owner.run()
		fx.sent[3].on_text("   ")
		helpers.assert_eq(fx.last(), "FAILED " .. TestPrediction.EMPTY_ANSWER_REASON)
		fx.owner.run()
		fx.sent[4].on_fail(nil)
		helpers.assert_eq(fx.last(), "FAILED " .. TestPrediction.UNKNOWN_FAILURE_REASON)
		fx.raises = "refused dispatch"
		helpers.assert_eq(fx.owner.run(), false, "a refused dispatch reports")
		helpers.assert_eq(fx.last(), "FAILED refused dispatch")
	end)

	helpers.it("a newer test, a pause or the switch-off withdraws the one in flight", function()
		local fx = fixture()
		fx.owner.run()
		fx.owner.run()
		helpers.assert_eq(fx.sent[1].current(), false, "superseded")
		helpers.assert_eq(fx.sent[2].current(), true)
		fx.sent[1].on_text("late")
		helpers.assert_eq(fx.last(), "RUNNING", "a superseded answer is dropped")
		fx.live = false
		helpers.assert_eq(fx.sent[2].current(), false, "paused or off")
		fx.sent[2].on_text("late")
		fx.sent[2].on_fail("late")
		helpers.assert_eq(fx.last(), "RUNNING", "nothing after the switch-off")
	end)
	end)
end
