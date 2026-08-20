--- tests/unit/modules/hotstrings/test_preview_candidates.lua

--- ==============================================================================
--- MODULE: What the Preview Bubble Is Given
--- DESCRIPTION:
--- The engine's candidate enumerator, and the two questions the preview asks
--- about each row: would this one fire, and was it refused.
---
--- WHY THE ENUMERATOR IS SEPARATE FROM best_match_at:
--- `best_match_at` returns on the first survivor, which is right for the hot
--- path and useless for a preview: the bubble exists to show the losers too. A
--- candidate that will not fire is the answer to "why did nothing happen", and
--- hiding it deletes the answer.
---
--- THE BUG THIS CLOSES:
--- `ui/tooltip/preview.lua` was complete — toggles, accent resolution, row
--- building, renderer call — and `M.show` had no caller anywhere in the driver.
--- The whole preview surface was inert on every desktop and in every
--- configuration, which also made the four preview toggles govern nothing. There
--- was no enumerator to call it with, and that is what this adds.
---
--- WHY NOT ASSERT THE BUBBLE ITSELF:
--- Drawing needs lgi, a display server and a compositor. What is decidable here
--- is which candidates the engine offers and how each is labelled, and that is
--- the half that was missing.
--- ==============================================================================

local helpers = require("tests.helpers")

local Engine = helpers.load_module("hotstring_engine")

--- An engine loaded with the given mappings.
--- @param mappings table
--- @return table
local function engine_with(mappings)
	local engine = Engine.new()
	engine:load_mappings(mappings)
	return engine
end

--- Types a whole string into an engine.
--- @param engine table
--- @param text string
local function type_text(engine, text)
	for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		engine:on_char(char, { is_terminator = false, terminator_consumed = false })
	end
end




-- =================================================================
-- =================================================================
-- ======= 1/ The losers are offered too ===========================
-- =================================================================
-- =================================================================

helpers.describe("preview candidates: what the bubble is given", function()

	helpers.it("returns every mapping the engine considered, not only the winner", function()
		local engine = engine_with({
			{ trigger = "btw", replacement = "by the way",    auto_expand = true },
			{ trigger = "tw",  replacement = "the way",       auto_expand = true },
			{ trigger = "w",   replacement = "with",          auto_expand = true },
		})
		type_text(engine, "btw")

		local candidates = engine:candidates()
		helpers.assert_true(#candidates >= 2,
			"best_match_at returns the first survivor by design; the preview needs the "
				.. "rest, because a candidate that will not fire is the answer to "
				.. "\"why did nothing happen\"")
	end)

	helpers.it("marks exactly one candidate as the one that would fire", function()
		local engine = engine_with({
			{ trigger = "btw", replacement = "by the way", auto_expand = true },
			{ trigger = "tw",  replacement = "the way",    auto_expand = true },
		})
		type_text(engine, "btw")

		local firing = 0
		for _, candidate in ipairs(engine:candidates()) do
			if candidate.fires then firing = firing + 1 end
		end
		helpers.assert_eq(firing, 1,
			"two rows both claiming they are about to fire is a bubble that lies about "
				.. "which one wins")
	end)

	helpers.it("carries the group AND the section of each candidate", function()
		local engine = engine_with({
			{ trigger = "btw", replacement = "by the way", auto_expand = true,
				group = "rolls", section = "common" },
		})
		type_text(engine, "btw")

		local candidate = engine:candidates()[1]
		helpers.assert_true(candidate ~= nil, "the mapping must be offered at all")
		helpers.assert_eq(candidate.group, "rolls", "the tint and the show_tooltip gate key off it")
		helpers.assert_eq(candidate.section, "common",
			"and the SECTION too — the settings window keys its per-section \"hide the "
				.. "bubble\" override by exactly this name, so resolving without it "
				.. "consults only the category and keeps drawing for a section the user "
				.. "just silenced")
	end)

	helpers.it("honours the limit rather than walking a whole bucket", function()
		local mappings = {}
		for index = 1, 40 do
			mappings[#mappings + 1] = {
				trigger = string.rep("a", index) .. "z", replacement = "x" .. index, auto_expand = true,
			}
		end
		local engine = engine_with(mappings)
		type_text(engine, string.rep("a", 40) .. "z")

		helpers.assert_true(#engine:candidates(5) <= 5,
			"the enumeration runs on every keystroke and a bucket for a common tail "
				.. "character holds hundreds of mappings")
	end)

	helpers.it("offers nothing when the buffer matches nothing", function()
		local engine = engine_with({
			{ trigger = "btw", replacement = "by the way", auto_expand = true },
		})
		type_text(engine, "qqq")
		helpers.assert_eq(#engine:candidates(), 0,
			"an empty list is what tells the caller to hide the bubble")
	end)

end)
