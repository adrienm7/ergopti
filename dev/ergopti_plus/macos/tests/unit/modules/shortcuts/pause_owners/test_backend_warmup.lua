--- tests/unit/modules/shortcuts/pause_owners/test_backend_warmup.lua

--- ==============================================================================
--- MODULE: Pause Owner backend warmup Regressions
--- DESCRIPTION:
--- Preserves the behavioral pause-owner regression scenarios with a focused
--- fixture boundary. Shared fixtures create fresh runtime state per invocation.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixtures = require("tests.unit.modules.shortcuts.pause_owners.fixtures")
local reset_module = fixtures.reset_module
local load_inventory_context = fixtures.load_inventory_context
local get_upvalue = fixtures.get_upvalue

local function load_commit_staged_backend(kind, options)
	options = options or {}
	local timers = {}
	local timer_after_calls = 0
	local timer_after_modes = options.timer_after_modes or {}
	local timer_cancel_mode = "true"
	local timer_cancel_handles = {}
	local cancel_timer
	local timer_scheduler = {
		now = function() return 100 end,
		after = function(delay, callback)
			timer_after_calls = timer_after_calls + 1
			local mode = timer_after_modes[timer_after_calls] or "true"
			if mode == "throw" then error("resume-stage acquisition exploded") end
			if mode == "nil" then return nil, nil end
			if mode == "false" then return { timer = nil, committed = false }, false end
			local committed = mode ~= "partial"
			local handle = { timer = {}, committed = committed, observers = {} }
			local entry = { delay = delay, handle = handle }
			entry.callback = function()
				if handle.timer == nil then return end
				if handle.committed ~= true then
					pcall(cancel_timer, handle)
					return
				end
				handle.committed = false
				pcall(cancel_timer, handle)
				callback()
			end
			timers[#timers + 1] = entry
			return handle, committed
		end,
		cancel = function(handle)
			if type(handle) ~= "table" or handle.timer == nil then return true end
			handle.committed = false
			timer_cancel_handles[#timer_cancel_handles + 1] = handle
			if timer_cancel_mode == "throw" then error("resume-stage cancel exploded") end
			if timer_cancel_mode == "false" then return false end
			if timer_cancel_mode == "nil" then return nil end
			handle.timer = nil
			local observers = handle.observers or {}
			handle.observers = {}
			for _, observer in ipairs(observers) do observer() end
			return true
		end,
		onSettled = function(handle, observer)
			if type(handle) ~= "table" or type(observer) ~= "function" then return false end
			if handle.timer == nil then observer(); return true end
			handle.observers = handle.observers or {}
			handle.observers[#handle.observers + 1] = observer
			return true
		end,
	}
	cancel_timer = timer_scheduler.cancel
	package.loaded["adapters.timer_scheduler"] = timer_scheduler
	package.loaded["modules.shortcuts.script_control"] = {
		is_paused = function() return false end,
		get_pause_epoch = function() return 0 end,
	}
	local notifications = 0
	package.loaded["infra.notifications"] = {
		notify = function() notifications = notifications + 1 end,
	}
	local decrypt_callbacks = {}
	local decrypt_calls = 0
	if options.encrypted == true then
		package.loaded["modules.llm.api_token_crypto"] = {
			is_encrypted = function(value)
				return type(value) == "string" and value:sub(1, 9) == "keychain:"
			end,
			decrypt_async = function(_, callback)
				decrypt_calls = decrypt_calls + 1
				decrypt_callbacks[#decrypt_callbacks + 1] = callback
				return { cancel = function() return true end }
			end,
		}
	end
	local module_name = kind == "remote"
		and "modules.llm.api_remote" or "modules.llm.api_ollama"
	reset_module(module_name)
	local api = helpers.load_with_stubs(module_name)
	if kind == "remote" then
		api.PROVIDERS.fixture = {
			label = "Fixture",
			base_url = "https://fixture.invalid",
			default_model = "fixture-model",
			format = "openai",
		}
		api.set_entries({ {
			id = "entry-a",
			provider = "fixture",
			base_url = "https://fixture.invalid",
			token = options.encrypted == true and "keychain:fixture" or "plain-token",
			model = "fixture-model",
		} })
		api.set_active_entry_id("entry-a")
	end
	local client = get_upvalue(api.warmup, "_warmup_client")
	helpers.assert_not_nil(client)
	local requests = 0
	local request_modes = options.request_modes or {}
	local client_cleanup_debt = false
	local client_settlement_observers = {}
	local initial_callback = nil
	client.cancel = function() return true end
	client.onSettled = function(observer)
		if client_cleanup_debt ~= true then observer(); return true end
		client_settlement_observers[#client_settlement_observers + 1] = observer
		return true
	end
	local function capture_request(on_done)
		requests = requests + 1
		local mode = request_modes[requests] or "true"
		if mode ~= "true" and options.request_settlement_debt == true then
			client_cleanup_debt = true
		end
		if mode == "sync_false" then
			on_done(kind == "remote"
				and { ok = true, status = 200, body = [[{"data":[]}]] }
				or { status = 200 })
			return false
		end
		if mode == "throw" then error("warmup request acquisition exploded") end
		if mode == "false" then return false end
		if mode == "nil" then return nil end
		if requests == 1 then
			initial_callback = on_done
		else
			on_done(kind == "remote"
				and { ok = true, status = 200, body = [[{"data":[]}]] }
				or { status = 200 })
		end
		return true
	end
	if kind == "remote" then
		client.get = function(_, _, on_done) return capture_request(on_done) end
	else
		client.post = function(_, _, _, on_done) return capture_request(on_done) end
	end
	helpers.assert_true(api.warmup("fixture-model", nil))
	if options.encrypted == true then
		helpers.assert_not_nil(decrypt_callbacks[1])
		decrypt_callbacks[1](true, "plain-token", nil)
	end
	helpers.assert_not_nil(initial_callback)
	return {
		api = api,
		timers = timers,
		get_requests = function() return requests end,
		get_notifications = function() return notifications end,
		get_timer_cancel_handles = function() return timer_cancel_handles end,
		get_timer_after_calls = function() return timer_after_calls end,
		get_decrypt_calls = function() return decrypt_calls end,
		resolve_decrypt = function(index)
			decrypt_callbacks[index](true, "plain-token", nil)
		end,
		set_timer_cancel_mode = function(mode) timer_cancel_mode = mode end,
		settle_client = function()
			client_cleanup_debt = false
			local observers = client_settlement_observers
			client_settlement_observers = {}
			for _, observer in ipairs(observers) do observer() end
		end,
		fire_initial = function()
			initial_callback(kind == "remote"
				and { ok = true, status = 200, body = [[{"data":[]}]] }
				or { status = 200 })
		end,
	}
end

helpers.describe("HS-012 Remote/Ollama post-commit warmup staging", function()
	for _, kind in ipairs({ "remote", "ollama" }) do
		helpers.it(kind .. " explicit disable consumes paused restore intent", function()
			local backend = load_commit_staged_backend(kind)
			helpers.assert_true(backend.api.pause_warmup())
			helpers.assert_true(backend.api.stop_warmup(),
				"the explicit disable boundary must settle the paused owner")
			helpers.assert_true(backend.api.resume_warmup())
			helpers.assert_eq(#backend.timers, 0)
			helpers.assert_eq(backend.get_requests(), 1,
				"resume may not resurrect a warmup explicitly disabled during PAUSED")
			backend.fire_initial()
			helpers.assert_eq(backend.api.is_ready(), false)
		end)

		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(kind .. " recovers a clean " .. mode
				.. " request and retry-stage refusal", function()
				local backend = load_commit_staged_backend(kind, {
					timer_after_modes = { "true", mode, mode },
					request_modes = { "true", mode, "true" },
				})
				local script_control = load_inventory_context({
					remote = kind == "remote" and backend.api or nil,
					ollama = kind == "ollama" and backend.api or nil,
				})
				helpers.assert_true(script_control.pause_all())
				backend.fire_initial()
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(#backend.timers, 1)
				helpers.assert_eq(backend.api.is_ready(), false)
				helpers.assert_eq(backend.api.is_ready(), false)
				helpers.assert_eq(#backend.timers, 1,
					"readiness polling must not replace a committed resume stage")
				helpers.assert_eq(backend.get_timer_after_calls(), 1)
				backend.timers[1].callback()
				helpers.assert_eq(backend.get_timer_after_calls(), 3,
					"post-commit recovery must make only two bounded staging attempts")
				helpers.assert_eq(backend.get_requests(), 3,
					"clean staging refusal must fall back to one exact direct request")
				helpers.assert_true(backend.api.is_ready(),
					"the bounded direct fallback must restore readiness")
				backend.timers[1].callback()
				helpers.assert_eq(backend.get_requests(), 3,
					"duplicate stage delivery cannot repeat the fallback")
				helpers.assert_true(backend.api.stop_warmup())
				script_control.stop()
			end)
		end

		helpers.it(kind .. " publishes one successor after synchronous stage settlement", function()
			local backend = load_commit_staged_backend(kind, {
				timer_after_modes = { "true", "partial", "true", "true" },
				request_modes = { "true", "false", "true" },
			})
			local script_control = load_inventory_context({
				remote = kind == "remote" and backend.api or nil,
				ollama = kind == "ollama" and backend.api or nil,
			})
			helpers.assert_true(script_control.pause_all())
			backend.fire_initial()
			helpers.assert_true(script_control.resume_all())
			backend.timers[1].callback()
			helpers.assert_eq(backend.get_timer_after_calls(), 2)
			helpers.assert_eq(#backend.timers, 2,
				"the refused retry stage must retain its exact live handle")

			helpers.assert_eq(backend.api.is_ready(), false)
			helpers.assert_eq(backend.get_timer_after_calls(), 3,
				"synchronous onSettled reentrance may publish only one successor")
			helpers.assert_eq(#backend.timers, 3)
			helpers.assert_eq(backend.api.is_ready(), false)
			helpers.assert_eq(backend.get_timer_after_calls(), 3,
				"the committed successor must be idempotent under polling")
			backend.timers[3].callback()
			helpers.assert_eq(backend.get_requests(), 3)
			helpers.assert_true(backend.api.is_ready())
			helpers.assert_true(backend.api.stop_warmup())
			script_control.stop()
		end)

		for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(kind .. " joins a due resume stage after terminal stop "
				.. stop_mode, function()
				local backend = load_commit_staged_backend(kind)
				local script_control = load_inventory_context({
					remote = kind == "remote" and backend.api or nil,
					ollama = kind == "ollama" and backend.api or nil,
				})
				helpers.assert_true(script_control.pause_all())
				backend.fire_initial()
				helpers.assert_true(script_control.resume_all())
				backend.set_timer_cancel_mode(stop_mode)
				backend.timers[1].callback()
				helpers.assert_eq(backend.get_requests(), 1,
					"a due stage cannot dispatch while its native timer remains live")
				helpers.assert_eq(backend.get_timer_after_calls(), 1)
				helpers.assert_eq(backend.api.is_ready(), false)
				helpers.assert_eq(backend.get_timer_after_calls(), 1,
					"polling cannot acquire over terminal timer cleanup debt")

				backend.set_timer_cancel_mode("true")
				backend.timers[1].callback()
				helpers.assert_eq(backend.get_timer_after_calls(), 2,
					"settlement may publish one replacement stage")
				helpers.assert_eq(backend.get_requests(), 1)
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 2)
				helpers.assert_true(backend.api.is_ready())
				backend.timers[1].callback()
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 2)
				helpers.assert_true(backend.api.stop_warmup())
				script_control.stop()
			end)
		end

		helpers.it(kind .. " discards a synchronous response when dispatch refuses", function()
			local backend = load_commit_staged_backend(kind, {
				request_modes = { "true", "sync_false", "true" },
			})
			local script_control = load_inventory_context({
				remote = kind == "remote" and backend.api or nil,
				ollama = kind == "ollama" and backend.api or nil,
			})
			helpers.assert_true(script_control.pause_all())
			backend.fire_initial()
			helpers.assert_true(script_control.resume_all())
			backend.timers[1].callback()
			helpers.assert_eq(backend.api.is_ready(), false,
				"a response delivered before false dispatch cannot publish readiness")
			helpers.assert_eq(#backend.timers, 2,
				"the refused dispatch must retain intent through one retry stage")
			backend.timers[2].callback()
			helpers.assert_true(backend.api.is_ready())
			helpers.assert_eq(backend.get_requests(), 3)
			if kind == "ollama" then
				helpers.assert_eq(backend.get_notifications(), 1,
					"only the committed response may notify readiness")
			end
			helpers.assert_true(backend.api.stop_warmup())
			script_control.stop()
		end)

		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(kind .. " waits for internal HTTP " .. mode
				.. " debt before staging a successor", function()
				local backend = load_commit_staged_backend(kind, {
					request_modes = { "true", mode, "true" },
					request_settlement_debt = true,
				})
				local script_control = load_inventory_context({
					remote = kind == "remote" and backend.api or nil,
					ollama = kind == "ollama" and backend.api or nil,
				})
				helpers.assert_true(script_control.pause_all())
				backend.fire_initial()
				helpers.assert_true(script_control.resume_all())
				backend.timers[1].callback()
				helpers.assert_eq(backend.get_requests(), 2)
				helpers.assert_eq(backend.get_timer_after_calls(), 1,
					"an internal HTTP owner must settle before any retry timer exists")
				helpers.assert_eq(backend.api.is_ready(), false)
				helpers.assert_eq(backend.api.is_ready(), false)
				helpers.assert_eq(backend.get_timer_after_calls(), 1,
					"readiness polling cannot bypass the retained HTTP owner")

				backend.settle_client()
				helpers.assert_eq(backend.get_timer_after_calls(), 2,
					"exact client settlement may acquire one retry stage")
				helpers.assert_eq(#backend.timers, 2)
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 3)
				helpers.assert_true(backend.api.is_ready())
				backend.settle_client()
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 3)
				helpers.assert_true(backend.api.stop_warmup())
				script_control.stop()
			end)
		end

		if kind == "remote" then
			for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
				helpers.it("remote starts no decrypt while due stage stop is "
					.. stop_mode, function()
					local backend = load_commit_staged_backend("remote", { encrypted = true })
					local script_control = load_inventory_context({ remote = backend.api })
					helpers.assert_true(script_control.pause_all())
					backend.fire_initial()
					helpers.assert_true(script_control.resume_all())
					backend.set_timer_cancel_mode(stop_mode)
					backend.timers[1].callback()
					helpers.assert_eq(backend.get_decrypt_calls(), 1,
						"terminal timer debt must fence the resumed Keychain operation")
					helpers.assert_eq(backend.get_requests(), 1)
					backend.set_timer_cancel_mode("true")
					backend.timers[1].callback()
					helpers.assert_eq(#backend.timers, 2)
					backend.timers[2].callback()
					helpers.assert_eq(backend.get_decrypt_calls(), 2)
					helpers.assert_eq(backend.get_requests(), 1)
					backend.resolve_decrypt(2)
					helpers.assert_eq(backend.get_requests(), 2)
					helpers.assert_true(backend.api.is_ready())
					helpers.assert_true(backend.api.stop_warmup())
					script_control.stop()
				end)
			end

			for _, mode in ipairs({ "false", "nil", "throw" }) do
				helpers.it("remote retains encrypted resume intent after late GET "
					.. mode, function()
					local backend = load_commit_staged_backend("remote", {
						encrypted = true,
						request_modes = { "true", mode, "true" },
						request_settlement_debt = true,
					})
					local script_control = load_inventory_context({ remote = backend.api })
					helpers.assert_true(script_control.pause_all())
					backend.fire_initial()
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(#backend.timers, 1)
					helpers.assert_eq(backend.api.is_ready(), false)
					helpers.assert_eq(#backend.timers, 1,
						"readiness polling cannot replace the committed stage")

					backend.timers[1].callback()
					helpers.assert_eq(backend.get_decrypt_calls(), 2,
						"stage delivery must own one resumed Keychain operation")
					helpers.assert_eq(backend.get_requests(), 1)
					helpers.assert_eq(backend.api.is_ready(), false)
					helpers.assert_eq(backend.api.is_ready(), false)
					helpers.assert_eq(backend.get_decrypt_calls(), 2,
						"polling cannot replace the asynchronous resolver lease")

					backend.resolve_decrypt(2)
					helpers.assert_eq(backend.get_requests(), 2)
					helpers.assert_eq(backend.get_timer_after_calls(), 1,
						"late GET debt must block every retry stage")
					backend.settle_client()
					helpers.assert_eq(#backend.timers, 2)
					backend.timers[2].callback()
					helpers.assert_eq(backend.get_decrypt_calls(), 2,
						"retry must reuse the already-resolved token cache without a sibling Keychain task")
					helpers.assert_eq(backend.get_requests(), 3)
					helpers.assert_true(backend.api.is_ready())
					backend.resolve_decrypt(2)
					helpers.assert_eq(backend.get_requests(), 3,
						"duplicate stale decrypt completion cannot launch a sibling GET")
					helpers.assert_true(backend.api.stop_warmup())
					script_control.stop()
				end)
			end
		end

		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(kind .. " stays inert when a later resume owner returns " .. mode, function()
				local backend = load_commit_staged_backend(kind)
				local script_control = load_inventory_context({
					remote = kind == "remote" and backend.api or nil,
					ollama = kind == "ollama" and backend.api or nil,
					fail_owner = "wpm_menubar",
					fail_mode = mode,
					fail_direction = "resume",
				})
				helpers.assert_true(script_control.pause_all())
				backend.fire_initial()
				helpers.assert_eq(backend.api.is_ready(), false,
					"the pre-pause terminal must be generation-fenced")

				helpers.assert_eq(script_control.resume_all(), false)
				helpers.assert_true(script_control.is_paused())
				helpers.assert_eq(#backend.timers, 1,
					"the backend must stage exactly one post-commit owner")
				backend.timers[1].callback()
				helpers.assert_eq(backend.get_requests(), 1,
					"a rollback-retained timer callback may not dispatch under PAUSED")
				helpers.assert_eq(backend.get_notifications(), 0)

				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(#backend.timers, 2)
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 2)
				helpers.assert_true(backend.api.is_ready())
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 2,
					"duplicate staged delivery must remain one-shot")
				if kind == "ollama" then
					helpers.assert_eq(backend.get_notifications(), 1)
				end
				helpers.assert_true(backend.api.stop_warmup())
				script_control.stop()
			end)
		end

		for _, cancel_mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(kind .. " retains the same resume stage after " .. cancel_mode
				.. " rollback cancellation", function()
				local backend = load_commit_staged_backend(kind)
				local script_control = load_inventory_context({
					remote = kind == "remote" and backend.api or nil,
					ollama = kind == "ollama" and backend.api or nil,
					fail_owner = "wpm_menubar",
					fail_mode = "false",
					fail_direction = "resume",
				})
				helpers.assert_true(script_control.pause_all())
				backend.set_timer_cancel_mode(cancel_mode)
				helpers.assert_eq(script_control.resume_all(), false)
				helpers.assert_true(script_control.is_paused())
				helpers.assert_eq(#backend.timers, 1)
				local retained_stage = backend.timers[1]
				local cancel_handles = backend.get_timer_cancel_handles()
				helpers.assert_eq(cancel_handles[1], retained_stage.handle,
					"rollback must retain the exact post-commit timer capability")

				retained_stage.callback()
				helpers.assert_eq(backend.get_requests(), 1,
					"retained callback remains inert while the global transaction is PAUSED")
				helpers.assert_eq(cancel_handles[#cancel_handles], retained_stage.handle,
					"callback retry must target the same unsettled handle")

				backend.set_timer_cancel_mode("true")
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(cancel_handles[#cancel_handles], retained_stage.handle,
					"resume retry must settle the retained handle before acquiring a successor")
				helpers.assert_eq(#backend.timers, 2)
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 2)
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 2)
				helpers.assert_true(backend.api.stop_warmup())
				script_control.stop()
			end)
		end
	end
end)

helpers.describe("HS-012 real Remote warmup generation", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("joins shared prewarm Keychain ownership after " .. mode, function()
			local decrypt_callbacks = {}
			local decrypt_calls = 0
			local cancel_calls = 0
			local operations = {}
			local cancelled_operations = {}
			local cancel_mode = mode
			package.loaded["modules.llm.api_token_crypto"] = {
				is_encrypted = function() return true end,
				decrypt_async = function(_, callback)
					decrypt_calls = decrypt_calls + 1
					decrypt_callbacks[#decrypt_callbacks + 1] = callback
					local operation = {}
					function operation.cancel()
						cancel_calls = cancel_calls + 1
						cancelled_operations[#cancelled_operations + 1] = operation
						if cancel_mode == "throw" then error("Keychain cancel exploded") end
						if cancel_mode == "false" then return false end
						if cancel_mode == "nil" then return nil end
						return true
					end
					operations[#operations + 1] = operation
					return operation
				end,
			}
			package.loaded["modules.shortcuts.script_control"] = {
				is_paused = function() return false end,
				get_pause_epoch = function() return 0 end,
			}
			reset_module("modules.llm.api_remote")
			local ApiRemote = helpers.load_with_stubs("modules.llm.api_remote")
			ApiRemote.PROVIDERS.fixture = {
				label = "Fixture",
				base_url = "https://fixture.invalid",
				default_model = "fixture-model",
				format = "openai",
			}
			ApiRemote.set_entries({ {
				id = "entry-keychain",
				provider = "fixture",
				base_url = "https://fixture.invalid",
				token = "keychain:fixture",
				model = "fixture-model",
			} })
			ApiRemote.set_active_entry_id("entry-keychain")
			local client = get_upvalue(ApiRemote.warmup, "_warmup_client")
			local get_calls = 0
			client.get = function()
				get_calls = get_calls + 1
				return true
			end
			client.cancel = function() return true end

			ApiRemote.prewarm_active_entry_decrypt()
			helpers.assert_true(ApiRemote.warmup("fixture-model"))
			helpers.assert_not_nil(decrypt_callbacks[1])
			helpers.assert_eq(decrypt_calls, 1)
			helpers.assert_eq(ApiRemote.pause_warmup(), false,
				"the shared prewarm operation must reject non-exact cancellation")
			helpers.assert_eq(cancel_calls, 1)
			cancel_mode = "true"
			helpers.assert_true(ApiRemote.pause_warmup())
			helpers.assert_eq(cancel_calls, 2,
				"the exact same Keychain operation must remain retryable")
			helpers.assert_eq(cancelled_operations[1], operations[1])
			helpers.assert_eq(cancelled_operations[2], operations[1])
			decrypt_callbacks[1](true, "plain-token", nil)
			helpers.assert_eq(get_calls, 0,
				"a late shared resolver terminal must remain inert after pause")
			helpers.assert_true(ApiRemote.resume_warmup())
			helpers.assert_eq(decrypt_calls, 2,
				"the exact encrypted warmup intent must survive cancellation debt")
			helpers.assert_true(operations[2] ~= operations[1],
				"restoration must acquire one fresh Keychain operation after settlement")
			helpers.assert_eq(get_calls, 0)
			helpers.assert_eq(ApiRemote.is_ready(), false)
			helpers.assert_eq(ApiRemote.is_ready(), false)
			helpers.assert_eq(decrypt_calls, 2,
				"readiness polling cannot replace an owned resumed Keychain lease")
			decrypt_callbacks[2](true, "plain-token", nil)
			helpers.assert_eq(get_calls, 1)
			helpers.assert_true(ApiRemote.resume_warmup())
			helpers.assert_eq(decrypt_calls, 2)
			helpers.assert_eq(get_calls, 1,
				"duplicate resume may not acquire a sibling warmup")
			helpers.assert_true(ApiRemote.stop_warmup())
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps and restores Remote intent after " .. mode .. " cancellation", function()
			-- The preceding encrypted-owner matrix installs an always-encrypted
			-- TokenCrypto double. Restore the real prefix contract so this plain-token
			-- positive control cannot accidentally wait on a phantom Keychain task.
			package.loaded["modules.llm.api_token_crypto"] = {
				is_encrypted = function(value)
					return type(value) == "string" and value:sub(1, 9) == "keychain:"
				end,
				decrypt_async = function()
					error("plain-token warmup must not dispatch Keychain decryption")
				end,
			}
			package.loaded["modules.shortcuts.script_control"] = {
				is_paused = function() return false end,
				get_pause_epoch = function() return 0 end,
			}
			reset_module("modules.llm.api_remote")
			local ApiRemote = helpers.load_with_stubs("modules.llm.api_remote")
			ApiRemote.PROVIDERS.fixture = {
				label = "Fixture",
				base_url = "https://fixture.invalid",
				default_model = "fixture-model",
				format = "openai",
			}
			ApiRemote.set_entries({ {
				id = "entry-a",
				provider = "fixture",
				base_url = "https://fixture.invalid",
				token = "plain-token",
				model = "fixture-model",
			} })
			ApiRemote.set_active_entry_id("entry-a")
			local client = get_upvalue(ApiRemote.warmup, "_warmup_client")
			helpers.assert_not_nil(client)
			local callback = nil
			local get_calls = 0
			local original_get = client.get
			local original_cancel = client.cancel
			client.get = function(_, _, on_done)
				get_calls = get_calls + 1
				callback = on_done
				return true
			end
			local cancel_mode = mode
			client.cancel = function()
				if cancel_mode == "false" then return false end
				if cancel_mode == "nil" then return nil end
				if cancel_mode == "throw" then error("remote cancellation exploded") end
				return true
			end

			ApiRemote.warmup()
			helpers.assert_eq(type(callback), "function",
				"positive control must dispatch the real Remote warmup callback")
			callback({ ok = true, status = 200, body = [[{"data":[]}]] })
			helpers.assert_eq(ApiRemote.is_ready(), true,
				"positive control proves the production callback can publish readiness")
			ApiRemote.warmup()
			local late_callback = callback
			helpers.assert_eq(ApiRemote.pause_warmup(), false,
				"non-exact HTTP settlement must reject the pause owner")
			late_callback({ ok = true, status = 200, body = [[{"data":[]}]] })
			helpers.assert_eq(ApiRemote.is_ready(), false,
				"the generation fence must beat a refused native cancellation")
			helpers.assert_eq(ApiRemote.resume_warmup(), false,
				"rollback may not consume intent over the same cancellation debt")
			cancel_mode = "true"
			helpers.assert_true(ApiRemote.resume_warmup())
			helpers.assert_eq(ApiRemote.is_ready(), false,
				"readiness stays fenced until the resumed request completes")
			helpers.assert_eq(get_calls, 3)
			callback({ ok = true, status = 200, body = [[{"data":[]}]] })
			helpers.assert_eq(ApiRemote.is_ready(), true)
			helpers.assert_true(ApiRemote.resume_warmup())
			helpers.assert_eq(get_calls, 3,
				"duplicate resume must not replay a settled Remote warmup")
			client.get = original_get
			client.cancel = original_cancel
		end)
	end
end)

helpers.describe("HS-012 real Ollama warmup generation", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps and restores Ollama intent after " .. mode .. " cancellation", function()
			package.loaded["modules.shortcuts.script_control"] = {
				is_paused = function() return false end,
				get_pause_epoch = function() return 0 end,
			}
			reset_module("modules.llm.api_ollama")
			local ApiOllama = helpers.load_with_stubs("modules.llm.api_ollama")
			local client = get_upvalue(ApiOllama.warmup, "_warmup_client")
			helpers.assert_not_nil(client)
			local callback = nil
			local post_calls = 0
			local cancel_mode = mode
			local original_post = client.post
			local original_cancel = client.cancel
			client.post = function(_, _, _, on_done)
				post_calls = post_calls + 1
				callback = on_done
				return true
			end
			client.cancel = function()
				if cancel_mode == "false" then return false end
				if cancel_mode == "nil" then return nil end
				if cancel_mode == "throw" then error("Ollama cancellation exploded") end
				return true
			end

			helpers.assert_true(ApiOllama.warmup("fixture-model"))
			callback({ status = 200 })
			helpers.assert_true(ApiOllama.is_ready())
			ApiOllama.reset_ready()
			helpers.assert_true(ApiOllama.warmup("fixture-model"))
			local late_callback = callback
			helpers.assert_eq(ApiOllama.pause_warmup(), false)
			late_callback({ status = 200 })
			helpers.assert_eq(ApiOllama.is_ready(), false)
			helpers.assert_eq(ApiOllama.resume_warmup(), false)
			cancel_mode = "true"
			helpers.assert_true(ApiOllama.resume_warmup())
			helpers.assert_eq(ApiOllama.is_ready(), false)
			helpers.assert_eq(post_calls, 3)
			callback({ status = 200 })
			helpers.assert_true(ApiOllama.is_ready())
			helpers.assert_true(ApiOllama.resume_warmup())
			helpers.assert_eq(post_calls, 3)
			client.post = original_post
			client.cancel = original_cancel
		end)
	end
end)

return true
