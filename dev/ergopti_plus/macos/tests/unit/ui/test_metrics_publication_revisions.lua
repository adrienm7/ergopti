--- tests/unit/ui/test_metrics_publication_revisions.lua

--- ==============================================================================
--- MODULE: Metrics Snapshot Publication Revisions
--- DESCRIPTION:
--- Checks real producer ordering metadata and fail-closed frontend capability probing.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_delivery = require("tests.support.metrics_delivery_fixture")

local function revisions(code)
	local manifest, categories = code:match("manifest_revision:(%d+),categories_revision:(%d+)")
	helpers.assert_true(manifest ~= nil and categories ~= nil, "actual publication must carry both revisions")
	return tonumber(manifest), tonumber(categories)
end

helpers.describe("metrics publication revisions", function()
	for _, outcome in ipairs({ "obsolete", "missing", "invalid" }) do
		helpers.it("(metrics-publication-order) reports execution outcome " .. outcome, function()
			with_delivery(false, function(_, _, evaluations, errors, successes)
				local decisions = {}
				package.loaded["infra.logger"].debug = function(_, message, ...)
					decisions[#decisions + 1] = string.format(message, ...)
				end
				evaluations[1].done("function")
				local result
				if outcome == "obsolete" then result = false elseif outcome == "invalid" then result = "PRIVATE_PAYLOAD" end
				evaluations[2].done(result)
				helpers.assert_eq(#successes, 0)
				if outcome == "obsolete" then
					helpers.assert_eq(#errors, 0)
					helpers.assert_eq(#decisions, 1)
					helpers.assert_true(decisions[1]:find("obsolete", 1, true) ~= nil)
				else
					helpers.assert_eq(#errors, 1)
					helpers.assert_true(errors[1]:find("publication result invalid", 1, true) ~= nil)
					helpers.assert_eq(errors[1]:find("PRIVATE_PAYLOAD", 1, true), nil)
				end
			end)
		end)
	end
	helpers.it("(metrics-publication-order) cache and fresh snapshots keep independent priorities", function()
		with_delivery(true, function(_, _, evaluations, _, _, pending)
			local cache_ready = evaluations[1].done
			pending[#pending]()
			local fresh_ready = evaluations[2].done
			fresh_ready("function")
			local fresh_manifest, fresh_categories = revisions(evaluations[3].code)
			helpers.assert_true(fresh_manifest > 0 and fresh_categories > 0)
			cache_ready("function")
			local cache_manifest, cache_categories = revisions(evaluations[4].code)
			helpers.assert_eq(cache_manifest, 0)
			helpers.assert_eq(cache_categories, 0)
		end)
	end)
	helpers.it("(metrics-publication-order) request order does not depend on completion order", function()
		with_delivery(false, function(dashboard, _, evaluations, _, _, pending)
			local old_ready = evaluations[1].done
			helpers.assert_true(dashboard.push_live_update())
			pending[#pending]()
			evaluations[2].done("function")
			local newer = revisions(evaluations[3].code)
			old_ready("function")
			local older = revisions(evaluations[4].code)
			helpers.assert_true(newer > older)
		end)
	end)
	for _, cached in ipairs({ false, true }) do
		helpers.it("(metrics-publication-order) missing revision capability remains bounded, cache=" .. tostring(cached), function()
			with_delivery(cached, function(_, _, evaluations, errors, successes, pending)
				local steps = 0
				while #errors == 0 and steps < 100 do
					steps = steps + 1
					local count = #pending
					evaluations[#evaluations].done("undefined")
					if #pending > count then pending[#pending]() end
				end
				helpers.assert_eq(#errors, 1)
				helpers.assert_true(errors[1]:find("readiness exhausted", 1, true) ~= nil)
				helpers.assert_eq(#successes, 0)
				for _, evaluation in ipairs(evaluations) do
					helpers.assert_eq(evaluation.code, "typeof window.publishMetricsAppsData")
				end
			end)
		end)
	end
end)
