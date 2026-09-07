--- tests/unit/ui/test_onboarding_javascript_delivery.lua

--- ==============================================================================
--- MODULE: Onboarding JavaScript Delivery
--- DESCRIPTION:
--- Drives wizard publications through native admission and asynchronous completion.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.onboarding_delivery_fixture")
local with_delivery, dispatch = fixture.with_delivery, fixture.dispatch


helpers.describe("onboarding JavaScript delivery", function()
	for _, action in ipairs({ "finish", "cancel" }) do
		helpers.it("(onboarding-js-delivery) retained " .. action .. " retries cleanup without another commit", function()
			with_delivery(function(_, state, pending, errors, evaluations, open)
				local persists = 0
				package.loaded["infra.i18n"].persist_locale = function() persists = persists + 1; return false end
				local old_receiver = state.receiver
				state.refused = true
				old_receiver({ body = { action = "finish", answers = { locale = "en" } } })
				helpers.assert_eq(persists, 1)
				helpers.assert_eq(state.deleted, 1)
				local error_count = #errors
				old_receiver({ body = { action = "previewLocale", locale = "fr" } })
				helpers.assert_eq(#evaluations, 0)
				state.refused = false
				old_receiver({ body = { action = action, answers = { locale = "en" } } })
				helpers.assert_eq(state.deleted, 2)
				helpers.assert_eq(persists, 1, "cleanup must not restart the configuration transaction")
				helpers.assert_eq(#pending, 0, "cleanup must not schedule a reload")
				helpers.assert_eq(#errors, error_count)
				open()
				old_receiver({ body = { action = action, answers = { locale = "en" } } })
				helpers.assert_eq(state.deleted, 2, "retired cleanup bridge cannot delete the replacement")
				helpers.assert_eq(persists, 1)
			end)
		end)
	end
	for _, route in ipairs({ "previewLocale", "ready", "pickConfigDir", "loadExistingConfig" }) do
		for _, mode in ipairs({ "throw", "nil", "false", "async", "success", "sync_refused" }) do
			helpers.it("(onboarding-js-delivery) " .. route .. " " .. mode, function()
				with_delivery(function(_, state, pending, errors, evaluations)
					state.submit = function(self, _, done)
						if mode == "throw" then error("PRIVATE_NATIVE_DETAIL") end
						if mode == "nil" then return nil end
						if mode == "false" then return false end
						if mode == "sync_refused" then if done then done(nil) end; return nil end
						return self
					end
					dispatch(route, state, pending)
					helpers.assert_eq(#evaluations, 1)
					local methods = { previewLocale = "applyStrings", ready = "initData",
						pickConfigDir = "setConfigDir", loadExistingConfig = "applyExistingAnswers" }
					helpers.assert_true(evaluations[1].code:find("window." .. methods[route] .. "(", 1, true) ~= nil)
					if route == "previewLocale" then helpers.assert_eq(state.payload.locale, "fr") end
					if route == "ready" then helpers.assert_eq(state.payload.answers.locale, "en") end
					if route == "pickConfigDir" then helpers.assert_eq(state.payload, "/virtual/chosen/") end
					if route == "loadExistingConfig" then helpers.assert_eq(state.payload.use_metrics, false) end
					if mode == "success" or mode == "async" then
						helpers.assert_eq(#errors, 0)
						helpers.assert_type(evaluations[1].done, "function")
						evaluations[1].done(nil, mode == "async" and { message = "PRIVATE_NATIVE_DETAIL" } or nil)
						evaluations[1].done(nil, { message = "PRIVATE_NATIVE_DETAIL" })
					end
					helpers.assert_eq(#errors, mode == "success" and 0 or 1)
					for _, message in ipairs(errors) do
						helpers.assert_nil(message:find("PRIVATE_NATIVE_DETAIL", 1, true))
						helpers.assert_nil(message:find("/virtual/", 1, true))
					end
				end)
			end)
		end
	end
	for _, route in ipairs({ "previewLocale", "ready", "pickConfigDir", "loadExistingConfig" }) do
		helpers.it("(onboarding-js-delivery) " .. route .. " encoding failure remains visible", function()
			with_delivery(function(_, state, pending, errors, evaluations)
				state.encode = function() error("PRIVATE_ENCODING_DETAIL") end
				dispatch(route, state, pending)
				helpers.assert_eq(#evaluations, 0)
				helpers.assert_eq(#errors, 1)
				helpers.assert_nil(errors[1]:find("PRIVATE_ENCODING_DETAIL", 1, true))
			end)
		end)
	end
	helpers.it("(onboarding-js-delivery) encoding reentry cannot submit the old payload to a successor", function()
		with_delivery(function(_, state, pending, errors, evaluations, open)
			state.encode = function()
				state.encode = nil
				state.view.options.on_close()
				open()
				return "{}"
			end
			dispatch("previewLocale", state, pending)
			helpers.assert_eq(#evaluations, 0)
			helpers.assert_eq(#errors, 0)
			dispatch("previewLocale", state, pending)
			helpers.assert_eq(#evaluations, 1)
		end)
	end)
	helpers.it("(onboarding-js-delivery) retired completion and queued ready cannot target a successor", function()
		with_delivery(function(_, state, pending, errors, evaluations, open)
			dispatch("previewLocale", state, pending)
			local old_completion = evaluations[1].done
			helpers.assert_type(old_completion, "function")
			state.receiver({ body = { action = "ready" } })
			local old_ready = pending[#pending]
			state.view.options.on_close()
			open()
			old_ready()
			old_completion(nil, { message = "PRIVATE_NATIVE_DETAIL" })
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(#errors, 0)
		end)
	end)
	helpers.it("(onboarding-js-delivery) repeated failures are bounded per owner despite logging reentry", function()
		with_delivery(function(_, state, pending, errors, evaluations, open)
			dispatch("previewLocale", state, pending)
			helpers.assert_type(evaluations[1].done, "function")
			state.on_error = function()
				state.on_error = nil
				state.view.options.on_close()
				open()
			end
			evaluations[1].done(nil, {})
			evaluations[1].done(nil, {})
			helpers.assert_eq(#errors, 1)
			for _ = 1, 3 do
				dispatch("previewLocale", state, pending)
				evaluations[#evaluations].done(nil, {})
			end
			helpers.assert_eq(#errors, 2, "the successor must report its own first failure only")
		end)
	end)
end)
