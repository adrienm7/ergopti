--- _shared/lua/test/incremental_steps_contract.lua

--- Replays the shared incremental step corpus against the shared step rule,
--- the one the macOS engine and the Linux tracker count through; the Windows
--- suite replays the same file through its AutoHotkey port.
return function(helpers, json, shared_root)
	local Incremental = require("gestures.incremental")

	local function read_corpus()
		local file = assert(io.open(shared_root .. "/tests/corpus/gestures/incremental_steps.json", "rb"))
		local text = file:read("*a")
		file:close()
		return json.decode(text)
	end

	helpers.describe("incremental swipes: the shared step rule", function()
		helpers.it("holds the corpus constants (incremental-step-vectors)", function()
			local corpus = read_corpus()
			helpers.assert_eq(Incremental.FIRST_STEP, corpus.first_step, "first step")
			helpers.assert_eq(Incremental.MAX_ACTIONS_PER_FRAME, corpus.max_actions_per_frame, "frame bound")
		end)

		helpers.it("counts every vector's actions (incremental-step-vectors)", function()
			local corpus = read_corpus()
			helpers.assert_true(#corpus.steps >= 15, "the corpus must hold its step vectors")
			for _, vector in ipairs(corpus.steps) do
				helpers.assert_eq(Incremental.steps(vector.distance, vector.step), vector.steps, vector.id)
			end
			helpers.assert_true(#corpus.reverse_min >= 5, "the corpus must hold its reversal vectors")
			for _, vector in ipairs(corpus.reverse_min) do
				helpers.assert_eq(Incremental.reverse_min(vector.step, vector.floor), vector.reverse_min, vector.id)
			end
		end)

		helpers.it("refuses every invalid input (incremental-step-vectors)", function()
			local corpus = read_corpus()
			helpers.assert_true(#corpus.invalid >= 3, "the corpus must hold its invalid inputs")
			for _, vector in ipairs(corpus.invalid) do
				helpers.assert_eq(pcall(Incremental.steps, vector.distance, vector.step), false, vector.id)
			end
		end)
	end)
end
