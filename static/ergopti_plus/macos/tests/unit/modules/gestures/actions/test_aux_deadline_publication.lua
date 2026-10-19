--- tests/unit/modules/gestures/actions/test_aux_deadline_publication.lua

--- ==============================================================================
--- MODULE: Auxiliary Deadline Publication Ownership
--- DESCRIPTION:
--- A due timeout can wait for exact native timer retirement. That continuation
--- retains cleanup ownership, never business authority across parent revocation.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs the real auxiliary owner and scheduler with one controllable native child.
local function with_owner(callback)
	helpers.with_stub_scope({ "modules.gestures.actions_aux_owner", "adapters.timer_scheduler",
		"adapters.shell_runner", "infra.timings", "infra.logger" }, function()
		local f = { timers = {}, outcomes = {}, settled = false, observers = {}, terminations = 0 }
		_G.hs = { timer = { new = function(delay, receive)
			local native = { delay = delay, active = false, refuse_stop = #f.timers == 0 }
			function native:start() self.active = true; return self end
			function native:running() return self.active end
			function native:stop()
				if self.refuse_stop then return false end
				self.active = false
				return self
			end
			function native:deliver() receive() end
			f.timers[#f.timers + 1] = native
			return native
		end } }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.timings"] = { sec = function(_, name)
			return name == "aux_shell_timeout_ms" and 10 or 0.1
		end }
		local child = {
			isSettled = function() return f.settled end,
			onSettled = function(receive) f.observers[#f.observers + 1] = receive; return true end,
			terminate = function() f.terminations = f.terminations + 1; return true, "pending" end,
		}
		package.loaded["adapters.shell_runner"] = { open = function(_, terminal)
			f.terminal = terminal
			return true, child
		end }
		f.owner = require("modules.gestures.actions_aux_owner")
		function f.start(parent)
			return f.owner.open("https://example.invalid", "deadline publication", function(ok)
				f.outcomes[#f.outcomes + 1] = ok
			end, parent)
		end
		function f.settle()
			f.settled = true
			f.terminal(true)
			for _, receive in ipairs(f.observers) do receive() end
		end
		callback(f)
	end)
end

helpers.describe("auxiliary deadline publication remains parent-bound", function()
	helpers.it("suppresses a due timeout after its parent pauses (aux-deadline-revoked)", function()
		with_owner(function(f)
			helpers.assert_true(f.start("gestures"))
			local deadline = f.timers[1]
			deadline:deliver()
			helpers.assert_eq(#f.outcomes, 0, "timeout waits for actual timer retirement")
			helpers.assert_eq(f.owner.pause("gestures"), false)
			deadline.refuse_stop = false
			deadline:deliver()
			helpers.assert_eq(#f.outcomes, 0, "retirement cannot restore a paused parent's business callback")
			helpers.assert_true(f.terminations > 0, "revocation must retain child cleanup")
			f.settle()
			helpers.assert_eq(#f.outcomes, 0, "late child completion cannot republish the revoked timeout")
			helpers.assert_eq(f.owner.has_pending("gestures"), false)
			helpers.assert_true(f.owner.resume("gestures"))
		end)
	end)

	helpers.it("publishes a live timeout exactly once after native retirement (aux-deadline-live)", function()
		with_owner(function(f)
			helpers.assert_true(f.start("gestures"))
			local deadline = f.timers[1]
			deadline:deliver()
			helpers.assert_eq(#f.outcomes, 0)
			deadline.refuse_stop = false
			deadline:deliver()
			helpers.assert_eq(f.outcomes, { false })
			deadline:deliver()
			f.settle()
			helpers.assert_eq(f.outcomes, { false })
			helpers.assert_eq(f.owner.has_pending("gestures"), false)
		end)
	end)

	helpers.it("preserves a sibling parent's due timeout (aux-deadline-sibling)", function()
		with_owner(function(f)
			helpers.assert_true(f.start("shortcut_bindings"))
			local deadline = f.timers[1]
			deadline:deliver()
			helpers.assert_true(f.owner.pause("gestures"))
			deadline.refuse_stop = false
			deadline:deliver()
			helpers.assert_eq(f.outcomes, { false })
			f.settle()
			helpers.assert_eq(f.owner.has_pending("shortcut_bindings"), false)
		end)
	end)
end)
