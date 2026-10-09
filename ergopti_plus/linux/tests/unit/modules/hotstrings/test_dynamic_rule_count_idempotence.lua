--- tests/unit/modules/hotstrings/test_dynamic_rule_count_idempotence.lua

--- ==============================================================================
--- MODULE: Dynamic Rule Count Idempotence
--- DESCRIPTION:
--- Proves that reloads and magic-key changes replace the dynamic rule snapshot
--- instead of accumulating its previous published count.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("dynamic hotstrings: repeated initialisation", function()

	helpers.it("keeps published and active-engine counts identical across reloads", function()
		local temporary = os.tmpname()
		os.remove(temporary)
		local path = temporary .. "_dynamic_count.toml"
		local file = assert(io.open(path, "w"))
		file:write([=[
[info]
first_name = "Ada"
last_name = "Lovelace"

[letters]
p = "first_name"
n = "last_name"
]=])
		file:close()

		local ok, err = pcall(function()
			local manager = helpers.load_module("modules.dynamic_hotstrings.manager")
			local engine = require("dynamic_hotstrings")

			local function assert_snapshot(trigger, phase)
				helpers.assert_true(manager.init({
					trigger_char = trigger,
					personal_info_path = path,
				}), phase .. " must initialise successfully")
				helpers.assert_eq(manager.get_rules_count(), 5,
					phase .. " must publish two personal rules plus three date rules")
				helpers.assert_eq(manager.get_rules_count(), #engine.get_rules(),
					phase .. " count must describe the active engine snapshot")
			end

			assert_snapshot("★", "first start")
			assert_snapshot("★", "same-key reload")
			assert_snapshot("§", "magic-key reload")
		end)

		os.remove(path)
		if not ok then error(err, 0) end
	end)

end)
