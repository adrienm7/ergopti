--- tests/unit/modules/llm/prediction/test_prediction_backend.lua

--- ==============================================================================
--- MODULE: Which Backend Answers A Prediction
--- DESCRIPTION:
--- With the API backend selected, a prediction goes to the active API entry
--- (Cerebras, …) instead of Ollama; with no entry it is not sent anywhere and
--- the reason is logged. Sequential variants are paced by the shared minimum
--- interval and each is a little warmer than the last.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = require("tests.fakes")

local ENTRY = { id = "cerebras-1", provider = "cerebras", label = "Cerebras", token = "k", model = "", base_url = "" }

--- Runs predictions against scripted backends.
--- @param backend string "api" or "ollama"
--- @param entry table|nil The active API entry.
--- @return table engine, table calls, table scheduler, function restore
local function load(backend, entry, stored_settings, without_local_model, asynchronous, privacy)
	local names = {
		"adapters.secure_field_detector", "modules.llm.api_ollama", "modules.llm.api_remote",
		"modules.llm.api_entries", "modules.llm.profiles", "modules.llm.profile_settings", "adapters.storage",
		"infra.llm_preferences", "modules.llm.trigger_settings",
	}
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local calls = { ollama = {}, remote = {}, notices = {}, cancelled = 0, applied = 0, resets = 0, focus = "x11:fixture:1" }
	package.loaded["adapters.secure_field_detector"] = {
		isSecureField = function() return false end,
		isSecureApp = function() return false end,
		isUrlBar = function() return false end,
	}
	package.loaded["modules.llm.api_ollama"] = {
		chat = function(target, model, _, _, chunk, done)
			calls.ollama[#calls.ollama + 1] = { target = target, model = model, chunk = chunk, done = done }
		end,
		cancel = function() return true end,
	}
	package.loaded["modules.llm.api_remote"] = {
		provider = function() return { default_model = "qwen-default" } end,
		serves = function(_, use) return use == "chat" end,
		chat = function(target, model, _, opts, on_chunk, on_done)
			calls.remote[#calls.remote + 1] = { target = target, model = model, opts = opts, chunk = on_chunk, done = on_done }
			if not asynchronous then on_done(" que tout le monde aille bien " .. #calls.remote, nil) end
		end,
		cancel = function()
			calls.cancelled = calls.cancelled + 1
			if calls.on_cancel then calls.on_cancel() end
			return calls.cancel_refused ~= true
		end,
	}
	package.loaded["modules.llm.api_entries"] = { active = function() return entry end }
	package.loaded["modules.llm.profiles"] = {
		init = function() end,
		is_enabled = function() return true end,
		get_current_model = function() if not without_local_model then return "ollama-model" end end,
		set_model = function(name, source, admission)
			return require("infra.llm_preferences").set_many({ ["llm.models.ollama"] = name }, source, admission)
		end,
		get_base_url = function() return "http://127.0.0.1:11434" end,
	}
	package.loaded["modules.llm.profile_settings"] = {
		get = function(key) if key == "num_predictions" then return 3 end end,
		resolve = function() return { id = "raw", system_single = "{context}" } end,
	}
	local stored = { ["llm.models.selected"] = backend }
	for key, value in pairs(stored_settings or {}) do stored[key] = value end
	package.loaded["infra.llm_preferences"] = require("tests.support.llm_preferences_fixture").new({ initial = stored })
	-- Settings caches what it read; a fresh copy reads this storage.
	package.loaded["modules.llm.settings"] = nil
	package.loaded["modules.llm.trigger_settings"] = nil
	package.loaded["adapters.storage"] = {
		get = function(key, default) if stored[key] ~= nil then return stored[key] end return default end,
		set = function(key, value) stored[key] = value; return true end,
	}
	local scheduler = Fakes.timer_scheduler()
	-- One pass per call, as the real loop does: step through several.
	function scheduler.settle()
		for _ = 1, 10 do scheduler.test.advance(0.6) end
	end
	local engine = helpers.load_module("modules.llm.prediction_engine")
	engine.init({
		scheduler = scheduler, clock_ms = function() return scheduler.now * 1000 end,
		focus_id = function() return calls.focus end,
		privacy_guard = privacy and privacy.guard,
		privacy_context = privacy and privacy.context,
		engine = { current_buffer = function() return calls.buffer or "Bonjour à tous" end, reset = function() calls.resets = calls.resets + 1 end },
		apply_prediction = function() calls.applied = calls.applied + 1; return calls.refuse_apply ~= true end,
		notify = function(text) calls.notices[#calls.notices + 1] = text; return true end,
	})
	return engine, calls, scheduler, function()
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		package.loaded["modules.llm.prediction_engine"] = nil
		package.loaded["modules.llm.settings"] = nil
	end
end

helpers.describe("prediction backend: the selected backend answers", function()

	helpers.it("withdraws a pending prediction after changing local model (ai-pass2-model)", function()
		local engine, calls, _, restore = load("ollama", ENTRY, nil, false, true)
		local ok, err = pcall(function()
			engine.predict("Bonjour à tous", nil, { num_predictions = 1 })
			helpers.assert_eq(#calls.ollama, 1, "the original model owns the request")
			helpers.assert_eq(engine.set_model("replacement-model"), true)
			helpers.assert_eq(engine.is_predicting(), false, "model selection retires the old request")
			calls.ollama[1].done(" qui vous souhaite une bonne journée", nil)
			helpers.assert_eq(#engine.get_suggestions(), 0, "late old-model output cannot reappear")
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("manual API prediction works without a local model (manual-selected-backend)", function()
		local engine, calls, scheduler, restore = load("api", ENTRY, nil, true)
		local ok, err = pcall(function()
			helpers.assert_eq(engine.trigger_now(), true, "the selected API is ready without Ollama")
			scheduler.settle()
			helpers.assert_eq(#calls.remote, 3, "the real prediction pipeline reaches the selected API")
			helpers.assert_eq(calls.remote[1].target, ENTRY)
			helpers.assert_eq(#calls.ollama, 0)
			helpers.assert_eq(#calls.notices, 0)
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("manual API prediction refuses an absent API entry despite a local model (manual-selected-backend)", function()
		local engine, calls, scheduler, restore = load("api", nil)
		local ok, err = pcall(function()
			helpers.assert_eq(engine.trigger_now(), false, "a local model cannot satisfy API admission")
			scheduler.settle()
			helpers.assert_eq(#calls.remote + #calls.ollama, 0)
			helpers.assert_eq(#calls.notices, 1, "the refusal must reach the visible notice surface")
			helpers.assert_eq(calls.notices[1], require("infra.i18n").get("llm.manual_prediction.backend_not_ready"))
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("sends to the active API entry, with the provider's default model", function()
		local engine, calls, scheduler, restore = load("api", ENTRY)
		engine.predict("Bonjour à tous")
		scheduler.settle()
		restore()
		helpers.assert_eq(#calls.ollama, 0, "Ollama is not asked")
		helpers.assert_eq(#calls.remote, 3, "one request per requested prediction")
		helpers.assert_eq(calls.remote[1].target, ENTRY)
		helpers.assert_eq(calls.remote[1].model, "qwen-default")
	end)

	helpers.it("sends nothing when the API is selected but no entry is", function()
		local engine, calls, scheduler, restore = load("api", nil)
		engine.predict("Bonjour à tous")
		scheduler.settle()
		restore()
		helpers.assert_eq(#calls.remote + #calls.ollama, 0)
	end)

	helpers.it("keeps Ollama as the default", function()
		local engine, calls, scheduler, restore = load(nil, ENTRY)
		engine.predict("Bonjour à tous")
		scheduler.settle()
		restore()
		helpers.assert_eq(#calls.remote, 0)
		helpers.assert_true(#calls.ollama >= 1)
	end)

end)

helpers.describe("prediction backend: variants are paced and diverse", function()

	helpers.it("waits the shared API interval between two requests", function()
		local engine, calls, scheduler, restore = load("api", ENTRY)
		engine.predict("Bonjour à tous")
		local first = #calls.remote
		scheduler.test.advance(0.49)
		local before_interval = #calls.remote
		scheduler.test.advance(0.02)
		local after_interval = #calls.remote
		restore()
		helpers.assert_eq(first, 1, "the first request leaves at once")
		helpers.assert_eq(before_interval, 1, "the second waits for the interval")
		helpers.assert_eq(after_interval, 2)
	end)

	helpers.it("warms each next variant", function()
		local engine, calls, scheduler, restore = load("api", ENTRY)
		engine.predict("Bonjour à tous")
		scheduler.settle()
		restore()
		helpers.assert_true(calls.remote[2].opts.temperature > calls.remote[1].opts.temperature)
		helpers.assert_true(calls.remote[3].opts.temperature > calls.remote[2].opts.temperature)
	end)

	helpers.it("offers the first variant before the next one arrives", function()
		local engine, _, _, restore = load("api", ENTRY)
		engine.predict("Bonjour à tous")
		local offered = #engine.get_suggestions()
		restore()
		helpers.assert_eq(offered, 1)
	end)

end)

helpers.describe("prediction backend: the model the menu shows profiles for", function()

	helpers.it("is the API entry's model when the API answers", function()
		local engine, _, _, restore = load("api", ENTRY)
		local model = engine.get_prediction_model()
		restore()
		helpers.assert_eq(model, "qwen-default")
	end)

	helpers.it("is Ollama's model otherwise", function()
		local engine, _, _, restore = load("ollama", ENTRY)
		local model = engine.get_prediction_model()
		restore()
		helpers.assert_eq(model, "ollama-model")
	end)

	helpers.it("is what the AI menu resolves the automatic profile against", function()
		local fh = assert(io.open("ui/menu/menu_builder.lua", "r"))
		local source = fh:read("*a")
		fh:close()
		local handler = source:match('dynamic_handlers%["llm_profile"%] = function%(target%)(.-)local function refresh')
		helpers.assert_true(handler ~= nil and handler:find("get_prediction_model", 1, true) ~= nil,
			"the profile rows must follow the model predictions use")
	end)

end)

helpers.describe("prediction backend: the raise-temperature switch", function()

	local SETTINGS = {
		["llm.generation.temperature"] = 0.3,
	}

	helpers.it("keeps every variant at the user's temperature when off", function()
		local stored = { ["llm.generation.auto_raise_temp"] = false }
		for key, value in pairs(SETTINGS) do stored[key] = value end
		local engine, calls, scheduler, restore = load("api", ENTRY, stored)
		engine.predict("Bonjour à tous")
		scheduler.settle()
		restore()
		for index = 1, 3 do helpers.assert_eq(calls.remote[index].opts.temperature, 0.3) end
	end)

	helpers.it("starts from the user's temperature when on, warming only the next ones", function()
		local stored = { ["llm.generation.auto_raise_temp"] = true }
		for key, value in pairs(SETTINGS) do stored[key] = value end
		local engine, calls, scheduler, restore = load("api", ENTRY, stored)
		engine.predict("Bonjour à tous")
		scheduler.settle()
		restore()
		helpers.assert_eq(calls.remote[1].opts.temperature, 0.3, "the first variant is not pre-heated")
		helpers.assert_true(calls.remote[2].opts.temperature > 0.3)
	end)

end)


helpers.describe("local API configuration uses the ordinary prediction admission owner", function()
	helpers.it("master OFF permits configuration but pause and retained scope debt refuse it", function()
		local engine, _, scheduler, restore = load("ollama", nil, { ["llm.enabled"] = false })
		-- The engine reads the profiles owner, not the storage fixture directly.
		package.loaded["modules.llm.profiles"].is_enabled = function() return false end
		local paused, debt = false, true
		local owner = { pending = function() return debt end }
		local ok, err = pcall(function()
			engine.init({ scheduler = scheduler, is_paused = function() return paused end })
			helpers.assert_eq(engine.is_enabled(), false)
			helpers.assert_eq(engine.can_configure_local_servers(), true)
			paused = true
			helpers.assert_eq(engine.can_configure_local_servers(), false)
			paused = false
			helpers.assert_eq(engine.acquire_configuration(owner), true)
			helpers.assert_eq(engine.can_configure_local_servers(), false)
			helpers.assert_eq(engine.release_configuration(owner), false)
			helpers.assert_eq(engine.can_configure_local_servers(), false)
			debt = false
			helpers.assert_eq(engine.release_configuration(owner), true)
			helpers.assert_eq(engine.can_configure_local_servers(), true)
		end)
		restore()
		if not ok then error(err, 0) end
	end)
end)


helpers.describe("backend publication rechecks actual admission after dismissal", function()
	for _, condition in ipairs({"pause", "foreign source", "admission withdrawn", "unchanged"}) do
		helpers.it("retains canonical bytes after dismissal: " .. condition .. " (backend-second-admission)", function()
			local Sandbox = require("test.config_unused_keys_contract").sandbox
			local initial = '[llm]\nenabled = true\n[llm.models]\nselected = "ollama"\n[future]\nvalue = 42 # independently owned\n'
			Sandbox.with_config(initial, function(path)
				local engine, _, scheduler, restore = load("ollama", nil)
				local previous_paths = package.loaded["infra.config_paths"]
				local ok, err = xpcall(function()
					package.loaded["infra.config_paths"] = {config = function() return path end}
					package.loaded["infra.llm_preferences"] = nil
					local preferences = require("infra.llm_preferences")
					local _, captured = preferences.get_many({"llm.models.selected"})
					local paused, allowed, armed = false, true, false
					local observations = {dismissals = 0, admissions = 0, changed = false}
					local foreign = initial:gsub("value = 42", "value = 73")
					engine.init({scheduler = scheduler, is_paused = function() return paused end,
						overlay = {hide = function()
							if not armed then return end
							observations.dismissals = observations.dismissals + 1
							if condition == "pause" then paused = true end
							if condition == "admission withdrawn" then allowed = false end
							if condition == "foreign source" then
								Sandbox.write_bytes(path, foreign)
								observations.changed = Sandbox.read_bytes(path) == foreign
							end
						end}})
					armed = true
					local function admission()
						observations.admissions = observations.admissions + 1
						local _, current = preferences.get_many({"llm.models.selected"})
						return allowed and engine.can_configure_local_servers() == true
							and preferences.admit() == true and captured.status == current.status
							and captured.content == current.content
					end
					local committed = engine.set_backend("api", admission)
					armed = false
					-- Assertions follow the actual dismissal observer; none can be swallowed by production.
					helpers.assert_eq(observations.dismissals, 1, "the real dismissal must invoke its native overlay port")
					helpers.assert_eq(committed, condition == "unchanged")
					local bytes = Sandbox.read_bytes(path)
					if condition == "unchanged" then
						local decoded = require("toml_codec").decode(bytes)
						helpers.assert_eq(decoded.llm.models.selected, "api", "the real preference writer must acknowledge a new canonical backend")
						helpers.assert_eq(decoded.future.value, 42)
						package.loaded["infra.llm_preferences"] = nil
						helpers.assert_eq(require("infra.llm_preferences").get("llm.models.selected"), "api", "a fresh actual reader must observe the durable backend")
					else
						helpers.assert_eq(bytes, condition == "foreign source" and foreign or initial)
						helpers.assert_eq(preferences.get("llm.models.selected"), "ollama")
						if condition == "foreign source" then helpers.assert_eq(observations.changed, true) end
					end
					helpers.assert_eq(observations.admissions, 2, "the existing admission owner is rechecked after real dismissal")
				end, debug.traceback)
				package.loaded["infra.config_paths"] = previous_paths
				restore()
				if not ok then error(err, 0) end
			end)
		end)
	end
end)

helpers.describe("acceptance retires the originating prediction request", function()

	helpers.it("does not send remaining variants after accepting the first paced candidate (acceptance-retires-request)", function()
		local engine, calls, scheduler, restore = load("api", ENTRY)
		local ok, err = pcall(function()
			engine.predict("Bonjour à tous")
			helpers.assert_eq(#calls.remote, 1)
			helpers.assert_eq(#engine.get_suggestions(), 1, "the first candidate is available during pacing")
			helpers.assert_eq(engine.accept(1), true)
			scheduler.settle()
			helpers.assert_eq(#calls.remote, 1, "acceptance retires the remaining paid requests")
			helpers.assert_eq(engine.is_predicting(), false)
			helpers.assert_eq(#engine.get_suggestions(), 0)
			helpers.assert_eq(calls.applied, 1)
			helpers.assert_eq(calls.resets, 1)
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("ignores streamed completion and synchronous cancellation callbacks after insertion (acceptance-retires-request)", function()
		local engine, calls, scheduler, restore = load("api", ENTRY, nil, nil, true)
		local ok, err = pcall(function()
			engine.predict("Bonjour à tous")
			local request = calls.remote[1]
			request.chunk(" que tout le monde aille bien")
			helpers.assert_eq(#engine.get_suggestions(), 1, "a real streaming partial must be offered")
			calls.on_cancel = function() request.done(" que tout le monde aille mieux", nil) end
			helpers.assert_eq(engine.accept(1), true)
			request.chunk(" demain")
			request.done(" que tout le monde aille bien demain", nil)
			scheduler.settle()
			helpers.assert_eq(calls.cancelled, 1, "the originating HTTP owner is withdrawn")
			helpers.assert_eq(engine.is_predicting(), false)
			helpers.assert_eq(#engine.get_suggestions(), 0, "late callbacks cannot resurrect an accepted offer")
			helpers.assert_eq(#calls.remote, 1)
			helpers.assert_eq(calls.applied, 1)
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	for _, mode in ipairs({ "refused", "raised" }) do
		helpers.it("keeps the committed offer retired when transport cancellation " .. mode .. " (acceptance-retires-request)", function()
			local engine, calls, scheduler, restore = load("api", ENTRY, nil, nil, true)
			local ok, err = pcall(function()
				engine.predict("Bonjour à tous")
				calls.remote[1].chunk(" que tout le monde aille bien")
				calls.cancel_refused = true
				if mode == "raised" then calls.on_cancel = function() error("owned transport cancellation failure", 0) end end
				helpers.assert_eq(engine.accept(1), true, "a completed physical edit cannot be retried")
				calls.remote[1].done(" que tout le monde aille bien demain", nil)
				scheduler.settle()
				helpers.assert_eq(#engine.get_suggestions(), 0)
				helpers.assert_eq(engine.is_predicting(), false)
				helpers.assert_eq(calls.resets, 1)
				helpers.assert_eq(calls.applied, 1)
				helpers.assert_eq(#calls.remote, 1)
			end)
			restore()
			if not ok then error(err, 0) end
		end)
	end

	helpers.it("keeps an uncommitted streaming offer available when insertion refuses (acceptance-retires-request)", function()
		local engine, calls, _, restore = load("api", ENTRY, nil, nil, true)
		local ok, err = pcall(function()
			engine.predict("Bonjour à tous")
			calls.remote[1].chunk(" que tout le monde aille bien")
			calls.refuse_apply = true
			helpers.assert_eq(engine.accept(1), false)
			helpers.assert_eq(calls.cancelled, 0)
			helpers.assert_eq(engine.is_predicting(), true)
			helpers.assert_eq(#engine.get_suggestions(), 1)
			helpers.assert_eq(calls.resets, 0)
		end)
		restore()
		if not ok then error(err, 0) end
	end)

end)

helpers.describe("ordinary predictions retain their exact native target", function()
	helpers.it("refuses a prediction when native focus is unavailable (prediction-native-focus)", function()
		local engine, calls, _, restore = load("api", ENTRY)
		local ok, err = pcall(function()
			calls.focus = ""
			helpers.assert_eq(engine.predict("Bonjour à tous"), false)
			helpers.assert_eq(#calls.remote, 0)
			helpers.assert_eq(engine.has_suggestions(), false)
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("drops a delayed completion after a native window switch (prediction-native-focus)", function()
		local engine, calls, scheduler, restore = load("api", ENTRY, nil, nil, true)
		local ok, err = pcall(function()
			engine.predict("Bonjour à tous")
			calls.focus = "x11:fixture:2"
			calls.remote[1].done(" que tout le monde aille bien", nil)
			scheduler.settle()
			helpers.assert_eq(engine.has_suggestions(), false)
			helpers.assert_eq(engine.is_predicting(), false)
			helpers.assert_eq(engine.accept(1), false)
			helpers.assert_eq(calls.applied, 0)
			helpers.assert_eq(#calls.remote, 1, "the switched target cannot authorize later variants")
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("refuses an already visible prediction after a native window switch (prediction-native-focus)", function()
		local engine, calls, _, restore = load("api", ENTRY)
		local ok, err = pcall(function()
			engine.predict("Bonjour à tous")
			helpers.assert_eq(engine.has_suggestions(), true)
			calls.focus = "x11:fixture:2"
			helpers.assert_eq(engine.accept(1), false)
			helpers.assert_eq(calls.applied, 0)
			helpers.assert_eq(calls.resets, 0, "a refused native target is never reported as an inserted output")
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	for _, action in ipairs({"debounce", "manual"}) do
		helpers.it("does not attribute the old buffer to a new window before " .. action .. " dispatch (prediction-native-focus)", function()
			local engine, calls, scheduler, restore = load("api", ENTRY)
			local ok, err = pcall(function()
				engine.on_char("s", "Bonjour à tous")
				calls.focus = "x11:fixture:2"
				if action == "manual" then helpers.assert_eq(engine.trigger_now(), false) end
				scheduler.settle()
				helpers.assert_eq(#calls.remote, 0)
				helpers.assert_eq(calls.applied, 0)
			end)
			restore()
			if not ok then error(err, 0) end
		end)
	end
end)

helpers.describe("buffer-origin ownership follows matcher retirement", function()
	for _, origin in ipairs({"unavailable", "known"}) do
		helpers.it("reacquires a fresh target after an empty matcher retires a " .. origin .. " origin (prediction-origin-retirement)", function()
			local engine, calls, scheduler, restore = load("api", ENTRY)
			local ok, err = pcall(function()
				calls.focus = origin == "unavailable" and "" or "x11:fixture:1"
				engine.on_char("s", "Bonjour à tous")
				-- Escape empties the real matcher before it asks predictions to withdraw.
				calls.buffer = ""
				engine.withdraw()
				calls.focus = "x11:fixture:2"
				calls.buffer = "Fresh typing in a known target"
				engine.on_char("t", calls.buffer)
				scheduler.settle()
				helpers.assert_eq(#calls.remote, 3, "only the fresh buffer may acquire the recovered native target")
				helpers.assert_eq(calls.resets, 0, "withdrawal must preserve the caller's matcher edit")
				helpers.assert_eq(calls.applied, 0)
			end)
			restore()
			if not ok then error(err, 0) end
		end)
	end

	for _, origin in ipairs({"unavailable", "known"}) do
		helpers.it("preserves a nonempty matcher and its " .. origin .. " target lease (prediction-origin-retirement)", function()
			local engine, calls, scheduler, restore = load("api", ENTRY)
			local ok, err = pcall(function()
				calls.focus = origin == "unavailable" and "" or "x11:fixture:1"
				engine.on_char("s", "Bonjour à tous")
				-- Backspace leaves existing context whose native origin cannot be reassigned.
				calls.buffer = "Bonjour à tou"
				engine.withdraw()
				calls.focus = "x11:fixture:2"
				engine.on_char("s", "Bonjour à tous")
				scheduler.settle()
				helpers.assert_eq(#calls.remote, 0, "withdrawal of an offer cannot lend retained text to a different native target")
				helpers.assert_eq(calls.resets, 0)
			end)
			restore()
			if not ok then error(err, 0) end
		end)
	end

	helpers.it("continues prediction after Backspace retains text in the same known target (prediction-origin-retirement)", function()
		local engine, calls, scheduler, restore = load("api", ENTRY)
		local ok, err = pcall(function()
			engine.on_char("s", "Bonjour à tous")
			calls.buffer = "Bonjour à tou"
			engine.withdraw()
			engine.on_char("s", "Bonjour à tous")
			scheduler.settle()
			helpers.assert_eq(#calls.remote, 3)
			helpers.assert_eq(calls.resets, 0)
		end)
		restore()
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("prediction resident global privacy admission", function()
	local function request(engine, count)
		return engine.predict("Bonjour à tous", nil, { num_predictions = count or 1,
			profile = { id = "raw", system_single = "{context}" } })
	end
	local settings = { ["llm.trigger.secure_filter_enabled"] = false, ["llm.trigger.url_bar_filter_enabled"] = false }
	helpers.it("admits a known ordinary owner without querying the guard per streamed token (llm-global-privacy)", function()
		local checks = 0
		local engine, calls, _, restore = load("api", ENTRY, settings, true, true, { guard = function() checks = checks + 1; return false end })
		local okay, problem = pcall(function()
			request(engine)
			helpers.assert_eq(#calls.remote, 1)
			helpers.assert_true(checks > 0, "the global owner must be checked even with both optional filters disabled")
			local admitted = checks
			for _ = 1, 20 do calls.remote[1].chunk(" que") end
			helpers.assert_eq(checks, admitted, "stream deltas must not perform native privacy barriers")
			calls.remote[1].done(" que tout le monde aille bien", nil)
			helpers.assert_true(engine.accept(1))
			helpers.assert_eq(calls.applied, 1)
		end)
		restore(); if not okay then error(problem, 0) end
	end)
	for _, verdict in ipairs({ "protected", "unknown", "throw" }) do
		helpers.it("refuses " .. verdict .. " global ownership before any provider call (llm-global-privacy)", function()
			local engine, calls, scheduler, restore = load("api", ENTRY, settings, true, true, { guard = function()
				if verdict == "throw" then error("controlled resident barrier failure") end
				if verdict == "protected" then return true end
			end })
			local okay, problem = pcall(function()
				helpers.assert_eq(engine.trigger_now(), false)
				scheduler.settle()
				helpers.assert_eq(#calls.remote, 0)
				helpers.assert_eq(calls.applied, 0)
				helpers.assert_true(engine.is_enabled(), "a privacy refusal must not change the saved AI switch")
			end)
			restore(); if not okay then error(problem, 0) end
		end)
	end
	helpers.it("refuses unknown joined context even when optional privacy filters are disabled (llm-global-privacy)", function()
		local engine, calls, _, restore = load("api", ENTRY, settings, true, true,
			{ guard = function() return false end, context = function() return nil end })
		local okay, problem = pcall(function()
			helpers.assert_eq(engine.trigger_now(), false)
			helpers.assert_eq(#calls.remote, 0)
			helpers.assert_true(engine.is_enabled())
		end)
		restore(); if not okay then error(problem, 0) end
	end)
	helpers.it("refuses a request cancelled synchronously by the resident barrier (llm-global-privacy)", function()
		local current
		local engine, calls, _, restore = load("api", ENTRY, settings, true, true, { guard = function() current.cancel(); return false end })
		current = engine
		local okay, problem = pcall(function()
			helpers.assert_eq(engine.trigger_now(), false)
			helpers.assert_eq(#calls.remote, 0, "a cleared old buffer cannot be sent after nested cancellation")
		end)
		restore(); if not okay then error(problem, 0) end
	end)
	helpers.it("revokes a paced variant and admits a later ordinary request (llm-global-privacy)", function()
		local blocked = false
		local engine, calls, scheduler, restore = load("api", ENTRY, settings, true, true, { guard = function() return blocked end })
		local okay, problem = pcall(function()
			request(engine, 2)
			calls.remote[1].done(" que tout le monde aille bien", nil)
			helpers.assert_eq(#calls.remote, 1, "the next variant must still be paced")
			blocked = true; scheduler.settle()
			helpers.assert_eq(#calls.remote, 1, "revoked context must not send the next request")
			helpers.assert_eq(engine.has_suggestions(), false)
			helpers.assert_true(engine.is_enabled())
			blocked = false; request(engine); scheduler.settle()
			helpers.assert_eq(#calls.remote, 2, "privacy recovery permits a new independent request")
			calls.remote[2].done(" que tout le monde aille bien", nil)
			helpers.assert_true(engine.accept(1))
		end)
		restore(); if not okay then error(problem, 0) end
	end)
	helpers.it("withdraws completion after global privacy is revoked (llm-global-privacy)", function()
		local blocked = false
		local engine, calls, _, restore = load("api", ENTRY, settings, true, true, { guard = function() return blocked end })
		local okay, problem = pcall(function()
			request(engine); blocked = true
			calls.remote[1].done(" que tout le monde aille bien", nil)
			helpers.assert_eq(engine.has_suggestions(), false)
			helpers.assert_eq(engine.accept(1), false)
			helpers.assert_eq(calls.applied, 0)
			helpers.assert_true(engine.is_enabled())
		end)
		restore(); if not okay then error(problem, 0) end
	end)
	for _, kind in ipairs({ "protected", "nested cancel" }) do
		helpers.it("refuses " .. kind .. " at physical acceptance without changing the AI switch (llm-global-privacy)", function()
			local accepting, current = false
			local engine, calls, _, restore = load("api", ENTRY, settings, true, true, { guard = function()
				if accepting and kind == "nested cancel" then current.cancel(); return false end
				return accepting
			end })
			current = engine
			local okay, problem = pcall(function()
				request(engine); calls.remote[1].done(" que tout le monde aille bien", nil)
				helpers.assert_true(engine.has_suggestions())
				accepting = true
				helpers.assert_eq(engine.accept(1), false)
				helpers.assert_eq(calls.applied, 0, "the locally retained candidate cannot commit after cancellation")
				helpers.assert_eq(engine.has_suggestions(), false)
				helpers.assert_true(engine.is_enabled())
			end)
			restore(); if not okay then error(problem, 0) end
		end)
	end
end)
