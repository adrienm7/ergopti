--- _shared/lua/test/hotstring_palette_contract.lua

--- ==============================================================================
--- MODULE: Hotstring Colour Palette Contract
--- DESCRIPTION:
--- The hotstrings settings window offers the same 14 colours on the three
--- drivers, from one source (_shared/data/native_theme.toml, generated into
--- _shared/lua/native_theme_data.lua). This contract holds the macOS and Linux
--- drivers to that list: the names and their order are the Windows picker's,
--- every colour is a six-digit hex and names itself through a locale key.
---
--- FEATURES & RATIONALE:
--- 1. The list is typed here once, as the maintainer's decision of 2026-10-26
---    (14 colours on the three OS); a palette that shrank back to the older 8
---    colours fails by name, not by a count.
--- 2. Both Lua drivers register the same checks, so they cannot drift apart.
--- ==============================================================================

local M = {}

-- The Windows picker's colours, in its order.
local EXPECTED_NAMES = {
	"red", "pink", "purple", "ai", "indigo", "blue", "cyan", "turquoise", "green", "lime", "yellow", "orange",
	"brown", "gray",
}

--- Registers the palette checks.
--- @param helpers table The driver's test helpers.
function M.register(helpers)
	local palette = require("native_theme_data").hotstring_palette
	helpers.describe("hotstring colour palette", function()
		helpers.it("offers the 14 colours of the Windows picker, in its order", function()
			local names = {}
			for _, row in ipairs(palette) do names[#names + 1] = row.name end
			helpers.assert_eq(names, EXPECTED_NAMES)
		end)

		helpers.it("gives every colour a six-digit hex and a locale key for its name", function()
			for _, row in ipairs(palette) do
				helpers.assert_true(row.hex:match("^#%x%x%x%x%x%x$") ~= nil, row.name .. " has hex " .. tostring(row.hex))
				helpers.assert_true(type(row.i18n) == "string" and row.i18n ~= "", row.name .. " has no locale key")
			end
		end)
	end)
end

return M
