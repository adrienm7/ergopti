--- tests/unit/ui/test_typing_publication_order.lua

--- ==============================================================================
--- MODULE: Typing Publication Order Tests
--- DESCRIPTION:
--- Captures producer revisions before delayed native readiness callbacks resolve.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_delivery = require("tests.support.typing_delivery_fixture")

helpers.describe("typing publication ordering", function()
	helpers.it("(typing-publication-order) reentrant read cannot replace a newer pending snapshot", function()
		with_delivery(function(dashboard, _, timers, _, _, evaluations)
			local entered = false
			package.loaded["modules.keylogger.log_manager"].get_sqlite_path = function()
				if not entered then
					entered = true
					dashboard.push_live_update(); timers[#timers]()
				end
				return nil
			end
			dashboard.push_live_update(); timers[#timers]()
			helpers.assert_eq(#evaluations, 1)
			evaluations[1].done("function", nil)
			helpers.assert_true(evaluations[2].code:find('"manifest_revision":2', 1, true) ~= nil)
		end)
	end)
	helpers.it("(typing-publication-order) admission failure log reentry owns a successor chain", function()
		with_delivery(function(dashboard, context, timers, errors, _, evaluations)
			local native = context.webview.evaluateJavaScript
			local first = true
			context.webview.evaluateJavaScript = function(self, code, done)
				if first then first = false; return nil end
				return native(self, code, done)
			end
			local capture = package.loaded["infra.logger"].error
			package.loaded["infra.logger"].error = function(...)
				capture(...)
				dashboard.push_live_update(); timers[#timers]()
			end
			dashboard.push_live_update(); timers[#timers]()
			helpers.assert_eq(#errors, 1)
			helpers.assert_eq(#evaluations, 1)
			evaluations[1].done("function", nil)
			helpers.assert_true(evaluations[2].code:find('"manifest_revision":2', 1, true) ~= nil)
		end)
	end)
	helpers.it("(typing-publication-order) failed live readiness releases only its exact chain", function()
		with_delivery(function(dashboard, _, timers, errors, _, evaluations)
			dashboard.push_live_update(); timers[#timers]()
			local old = evaluations[1].done
			old(nil, {})
			dashboard.push_live_update(); timers[#timers]()
			helpers.assert_eq(#evaluations, 2)
			old(nil, {})
			dashboard.push_live_update(); timers[#timers]()
			helpers.assert_eq(#evaluations, 2)
			evaluations[2].done("function", nil)
			helpers.assert_true(evaluations[3].code:find('"manifest_revision":3', 1, true) ~= nil)
			helpers.assert_eq(#errors, 1)
		end)
	end)
	helpers.it("(typing-publication-order) pre-ready ingest burst owns one latest live readiness chain", function()
		with_delivery(function(dashboard, _, timers, _, _, evaluations)
			for _ = 1, 100 do
				dashboard.push_live_update(); timers[#timers]()
			end
			helpers.assert_eq(#evaluations, 1)
			evaluations[1].done("function", nil)
			helpers.assert_eq(#evaluations, 2)
			helpers.assert_true(evaluations[2].code:find('"manifest_revision":100', 1, true) ~= nil)
		end)
	end)
	helpers.it("(typing-publication-order) unsupported frontend exhausts bounded readiness without legacy writes", function()
		with_delivery(function(dashboard, _, timers, errors, _, evaluations)
			dashboard.push_live_update(); timers[#timers]()
			for index = 1, 61 do
				helpers.assert_eq(#evaluations, index)
				helpers.assert_eq(evaluations[index].code, "typeof window.publishTypingMetricsData")
				evaluations[index].done("undefined", nil)
				if index < 61 then timers[#timers]() end
			end
			helpers.assert_eq(#evaluations, 61)
			helpers.assert_eq(#errors, 1)
		end)
	end)
	for _, outcome in ipairs({ "applied", "stale", "invalid" }) do
		helpers.it("(typing-publication-order) acknowledges " .. outcome .. " truthfully", function()
			with_delivery(function(_, _, timers, errors, successes, evaluations)
				local discarded = 0
				package.loaded["infra.logger"].debug = function(_, template)
					if template:find("stale publication", 1, true) then discarded = discarded + 1 end
				end
				timers[1](); timers[2]()
				evaluations[1].done("function", nil)
				if outcome == "applied" then evaluations[2].done(true, nil)
				elseif outcome == "stale" then evaluations[2].done(false, nil)
				else evaluations[2].done(nil, nil) end
				helpers.assert_eq(#successes, outcome == "applied" and 1 or 0)
				helpers.assert_eq(discarded, outcome == "stale" and 1 or 0)
				helpers.assert_eq(#errors, outcome == "invalid" and 1 or 0)
			end)
		end)
	end
	helpers.it("(typing-publication-order) readiness reordering retains captured producer revisions", function()
		with_delivery(function(dashboard, _, timers, _, _, evaluations)
			timers[1](); timers[2]()
			dashboard.push_live_update(); timers[#timers]()
			helpers.assert_eq(#evaluations, 2)
			evaluations[2].done("function", nil)
			evaluations[1].done("function", nil)
			helpers.assert_true(evaluations[3].code:find('"manifest_revision":2', 1, true) ~= nil)
			helpers.assert_nil(evaluations[3].code:find('"assets_revision"', 1, true))
			helpers.assert_true(evaluations[4].code:find('"manifest_revision":1,"assets_revision":1', 1, true) ~= nil)
		end)
	end)
	helpers.it("(typing-publication-order) live publication waits for revision-capable frontend", function()
		with_delivery(function(dashboard, _, timers, _, _, evaluations)
			helpers.assert_eq(dashboard.push_live_update(), true)
			timers[#timers]()
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(evaluations[1].code, "typeof window.publishTypingMetricsData")
			evaluations[1].done("undefined", nil)
			helpers.assert_eq(#evaluations, 1)
			timers[#timers]()
			evaluations[2].done("function", nil)
			helpers.assert_true(evaluations[3].code:find("publishTypingMetricsData", 1, true) ~= nil)
		end)
	end)
end)
