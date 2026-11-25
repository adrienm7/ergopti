--- tests/unit/hotstrings/test_hotstring_actions.lua

--- ==============================================================================
--- MODULE: Hotstring Actions (macOS)
--- DESCRIPTION:
--- Replays the shared action entry contract
--- (_shared/tests/lua/hotstrings/action_entry_contract.lua) on the Hammerspoon
--- runtime, and runs an entry's action through the macOS runner, never inside
--- the event tap.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.hotstrings.action_entry_contract").register(helpers, helpers.shared)

helpers.describe("hotstring actions on macOS (hotstring-actions)", function()
	helpers.it("the runner defers the workflow and the plain action (hotstring-actions)", function()
		local Runner = require("hotstrings.engine.action_runner")
		local queued, ran = {}, {}
		local deps = {
			timer = { after = function(_, fn) queued[#queued + 1] = fn end },
			workflows = { run = function(p) ran[#ran + 1] = "wf:" .. p.id; return true end },
			actions = {
				execute_single = function(a, binding) ran[#ran + 1] = a .. "@" .. binding; return true end,
				get_action_parameter_spec = function() return nil end,
			},
		}
		Runner.run({ action = "run_workflow", workflow = "wf_a" }, deps)
		Runner.run({ action = "select_all" }, deps)
		helpers.assert_eq(#ran, 0, "nothing runs inside the event tap")
		for _, fn in ipairs(queued) do fn() end
		helpers.assert_eq(table.concat(ran, ","), "wf:wf_a,select_all@hotstring")
	end)
end)
