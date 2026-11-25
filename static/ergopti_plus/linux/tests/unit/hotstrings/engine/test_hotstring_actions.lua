--- tests/unit/hotstrings/engine/test_hotstring_actions.lua

--- ==============================================================================
--- MODULE: Hotstring Actions (Linux)
--- DESCRIPTION:
--- Replays the shared action entry contract
--- (_shared/tests/lua/hotstrings/action_entry_contract.lua) on the Linux
--- runtime, and runs an action entry's action through the Linux runner out of
--- the key callback.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.hotstrings.action_entry_contract").register(helpers, require("core.fs.engine.paths").shared)

helpers.describe("hotstring actions on Linux (hotstring-actions)", function()
	helpers.it("the runner defers the workflow and the plain action (hotstring-actions)", function()
		local Runner = require("hotstrings.engine.action_runner")
		local queued, ran = {}, {}
		local deps = {
			after = function(fn) queued[#queued + 1] = fn end,
			workflows = { run = function(p) ran[#ran + 1] = "wf:" .. p.id; return true end },
			gestures = {
				execute_action = function(a, binding) ran[#ran + 1] = a .. "@" .. binding; return true end,
				get_action_parameter_spec = function() return nil end,
			},
		}
		Runner.run({ action = "run_workflow", workflow = "wf_a" }, deps)
		Runner.run({ action = "select_all" }, deps)
		helpers.assert_eq(#ran, 0, "nothing runs inside the key callback")
		for _, fn in ipairs(queued) do fn() end
		helpers.assert_eq(table.concat(ran, ","), "wf:wf_a,select_all@hotstring")
	end)
end)
