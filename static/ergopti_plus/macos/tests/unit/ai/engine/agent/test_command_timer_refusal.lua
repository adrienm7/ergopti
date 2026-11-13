--- tests/unit/ai/engine/agent/test_command_timer_refusal.lua

--- A command that never schedules must not invalidate a prior agent request.
local helpers = require("tests.helpers")
local World = require("tests.support.ai.agent_world")

helpers.describe("agent command timer admission", function()
	helpers.it("retains the in-flight selection when command scheduling is refused", function()
		local world = World.build_world()
		helpers.assert_true(World.trigger(world, "llm_agent_selection"))
		helpers.assert_eq(#world.posts, 1)
		local scheduler = require("core.events.timer_scheduler")
		local original = scheduler.after
		scheduler.after = function() return {}, false end
		local ok, result = pcall(world.runner.run_command)
		scheduler.after = original
		helpers.assert_true(ok)
		helpers.assert_eq(result, false)
		World.answer(world.posts[1], World.TWO_ACTIONS)
		helpers.assert_eq(#world.renders, 1, "refused command must not discard the preceding response")
		helpers.assert_eq(#world.renders[1].texts, 2)
	end)
	helpers.it("preserves the existing request if timer admission raises", function()
		local world = World.build_world()
		helpers.assert_true(World.trigger(world, "llm_agent_selection"))
		local scheduler = require("core.events.timer_scheduler")
		local original = scheduler.after
		scheduler.after = function() error("controlled timer failure") end
		local ok, result = pcall(world.runner.run_command)
		scheduler.after = original
		helpers.assert_true(ok)
		helpers.assert_eq(result, false)
		World.answer(world.posts[1], World.TWO_ACTIONS)
		helpers.assert_eq(#world.renders, 1)
	end)

	helpers.it("delivers the existing answer during reentrant timer admission", function()
		local world = World.build_world()
		helpers.assert_true(World.trigger(world, "llm_agent_selection"))
		local scheduler = require("core.events.timer_scheduler")
		local original = scheduler.after
		scheduler.after = function()
			World.answer(world.posts[1], World.TWO_ACTIONS)
			return {}, false
		end
		local ok, result = pcall(world.runner.run_command)
		scheduler.after = original
		helpers.assert_true(ok)
		helpers.assert_eq(result, false)
		helpers.assert_eq(#world.renders, 1, "admission cannot preempt an existing callback")
	end)

	helpers.it("does not revive a command when timer admission reenters an AI-off transition", function()
		local world = World.build_world()
		local scheduler = require("core.events.timer_scheduler")
		local after, cancel = scheduler.after, scheduler.cancel
		local delivered, cancelled = nil, 0
		scheduler.after = function(_, callback)
			delivered = callback
			helpers.assert_true(world.runner.set_mode("off"))
			return {}, true
		end
		scheduler.cancel = function() cancelled = cancelled + 1; return true end
		local ok, result = pcall(world.runner.run_command)
		scheduler.after, scheduler.cancel = after, cancel
		helpers.assert_true(ok)
		helpers.assert_eq(result, false)
		helpers.assert_eq(cancelled, 1, "the unpublishable timer must be retired")
		assert(delivered)()
		helpers.assert_eq(#world.dialogs, 0)
	end)

end)
