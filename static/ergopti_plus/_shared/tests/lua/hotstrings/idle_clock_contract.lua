--- _shared/tests/lua/hotstrings/idle_clock_contract.lua

--- ==============================================================================
--- MODULE: Hotstring Idle Clock Integer Contract
--- DESCRIPTION:
--- Keeps admitted wide second counts from resetting words immediately, while
--- retaining exact representable millisecond deadlines on native integer Lua.
--- ==============================================================================

local M = {}

--- Registers real shared engine checks without driver hooks or native output.
--- @param helpers table Test assertions and registration helpers.
-- Lua 5.4 only: LuaJIT has no integer subtype, so the integer controls skip there.
local math_type = math.type

function M.register(helpers)
	local Engine = require("hotstrings.engine.matcher")
	helpers.describe("hotstring idle clock integer domain", function()
		helpers.it("keeps admitted wide durations instead of wrapping into an immediate reset", function()
			local wide = assert(tonumber("4611686018427387904"))
			if math_type then helpers.assert_eq(math_type(wide), "integer", "the counterfactual must use a native integer") end
			for _, seconds in ipairs({wide, assert(tonumber("9223372036854775807")), 1e308}) do
				helpers.assert_true(Engine.valid_idle_reset_seconds(seconds), "the existing uncapped policy admits this finite value")
				helpers.assert_eq(Engine.idle_resets_word(1000, 1001, seconds, 0), false, "a one-millisecond pause cannot satisfy a huge duration")
			end
		end)

		helpers.it("retains exact native integer deadlines and ordinary float and zero policy", function()
			if math_type then
				local seconds = assert(tonumber("9223372036854775"))
				local deadline = seconds * 1000
				helpers.assert_eq(math_type(deadline), "integer", "the reachable deadline must remain exact")
				helpers.assert_eq(Engine.idle_resets_word(0, deadline - 1, seconds, 0), false, "the preceding native millisecond remains in the word")
				helpers.assert_eq(Engine.idle_resets_word(0, deadline, seconds, 0), true, "the exact original inclusive deadline still expires")
				helpers.assert_eq(Engine.idle_resets_word(0, deadline + 1, seconds, 0), true, "the following native millisecond remains expired")
			end
			helpers.assert_eq(Engine.idle_resets_word(1000, 2499, 1.5, 0), false)
			helpers.assert_eq(Engine.idle_resets_word(1000, 2500, 1.5, 0), true)
			helpers.assert_eq(Engine.idle_resets_word(1000, 2500, 1.5, 1), false, "clock resolution remains subtracted")
			helpers.assert_eq(Engine.idle_resets_word(0, 999999, 0, 0), false, "only explicit zero disables reset")
			helpers.assert_eq(Engine.idle_resets_word(nil, 999999, 3, 0), false, "the first key is not a pause")
		end)
	end)
end

return M
