--- _shared/lua/test/hotstring_choice_catalogue_contract.lua

--- ==============================================================================
--- MODULE: Hotstring Choice Catalogue Contract
--- DESCRIPTION:
--- The Lua drivers replay the same judgement of an explicit category or section
--- choice against a published catalogue.
--- ==============================================================================

local M = {}

--- Registers the shared judgement cases.
--- @param helpers table Driver assertion and registration API.
--- @param catalogue table _shared/lua/hotstrings/choice_catalogue.
function M.run(helpers, catalogue)
	local known = {
		autocorrection = { sections = { names = true } },
		overridden = { sections = nil },
		personal = { unjudged = true },
	}
	local function lookup(id) return known[id] end

	helpers.describe("hotstring choice catalogue judgement", function()
		helpers.it("(hotstring-choice-catalogue) retires nothing before a catalogue is published", function()
			helpers.assert_eq(catalogue.is_retired(false, lookup, "removed"), false)
			helpers.assert_eq(catalogue.is_retired(false, lookup, "autocorrection", "gone"), false)
		end)

		helpers.it("(hotstring-choice-catalogue) retires a category the catalogue does not know", function()
			helpers.assert_eq(catalogue.is_retired(true, lookup, "removed"), true)
			helpers.assert_eq(catalogue.is_retired(true, lookup, "autocorrection"), false)
		end)

		helpers.it("(hotstring-choice-catalogue) retires a section the build's category lacks", function()
			helpers.assert_eq(catalogue.is_retired(true, lookup, "autocorrection", "names"), false)
			helpers.assert_eq(catalogue.is_retired(true, lookup, "autocorrection", "gone"), true)
		end)

		helpers.it("(hotstring-choice-catalogue) never judges sections it cannot prove or categories it cannot judge", function()
			helpers.assert_eq(catalogue.is_retired(true, lookup, "overridden", "any"), false)
			helpers.assert_eq(catalogue.is_retired(true, lookup, "personal"), false)
			helpers.assert_eq(catalogue.is_retired(true, lookup, "personal", "any"), false)
		end)
	end)
end

return M
