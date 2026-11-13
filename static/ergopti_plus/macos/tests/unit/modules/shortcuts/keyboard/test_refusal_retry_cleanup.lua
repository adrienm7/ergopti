--- tests/unit/modules/shortcuts/keyboard/test_refusal_retry_cleanup.lua

--- ==============================================================================
--- MODULE: Shortcut Retry Cleanup
--- DESCRIPTION:
--- A refused native timer stop remains owned until a later exact retry settles.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("shortcut retry timer cleanup", function()
	for _, failure in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the same timer after cancellation returns " .. failure, function()
			helpers.with_fresh_modules({ "modules.shortcuts.refusal_retry", "core.events.timer_scheduler",
				"infra.logger" }, function()
				local handles, calls, may_stop = {}, {}, false
				package.loaded["infra.logger"] = helpers.make_logger_stub()
				package.loaded["core.events.timer_scheduler"] = {
					after = function(_, callback)
						local handle = { callback = callback }
						handles[#handles + 1] = handle
						return handle, true
					end,
					cancel = function(handle)
						calls[#calls + 1] = handle
						if may_stop then return true end
						if failure == "throw" then error("native stop failed") end
						if failure == "false" then return false end
						return nil
					end,
				}
				local attempts = 0
				local series = require("modules.shortcuts.refusal_retry").new("test", function()
					attempts = attempts + 1
					return true
				end)
				helpers.assert_eq(series.schedule(), true)
				helpers.assert_eq(series.cancel(), false)
				helpers.assert_eq(series.schedule(), false, "a successor cannot hide pending cleanup")
				helpers.assert_eq(#handles, 1)
				helpers.assert_eq(calls, { handles[1], handles[1] })
				handles[1].callback()
				helpers.assert_eq(attempts, 0, "the refused timer's callback was fenced")
				may_stop = true
				helpers.assert_eq(series.schedule(), true)
				helpers.assert_eq(calls[3], handles[1], "retry the original native timer")
				helpers.assert_eq(#handles, 2)
				helpers.assert_eq(series.cancel(), true)
			end)
		end)
	end

	for _, boundary in ipairs({ "start", "fire" }) do
		helpers.it("retains native cleanup debt after a timer " .. boundary .. " refusal", function()
			helpers.with_fresh_modules({ "modules.shortcuts.refusal_retry", "core.events.timer_scheduler",
				"infra.logger" }, function()
				local handles, calls, may_stop = {}, {}, false
				package.loaded["infra.logger"] = helpers.make_logger_stub()
				package.loaded["core.events.timer_scheduler"] = {
					after = function(_, callback)
						local handle = { callback = callback, timer = {} }
						handles[#handles + 1] = handle
						return handle, boundary ~= "start"
					end,
					cancel = function(handle)
						calls[#calls + 1] = handle
						if not may_stop then return false end
						handle.timer = nil
						return true
					end,
				}
				local series = require("modules.shortcuts.refusal_retry").new("test", function() return true end)
				helpers.assert_eq(series.schedule(), boundary ~= "start")
				if boundary == "fire" then handles[1].callback() end
				helpers.assert_eq(series.cancel(), false)
				helpers.assert_eq(series.schedule(), false)
				helpers.assert_eq(#handles, 1, "no successor while native cleanup is unproved")
				may_stop = true
				helpers.assert_eq(series.cancel(), true)
				helpers.assert_eq(calls[#calls], handles[1], "the exact timer remains retryable")
			end)
		end)
	end
end)
