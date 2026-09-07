--- tests/unit/ui/test_onboarding_javascript_delivery.lua

--- ==============================================================================
--- MODULE: Onboarding JavaScript Delivery
--- DESCRIPTION:
--- Drives wizard publications through native admission and asynchronous completion.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.dashboard_window_fixture")

local function with_delivery(callback)
	helpers.with_fresh_modules({ "ui.menu.menu_paths", "infra.toml.codec", "infra.toml.writer",
		"adapters.file_system" }, function()
		package.loaded["ui.menu.menu_paths"] = {
			get_config_dir = function() return "/virtual/current" end,
			get_default_config_dir = function() return "/virtual/default" end,
		}
		package.loaded["infra.toml.codec"] = { decode = function() return {} end }
		with_window("ui.onboarding", function(onboarding, state)
			local pending, errors, evaluations = {}, {}, {}
			local i18n = package.loaded["infra.i18n"]
			i18n.get_locale = function() return "en" end
			i18n.format = function(key) return key end
			i18n.get_sorted_locales = function() return {} end
			hs.json.encode = function(payload)
				state.payload = payload
				if state.encode then return state.encode(payload) end
				return "{}"
			end
			hs.fs.attributes = function() return {} end
			hs.fs.pathToAbsolute = function(path) return path end
			hs.osascript.applescript = function() return true, "/virtual/chosen", "/virtual/chosen" end
			package.loaded["infra.deferred_work"].after = function(_, fn)
				pending[#pending + 1] = fn
				return true
			end
			package.loaded["infra.logger"].error = function(_, message, ...)
				errors[#errors + 1] = string.format(message, ...)
				if state.on_error then state.on_error() end
			end
			local original_open = io.open
			local ok, err = xpcall(function()
				io.open = function(_, mode)
					helpers.assert_eq(mode, "r", "fixture must never authorize config writes")
					return { read = function() return "fixture" end, close = function() end }
				end
				local function open()
					helpers.assert_true(onboarding.run("/virtual/config.toml"))
					state.view.evaluateJavaScript = function(self, code, done)
						evaluations[#evaluations + 1] = { code = code, done = done, view = self }
						if state.submit then return state.submit(self, code, done) end
						return self
					end
				end
				open()
				callback(onboarding, state, pending, errors, evaluations, open)
			end, debug.traceback)
			io.open = original_open
			if not ok then error(err, 0) end
		end)
	end)
end

local function dispatch(route, state, pending)
	local body = {
		previewLocale = { action = "previewLocale", locale = "fr" },
		ready = { action = "ready" },
		pickConfigDir = { action = "pickConfigDir", current = "/virtual/current" },
		loadExistingConfig = { action = "loadExistingConfig", config_dir = "/virtual/chosen" },
	}
	state.receiver({ body = body[route] })
	if route == "ready" then pending[#pending]() end
end

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
