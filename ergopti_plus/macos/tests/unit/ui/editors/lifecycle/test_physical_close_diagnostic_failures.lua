--- tests/unit/ui/editors/lifecycle/test_physical_close_diagnostic_failures.lua

--- ==============================================================================
--- MODULE: Physical Diagnostic Failure Observations
--- DESCRIPTION:
--- Preserves independently withheld retirement facts from the actual diagnostic.
--- The controlled native boundary is never a substitute for Cocoa execution.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.physical_close_diagnostic_fixture")

helpers.describe("physical diagnostic retains incomplete native observations", function()
	helpers.it("keeps the healthy two-phase close contract unchanged", function()
		Fixture(nil, function(h)
			h.drain()
			assert(h.result.status == "ok", table.concat(h.result.errors, "\n"))
			assert(h.result.ax_user_close.exact_bridge_detach)
			assert(h.result.public_close.product_timer_retired)
			assert(h.result.failure_observation == nil)
		end)
	end)
	helpers.it("records a binding attempt even when its native boundary raises", function()
		Fixture("bind_throw", function(h)
			assert(h.result and h.result.status == "error")
			local observation = assert(h.result.failure_observation)
			assert(observation.phase == "ax_user_close.open")
			local case = observation.cases[1]
			assert(case.bind_attempts == 1 and not case.bind_acknowledged)
			assert(not case.view_observed and case.bridge_observed)
			assert(case.detach_attempts == 1 and case.detach_acknowledged)
		end)
	end)
	for _, blocked in ipairs({ "consumption", "detach", "detach_throw", "callback", "timer" }) do
		helpers.it("retains the refused " .. blocked .. " fact without claiming success", function()
			Fixture(blocked, function(h)
				h.drain()
				assert(h.result.status == "error")
				assert(h.result.errors[1]:find("deadline exceeded", 1, true))
				local observation = assert(h.result.failure_observation, "deadline must preserve measured facts")
				local explicit = blocked == "timer"
				assert(observation.phase == (explicit and "public_close.await_retirement" or "ax_user_close.await_retirement"))
				assert(#observation.cases == (explicit and 2 or 1))
				local case = observation.cases[#observation.cases]
				assert(case.name == (explicit and "public_close" or "ax_user_close"))
				assert(case.bind_attempts == 1 and case.bind_acknowledged)
				assert(case.native_delete_requests == 1 and #case.notifications >= 1)
				assert(case.notifications[1].action == "closing")
				assert(case.view_observed and case.bridge_observed and case.visible_before)
				assert(case.userdata_consumed == (blocked ~= "consumption"))
				assert(case.detach_acknowledged == (blocked == "callback"))
				assert(case.consumed_before_detach == (blocked == "detach" or blocked == "detach_throw" or blocked == "callback"))
				assert(case.callback_alive, "the withheld boundary still owns the actual callback")
				assert(case.timer_active_count == ((explicit or blocked == "consumption") and 1 or 0))
				assert(case.detach_attempts == ((blocked == "detach" or blocked == "detach_throw" or blocked == "callback") and 1 or 0))
				assert(h.result.observers_restored)
			end)
		end)
	end
end)
