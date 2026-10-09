--- tests/unit/ui/test_metrics_javascript_delivery.lua

--- ==============================================================================
--- MODULE: Metrics JavaScript Delivery Boundaries
--- DESCRIPTION:
--- Drives real fresh and cached publication through native submission and completion.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_delivery = require("tests.support.metrics_delivery_fixture")


helpers.describe("metrics JavaScript delivery", function()
	for _, mode in ipairs({ "nil", "async", "success", "stale", "invalid_result" }) do
		helpers.it("(metrics-js-delivery) category publication " .. mode, function()
			with_delivery(false, function(dashboard, state, evaluations, errors)
				local choose
				hs.chooser = {}
				hs.chooser.new = function(callback)
					choose = callback
					local chooser = {}
					for _, method in ipairs({ "placeholderText", "choices", "searchSubText", "show", "delete" }) do
						chooser[method] = function(self) return self end
					end
					return chooser
				end
				package.loaded["infra.dialog_util"].text_prompt = function() return "button.ok", "1" end
				package.loaded["adapters.file_system"].write_if_unchanged = function() return true end
				state.submit = function(self) if mode ~= "nil" then return self end end
				helpers.assert_true(dashboard.prompt_category("Example", "Old", 0))
				choose({ _kind = "pick", _value = "New" })
				helpers.assert_eq(#evaluations, 2)
				helpers.assert_true(evaluations[2].code:find("publishMetricsAppsCategories", 1, true) ~= nil)
				if mode ~= "nil" then
					local result = true
					if mode == "stale" then result = false elseif mode == "invalid_result" then result = nil end
					evaluations[2].done(result, mode == "async" and { message = "PRIVATE_PAYLOAD" } or nil)
				end
				helpers.assert_eq(#errors, (mode == "success" or mode == "stale") and 0 or 1)
				for _, message in ipairs(errors) do helpers.assert_eq(message:find("PRIVATE_PAYLOAD", 1, true), nil) end
			end)
		end)
	end
	helpers.it("(metrics-js-delivery) synchronous completion cannot precede native admission", function()
		with_delivery(false, function(_, state, evaluations, errors, successes)
			state.submit = function(_, _, done) done(nil); return nil end
			evaluations[1].done("function")
			helpers.assert_eq(#errors, 1)
			helpers.assert_eq(#successes, 0)
			evaluations[2].done(nil)
			helpers.assert_eq(#successes, 0)
		end)
	end)
	helpers.it("(metrics-js-delivery) old and duplicate completions cannot publish", function()
		with_delivery(false, function(dashboard, _, evaluations, errors, successes)
			evaluations[1].done("function")
			evaluations[1].done("function")
			helpers.assert_eq(#evaluations, 2)
			helpers.assert_true(dashboard.close())
			helpers.assert_true(dashboard.show())
			local count = #successes
			evaluations[2].done(nil)
			evaluations[2].done(nil, { message = "PRIVATE_PAYLOAD" })
			helpers.assert_eq(#errors, 0)
			helpers.assert_eq(#successes, count)
		end)
	end)
	helpers.it("(metrics-js-delivery) failure logging cannot transfer an old completion", function()
		with_delivery(false, function(dashboard, _, evaluations, errors, successes)
			evaluations[1].done("function")
			local logger = package.loaded["infra.logger"]
			local report = logger.error
			logger.error = function(...)
				report(...)
				helpers.assert_true(dashboard.close())
				helpers.assert_true(dashboard.show())
			end
			evaluations[2].done(nil, { message = "PRIVATE_PAYLOAD" })
			local count = #successes
			evaluations[2].done(nil)
			helpers.assert_eq(#errors, 1)
			helpers.assert_eq(#successes, count)
		end)
	end)
	for _, route in ipairs({ "fresh", "cache", "deferred fresh", "deferred cache" }) do
		local cached = route:find("cache", 1, true) ~= nil
		local deferred = route:find("deferred", 1, true) ~= nil
		for _, mode in ipairs({ "nil", "false", "throw", "async", "success", "probe_error" }) do
			helpers.it("(metrics-js-delivery) " .. route .. " mode=" .. mode, function()
				with_delivery(cached, function(_, state, evaluations, errors, successes, pending)
					if deferred then
						evaluations[1].done("undefined")
						helpers.assert_eq(#evaluations, 1, "missing capability must not invoke the old unversioned API")
						pending[#pending]()
						helpers.assert_eq(evaluations[2].code, "typeof window.publishMetricsAppsData")
					end
					if mode == "probe_error" then
						local count = #pending
						evaluations[#evaluations].done(nil, { message = "PRIVATE_PAYLOAD" })
						helpers.assert_eq(#errors, 1)
						helpers.assert_eq(#pending, count, "execution failure is not a readiness retry")
					else
						state.submit = function(self, code)
							if code:find("typeof", 1, true) == 1 then return self end
							if mode == "nil" then return nil end
							if mode == "false" then return false end
							if mode == "throw" then error("PRIVATE_PAYLOAD") end
							return self
						end
						evaluations[#evaluations].done("function")
						helpers.assert_eq(#successes, 0, "submission is not successful execution")
						if mode == "async" or mode == "success" then
							helpers.assert_type(evaluations[#evaluations].done, "function")
							evaluations[#evaluations].done(true, mode == "async" and { message = "PRIVATE_PAYLOAD" } or nil)
						end
						helpers.assert_eq(#errors, mode == "success" and 0 or 1)
						helpers.assert_eq(#successes, mode == "success" and 1 or 0)
					end
					for _, message in ipairs(errors) do helpers.assert_eq(message:find("PRIVATE_PAYLOAD", 1, true), nil) end
				end)
			end)
		end
	end
end)
