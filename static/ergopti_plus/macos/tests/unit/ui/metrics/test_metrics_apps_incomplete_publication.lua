--- tests/unit/ui/metrics/test_metrics_apps_incomplete_publication.lua

--- ==============================================================================
--- MODULE: Apps Dashboard Incomplete Publication Regression
--- DESCRIPTION:
--- A missing store or an incomplete manifest read is published flagged
--- incomplete and never saved as the next open's snapshot, as Windows and
--- Linux answer (MET-11). The host used to publish nothing, so the page kept
--- its disk snapshot, or stayed empty, without a notice.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_delivery = require("tests.support.metrics_delivery_fixture")

--- Delivers the readiness probe, then every queued slice of the refresh.
--- @param evaluations table Observed JavaScript submissions.
--- @param pending table Queued timer turns.
--- @return string code The publication the page executed.
local function publish(evaluations, pending)
	helpers.assert_eq(evaluations[1].code, "typeof window.publishMetricsAppsData")
	evaluations[1].done("function")
	helpers.assert_true(evaluations[2] ~= nil, "the refresh publishes its manifest")
	local code = evaluations[2].code
	evaluations[2].done(true)
	while #pending > 0 do table.remove(pending)() end
	return code
end

helpers.describe("metrics apps incomplete publication", function()
	for _, case in ipairs({
		{ name = "a missing store", store = { missing = true } },
		{ name = "an incomplete read", store = { complete = false } },
	}) do
		helpers.it("(apps-incomplete-publication, met-11) " .. case.name .. " is shown incomplete, not saved", function()
			with_delivery(false, function(_, state, evaluations, errors, _, pending)
				local code = publish(evaluations, pending)
				helpers.assert_true(code:find("manifest_incomplete:true", 1, true) ~= nil,
					"the page is told the history is incomplete")
				helpers.assert_eq(state.disk_writes, 0, "an incomplete manifest never becomes the snapshot")
				helpers.assert_eq(#errors, 0)
			end, case.store)
		end)
	end
	helpers.it("(apps-incomplete-publication, met-11) a complete read is saved and says nothing", function()
		with_delivery(false, function(_, state, evaluations, _, _, pending)
			local code = publish(evaluations, pending)
			helpers.assert_eq(code:find("manifest_incomplete", 1, true), nil)
			helpers.assert_true(state.disk_writes > 0, "a complete read becomes the snapshot")
		end)
	end)
end)
