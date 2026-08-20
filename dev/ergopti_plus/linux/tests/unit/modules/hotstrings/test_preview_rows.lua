--- tests/unit/modules/hotstrings/test_preview_rows.lua

--- ==============================================================================
--- MODULE: The Rows the Preview Bubble Draws
--- DESCRIPTION:
--- How candidates become rows: which one is dimmed, which is struck, and what
--- colour each carries.
---
--- THE DEFECT THIS PINS:
--- The panel took ONE accent, from `candidates[1]`. Two things were wrong with
--- that. A bubble usually holds candidates from several categories at once — an
--- autocorrect entry and a ★ entry, say — so every row after the first was
--- labelled by a colour belonging to a different category. And `candidates[1]`
--- is merely the first the engine listed, not the one that will fire, so the
--- panel's whole colour could come from a candidate the engine had already
--- ruled out.
---
--- Each row now carries its own accent, and the panel takes the FIRING
--- candidate's.
---
--- WHAT IS NOT ASSERTED HERE:
--- Pixels. `build_rows` is pure and decides everything above the renderer; the
--- bar itself needs lgi, a display and a compositor, and stays in HARDWARE.md.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A config module whose categories have distinct colours.
--- @return table
local function fake_config()
	local COLORS = { magickey = "#0000ff", autocorrection = "#00ff00", personal = "#666666", rolls = "#ff0000" }
	return {
		resolve = function(category, _section)
			return {
				delay = 0.75,
				color = COLORS[category] or "#1e88e5",
				show_tooltip = true,
				has_override = false,
			}
		end,
	}
end

--- A preview module initialised with a style stub and the config above.
--- @return table
local function preview()
	local P = helpers.load_module("ui.tooltip.preview")
	P.init({ style = { positioning = { window_bottom_inset = 0 } }, config = fake_config() })
	return P
end

local CANDIDATES = {
	{ trigger = "btw", replacement = "by the way", group = "rolls",          fires = true },
	{ trigger = "tw",  replacement = "the way",    group = "autocorrection", fires = false },
	{ trigger = "w",   replacement = "with",       group = "magickey",       fires = false, blocked = true },
}




-- =================================================================
-- =================================================================
-- ======= 1/ One colour per row ===================================
-- =================================================================
-- =================================================================

helpers.describe("preview rows: colour", function()

	helpers.it("colours by FAMILY, so the colour says what will validate the row", function()
		-- Aligned with macOS on the maintainer's decision: a ★-validated row wears
		-- the magic-key colour whichever pack it came from, so the colour tells the
		-- user which kind of expansion is about to fire rather than which file it
		-- happens to live in.
		local rows = preview().build_rows(CANDIDATES, { kind = "star" })
		helpers.assert_eq(#rows, 3, "every candidate becomes a row")
		for index, row in ipairs(rows) do
			helpers.assert_eq(row.accent.blue, 1,
				"row " .. index .. " is ★-validated, so it wears the magickey colour")
		end
	end)

	helpers.it("keeps a personal entry in its own colour whatever validates it", function()
		-- "personal" is a family as much as a pack, and macOS treats it that way.
		local rows = preview().build_rows(
			{ { trigger = "sig", replacement = "…", group = "personal", fires = true } },
			{ kind = "star" })
		helpers.assert_eq(rows[1].accent.red, 0.4, "the personal grey, not the magickey blue")
	end)

	helpers.it("drops every accent when coloured previews are off", function()
		local P = preview()
		P.set_enabled("colored", false)
		for _, row in ipairs(P.build_rows(CANDIDATES, { kind = "star" })) do
			helpers.assert_nil(row.accent,
				"the toggle governs the colour on every row, not only on the panel")
		end
		P.set_enabled("colored", true)
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ Dimming and striking =================================
-- =================================================================
-- =================================================================

helpers.describe("preview rows: what each row says", function()

	helpers.it("dims what will not fire and strikes what was refused", function()
		local rows = preview().build_rows(CANDIDATES, {})
		helpers.assert_true(not rows[1].dimmed, "the firing candidate is not dimmed")
		helpers.assert_true(rows[2].dimmed, "one that merely ranked lower is dimmed")
		helpers.assert_true(rows[3].struck,
			"one the engine REFUSED is struck through — the user asking \"why did "
				.. "nothing happen\" needs those two to look different")
	end)

	helpers.it("labels each row with the key that VALIDATES it, not the trigger", function()
		-- The column used to repeat the trigger the user had just typed and was
		-- already looking at, so the bubble never said how to fire anything.
		-- Aligned with macOS on the maintainer's decision.
		local star = preview().build_rows(CANDIDATES, { kind = "star" })
		helpers.assert_eq(star[1].text, "by the way", "the text is what they are about to get")
		helpers.assert_true(star[1].label ~= "btw", "and the label is no longer the trigger")

		local ended = preview().build_rows(CANDIDATES, { kind = "autocorrect" })
		helpers.assert_eq(ended[1].label, "↵",
			"an end-char row is fired by a terminator, and the bubble should say so")
	end)

	helpers.it("honours the row limit", function()
		local many = {}
		for index = 1, 20 do
			many[index] = { trigger = "t" .. index, replacement = "r" .. index, group = "rolls" }
		end
		helpers.assert_eq(#preview().build_rows(many, { max_rows = 4 }), 4,
			"beyond a handful the panel is taller than it is useful and covers the "
				.. "text it annotates")
	end)

end)
