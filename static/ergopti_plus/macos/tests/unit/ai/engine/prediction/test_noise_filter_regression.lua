--- tests/unit/ai/engine/prediction/test_noise_filter_regression.lua

--- ==============================================================================
--- MODULE: Noise Filter Regression Tests
--- DESCRIPTION:
--- Regression tests for the is_noise_pred bug: uppercase predictions were
--- incorrectly silenced at document-start (empty buffer) or after whitespace-only
--- content because `prev_char and prev_char:match(...)` evaluates to nil — not
--- false — when prev_char is nil, making `not ends_sent` unexpectedly true.
---
--- Root cause: `prev_char and expr` short-circuits to nil (not false) in Lua
--- when prev_char is nil. The fix treats a nil prev_char as an implicit sentence
--- boundary: `(prev_char == nil) or (prev_char:match(...) ~= nil)`.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Reproduces the OLD (buggy) ends_sent formula exactly.
--- Returns nil (not false) when prev_char is nil — the core of the bug.
--- @param prev_char string|nil Last non-space character in the buffer.
--- @return any
local function old_ends_sent(prev_char)
	return prev_char and prev_char:match("[%.%!%?…:;]") ~= nil
end

--- Reproduces the FIXED ends_sent formula shipped in production.
--- Treats nil prev_char (doc-start / whitespace-only buffer) as a sentence boundary.
--- @param prev_char string|nil Last non-space character in the buffer.
--- @return boolean
local function new_ends_sent(prev_char)
	return (prev_char == nil) or (prev_char:match("[%.%!%?…:;\n]") ~= nil)
end

--- Applies only the uppercase-capital branch of is_noise_pred.
--- Returns true when the prediction would be suppressed as noise.
--- @param first_ch string First character of the candidate prediction.
--- @param ends_sent any The value returned by the ends_sent expression.
--- @return boolean
local function uppercase_is_noise(first_ch, ends_sent)
	return first_ch:match("[A-Z]") ~= nil and not ends_sent
end




-- ========================================================
-- ========================================================
-- ======= 1/ Old Formula — Bug Demonstration =============
-- ========================================================
-- ========================================================

helpers.describe("is_noise_pred old formula: demonstrates the nil-vs-false bug", function()
	helpers.it("nil prev_char yields nil — not false — from the old formula", function()
		-- `nil and expr` short-circuits to nil in Lua; `not nil` == true.
		-- This is the root cause: the uppercase gate fires when it should not.
		local result = old_ends_sent(nil)
		helpers.assert_eq(result, nil,
			"old formula must return nil (not false) for nil prev_char")
	end)

	helpers.it("nil ends_sent causes uppercase prediction to be wrongly filtered at doc-start", function()
		local ends  = old_ends_sent(nil)           -- nil
		local noise = uppercase_is_noise("B", ends) -- true because not nil == true
		helpers.assert_eq(noise, true,
			"old formula: 'Bonjour' at doc-start was incorrectly classified as noise")
	end)

	helpers.it("nil also fires after a whitespace-only buffer", function()
		-- buffer:match(".*(%S)") on whitespace returns nil — same code path
		local noise = uppercase_is_noise("M", old_ends_sent(nil))
		helpers.assert_eq(noise, true,
			"old formula: uppercase after spaces-only was incorrectly classified as noise")
	end)
end)




-- ========================================================
-- ========================================================
-- ======= 2/ Fixed Formula — Correctness Guard ===========
-- ========================================================
-- ========================================================

helpers.describe("is_noise_pred fixed formula: regression guard", function()
	helpers.it("nil prev_char yields true — doc-start is an implicit sentence boundary", function()
		helpers.assert_eq(new_ends_sent(nil), true,
			"nil prev_char must be treated as a sentence boundary in the fixed formula")
	end)

	helpers.it("uppercase prediction at doc-start is NOT noise", function()
		local noise = uppercase_is_noise("B", new_ends_sent(nil))
		helpers.assert_eq(noise, false,
			"'Bonjour' at doc-start must pass through the noise gate")
	end)

	helpers.it("uppercase prediction after whitespace-only buffer is NOT noise", function()
		-- Simulates a buffer of "   " where match(".*(%S)") returns nil
		local noise = uppercase_is_noise("M", new_ends_sent(nil))
		helpers.assert_eq(noise, false,
			"'Merci' after whitespace-only buffer must pass through the noise gate")
	end)

	helpers.it("uppercase prediction mid-sentence without sentence-end IS noise", function()
		-- "le chat mange" → prev_char = 'e' — no boundary, uppercase is suspicious
		local noise = uppercase_is_noise("V", new_ends_sent("e"))
		helpers.assert_eq(noise, true,
			"uppercase mid-sentence (no boundary) should still be filtered")
	end)

	helpers.it("uppercase prediction after period is NOT noise", function()
		helpers.assert_eq(uppercase_is_noise("B", new_ends_sent(".")),  false)
	end)

	helpers.it("uppercase prediction after exclamation mark is NOT noise", function()
		helpers.assert_eq(uppercase_is_noise("B", new_ends_sent("!")),  false)
	end)

	helpers.it("uppercase prediction after question mark is NOT noise", function()
		helpers.assert_eq(uppercase_is_noise("B", new_ends_sent("?")),  false)
	end)

	helpers.it("lowercase prediction is never filtered by this gate regardless of context", function()
		helpers.assert_eq(uppercase_is_noise("b", new_ends_sent(nil)), false)
		helpers.assert_eq(uppercase_is_noise("b", new_ends_sent("e")), false)
		helpers.assert_eq(uppercase_is_noise("b", new_ends_sent(".")), false)
	end)
end)




-- ========================================================
-- ========================================================
-- ======= 3/ Real Pipeline — Fix Permanence ==============
-- ========================================================
-- ========================================================

-- The formulas above only document the bug. This section runs the real engine
-- and streaming handler, so the noise gate they share is the one judged: an
-- uppercase completion must reach the tooltip at document start and after a
-- sentence end, and only mid-sentence is it dropped as noise.
local load_pipeline = require("tests.support.ai.prediction_pipeline").load

--- Dispatches one request over a buffer and answers it with one completion.
--- @param buffer string Typed context the engine reads.
--- @param completion string Text the backend returns.
--- @return table fixture Pipeline fixture after the final callback.
local function answer(buffer, completion)
	local fixture = load_pipeline({ render_success = true, buffer = buffer })
	fixture.engine.perform_check(true)
	helpers.assert_eq(fixture.fetches, 1,
		"the engine must dispatch a request over " .. string.format("%q", buffer))
	fixture.on_success({ {
		to_type = completion, deletes = 0,
		chunks = { { type = "insert", text = completion } }, nw = "",
	} }, 25, true, false)
	return fixture
end

helpers.describe("is_noise_pred: the real pipeline keeps a capitalised completion where one belongs", function()
	for _, case in ipairs({
		{ name = "a whitespace-only buffer", buffer = "   " },
		{ name = "a finished sentence", buffer = "Il pleut." },
	}) do
		helpers.it("shows an uppercase completion after " .. case.name, function()
			local fixture = answer(case.buffer, "Demain il fera beau")
			helpers.assert_eq(fixture.prediction_renders, 1,
				"an uppercase completion after " .. case.name .. " is not noise")
			helpers.assert_true(fixture.engine.is_visible(), "the completion must stay on screen")
		end)
	end

	helpers.it("drops an uppercase completion in the middle of a sentence", function()
		local fixture = answer("il pleut et", "Demain il fera beau")
		helpers.assert_eq(fixture.prediction_renders, 0,
			"a capital in the middle of a sentence is the noise the gate exists for")
		helpers.assert_true(not fixture.engine.is_visible(), "no noise completion may stay on screen")
	end)
end)
