--- tests/unit/hotstrings/engine/test_actions.lua

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

	helpers.it("the commit follow-up runs an action entry and drops its context (hotstring-actions)", function()
		local Followup = require("hotstrings.engine.commit_followup")
		local calls = {}
		local engine = {
			reset = function(_, keep) calls[#calls + 1] = "reset:" .. tostring(keep) end,
			apply_expansion = function() calls[#calls + 1] = "apply" end,
		}
		local ran = {}
		local deps = { run_action = function(result) ran[#ran + 1] = result.action end }
		helpers.assert_eq(Followup.apply(engine, { action = "select_all" }, deps), true,
			"an action entry changes the context, so the undo must be dropped")
		helpers.assert_eq(table.concat(ran, ","), "select_all")
		helpers.assert_eq(table.concat(calls, ","), "reset:false", "an action entry never chains")
		calls = {}
		helpers.assert_eq(Followup.apply(engine, { output = "x" }, deps), false)
		helpers.assert_eq(table.concat(calls, ","), "apply", "a plain entry keeps the text to chain on")
		helpers.assert_eq(#ran, 1, "a plain entry runs no action")
	end)

	helpers.it("the daemon entry point routes the commit through the follow-up owner (hotstring-actions)", function()
		-- main() sits at LuaJIT's 60-upvalue budget; the action wiring inlined there
		-- once stopped the entry point compiling, so it stays behind one owner.
		local handle = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = handle:read("*a")
		handle:close()
		helpers.assert_true(source:find("CommitFollowup.apply(engine, result)", 1, true) ~= nil,
			"the committed expansion must go through hotstrings.engine.commit_followup")
		helpers.assert_true(source:find("action_runner", 1, true) == nil,
			"the entry point must not wire the action runner itself")
	end)
end)
