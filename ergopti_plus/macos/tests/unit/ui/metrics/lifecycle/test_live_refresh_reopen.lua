--- tests/unit/ui/metrics/lifecycle/test_live_refresh_reopen.lua

--- ==============================================================================
--- MODULE: Typing Metrics Live Refresh Reopen Regression
--- DESCRIPTION:
--- Drives ingest notifications through the real dashboard and paced jobs. A
--- native close must retire the queued refresh reservation with its timer,
--- so a successor window can publish fresh metrics after later ingests.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_delivery = require("tests.support.typing_delivery_fixture")

--- Fires a live continuation and its real paced projection, then accepts delivery.
--- @param context table Dashboard fixture context.
--- @param timers table Owned scheduler callbacks.
--- @param evaluations table Recorded native JavaScript submissions.
local function publish_live(context, timers, evaluations)
	local before = #evaluations
	timers[#timers]()
	context.settle_jobs()
	helpers.assert_eq(#evaluations, before + 1, "live projection must reach page readiness")
	helpers.assert_eq(evaluations[#evaluations].code, "typeof window.publishTypingMetricsData")
	evaluations[#evaluations].done("function")
	helpers.assert_eq(#evaluations, before + 2, "ready page must receive the live manifest")
	helpers.assert_true(evaluations[#evaluations].code:find(
		'window.publishTypingMetricsData({"manifest":{}}', 1, true) == 1)
	evaluations[#evaluations].done(true)
end

helpers.describe("typing metrics live refresh reservation lifecycle", function()
	for _, mode in ipairs({ "native close", "explicit close" }) do
		helpers.it("publishes the next ingest after " .. mode .. " cancels a queued refresh", function()
			with_delivery(function(dashboard, context, timers, errors, _, evaluations)
				context.on_ingest()
				helpers.assert_true(dashboard._pending_full_refresh)
				if mode == "native close" then context.on_close()
				else helpers.assert_true(dashboard.close()) end
				helpers.assert_nil(dashboard._wv)
				helpers.assert_true(dashboard.show())
				local before = #timers
				context.on_ingest()
				helpers.assert_eq(#timers, before + 1,
					"the successor window must reserve its own live continuation")
				publish_live(context, timers, evaluations)
				helpers.assert_eq(#errors, 0)
			end)
		end)
	end

	helpers.it("keeps same-window ingest coalescing and rearms after publication", function()
		with_delivery(function(dashboard, context, timers, errors, _, evaluations)
			local before = #timers
			context.on_ingest()
			context.on_ingest()
			helpers.assert_eq(#timers, before + 1, "one active window coalesces repeated ingest signals")
			publish_live(context, timers, evaluations)
			helpers.assert_eq(dashboard._pending_full_refresh, false)
			before = #timers
			context.on_ingest()
			helpers.assert_eq(#timers, before + 1, "a completed continuation releases its reservation")
			publish_live(context, timers, evaluations)
			helpers.assert_eq(#errors, 0)
		end)
	end)

	helpers.it("ignores a retired timer and native close notification after reopening", function()
		with_delivery(function(dashboard, context, timers, errors, _, evaluations)
			context.on_ingest()
			local retired_timer, retired_close = timers[#timers], context.on_close
			retired_close()
			helpers.assert_true(dashboard.show())
			local before = #timers
			context.on_ingest()
			helpers.assert_eq(#timers, before + 1, "a successor must accept its own ingest")
			local current_view = dashboard._wv
			-- Native callbacks already queued before cancellation may still arrive.
			retired_timer()
			retired_close()
			helpers.assert_true(dashboard._wv == current_view)
			helpers.assert_eq(dashboard._pending_full_refresh, true,
				"retired callbacks cannot release the successor's reservation")
			context.on_ingest()
			helpers.assert_eq(#timers, before + 1, "the successor still coalesces its pending continuation")
			publish_live(context, timers, evaluations)
			helpers.assert_eq(#errors, 0)
		end)
	end)
end)
