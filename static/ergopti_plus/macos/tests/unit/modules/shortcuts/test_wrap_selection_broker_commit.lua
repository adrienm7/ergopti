--- tests/unit/modules/shortcuts/test_wrap_selection_broker_commit.lua

--- ==============================================================================
--- MODULE: Selection Wrap Broker Completion Regression
--- DESCRIPTION:
--- Executes the real text and synthetic-input owners while delaying the native
--- broker. Clipboard restoration must follow the paste handoff, never its queue
--- admission. These controlled Quartz ports do not qualify native macOS input.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_input_fixture")


--- Runs the actual wrap owner over a controllable native broker and pasteboard.
--- @param callback function Scenario body.
local function with_broker(callback)
	helpers.with_stub_scope({
		"modules.shortcuts.actions.text", "adapters.synthetic_input",
		"adapters.timer_scheduler", "adapters.event_provenance", "adapters.storage",
		"adapters.json_codec", "infra.logger", "infra.paths", "infra.timings",
	}, function()
		local f = Fixture.make({ deliver_trigger = false, absolute_time = 0 })
		local initial = {
			["public.utf8-plain-text"] = "USER CLIPBOARD",
			["public.html"] = "<b>USER CLIPBOARD</b>",
		}
		local clipboard = initial
		f.hs_overrides.pasteboard = {
			readAllData = function() return clipboard end,
			setContents = function(value)
				clipboard = { ["public.utf8-plain-text"] = value }
				return true
			end,
			writeAllData = function(value) clipboard = value; return true end,
			clearContents = function() clipboard = {}; return true end,
		}
		local synthetic = f.load()
		package.loaded["modules.shortcuts.actions.text"] = nil
		local text = require("modules.shortcuts.actions.text")
		f.text = text
		f.synthetic = synthetic
		f.clipboard = function() return clipboard end
		f.initial = initial
		f.expire_restore = function()
			local snapshot = {}
			for _, timer in ipairs(f.timers) do snapshot[#snapshot + 1] = timer end
			for _, timer in ipairs(snapshot) do
				if timer.delay > 0 and not timer.stopped then
					f.options.absolute_time = f.options.absolute_time + math.ceil(timer.delay * 1e9)
					timer.callback()
				end
			end
		end
		f.finish_broker = function()
			f.deliver_trigger = true
			for _ = 1, 32 do
				local selected
				for index, timer in ipairs(f.timers) do
					if not timer.stopped and timer.delay <= synthetic.PERIODIC_OWNER_TICK_SEC then
						selected = table.remove(f.timers, index)
						break
					end
				end
				if not selected then return end
				f.options.absolute_time = f.options.absolute_time + math.floor(selected.delay * 1e9)
				selected.callback()
				if selected.recurring and not selected.stopped then
					f.timers[#f.timers + 1] = selected
				end
			end
			error("synthetic wrap lifecycle did not settle")
		end
		f.handoff_only = function()
			f.deliver_trigger = true
			for index, timer in ipairs(f.timers) do
				if timer.delay == 0 and not timer.stopped then
					table.remove(f.timers, index)
					timer.callback()
					return
				end
			end
			error("no queued native handoff was available")
		end
		f.active_delayed = function()
			local count = 0
			for _, timer in ipairs(f.timers) do
				if timer.delay > 0 and not timer.stopped then count = count + 1 end
			end
			return count
		end
		callback(f)
	end)
end


helpers.describe("selection wrap waits for the real broker", function()
	helpers.it("retains wrapped clipboard before queued paste handoff (wrap-broker-commit)", function()
		with_broker(function(f)
			helpers.assert_eq(f.text.wrap_selection("selected", "(", ")"), true)
			helpers.assert_eq(#f.pump_deliveries, 0, "the broker must still be held")
			f.expire_restore()
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "(selected)",
				"queued Cmd+V must never receive the restored user's clipboard")
		end)
	end)

	helpers.it("keeps exact admission closed until queued paste settles (wrap-broker-commit)", function()
		with_broker(function(f)
			helpers.assert_eq(f.text.wrap_selection("selected", "(", ")"), true)
			f.expire_restore()
			helpers.assert_eq(f.text.wrap_selection("replacement", "[", "]"), false,
				"an older queued paste still owns the clipboard and selection")
		end)
	end)

	helpers.it("restores every original type after the actual paste completion (wrap-broker-commit)", function()
		with_broker(function(f)
			helpers.assert_eq(f.text.wrap_selection("selected", "(", ")"), true)
			f.expire_restore()
			f.finish_broker()
			helpers.assert_eq(#f.pump_deliveries, 1)
			local events = f.pump_deliveries[1].events
			helpers.assert_eq(events[1].key, "v")
			helpers.assert_eq(events[1].modifiers[1], "cmd")
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "(selected)",
				"the paste settling interval starts after terminal producer confirmation")
			f.expire_restore()
			helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
			helpers.assert_eq(f.text.wrap_selection("fresh", "[", "]"), true)
		end)
	end)

	helpers.it("joins cancelled paste before restoring during PAUSE (wrap-broker-commit)", function()
		with_broker(function(f)
			helpers.assert_eq(f.text.wrap_selection("selected", "(", ")"), true)
			helpers.assert_eq(f.text.pause_text_actions(), false,
				"cancellation admission is not a terminal native producer receipt")
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "(selected)")
			f.finish_broker()
			helpers.assert_eq(#f.pump_deliveries, 0, "cancelled queued paste must never publish")
			helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
			helpers.assert_eq(f.text.pause_text_actions(), true)
			helpers.assert_eq(f.text.resume_text_actions(), true)
		end)
	end)

	helpers.it("preserves the full settling interval after late completion (wrap-broker-late-completion)", function()
		with_broker(function(f)
			helpers.assert_eq(f.text.wrap_selection("selected", "(", ")"), true)
			local initial_restore = f.timers[1]
			helpers.assert_true(initial_restore.delay > 0)
			f.options.absolute_time = math.floor(initial_restore.delay * 0.9 * 1e9)
			f.finish_broker()
			f.options.absolute_time = math.floor(initial_restore.delay * 1e9)
			initial_restore.callback()
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "(selected)",
				"the initial deadline cannot shorten the post-completion paste interval")
			f.expire_restore()
			helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
		end)
	end)

	helpers.it("keeps completed paste grace during PAUSE without business replay (wrap-pause-paste-grace)", function()
		with_broker(function(f)
			helpers.assert_eq(f.text.wrap_selection("selected", "(", ")"), true)
			f.finish_broker()
			helpers.assert_eq(#f.pump_deliveries, 1)
			helpers.assert_eq(f.text.pause_text_actions(), false,
				"terminal Quartz output still owns the host paste settling interval")
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "(selected)")
			helpers.assert_eq(f.active_delayed(), 1,
				"one bounded cleanup timer must own the fixed remaining grace")
			helpers.assert_eq(f.text.pause_text_actions(), false)
			helpers.assert_eq(f.text.resume_text_actions(), false)
			helpers.assert_eq(f.active_delayed(), 1,
				"repeated lifecycle calls must not multiply or restart grace timers")
			helpers.assert_eq(f.text.wrap_selection("late", "[", "]"), false)
			f.expire_restore()
			helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
			helpers.assert_eq(f.text.pause_text_actions(), true)
			helpers.assert_eq(f.text.resume_text_actions(), true)
			helpers.assert_eq(#f.pump_deliveries, 1, "cleanup may never replay document output")
		end)
	end)

	helpers.it("preserves handed-off paste grace when cancellation precedes completion (wrap-pause-paste-grace)", function()
		with_broker(function(f)
			helpers.assert_eq(f.text.wrap_selection("selected", "(", ")"), true)
			f.handoff_only()
			helpers.assert_eq(#f.pump_deliveries, 1)
			helpers.assert_eq(f.text.pause_text_actions(), false)
			f.finish_broker()
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "(selected)",
				"cancelled status cannot retract an already returned native paste")
			helpers.assert_eq(f.text.resume_text_actions(), false)
			f.expire_restore()
			helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
			helpers.assert_eq(f.text.pause_text_actions(), true)
			helpers.assert_eq(f.text.resume_text_actions(), true)
		end)
	end)

	for _, terminal in ipairs({ false, true }) do
		helpers.it("joins reentrant rollback after native paste " .. (terminal and "completion" or "handoff")
			.. " (wrap-rollback-custody)", function()
			with_broker(function(f)
				local actual_seal = f.synthetic.seal
				f.synthetic.seal = function(tx)
					local sealed = actual_seal(tx)
					if terminal then f.finish_broker() else f.handoff_only() end
					helpers.assert_eq(#f.pump_deliveries, 1,
						"the real broker must have returned the native paste")
					helpers.assert_eq(f.text.pause_text_actions(), false,
						"the current native admission still owns its reentrant boundary")
					return sealed
				end
				helpers.assert_eq(f.text.wrap_selection("selected", "(", ")"), false,
					"PAUSE inside the actual seal must revoke wrap admission")
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "(selected)",
					"rollback cannot retract the host's accepted native paste")
				helpers.assert_eq(f.text.resume_text_actions(), false)
				if not terminal then f.finish_broker() end
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "(selected)",
					"aborting completion must retain the full host paste grace")
				helpers.assert_eq(f.active_delayed(), 1,
					"the original owner must retain exactly one bounded cleanup timer")
				f.expire_restore()
				helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
				helpers.assert_eq(f.text.pause_text_actions(), true)
				helpers.assert_eq(f.text.resume_text_actions(), true)
				helpers.assert_eq(#f.pump_deliveries, 1, "cleanup cannot replay the paste")
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains exact cleanup timer after stop " .. mode .. " (wrap-pause-paste-grace)", function()
			with_broker(function(f)
				helpers.assert_eq(f.text.wrap_selection("selected", "(", ")"), true)
				f.finish_broker()
				local next_timer = f.timer_new_calls + 1
				local field = mode == "false" and "timer_stop_failures_by_call"
					or mode == "nil" and "timer_stop_nils_by_call" or "timer_stop_throws_by_call"
				f.options[field] = { [next_timer] = 1 }
				helpers.assert_eq(f.text.pause_text_actions(), false)
				local cleanup = f.timers[#f.timers]
				local acquired = f.timer_new_calls
				f.expire_restore()
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "(selected)")
				helpers.assert_eq(cleanup.stop_calls, 1)
				helpers.assert_eq(f.text.resume_text_actions(), false)
				helpers.assert_eq(f.timer_new_calls, acquired,
					"refused cleanup must retain its exact candidate instead of acquiring a successor")
				f.expire_restore()
				helpers.assert_eq(cleanup.stop_calls, 2)
				helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
				helpers.assert_eq(f.text.pause_text_actions(), true)
				helpers.assert_eq(f.text.resume_text_actions(), true)
				helpers.assert_eq(#f.pump_deliveries, 1)
			end)
		end)
	end
end)
