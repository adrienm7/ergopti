--- tests/unit/ui/menu/menu_llm/test_llm_enable_unreachable_local.lua

--- ==============================================================================
--- MODULE: Enabling The AI With An Unreachable Local Backend
--- DESCRIPTION:
--- Maintainer report on dev.152 (macOS, oMLX running on localhost:8000):
--- turning the AI on failed, the diagnostics said "Network request failed"
--- although the AI is local, and the startup opened the error window with
--- "Disabling LLM (requirements check failed)".
---
--- ROOT CAUSE ENCODED:
--- 1. startup_controller turned every failure into that one error: a missing
---    Ollama, an Ollama that never answered its start, and even an API
---    backend (oMLX), whose requirement check models_manager routed to
---    Ollama's. Nothing named the backend, its address or the fix.
--- 2. The AI switch published "AI enabled" before the Ollama check and left
---    the AI on when Ollama never answered, so every request failed with
---    "Network request failed"; a missing Ollama was offered only a download,
---    never the local server that already answers.
---
--- These cases drive the real AI switch (llm_activation_fixture), the real
--- startup controller and the real models manager router. The dialog, the
--- notifications and the local-server sweep are faked at their modules.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_activation = require("tests.support.llm_activation_fixture")

local OLLAMA_URL = "http://127.0.0.1:11434"




-- =====================================
-- =====================================
-- ======= 1/ Helpers ==================
-- =====================================
-- =====================================

--- Tells whether a text contains a plain substring.
--- @param text any
--- @param part string
--- @return boolean
local function has(text, part)
	return type(text) == "string" and text:find(part, 1, true) ~= nil
end

--- The notices whose title names the unreachable backend.
--- @param calls table Fixture calls.
--- @return table notices
local function unreachable_notices(calls)
	local found = {}
	for _, notice in ipairs(calls.notices) do
		if has(notice.title, "llm.unreachable.title") then found[#found + 1] = notice end
	end
	return found
end

--- Picks the button whose label starts with a locale key.
--- @param key string
--- @return function pick For options.offer_pick.
local function pick(key)
	return function(dialog)
		for index, label in ipairs(dialog.choices) do
			if label:sub(1, #key) == key then return index end
		end
		error("no button " .. key .. " in " .. table.concat(dialog.choices, " / "))
	end
end

--- The cancel reason of an Ollama that never answered at its endpoint.
--- @return any reason
local function unreachable_reason()
	return require("modules.llm.ollama_endpoint").UNREACHABLE
end




-- =====================================
-- =====================================
-- ======= 2/ The AI Switch ============
-- =====================================
-- =====================================

helpers.describe("Enabling the AI with an unreachable local Ollama (llm-enable-unreachable-local)", function()
	helpers.it("Ollama down with oMLX up: the error offers oMLX first, whose button switches and enables (llm-enable-unreachable-local)",
		function()
			with_activation("ollama", { true, true }, {
				ollama_installed = false,
				local_servers_up = { omlx = { "Qwen3-8B-4bit", "gemma-3-4b-it" } },
				offer_pick = pick("llm.unreachable.use_server"),
			}, function(action, state, calls)
				action()
				helpers.assert_eq(#calls.offer_dialogs, 1, "one error names the fixes")
				local dialog = calls.offer_dialogs[1]
				helpers.assert_true(has(dialog.title, "Ollama"), "the error names the backend: " .. tostring(dialog.title))
				helpers.assert_true(has(dialog.message, OLLAMA_URL), "the error names the address: " .. tostring(dialog.message))
				helpers.assert_true(calls.sweeps >= 1, "the servers are swept before the error is shown")
				helpers.assert_eq(#dialog.choices, 2)
				helpers.assert_eq(dialog.choices[1], "llm.unreachable.use_server|oMLX|Qwen3-8B-4bit|localhost:8000",
					"the answering server is the first button, with its model and address")
				helpers.assert_eq(dialog.choices[2], "llm.unreachable.install|Ollama")
				helpers.assert_eq(dialog.cancel, "llm.unreachable.keep_off")
				helpers.assert_eq(calls.offers, 0, "no download-only offer ignores the running server")

				helpers.assert_eq(#calls.server_switches, 1)
				helpers.assert_eq(calls.server_switches[1].id, "omlx")
				helpers.assert_eq(calls.server_switches[1].model, "Qwen3-8B-4bit")
				helpers.assert_eq(state.llm_backend, "api", "the confirmed server is the backend")
				helpers.assert_eq(state.llm_enabled, true, "the fix turns the AI on")
				helpers.assert_eq(calls.ollama_installs, 0, "nothing is downloaded")
				helpers.assert_eq(calls.saves, 1, "one durable enable, with the server")
			end)
		end)

	helpers.it("Ollama down with nothing up: the error names Ollama and its address, and keeping it off commits nothing (llm-enable-unreachable-local)",
		function()
			with_activation("ollama", {}, { ollama_installed = false }, function(action, state, calls)
				action()
				helpers.assert_eq(#calls.offer_dialogs, 1, "one error names the fixes")
				local dialog = calls.offer_dialogs[1]
				helpers.assert_true(has(dialog.title, "Ollama"))
				helpers.assert_true(has(dialog.message, "llm.unreachable.body_unconfirmed|Ollama|" .. OLLAMA_URL),
					"the error says Ollama is missing and where nothing answers: " .. tostring(dialog.message))
				helpers.assert_true(has(dialog.message, "llm.unreachable.no_server|oMLX, LM Studio"),
					"the error says no local server answers either")
				helpers.assert_eq(#dialog.choices, 1)
				helpers.assert_eq(dialog.choices[1], "llm.unreachable.install|Ollama")

				helpers.assert_eq(state.llm_enabled, false, "the AI stays off")
				helpers.assert_eq(calls.saves, 0, "no enabled candidate is ever committed")
				helpers.assert_eq(calls.get_runtime_enabled(), false)
				helpers.assert_eq(calls.ollama_installs, 0, "keeping it off never downloads")
				helpers.assert_eq(calls.requirements, 0)
				helpers.assert_eq(calls.notifications, 0, "no \"AI enabled\" notice")
				helpers.assert_eq(calls.offers, 0)
			end)
		end)

	helpers.it("Ollama down with nothing up: the install button installs Ollama once, then checks the model (llm-enable-unreachable-local)",
		function()
			with_activation("ollama", { true }, {
				ollama_installed = false,
				version_receipts = {
					{ ok = false, status = 0, body = "" },
					{ ok = true, status = 200, body = '{"version":"fixture-after-install"}' },
				},
				offer_pick = pick("llm.unreachable.install"),
			}, function(action, state, calls)
				action()
				helpers.assert_eq(#calls.offer_dialogs, 1)
				helpers.assert_eq(calls.offers, 0, "the install button is the consent: not asked twice")
				helpers.assert_eq(calls.ollama_installs, 1)
				helpers.assert_eq(calls.requirements, 0, "the model check waits for the download")
				helpers.assert_type(calls.bootstrap_callback, "function")

				helpers.assert_eq(state.llm_enabled, false, "the AI remains off while its explicit installer owns work")
				helpers.assert_eq(calls.saves, 0)
				calls.bootstrap_callback(true)
				helpers.assert_eq(calls.service_repairs, 1)
				helpers.assert_eq(#calls.version_requests, 2, "native service publication must precede a fresh version proof")
				helpers.assert_eq(calls.requirements, 1, "the model is checked, and pulled, once Ollama exists")
				helpers.assert_eq(calls.ollama_installs, 1)
				helpers.assert_eq(state.llm_enabled, true)
			end)
		end)

	helpers.it("Ollama installed but not running: a start that never answers turns the AI back off and offers to start it (llm-enable-unreachable-local)",
		function()
			with_activation("ollama", { true, true, true }, {
				ollama_installed = true,
				offer_pick = pick("llm.unreachable.start"),
			}, function(action, state, calls)
				action()
				helpers.assert_eq(calls.requirements, 1, "enabling starts Ollama through the model check")

				calls.requirements_fail(unreachable_reason())
				helpers.assert_eq(state.llm_enabled, false, "the AI does not stay on with a dead backend")
				helpers.assert_eq(calls.get_runtime_enabled(), false)
				helpers.assert_eq(calls.saves, 2, "the enabled candidate is durably turned back off")
				helpers.assert_eq(calls.requirements_opts.reports_unreachable, true,
					"the switch reports a silent Ollama itself, not with a generic failure notice")
				helpers.assert_eq(#calls.offer_dialogs, 0, "a failure found after the click never opens a modal")
				local notices = unreachable_notices(calls)
				helpers.assert_eq(#notices, 1, "one notice names the failure")
				helpers.assert_true(has(notices[1].body, "Ollama") and has(notices[1].body, OLLAMA_URL),
					"the notice names the backend and its address: " .. tostring(notices[1].body))
				helpers.assert_type(notices[1].on_click, "function", "the notice opens the fixes")

				notices[1].on_click()
				helpers.assert_eq(#calls.offer_dialogs, 1)
				local dialog = calls.offer_dialogs[1]
				helpers.assert_true(has(dialog.message, "llm.unreachable.body_stopped|Ollama|" .. OLLAMA_URL))
				helpers.assert_eq(#dialog.choices, 1, "an installed Ollama is started, never downloaded again")
				helpers.assert_eq(dialog.choices[1], "llm.unreachable.start|Ollama")
				helpers.assert_eq(calls.requirements, 2, "the start button enables the AI, which starts Ollama")
				helpers.assert_eq(state.llm_enabled, true)
			end)
		end)

	helpers.it("the startup's offer posts one notice naming Ollama and its address, whose click opens the fixes (llm-enable-unreachable-local)",
		function()
			with_activation("ollama", { true }, {
				ollama_installed = false,
				local_servers_up = { lmstudio = { "qwen2.5-7b-instruct" } },
				offer_pick = pick("llm.unreachable.use_server"),
			}, function(_, state, calls)
				local ctx = calls.startup_ctx
				helpers.assert_type(ctx, "table")
				helpers.assert_type(ctx.offer_unreachable_ollama, "function",
					"the startup controller receives the offer")
				ctx.offer_unreachable_ollama()
				local notices = unreachable_notices(calls)
				helpers.assert_eq(#notices, 1)
				helpers.assert_true(has(notices[1].body, OLLAMA_URL))
				helpers.assert_eq(#calls.offer_dialogs, 0, "never a modal at startup")
				ctx.offer_unreachable_ollama()
				helpers.assert_eq(#unreachable_notices(calls), 1, "one notice until it is clicked")

				notices[1].on_click()
				helpers.assert_eq(calls.offer_dialogs[1].choices[1],
					"llm.unreachable.use_server|LM Studio|qwen2.5-7b-instruct|localhost:1234")
				helpers.assert_eq(state.llm_backend, "api")
				helpers.assert_eq(state.llm_enabled, true)
			end)
		end)
end)




-- =====================================
-- =====================================
-- ======= 3/ The Startup ==============
-- =====================================
-- =====================================

--- Builds a recording logger for the startup controller.
--- @return table logger
--- @return table records { errors = {}, warnings = {} }
local function recording_logger()
	local records = { errors = {}, warnings = {} }
	local logger = helpers.make_logger_stub()
	logger.error = function(_, template, ...)
		local ok, text = pcall(string.format, template, ...)
		records.errors[#records.errors + 1] = ok and text or template
	end
	logger.warn = function(_, template, ...)
		local ok, text = pcall(string.format, template, ...)
		records.warnings[#records.warnings + 1] = ok and text or template
	end
	return logger, records
end

--- Runs a startup with the AI on, firing its timers until the requirement
--- check is dispatched or nothing is left to fire.
--- @param options table { backend, installed, installed_models, on_check }.
--- @param callback function Receives (world).
local function with_startup(options, callback)
	helpers.with_fresh_modules({
		"infra.logger", "modules.llm", "adapters.timer_scheduler",
		"ui.menu.menu_llm.startup_controller", "modules.llm.ollama_endpoint",
	}, function()
		local logger, records = recording_logger()
		package.loaded["infra.logger"] = logger
		package.loaded["modules.llm"] = {
			BUILTIN_PROFILES = {},
			DEFAULT_STATE = { llm_ollama_port = 11434 },
			get_current_model = function() return "stub-model" end,
		}
		local timers = {}
		local StartupCtrl = helpers.load_with_stubs("ui.menu.menu_llm.startup_controller", {
			timer = {
				new = function(delay, fn)
					local timer = { delay = delay, fn = fn, live = false }
					function timer:start() self.live = true; return self end
					function timer:stop() self.live = false; return self end
					function timer:running() return self.live end
					timers[#timers + 1] = timer
					return timer
				end,
				secondsSinceEpoch = function() return os.time() end,
			},
		})
		local world = {
			records = records, saves = 0, offers = 0, checks = {}, polls = 0,
			state = { llm_enabled = true, llm_backend = options.backend, llm_model = "gemma-4-E2B-it" },
		}
		local models_mgr = {
			get_installed_models = function()
				world.polls = world.polls + 1
				return options.installed_models or {}
			end,
			check_requirements = function(model, on_ok, on_fail, opts)
				world.checks[#world.checks + 1] = { model = model, on_ok = on_ok, on_fail = on_fail, opts = opts }
				return true
			end,
		}
		local check_startup = StartupCtrl.new({
			state = world.state,
			keymap = {
				set_llm_backend_name = function() return true end,
				set_llm_enabled = function(enabled) world.runtime_enabled = enabled; return true end,
			},
			models_mgr = models_mgr,
			guarded_check_requirements = function() return true end,
			save_prefs = function() world.saves = world.saves + 1; return true end,
			update_menu = function() return true end,
			apply_llm_profile_shortcut = function() return true end,
			activate_hotkey = function() return true end,
			mlx_deps_checker = {},
			runtime_installed = function(backend)
				if backend == "ollama" then return options.installed == true end
				return true
			end,
			offer_unreachable_ollama = function() world.offers = world.offers + 1; return true end,
			deps = { update_menu = function() return true end },
			get_startup_silence = function() return false end,
			set_startup_silence = function() end,
			get_profile_hks = function() return {} end,
		})
		helpers.assert_eq(check_startup(), true, "the startup is accepted")
		-- The installed-models poll retries every second, ten times at most
		for _ = 1, 20 do
			local fired = false
			for _, timer in ipairs(timers) do
				if timer.live then
					timer.live = false
					timer.fn()
					fired = true
				end
			end
			if not fired or #world.checks > 0 then break end
		end
		--- Tells whether an error line contains a text.
		function world.errored(part)
			for _, line in ipairs(records.errors) do
				if has(line, part) then return true end
			end
			return false
		end
		callback(world)
	end)
end

helpers.describe("Starting with the AI on and an unreachable local backend (llm-enable-unreachable-local)", function()
	helpers.it("Ollama down with nothing installed: the AI turns off with a warning and the fixes, not a requirements error (llm-enable-unreachable-local)",
		function()
			with_startup({ backend = "ollama", installed = false }, function(world)
				helpers.assert_eq(world.state.llm_enabled, false, "the AI is off, as the menu shows")
				helpers.assert_eq(world.saves, 1, "the off state is durable")
				helpers.assert_eq(world.errored("requirements check failed"), false,
					"an explained failure never opens the generic error window")
				helpers.assert_eq(#world.records.errors, 0, table.concat(world.records.errors, " / "))
				helpers.assert_true(#world.records.warnings >= 1)
				helpers.assert_eq(world.offers, 1, "the error that names the fixes is offered once")
				helpers.assert_eq(#world.checks, 0, "a missing Ollama is not started")
			end)
		end)

	helpers.it("Ollama installed but not running: a start that never answers turns the AI off with its fixes (llm-enable-unreachable-local)",
		function()
			with_startup({ backend = "ollama", installed = true }, function(world)
				helpers.assert_eq(#world.checks, 1, "the startup waits, then starts Ollama through its check")
				helpers.assert_eq(world.state.llm_enabled, true, "the AI stays on while Ollama starts")

				world.checks[1].on_fail(unreachable_reason())
				helpers.assert_eq(world.state.llm_enabled, false)
				helpers.assert_eq(world.errored("requirements check failed"), false,
					"a silent Ollama is not an unexplained requirements failure")
				helpers.assert_eq(#world.records.errors, 0, table.concat(world.records.errors, " / "))
				helpers.assert_eq(world.offers, 1)
				helpers.assert_eq(world.checks[1].opts.reports_unreachable, true,
					"the startup reports a silent Ollama itself")
			end)
		end)

	helpers.it("oMLX chosen as the API backend is never checked against Ollama (llm-enable-unreachable-local)", function()
		with_startup({ backend = "api", installed = false }, function(world)
			helpers.assert_eq(#world.checks, 0, "a local OpenAI server has no Ollama requirement")
			helpers.assert_eq(world.polls, 0, "nor any Ollama model list to poll")
			helpers.assert_eq(world.state.llm_enabled, true, "the AI stays on")
			helpers.assert_eq(world.saves, 0)
			helpers.assert_eq(world.offers, 0)
			helpers.assert_eq(#world.records.errors, 0, table.concat(world.records.errors, " / "))
		end)
	end)
end)

helpers.describe("A startup failure nobody explains stays an error (llm-requirements-error-kept)", function()
	helpers.it("a model that fails to load still reports the requirements failure (llm-requirements-error-kept)", function()
		with_startup({ backend = "ollama", installed = true }, function(world)
			world.checks[1].on_fail("model_load_failed")
			helpers.assert_eq(world.state.llm_enabled, false)
			helpers.assert_eq(world.errored("requirements check failed"), true,
				"only the unreachable backend is explained; any other failure stays visible")
			helpers.assert_eq(world.offers, 0)
		end)
	end)
end)




-- =====================================
-- =====================================
-- ======= 4/ Requirements ==============
-- =====================================
-- =====================================

helpers.describe("The API backend has no local requirement (llm-enable-unreachable-local)", function()
	helpers.it("a local OpenAI server's requirement holds without asking Ollama (llm-enable-unreachable-local)", function()
		local modules = {
			"adapters.json_codec",
			"infra.logger", "infra.dialog_util", "infra.i18n", "infra.paths", "modules.llm",
			"ui.menu.menu_llm.models_manager_mlx", "ui.menu.menu_llm.models_manager_ollama",
			"ui.menu.menu_llm.models_manager",
		}
		local saved_hs, saved_open = _G.hs, io.open
		local ok, err = pcall(helpers.with_fresh_modules, modules, function()
			local asked = { ollama = 0, mlx = 0 }
			local function backend_manager(name)
				return {
					create_requirement_owner = function() return {} end,
					pause_requirements = function() return true, false end,
					check_requirements = function(_, _, on_cancel)
						asked[name] = asked[name] + 1
						-- A dead Ollama cancels, as its readiness probe does
						if type(on_cancel) == "function" then on_cancel(unreachable_reason()) end
						return true
					end,
					get_installed_models = function() return {} end,
				}
			end
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.dialog_util"] = { block_alert = function() return false end }
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.paths"] = { shared_llm_path = function() return "/fixture/models.json" end }
			package.loaded["modules.llm"] = { get_backend = function() return "api" end }
			package.loaded["ui.menu.menu_llm.models_manager_mlx"] = { new = function() return backend_manager("mlx") end }
			package.loaded["ui.menu.menu_llm.models_manager_ollama"] = {
				new = function() return backend_manager("ollama") end,
			}
			_G.hs = {
				json = { decode = function() return { { families = {} } } end },
				execute = function() return "" end,
				timer = { doAfter = function() return true end },
			}
			io.open = function()
				return { read = function() return "fixture" end, close = function() return true end }
			end
			local manager = require("ui.menu.menu_llm.models_manager").new({})
			local outcome = {}
			local accepted = manager.check_requirements("gemma-4-E2B-it",
				function() outcome.success = (outcome.success or 0) + 1; return true end,
				function(reason) outcome.cancel = reason; return true end, {})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(outcome.success, 1, "the API backend's requirement holds")
			helpers.assert_eq(outcome.cancel, nil, "a dead Ollama never cancels it")
			helpers.assert_eq(asked.ollama, 0, "Ollama is not asked")
			helpers.assert_eq(asked.mlx, 0)
		end)
		_G.hs, io.open = saved_hs, saved_open
		if not ok then error(err, 0) end
	end)
end)
