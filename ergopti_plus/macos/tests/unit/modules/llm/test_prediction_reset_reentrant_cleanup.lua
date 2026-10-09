--- tests/unit/modules/llm/test_prediction_reset_reentrant_cleanup.lua

--- ==============================================================================
--- MODULE: Prediction Reset Reentrant Cleanup
--- DESCRIPTION:
--- Exercises real pipeline ownership when cleanup boundaries synchronously admit
--- a successor request. An obsolete reset must not cancel or hide its successor.
--- ==============================================================================

local helpers = require("tests.helpers")
local Pipeline = require("tests.support.prediction_pipeline")


local function deliver(callback)
	callback({ {
		to_type = " completion", deletes = 0,
		chunks = { { type = "insert", text = " completion" } }, nw = "",
	} }, 25, true, false)
end


helpers.describe("prediction reset cleanup ownership", function()
	for _, boundary in ipairs({ "chain timing", "silent hide", "hide error", "watchdog stop",
		"backend cancel", "profile warmup stop", "cancellation info" }) do
		helpers.it("preserves successor at " .. boundary .. " (reset-cleanup-owner)", function()
			local reentered = false
			local function dispatch_successor(fixture)
				if reentered then return end
				reentered = true
				fixture.engine.perform_check(true)
			end
			local fixture = Pipeline.load({ render_success = true, capture_info = true,
				on_log = function(active, record)
					if boundary == "hide error"
						and record.message:find("Prediction reset hide attempt", 1, true) then
						dispatch_successor(active)
					end
					if boundary == "cancellation info" and record.level == "info"
						and record.message:find("LLM request cancelled", 1, true) then
						dispatch_successor(active)
					end
				end })
			fixture.engine.perform_check(true)
			local stale_final = fixture.on_success
			local tooltip = package.loaded["ui.tooltip"]
			local core = package.loaded["modules.llm"]
			local cancelled_fetches = {}
			local original_cancel = core.cancel_streaming
			core.cancel_streaming = function()
				cancelled_fetches[#cancelled_fetches + 1] = fixture.fetches
				local result = original_cancel()
				if boundary == "backend cancel" then dispatch_successor(fixture) end
				return result
			end
			if boundary == "chain timing" then
				tooltip.mark_chain_complete = function() dispatch_successor(fixture); return true end
			elseif boundary == "silent hide" then
				tooltip.hide_forced_silent = function() dispatch_successor(fixture); return true end
			elseif boundary == "hide error" then
				tooltip.hide_forced_silent = function() return false end
			elseif boundary == "watchdog stop" then
				local original_stop = fixture.handler.stop_watchdog
				fixture.handler.stop_watchdog = function()
					local result = original_stop()
					dispatch_successor(fixture)
					return result
				end
			elseif boundary == "profile warmup stop" then
				core.pause_deferred_profile_warmup = function() dispatch_successor(fixture); return true end
			end
			local hidden_fetches = {}
			for _, name in ipairs({ "hide_forced_silent", "hide_forced", "hide" }) do
				local original_hide = tooltip[name]
				if original_hide then
					tooltip[name] = function(...)
						hidden_fetches[#hidden_fetches + 1] = fixture.fetches
						return original_hide(...)
					end
				end
			end
			local reset_result = fixture.engine.reset({ suppress_telemetry = boundary == "profile warmup stop" })
			helpers.assert_true(reentered, "the named cleanup boundary must admit a successor")
			helpers.assert_eq(fixture.fetches, 2)
			for _, fetches in ipairs(cancelled_fetches) do
				helpers.assert_eq(fetches, 1, "predecessor cleanup must never cancel after successor dispatch")
			end
			for _, fetches in ipairs(hidden_fetches) do
				helpers.assert_eq(fetches, 1, "predecessor cleanup must never hide after successor dispatch")
			end
			helpers.assert_eq(reset_result, false, "superseded cleanup must not claim an uninterrupted commit")
			deliver(stale_final)
			helpers.assert_eq(fixture.prediction_renders, 0)
			deliver(fixture.on_success)
			helpers.assert_true(fixture.engine.is_visible(), "successor callback must retain authority")
			helpers.assert_eq(fixture.prediction_renders, 1)
		end)
	end

	helpers.it("revokes old callbacks before chain timing (reset-cleanup-owner)", function()
		local fixture = Pipeline.load({ render_success = true })
		fixture.engine.perform_check(true)
		local stale_final = fixture.on_success
		local reentered = false
		package.loaded["ui.tooltip"].mark_chain_complete = function()
			if reentered then return end
			reentered = true
			deliver(stale_final)
		end
		helpers.assert_true(fixture.engine.reset())
		helpers.assert_true(reentered)
		helpers.assert_eq(fixture.prediction_renders, 0, "reset authority must be revoked before its first native call")
	end)
end)
