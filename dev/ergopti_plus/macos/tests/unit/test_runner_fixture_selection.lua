--- tests/unit/test_runner_fixture_selection.lua

--- ==============================================================================
--- MODULE: Focused Fixture Registration Selection
--- DESCRIPTION:
--- Replays selected source chunks to prove shared registration wrappers retain
--- matching callbacks when another module supplies a direct literal match.
--- ==============================================================================

local helpers = require("tests.helpers")
local OnlySelector = require("tests.support.only_selector")

helpers.describe("Focused fixture registration (fixture-only-selection)", function()
	local variants = {
		{ name = "shared wrapper", source = 'Fixture.it("target", callback)' },
		{ name = "mixed registration", source = [[
			helpers.it("unrelated", callback)
			Fixture.it("target", callback)
		]] },
		{ name = "aliased registration", source = [[
			local register = Fixture.it
			register("target", callback)
		]] },
		{ name = "delegated registration", source = 'register("target", callback)' },
		{ name = "mixed helper alias", source = [[
			helpers.it("unrelated", callback)
			local register = helpers.it
			register("target", callback)
		]] },
	}

	for _, variant in ipairs(variants) do
		helpers.it("retains " .. variant.name .. " callbacks", function()
			local sources = {
				direct = 'helpers.it("target", callback)',
				wrapped = variant.source,
				unrelated = [=[
					-- Fixture.it("target", callback)
					local documentation = 'Fixture.it("target", callback)'
					local example = [[Fixture.it("target", callback)]]
					helpers.it("other", callback)
				]=],
			}
			local selected, _, filter = OnlySelector.select_modules(
				{ "direct", "wrapped", "unrelated" }, "target",
				function(name) return sources[name] end
			)
			local deliveries = {}
			for _, module_name in ipairs(selected) do
				local function register(name, callback)
					if name:find(filter, 1, true) then callback() end
				end
				local environment = {
					helpers = { it = register },
					Fixture = { it = register },
					register = register,
					callback = function()
						deliveries[module_name] = (deliveries[module_name] or 0) + 1
					end,
				}
				assert(load(sources[module_name], "=" .. module_name, "t", environment))()
			end
			helpers.assert_eq(deliveries.direct, 1)
			helpers.assert_eq(deliveries.wrapped, 1,
				"a direct literal match must not hide a fixture's matching callback")
			helpers.assert_nil(deliveries.unrelated)
			helpers.assert_eq(#selected, 2,
				"proven unrelated direct registrations still avoid module execution")
		end)
	end

	helpers.it("retains the real shared gesture registration source", function()
		local module_name = "tests.unit.modules.gestures.actions.test_dispatch_fences"
		local path = helpers.driver_root() .. module_name:gsub("%.", "/") .. ".lua"
		local handle = assert(io.open(path, "rb"))
		local source = assert(handle:read("*a"))
		assert(handle:close())
		local selected = OnlySelector.select_modules({ "direct", module_name }, "refuses",
			function(name)
				if name == module_name then return source end
				return 'helpers.it("refuses", callback)'
			end
		)
		helpers.assert_eq(#selected, 2)
		helpers.assert_eq(selected[2], module_name)
	end)
end)
