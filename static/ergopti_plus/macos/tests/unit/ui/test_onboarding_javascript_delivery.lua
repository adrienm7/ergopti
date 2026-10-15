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
				old_receiver({ body = { action = "finish", answers = { locale = "en", config_dir = "", operations = {} } } })
				helpers.assert_eq(persists, 1)
				helpers.assert_eq(state.deleted, 1)
				local error_count = #errors
				old_receiver({ body = { action = "previewLocale", locale = "fr" } })
				helpers.assert_eq(#evaluations, 0)
				state.refused = false
				old_receiver({ body = { action = action, answers = { locale = "en", config_dir = "", operations = {} } } })
				helpers.assert_eq(state.deleted, 2)
				helpers.assert_eq(persists, 1, "cleanup must not restart the configuration transaction")
				helpers.assert_eq(#pending, 0, "cleanup must not schedule a reload")
				helpers.assert_eq(#errors, error_count)
				open()
				old_receiver({ body = { action = action, answers = { locale = "en", config_dir = "", operations = {} } } })
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
						pickConfigDir = "setConfigDir", loadExistingConfig = "applyCurrentValues" }
					helpers.assert_true(evaluations[1].code:find("window." .. methods[route] .. "(", 1, true) ~= nil)
					if route == "previewLocale" then helpers.assert_eq(state.payload.locale, "fr") end
					if route == "ready" then helpers.assert_eq(state.payload.locale, "en") end
					if route == "pickConfigDir" then helpers.assert_eq(state.payload, "/virtual/chosen/") end
					if route == "loadExistingConfig" then helpers.assert_eq(state.payload.request, 1) end
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
	for _, route in ipairs({ "previewLocale", "ready", "pickConfigDir", "loadExistingConfig" }) do
		for _, mode in ipairs({ "nil", "false", "empty", "wrong_type" }) do
			helpers.it("(onboarding-js-delivery) " .. route .. " refuses " .. mode .. " encoding result", function()
				with_delivery(function(_, state, pending, errors, evaluations)
					state.encode = function()
						if mode == "false" then return false end
						if mode == "empty" then return "  " end
						if mode == "wrong_type" then return {} end
					end
					dispatch(route, state, pending)
					helpers.assert_eq(#evaluations, 0, "a refused encoding cannot publish JavaScript")
					helpers.assert_eq(#errors, 1)
					helpers.assert_true(errors[1]:find("encoding failed", 1, true) ~= nil)
					helpers.assert_nil(errors[1]:find("/virtual/", 1, true))
				end)
			end)
		end
	end
	helpers.it("(onboarding-js-delivery) picked folder reaches setConfigDir as a JSON string", function()
		with_delivery(function(_, state, pending, errors, evaluations)
			state.receiver({ body = { action = "pickConfigDir", current = "" } })
			helpers.assert_eq(#errors, 0, "a bare string payload must encode without error")
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(evaluations[1].code, 'window.setConfigDir("/virtual/chosen/")')
			helpers.assert_eq(state.picker.current, "")
			helpers.assert_eq(state.picker.prompt, "dialog.config_folder.select_title")
			helpers.assert_eq(#pending, 0)
		end)
	end)
	helpers.it("(onboarding-js-delivery) cancelled folder picker publishes nothing", function()
		with_delivery(function(_, state, _, errors, evaluations)
			package.loaded["ui.menu.menu_paths"].pick_config_dir = function() return nil end
			state.receiver({ body = { action = "pickConfigDir", current = "/virtual/current" } })
			helpers.assert_eq(#evaluations, 0)
			helpers.assert_eq(#errors, 0)
		end)
	end)
	helpers.it("(onboarding-js-delivery) a raising folder picker is reported, not propagated", function()
		with_delivery(function(_, state, _, errors, evaluations)
			package.loaded["ui.menu.menu_paths"].pick_config_dir = function() error("native picker exploded") end
			state.receiver({ body = { action = "pickConfigDir", current = "/virtual/current" } })
			helpers.assert_eq(#evaluations, 0)
			helpers.assert_eq(#errors, 1)
		end)
	end)
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


helpers.describe("onboarding initialization scheduling", function()
	for _, refusal in ipairs({ "new", "start" }) do
		helpers.it("(onboarding-init-retry) actual native " .. refusal .. " refusal repairs through same-owner reopen", function()
			with_delivery(function(onboarding, state, _, _, evaluations)
				local view = state.view
				state.timer_refusal = refusal
				state.receiver({ body = { action = "ready" } })
				view.options.on_navigation("didFinishNavigation")
				helpers.assert_eq(state.timer_attempts, 2)
				helpers.assert_eq(#evaluations, 0)
				helpers.assert_eq(#state.read_paths, 0)
				helpers.assert_eq(state.scheduler.activeCount(), 0)
				for _, timer in ipairs(state.native_timers) do
					helpers.assert_eq(timer:running(), false)
					helpers.assert_true(timer.stops > 0)
				end
				state.timer_refusal = nil
				helpers.assert_true(onboarding.run("/virtual/config.toml"))
				helpers.assert_eq(state.view, view)
				helpers.assert_eq(state.timer_attempts, 3, "native repair must commit deferred initialization")
				helpers.assert_eq(#evaluations, 0, "reopen must never initialize inline")
				state.receiver({ body = { action = "ready" } })
				view.options.on_navigation("didFinishNavigation")
				helpers.assert_eq(state.timer_attempts, 3, "one committed reservation owns both ready signals")
				state.fire_timer(#state.native_timers)
				helpers.assert_eq(#evaluations, 1)
				helpers.assert_eq(evaluations[1].view, view)
				helpers.assert_true(evaluations[1].code:find("window.initData(", 1, true) ~= nil)
				helpers.assert_eq(state.payload.locale, "en")
				helpers.assert_eq(state.scheduler.activeCount(), 0)
				helpers.assert_true(onboarding.run("/virtual/config.toml"))
				helpers.assert_eq(state.timer_attempts, 3, "post-success reopen only focuses")
				helpers.assert_eq(#evaluations, 1)
			end, true)
		end)
	end

	helpers.it("(onboarding-init-retry) changed-path singleton does not retarget refused initialization", function()
		with_delivery(function(onboarding, state, _, _, evaluations)
			local view = state.view
			state.timer_refusal = "start"
			state.receiver({ body = { action = "ready" } })
			view.options.on_navigation("didFinishNavigation")
			state.timer_refusal = nil
			helpers.assert_true(onboarding.run("/virtual/other/config.toml"))
			helpers.assert_eq(state.view, view)
			helpers.assert_eq(state.focus_attempts, 1)
			helpers.assert_eq(state.timer_attempts, 2, "old-path debt grants no new-path scheduling")
			helpers.assert_eq(#evaluations, 0)
			helpers.assert_true(onboarding.run("/virtual/config.toml"))
			helpers.assert_eq(state.timer_attempts, 3)
			state.fire_timer(#state.native_timers)
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(state.read_paths[1], "/virtual/config.toml")
		end, true)
	end)

	helpers.it("(onboarding-init-retry) cleanup-only debt and retired signals cannot initialize a successor", function()
		with_delivery(function(onboarding, state, _, _, evaluations, open)
			local view, receiver = state.view, state.receiver
			state.timer_refusal = "new"
			receiver({ body = { action = "ready" } })
			view.options.on_navigation("didFinishNavigation")
			state.refused = true
			receiver({ body = { action = "finish", answers = { locale = "en", config_dir = "", operations = {} } } })
			state.timer_refusal = nil
			helpers.assert_true(onboarding.run("/virtual/config.toml"))
			helpers.assert_eq(onboarding.run("/virtual/other/config.toml"), false)
			receiver({ body = { action = "ready" } })
			view.options.on_navigation("didFinishNavigation")
			helpers.assert_eq(state.timer_attempts, 2)
			helpers.assert_eq(#evaluations, 0)
			state.refused = false
			receiver({ body = { action = "cancel" } })
			open()
			local successor = state.view
			helpers.assert_true(successor ~= view)
			receiver({ body = { action = "ready" } })
			view.options.on_navigation("didFinishNavigation")
			helpers.assert_eq(state.timer_attempts, 2)
			state.receiver({ body = { action = "ready" } })
			state.fire_timer(#state.native_timers)
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(evaluations[1].view, successor)
		end, true)
	end)

	helpers.it("(onboarding-init-retry) queued native delivery retires with its exact view", function()
		with_delivery(function(_, state, _, _, evaluations, open)
			state.receiver({ body = { action = "ready" } })
			local old_timer = #state.native_timers
			state.view.options.on_close()
			open()
			local successor = state.view
			state.fire_timer(old_timer)
			helpers.assert_eq(#evaluations, 0)
			state.receiver({ body = { action = "ready" } })
			state.fire_timer(#state.native_timers)
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(evaluations[1].view, successor)
		end, true)
	end)

	helpers.it("(onboarding-init-retry) early native navigation binds the accepted view after construction", function()
		with_delivery(function(_, state, _, _, evaluations, open)
			state.view.options.on_close()
			local builder = package.loaded["ui.ui_builder"]
			local original_show = builder.show_webview
			builder.show_webview = function(options)
				options.on_navigation("didFinishNavigation")
				return original_show(options)
			end
			open()
			builder.show_webview = original_show
			helpers.assert_eq(#evaluations, 0)
			helpers.assert_eq(state.timer_attempts, 1)
			state.fire_timer(1)
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(evaluations[1].view, state.view)
		end, true)
	end)
end)


helpers.describe("onboarding native scheduling reentry", function()
	helpers.it("(onboarding-init-retry) synchronous native delivery refuses before deferred repair", function()
		with_delivery(function(onboarding, state, _, _, evaluations)
			state.timer_synchronous = true
			state.receiver({ body = { action = "ready" } })
			state.view.options.on_navigation("didFinishNavigation")
			helpers.assert_eq(state.timer_attempts, 2)
			helpers.assert_eq(#evaluations, 0)
			helpers.assert_eq(state.scheduler.activeCount(), 0)
			state.timer_synchronous = false
			helpers.assert_true(onboarding.run("/virtual/config.toml"))
			helpers.assert_eq(state.timer_attempts, 3)
			helpers.assert_eq(#evaluations, 0)
			state.fire_timer(#state.native_timers)
			helpers.assert_eq(#evaluations, 1)
		end, true)
	end)
	helpers.it("(onboarding-init-retry) native start reentry shares one exact owner reservation", function()
		with_delivery(function(onboarding, state, _, _, evaluations)
			state.on_timer_start = function()
				helpers.assert_true(onboarding.run("/virtual/config.toml"))
			end
			state.receiver({ body = { action = "ready" } })
			helpers.assert_eq(state.timer_attempts, 1)
			helpers.assert_eq(#evaluations, 0)
			state.on_timer_start = nil
			state.fire_timer(1)
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(state.scheduler.activeCount(), 0)
		end, true)
	end)
end)


helpers.describe("onboarding terminal initialization custody", function()
	helpers.it("(onboarding-init-retry) a source-dropped terminal callback remains retryable by reopen alone", function()
		with_delivery(function(onboarding, state, _, _, evaluations)
			local view = state.view
			state.receiver({ body = { action = "ready" } })
			helpers.assert_true(onboarding.run("/virtual/other/config.toml"))
			state.fire_timer(1)
			helpers.assert_eq(#evaluations, 0, "old-source callback cannot initialize another source")
			helpers.assert_eq(#state.read_paths, 0)
			helpers.assert_eq(state.scheduler.activeCount(), 0)
			helpers.assert_true(onboarding.run("/virtual/config.toml"))
			helpers.assert_eq(state.timer_attempts, 2, "the page sends ready once; reopen must retry alone")
			helpers.assert_eq(#evaluations, 0)
			state.fire_timer(2)
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(evaluations[1].view, view)
			helpers.assert_eq(state.read_paths[1], "/virtual/config.toml")
		end, true)
	end)
	helpers.it("(onboarding-init-retry) fresh source signals supersede one pending native reservation", function()
		with_delivery(function(onboarding, state, _, _, evaluations)
			state.receiver({ body = { action = "ready" } })
			local expected_path
			for index = 1, 16 do
				expected_path = "/virtual/choice" .. index .. "/config.toml"
				helpers.assert_true(onboarding.run(expected_path))
				state.receiver({ body = { action = "ready" } })
				state.view.options.on_navigation("didFinishNavigation")
			end
			helpers.assert_eq(state.timer_attempts, 1, "actual new requests share one queued native timer")
			helpers.assert_eq(state.scheduler.activeCount(), 1)
			helpers.assert_eq(#evaluations, 0)
			state.fire_timer(1)
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(state.read_paths[1], expected_path)
			helpers.assert_eq(state.scheduler.activeCount(), 0)
			helpers.assert_true(onboarding.run(expected_path))
			helpers.assert_eq(state.timer_attempts, 1)
		end, true)
	end)
end)


helpers.describe("onboarding captured initialization publication", function()
	helpers.it("(onboarding-init-retry) actual encoding reentry cannot publish another configuration source", function()
		with_delivery(function(onboarding, state, _, _, evaluations)
			local view = state.view
			state.receiver({ body = { action = "ready" } })
			state.encode = function(payload)
				state.encode = nil
				helpers.assert_true(onboarding.run("/virtual/other/config.toml"))
				return require("json").encode(payload)
			end
			state.fire_timer(1)
			helpers.assert_eq(state.read_paths[1], "/virtual/config.toml")
			helpers.assert_eq(state.view, view)
			helpers.assert_eq(#evaluations, 0, "actual source guard must still hold after genuine encoding")
			helpers.assert_true(onboarding.run("/virtual/other/config.toml"))
			helpers.assert_eq(state.timer_attempts, 1)
			helpers.assert_true(onboarding.run("/virtual/config.toml"))
			helpers.assert_eq(state.timer_attempts, 2, "unadmitted original-source data remains retryable")
			state.fire_timer(2)
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(evaluations[1].view, view)
			helpers.assert_eq(state.read_paths[#state.read_paths], "/virtual/config.toml")
		end, true)
	end)
end)


helpers.describe("onboarding active initialization reservation", function()
	helpers.it("(onboarding-init-retry) same-source encoding reopen cannot chain native initializations", function()
		with_delivery(function(onboarding, state, _, _, evaluations)
			state.receiver({ body = { action = "ready" } })
			state.encode = function(payload)
				state.encode = nil
				helpers.assert_true(onboarding.run("/virtual/config.toml"))
				return require("json").encode(payload)
			end
			state.fire_timer(1)
			helpers.assert_eq(state.timer_attempts, 1)
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(state.scheduler.activeCount(), 0)
			helpers.assert_true(onboarding.run("/virtual/config.toml"))
			helpers.assert_eq(state.timer_attempts, 1)
		end, true)
	end)
	helpers.it("(onboarding-init-retry) an active initializer retires after genuine reporting raises", function()
		with_delivery(function(onboarding, state, _, _, evaluations)
			local failure = {}
			state.receiver({ body = { action = "ready" } })
			state.encode = function() error("encoding refused", 0) end
			state.on_error = function() error(failure, 0) end
			local fired, observed = pcall(state.fire_timer, 1)
			helpers.assert_eq(fired, false)
			helpers.assert_eq(observed, failure, "actual callback primary identity stays exact")
			helpers.assert_eq(#evaluations, 0)
			helpers.assert_eq(state.scheduler.activeCount(), 0)
			state.encode, state.on_error = nil, nil
			helpers.assert_true(onboarding.run("/virtual/config.toml"))
			helpers.assert_eq(state.timer_attempts, 2)
			state.fire_timer(2)
			helpers.assert_eq(#evaluations, 1)
		end, true)
	end)
	helpers.it("(onboarding-init-retry) a preparing reservation retires after genuine native refusal reporting raises", function()
		with_delivery(function(onboarding, state, _, _, evaluations)
			local failure = {}
			state.timer_refusal = "new"
			state.on_error = function() error(failure, 0) end
			local accepted, observed = pcall(state.receiver, { body = { action = "ready" } })
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(observed, failure)
			helpers.assert_eq(#evaluations, 0)
			helpers.assert_eq(state.scheduler.activeCount(), 0)
			state.timer_refusal, state.on_error = nil, nil
			helpers.assert_true(onboarding.run("/virtual/config.toml"))
			helpers.assert_eq(state.timer_attempts, 2)
			state.fire_timer(1)
			helpers.assert_eq(#evaluations, 1)
		end, true)
	end)
	helpers.it("(onboarding-init-retry) explicit source request during encoding owns one deferred successor", function()
		with_delivery(function(onboarding, state, _, _, evaluations)
			state.receiver({ body = { action = "ready" } })
			local attempts_during_encoding
			state.encode = function(payload)
				state.encode = nil
				helpers.assert_true(onboarding.run("/virtual/other/config.toml"))
				state.receiver({ body = { action = "ready" } })
				attempts_during_encoding = state.timer_attempts
				return require("json").encode(payload)
			end
			state.fire_timer(1)
			helpers.assert_eq(attempts_during_encoding, 1, "active submission cannot allocate a second timer inline")
			helpers.assert_eq(#evaluations, 0)
			helpers.assert_eq(state.timer_attempts, 2)
			helpers.assert_eq(state.scheduler.activeCount(), 1)
			state.fire_timer(2)
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(state.read_paths[#state.read_paths], "/virtual/other/config.toml")
			helpers.assert_eq(state.scheduler.activeCount(), 0)
		end, true)
	end)
end)


helpers.describe("onboarding empty-folder destination delivery", function()
	for _, vector in ipairs({
		{ path = "/virtual/captured/hammerspoon/config.toml", target = "/virtual/captured/" },
		{ path = "/virtual/direct/config.toml", target = "/virtual/direct/" },
		{ path = "/virtual/myhammerspoon/config.toml", target = "/virtual/myhammerspoon/" },
		{ path = "/hammerspoon/config.toml", target = "/" },
	}) do
		helpers.it("(onboarding-empty-folder) ready names the captured destination " .. vector.target, function()
			with_delivery(function(_, state, _, errors, evaluations, open)
				open(vector.path)
				state.receiver({ body = { action = "ready" } })
				state.fire_timer(1)
				helpers.assert_eq(#errors, 0)
				helpers.assert_eq(#evaluations, 1)
				helpers.assert_true(evaluations[1].code:find("window.initData(", 1, true) ~= nil)
				helpers.assert_eq(state.payload.empty_config_dir, vector.target,
					"clearing the macOS field retains the captured source rather than a live menu getter")
				helpers.assert_eq(state.payload.default_config_dir, "/virtual/default")
				helpers.assert_eq(state.payload.config_dir, "/virtual/current",
					"the existing displayed-choice contract is preserved")
				helpers.assert_eq(state.read_paths[#state.read_paths], vector.path,
					"the advertised empty destination belongs to the configuration actually read")
				helpers.assert_eq(state.scheduler.activeCount(), 0)
			end, true)
		end)
	end
end)
