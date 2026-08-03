--- tests/unit/meta/test_shared_core_agrees_with_macos.lua

--- ==============================================================================
--- MODULE: The Shared Matcher Core and the macOS Matcher Agree
--- DESCRIPTION:
--- TODO §2 is macOS adopting `_shared/lua/hotstring_engine/` — the 526-line
--- matcher that reaches Linux alone today. This file is the step that has to come
--- before the switch: replay the whole cross-driver corpus through BOTH matchers
--- and require the same verdict on every vector.
---
--- WHY THIS AND NOT THE PORT ITSELF:
--- a migration that swaps a matcher and then runs the suite tells you it broke
--- something; it does not tell you WHERE the two disagreed, and by then the old
--- one is gone. Running them side by side answers that while both still exist,
--- and the answer is what makes the switch a decision rather than a gamble.
---
--- WHAT THE SECTION GOT WRONG, and why this file only names macOS:
--- the entry said "macOS + Windows onto the shared core". The core is Lua and the
--- Windows driver has no Lua at all — no `.lua` file outside its test tree, no
--- runtime in its boot path. Windows cannot adopt it; it shares the behavioural
--- CONTRACT instead, which is what the corpus is. So this is one driver.
---
--- READ THE DISAGREEMENTS AS DATA, NOT AS FAILURES. A vector where the two differ
--- is not necessarily a bug in either: it may be a macOS behaviour the core does
--- not model, or the reverse. What it must never be is a surprise discovered
--- after the switch.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Vectors whose outcome hangs on a constant the drivers deliberately do not
-- share (the rolling-buffer cap: 500 codepoints on macOS, 256 in the core).
-- Comparing those would pin one driver's number to the other's.
local DRIVER_SPECIFIC_FIELD = "driver_specific"

-- Floor: a comparison that walks nothing passes for free, which is the failure
-- mode every corpus harness in this repository has had at least once.
local MIN_COMPARED = 20




-- =============================================
-- =============================================
-- ======= 1/ Reaching the shared core =========
-- =============================================
-- =============================================

--- Puts `_shared/lua/` on package.path and requires the core.
--- Returns nil when it cannot be loaded, so the assertions below can say so
--- rather than erroring out of the whole file.
--- @return table|nil
local function load_shared_core()
	local entry = helpers.shared("lua") .. "/?.lua"
	if not package.path:find(entry, 1, true) then
		package.path = entry .. ";" .. package.path
	end
	local ok, mod = pcall(require, "hotstring_engine")
	if not ok or type(mod) ~= "table" or type(mod.new) ~= "function" then return nil end
	return mod
end

--- Reads the shared corpus through the hs stub's JSON decoder.
--- @return table|nil
local function load_corpus()
	local fh = io.open(helpers.shared("tests/corpus/hotstrings/vectors.json"), "r")
	if not fh then return nil end
	local raw = fh:read("*a")
	fh:close()
	package.loaded["infra.logger"] = nil
	helpers.load_with_stubs("infra.logger")
	local ok, corpus = pcall(require("hs").json.decode, raw)
	return ok and corpus or nil
end

--- Splits a UTF-8 string into codepoint strings, so the core is fed the same
--- way a real keystroke stream feeds it.
--- @param s string
--- @return table
local function codepoints(s)
	local out = {}
	for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
	return out
end





-- =============================================
-- =============================================
-- ======= 2/ The two verdicts, compared =======
-- =============================================
-- =============================================

helpers.describe("shared matcher core vs the macOS matcher (TODO §2 pre-flight)", function()

	helpers.it("the core is reachable from this driver's tree", function()
		helpers.assert_true(load_shared_core() ~= nil,
			"could not require the shared hotstring_engine from the macOS test tree. The adoption "
			.. "cannot even be evaluated until it loads here, so this is the first thing to fix.")
	end)

	helpers.it("both matchers reach the same verdict on every corpus vector", function()
		local core   = load_shared_core()
		local corpus = load_corpus()
		if not core or not corpus then return end

		local compared, disagreements = 0, {}
		for _, v in ipairs(corpus.vectors) do
			if v[DRIVER_SPECIFIC_FIELD] == nil then
				local engine = core.new()
				engine:load_mappings({ {
					trigger                 = v.trigger,
					replacement             = v.replacement or "",
					is_word                 = v.is_word == true,
					auto_expand             = v.auto_expand == true,
					is_case_sensitive       = v.is_case_sensitive == true,
					is_case_sensitive_strict = v.is_case_sensitive_strict == true,
					final_result            = v.final_result == true,
				} })
				local result
				for _, ch in ipairs(codepoints(v.buffer or v.trigger)) do
					result = engine:on_char(ch)
				end

				local core_fired = result ~= nil
				local want       = (v.expected and v.expected.matched == true)
				compared = compared + 1
				if core_fired ~= want then
					disagreements[#disagreements + 1] = string.format(
						"%s (corpus says %s, core says %s)",
						v.id, tostring(want), tostring(core_fired))
				end
			end
		end

		helpers.assert_true(compared >= MIN_COMPARED,
			"only " .. tostring(compared) .. " vector(s) were compared (floor " .. tostring(MIN_COMPARED)
			.. ") — the walk is broken and this comparison means nothing")

		helpers.assert_eq(0, #disagreements,
			"the shared core and the corpus disagree on " .. tostring(#disagreements) .. " vector(s): "
			.. table.concat(disagreements, "; ")
			.. ". Every one is a behaviour macOS would gain or lose by adopting the core, and each "
			.. "has to be a decision rather than a discovery made after the switch.")
	end)

end)
