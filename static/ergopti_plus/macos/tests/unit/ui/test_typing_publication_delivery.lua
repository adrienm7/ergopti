--- tests/unit/ui/test_typing_publication_delivery.lua

--- ==============================================================================
--- MODULE: Typing Publication Delivery Tests
--- DESCRIPTION:
--- Observes completion rather than admission for each dashboard data publication.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_delivery = require("tests.support.typing_delivery_fixture")

helpers.describe("typing publication delivery", function()
	for _, route in ipairs({ "manifest", "cache", "live", "reopen" }) do
		for _, outcome in ipairs({ "success", "error", "retired" }) do
			helpers.it("(typing-publication-delivery) " .. route .. " " .. outcome, function()
				with_delivery(function(dashboard, context, timers, errors, successes, evaluations, filesystem)
					if route == "manifest" then
						timers[1](); timers[2]()
					elseif route == "cache" then
						filesystem.read_with_status = function() return "cached", "ok" end
						package.loaded["hs.json"].decode = function() return { manifest = "{}" } end
						timers[1]()
					elseif route == "live" then
						helpers.assert_eq(dashboard.push_live_update(), true)
						timers[#timers]()
					else helpers.assert_eq(dashboard.show(), true) end
					helpers.assert_eq(#evaluations, 1)
					if route == "manifest" or route == "cache" then
						evaluations[1].done("function", nil)
						helpers.assert_eq(#evaluations, 2)
					end
					helpers.assert_eq(#successes, 0)
					local completion = evaluations[#evaluations].done
					if outcome == "retired" then context.on_close() end
					completion(nil, outcome == "error" and { localizedDescription = "PRIVATE_DETAIL" } or nil)
					helpers.assert_eq(#errors, outcome == "error" and 1 or 0, table.concat(errors, " | "))
					local expected_success = outcome == "success" and (route == "manifest" or route == "cache")
					helpers.assert_eq(#successes, expected_success and 1 or 0)
					for _, message in ipairs(errors) do helpers.assert_nil(message:find("PRIVATE_DETAIL", 1, true)) end
				end)
			end)
		end
	end
end)

helpers.describe("typing request response delivery", function()
	for _, route in ipairs({ "manifest", "cache" }) do
		for _, mode in ipairs({ "nil", "throw", "execution_error" }) do
			helpers.it("(typing-publication-delivery) " .. route .. " readiness " .. mode, function()
				with_delivery(function(_, context, timers, errors, successes, evaluations, filesystem)
					context.webview.evaluateJavaScript = function(self, _, done)
						if mode == "throw" then error("PRIVATE_DETAIL") end
						if mode == "nil" then return nil end
						done(nil, {})
						return self
					end
					if route == "cache" then
						filesystem.read_with_status = function() return "cached", "ok" end
						package.loaded["hs.json"].decode = function() return { manifest = "{}" } end
					end
					timers[1]()
					if route == "manifest" then timers[2]() end
					helpers.assert_eq(#errors, 1)
					helpers.assert_eq(#successes, 0)
					helpers.assert_eq(#evaluations, 0)
				end)
			end)
		end
	end
	for _, site in ipairs({ "reset", "range" }) do
		helpers.it("(typing-publication-delivery) " .. site .. " execution refusal is visible", function()
			with_delivery(function(_, context, _, errors, _, evaluations)
				package.loaded["hs.json"].decode = function()
					return { start_date = "2026-09-01", end_date = "2026-09-07", apps = {}, request_id = 1 }
				end
				context.poll()
				evaluations[1].done("request", nil)
				helpers.assert_eq(#evaluations, 3)
				helpers.assert_true(evaluations[2].code:find("_lua_request = null", 1, true) ~= nil)
				helpers.assert_true(evaluations[3].code:find("receive_range_data", 1, true) ~= nil)
				evaluations[site == "reset" and 2 or 3].done(nil, {})
				helpers.assert_eq(#errors, 1)
			end)
		end)
	end
	helpers.it("(typing-publication-delivery) reopen logging reentry cannot evaluate retired window", function()
		with_delivery(function(dashboard, context, _, _, _, evaluations)
			package.loaded["infra.logger"].debug = function(_, template)
				if template:find("already open", 1, true) then context.on_close() end
			end
			helpers.assert_eq(dashboard.show(), false)
			helpers.assert_eq(#evaluations, 0)
		end)
	end)
end)
