--- _shared/lua/test/tap_hold_rollover_contract.lua

--- Shared validation and backend-alias regressions for typing-priority keys.
--- @param helpers table Driver test helpers.
--- @param Catalog table Shared key catalogue.
--- @param defaults table The actual decoded shipped defaults.
return function(helpers, Catalog, defaults)
	helpers.describe("shared typing-priority catalogue", function()
		local expected = {
			ahk = { escape = true, tab = true, enter = true, space = true, backspace = true, delete = true },
			linux = { escape = true, tab = true, enter = true, space = true, backspace = true, delete = true },
			hs = { escape = true, tab = true, return_or_enter = true, spacebar = true, delete_or_backspace = true },
		}
		for _, platform in ipairs(Catalog.PLATFORMS) do
			helpers.it("typing-priority keys resolve through the " .. platform .. " catalogue", function()
				helpers.assert_eq(Catalog.rollover_for_platform(defaults, platform), expected[platform])
			end)
		end
		for _, fixture in ipairs({
			{ name = "empty", keys = {} },
			{ name = "unknown", keys = { "not_a_key" } },
			{ name = "repeated", keys = { "space", "space" } },
			{ name = "record", keys = { space = true } },
			{ name = "sparse", keys = { [1] = "space", [3] = "tab" } },
			{ name = "non-string", keys = { 23 } },
		}) do
			helpers.it("typing-priority refuses a " .. fixture.name .. " key list", function()
				local invalid = { tap_hold = { catalog = defaults.tap_hold.catalog, rollover = { keys = fixture.keys } } }
				local ok = pcall(Catalog.rollover_for_platform, invalid, "hs")
				helpers.assert_eq(ok, false, "an invalid shared key list must fail closed")
			end)
		end
	end)
end
