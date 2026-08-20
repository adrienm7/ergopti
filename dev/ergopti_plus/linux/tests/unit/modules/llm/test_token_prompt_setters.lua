--- tests/unit/modules/llm/test_token_prompt_setters.lua

--- ==============================================================================
--- MODULE: The Settings Window Saves What It Says It Saves
--- DESCRIPTION:
--- Every setter `ui/token_prompt/bridge.lua` calls when the user saves, and the
--- values it hands over.
---
--- THE DEFECT THIS PINS:
--- Three of the four setters did not exist — `set_temperature`,
--- `set_max_tokens`, `set_triggers` — and the bridge calls each behind a
--- `type(…) == "function"` guard. So a user pressing Save had their
--- temperature, token budget and triggers silently discarded while the context
--- length beside them applied. Nothing errored, the window reported success,
--- and only one of four fields took effect.
---
--- That guard shape has now produced four separate defects in this driver: the
--- dashboard's app_detail, forty-one bridge calls that passed the module table
--- as self, the WPM widget's missing methods, and this. It reads as defensive
--- and it makes the branch permanently dead.
---
--- WHY THE COVERAGE CHECK IS DERIVED FROM THE BRIDGE:
--- Naming the four setters here would let the bridge grow a fifth and go quiet
--- again in exactly the way it just did. The source of truth is what the bridge
--- calls, so that is what is read.
--- ==============================================================================

local helpers = require("tests.helpers")

local Engine = helpers.load_module("modules.llm.prediction_engine")

--- Every `state.llm.<name>` the token-prompt bridge calls.
--- @return table Sorted array of names.
local function called_by_bridge()
	local handle = assert(io.open(
		helpers.driver_root() .. "/ui/token_prompt/bridge.lua", "r"))
	local source = handle:read("*a")
	handle:close()
	local seen = {}
	for name in source:gmatch("state%.llm%.([%a_]+)") do seen[name] = true end
	local out = {}
	for name in pairs(seen) do out[#out + 1] = name end
	table.sort(out)
	return out
end




-- =================================================================
-- =================================================================
-- ======= 1/ Everything it calls exists ===========================
-- =================================================================
-- =================================================================

helpers.describe("token prompt: the engine answers every call", function()

	helpers.it("implements every function the bridge invokes", function()
		local names = called_by_bridge()
		helpers.assert_true(#names > 0,
			"no calls were found in the bridge — the scan broke, and a scan that "
				.. "finds nothing agrees with any engine")

		local missing = {}
		for _, name in ipairs(names) do
			if type(Engine[name]) ~= "function" then missing[#missing + 1] = name end
		end
		table.sort(missing)
		helpers.assert_eq(#missing, 0,
			"the settings window calls " .. table.concat(missing, ", ") .. " and the "
				.. "engine has none of them. Behind the bridge's `type(…) == \"function\"` "
				.. "guard the call is skipped in silence, so Save reports success and "
				.. "only some of the fields take effect.")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ And each one holds ===================================
-- =================================================================
-- =================================================================

helpers.describe("token prompt: what the setters accept", function()

	helpers.it("applies a temperature the user saved", function()
		local before = Engine.get_temperature()
		local Settings = helpers.load_module("modules.llm.settings")
		local bounds = Settings.bounds("temperature")
		local target = (before == bounds.max) and bounds.min or bounds.max

		helpers.assert_true(Engine.set_temperature(target))
		local after = Engine.get_temperature()
		Engine.set_temperature(before)

		helpers.assert_eq(after, target,
			"the getter and the setter must agree, or the window shows one value "
				.. "and the request sends another")
	end)

	helpers.it("refuses a temperature outside the declared range", function()
		local before = Engine.get_temperature()
		local bounds = helpers.load_module("modules.llm.settings").bounds("temperature")
		local accepted = Engine.set_temperature(bounds.max + 10)
		local after = Engine.get_temperature()
		helpers.assert_true(not accepted)
		helpers.assert_eq(after, before,
			"a refused value must leave the previous one in place; applying it "
				.. "partially would be worse than either outcome")
	end)

	helpers.it("refuses an empty trigger list", function()
		local before = Engine.get_triggers()
		local accepted = Engine.set_triggers({})
		local after = Engine.get_triggers()
		helpers.assert_true(not accepted,
			"an engine with no trigger never predicts, and the field gives no sign "
				.. "that clearing it turns the feature off — the user reads it as "
				.. "broken rather than as configured")
		helpers.assert_eq(#after, #before)
	end)

	helpers.it("accepts a trigger list and drops the empty entries", function()
		local before = Engine.get_triggers()
		helpers.assert_true(Engine.set_triggers({ "::", "", "@@" }))
		local after = Engine.get_triggers()
		Engine.set_triggers(before)
		helpers.assert_eq(#after, 2,
			"an empty string would match on every keystroke, which is a trigger "
				.. "that fires constantly rather than one that never does")
	end)

	helpers.it("refuses a token budget below one", function()
		local before = Engine.get_max_tokens()
		local accepted = Engine.set_max_tokens(0)
		helpers.assert_true(not accepted)
		helpers.assert_eq(Engine.get_max_tokens(), before,
			"a budget of zero produces an empty completion for every request, "
				.. "which looks exactly like a model that cannot be reached")
	end)

end)
