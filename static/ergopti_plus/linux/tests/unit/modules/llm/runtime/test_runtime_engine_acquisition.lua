--- tests/unit/modules/llm/runtime/test_runtime_engine_acquisition.lua

--- ==============================================================================
--- MODULE: Concrete Linux Runtime Construction Admission
--- DESCRIPTION:
--- Exercises the actual engine around explicit runtime UI and reentrant start
--- constructors. Controlled capabilities do not prove native resource cleanup.
--- ==============================================================================

local helpers = require("tests.helpers")
local function test(name, body) helpers.it(name .. " (ollama-runtime-engine)", body) end
local PreferencesFixture = require("tests.support.llm_preferences_fixture")

local function with_owner(body, options)
	options = options or {}
	local names = { "adapters.http_client", "modules.llm.enable_admission", "ui.llm_enable_refusal",
		"modules.llm.prediction_engine", "modules.llm.profiles", "infra.llm_preferences",
		"modules.llm.local_servers", "modules.llm.api_entries", "adapters.keyboard_hook",
		"adapters.shell_runner", "infra.i18n", "window_titles", "modules.llm.runtime_factory" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local world = { calls = {}, commits = {}, rejects = {}, changes = 0, cancels = {}, cancel_ok = true }
	world.live = { backend = "ollama", model = "model:2b", origin = "http://127.0.0.1:11434",
		generation = 1, enabled = false, paused = false, blocked = false, source = { status = "absent" } }
	local Http = {
		get = function(url, _, request, callback)
			world.calls[#world.calls + 1] = { url = url, request = request, callback = callback }
			if options.synchronous then callback(options.synchronous) end
			return options.dispatched ~= false
		end,
		cancel = function(owner)
			world.cancels[#world.cancels + 1] = owner
			return world.cancel_ok
		end,
	}
	world.owned_http = {}
	package.loaded["adapters.http_client"] = require("tests.support.owned_http_fixture").attach(Http, world.owned_http)
	package.loaded["modules.llm.enable_admission"] = nil
	world.owner = require("modules.llm.enable_admission").new({
		snapshot = function()
			if world.unreadable then error("unreadable source") end
			local snapshot = {}
			for key, value in pairs(world.live) do snapshot[key] = value end
			return snapshot
		end,
		commit = function(source)
			world.commits[#world.commits + 1] = source
			return world.write_ok ~= false
		end,
		reject = function(origin, reason)
			world.rejects[#world.rejects + 1] = { origin, reason }
			if world.on_reject then world.on_reject() end
			return world.choice
		end,
		changed = function() world.changes = world.changes + 1 end,
	})
	world.good = { ok = true, status = 200, body = '{"version":"0.12.3"}' }
	function world.answer(receipt, index) world.calls[index or #world.calls].callback(receipt or world.good) end
	function world.load_engine(backend)
		local preferences = PreferencesFixture.new({ initial = {
			["llm.enabled"] = false, ["llm.models.selected"] = backend or "ollama",
			["llm.models.ollama"] = "model:2b",
		} })
		package.loaded["infra.llm_preferences"] = preferences
		package.loaded["modules.llm.profiles"] = nil
		package.loaded["modules.llm.prediction_engine"] = nil
		world.private_source, world.private_current, world.view_current = {}, true, true
		world.servers = {
			is_stale = function() return world.discovery_stale ~= false end,
			is_sweeping = function() return world.sweeping == true end,
			detected = function() return { "lm_studio" } end,
			result = function() return { status = "up", models = { "typed:model" }, base_url = "http://127.0.0.1:1234/v1" } end,
			servers = function() return { lm_studio = { label = "LM Studio" } } end,
			capture = function() return world.private_source end,
			is_current = function(receipt, model)
				return world.view_current and receipt == world.private_source and model == "typed:model"
			end,
			apply = function(receipt, fields, admit)
				if not admit() or not world.servers.is_current(receipt, fields.model) or world.apply_refused then return nil end
				world.applied = (world.applied or 0) + 1
				world.active_entry = { id = "local-entry", model = fields.model }
				if world.after_apply then world.after_apply(preferences) end
				return { saved = true, entry = world.active_entry }
			end,
		}
		package.loaded["modules.llm.local_servers"] = world.servers
		package.loaded["modules.llm.api_entries"] = {
			capture_source = function() return world.private_source end,
			source_is_current = function(source) return world.private_current and source == world.private_source end,
			active = function() return world.active_entry end,
		}
		package.loaded["ui.llm_enable_refusal"] = { show = function(origin, replacements)
			world.rejects[#world.rejects + 1] = { origin }
			world.replacements = replacements
			if world.on_notice then world.on_notice(preferences) end
			local selected = replacements and replacements[world.choice_index or 0]
			return true, false, selected and selected.value
		end }
		world.engine = require("modules.llm.prediction_engine")
		world.engine.init({ is_paused = function() return world.live.paused end })
		return world.engine, preferences
	end
	function world.use_native_notice()
		package.loaded["adapters.shell_runner"] = {
			has_command = function(name) return name == "zenity" end,
			quote = function(value) return "'" .. value:gsub("'", "'\\''") .. "'" end,
			exec_checked = function()
				if world.during_dialog then world.during_dialog() end
				return true, world.native_answer or "replacement_1\n"
			end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["window_titles"] = { compose = function(value) return value end }
		local Hook = helpers.load_module("adapters.keyboard_hook")
		package.loaded["ui.llm_enable_refusal"] = nil
		return Hook
	end
	local ok, err = xpcall(function() body(world) end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

local function runtime_fixture(world, during_start)
	local engine = world.load_engine()
	world.factory_calls, world.pending_native, world.native_closed = 0, false, false
	local request = { result = nil }
	function request:is_settled() return world.native_closed end
	function request:cancel()
		world.native_cancels = (world.native_cancels or 0) + 1
		if world.native_closed then world.pending_native = false end
		return world.native_closed
	end
	function request:on_result(observer) world.result_observer = observer; return true end
	package.loaded["modules.llm.runtime_factory"] = {
		new = function()
			world.factory_calls = world.factory_calls + 1
			return {
				resolve = function() return { status = "installed" } end,
				source = {
					capture = function() return { origin = engine.get_base_url() } end,
					diagnostic_current = function() return false end,
				},
				controller = {
					has_debt = function() return world.pending_native end,
					stop_app = function() return true end,
					start = function()
						world.pending_native = true
						world.start_entered = true
						if during_start then during_start(engine) end
						return request
					end,
				},
			}
		end,
	}
	world.choice_index = 1
	return engine
end

helpers.describe("runtime acquisition reserves actual engine teardown", function()
	test("explicit runtime constructor cannot reinitialize before returned cleanup capability", function()
		with_owner(function(world)
			local engine = runtime_fixture(world, function(current)
				world.init_during_start = current.init({})
				world.pending_during_start = current.runtime_pending()
			end)
			helpers.assert_true(engine.enable())
			world.answer({ ok = false, status = 503, body = "" })
			helpers.assert_true(world.start_entered, "explicit existing-binary choice reached actual engine start")
			helpers.assert_eq(world.init_during_start, false)
			helpers.assert_true(world.pending_during_start)
			helpers.assert_true(engine.runtime_pending())
			helpers.assert_eq(world.factory_calls, 1)
			world.native_closed = true
			helpers.assert_true(engine.stop_runtime())
			helpers.assert_eq(engine.runtime_pending(), false)
			local revision = engine.streaming_revision()
			engine.init({})
			helpers.assert_true(engine.streaming_revision() > revision, "cleanup permits acknowledged reinitialization")
		end)
	end)
	test("scope cannot quiesce or snapshot unfinished runtime construction", function()
		with_owner(function(world)
			local scope
			local engine = runtime_fixture(world, function(current)
				scope = { pending = function() return current.runtime_pending() end }
				world.acquired = current.acquire_configuration(scope)
				world.quiesced = current.quiesce_configuration(scope)
				world.snapshot = current.configuration_snapshot(scope)
				world.released = current.release_configuration(scope)
			end)
			helpers.assert_true(engine.enable()); world.answer({ ok = false, status = 503, body = "" })
			helpers.assert_true(world.start_entered)
			helpers.assert_true(world.acquired)
			helpers.assert_eq(world.quiesced, false)
			helpers.assert_nil(world.snapshot)
			helpers.assert_eq(world.released, false)
			helpers.assert_true(engine.runtime_pending())
			world.native_closed = true
			helpers.assert_true(engine.stop_runtime())
			helpers.assert_true(engine.release_configuration(scope))
		end)
	end)
	test("unknown constructor retains exact engine acquisition barrier", function()
		with_owner(function(world)
			local engine = runtime_fixture(world, function() error("unknown after native acquisition") end)
			helpers.assert_true(engine.enable())
			local answered, retained = pcall(function()
				world.answer({ ok = false, status = 503, body = "" })
				return engine.runtime_pending()
			end)
			helpers.assert_true(answered, "unknown constructor is classified without escaping its logical callback")
			helpers.assert_true(retained, "unknown constructor retains native acquisition debt")
			helpers.assert_true(world.start_entered)
			helpers.assert_true(engine.runtime_pending())
			helpers.assert_eq(engine.init({}), false)
			helpers.assert_eq(world.factory_calls, 1)
		end)
	end)
end)


helpers.describe("runtime daemon pause and terminal authority", function()
	local function owned_app(world)
		local engine = runtime_fixture(world)
		local factory = package.loaded["modules.llm.runtime_factory"]
		local original = factory.new
		factory.new = function(native, ...)
			world.runtime_hooks = native
			local owner = original(native, ...)
			world.runtime_owner = owner
			owner.controller.stop_app = function()
				world.app_stops = (world.app_stops or 0) + 1
				return world.app_closed == true
			end
			return owner
		end
		helpers.assert_true(engine.enable())
		world.answer({ ok = false, status = 503, body = "" })
		helpers.assert_true(world.start_entered)
		return engine
	end

	test("actual pause retires the exact app epoch and preserves pending cleanup", function()
		with_owner(function(world)
			local engine = owned_app(world)
			local epoch = world.runtime_hooks.state().app_epoch
			world.live.paused = true
			local acknowledged = engine.on_pause_change(true)
			helpers.assert_eq(acknowledged, false)
			helpers.assert_eq(world.app_stops, 1)
			helpers.assert_true(world.runtime_hooks.state().app_epoch > epoch)
			helpers.assert_true(engine.runtime_pending())
			world.native_closed, world.app_closed = true, true
			helpers.assert_true(engine.stop_runtime())
			helpers.assert_eq(engine.runtime_pending(), false)
		end)
	end)

	test("terminal daemon authority cannot capture fresh repair after cleanup", function()
		with_owner(function(world)
			local engine = owned_app(world)
			world.native_closed, world.app_closed = true, true
			local shutdown = engine.shutdown_runtime or engine.stop_runtime
			helpers.assert_true(shutdown())
			local calls = #world.calls
			helpers.assert_eq(engine.enable(), false, "terminal cleanup must not admit a fresh enable request")
			helpers.assert_eq(#world.calls, calls, "terminal refusal occurs before network IO")
			helpers.assert_eq(engine.init({}), false)
			helpers.assert_eq(world.factory_calls, 1)
		end)
	end)

	test("terminal lexical writer hooks reject even freshly captured native revisions", function()
		with_owner(function(world)
			local engine = owned_app(world)
			world.native_closed, world.app_closed = true, true
			local shutdown = engine.shutdown_runtime or engine.stop_runtime
			helpers.assert_true(shutdown())
			local native = world.runtime_hooks
			local state = native.state()
			helpers.assert_true(state.blocked, "terminal owner must remain blocked after physical ACK")
			local observed = 0
			local admitted = native.admit_write(state.revision, state.app_epoch, state.enabled, function()
				observed = observed + 1
				return true
			end)
			helpers.assert_eq(admitted, false)
			helpers.assert_eq(observed, 1)
			helpers.assert_eq(native.publish_enabled(state.revision, state.app_epoch), false)
			helpers.assert_eq(native.restore_disabled(state.revision, state.app_epoch), false)
		end)
	end)
	test("terminal close revokes an ordinary version receipt before native stop reenters", function()
		with_owner(function(world)
			local engine = owned_app(world)
			world.native_closed = true
			helpers.assert_eq(engine.stop_runtime(), false)
			helpers.assert_true(engine.enable())
			local late_index = #world.calls
			local delivered, revoked_before_stop = 0, false
			local cancelled_before = #world.cancels
			world.runtime_owner.controller.stop_app = function()
				delivered = delivered + 1
				revoked_before_stop = #world.cancels > cancelled_before
				world.answer(world.good, late_index)
				return true
			end
			local shutdown = engine.shutdown_runtime or engine.stop_runtime
			helpers.assert_true(shutdown())
			helpers.assert_eq(delivered, 1, "native stop delivered the old physical probe callback")
			helpers.assert_true(revoked_before_stop, "exact ordinary probe cancellation precedes native teardown")
			helpers.assert_eq(engine.is_enabled(), false)
			helpers.assert_eq(package.loaded["modules.llm.profiles"].is_enabled(), false)
			helpers.assert_eq(package.loaded["infra.llm_preferences"].get("llm.enabled"), false)
		end)
	end)

	test("backend admission cannot acknowledge shutdown and then publish a selection", function()
		with_owner(function(world)
			local engine, preferences = world.load_engine()
			local after, writes = 0, 0
			local write_many = preferences.set_many
			preferences.set_many = function(...)
				writes = writes + 1
				return write_many(...)
			end
			local changed = engine.set_backend("api", function(phase)
				if phase == "after" then
					after = after + 1
					local shutdown = engine.shutdown_runtime or engine.stop_runtime
					world.shutdown_ack = shutdown()
				end
				return true
			end)
			helpers.assert_eq(after, 1)
			helpers.assert_eq(writes, 0, "terminal reentry is refused before invoking the preference writer")
			helpers.assert_true(world.shutdown_ack)
			helpers.assert_eq(changed, false)
			helpers.assert_eq(preferences.get("llm.models.selected"), "ollama")
		end)
	end)

	test("ordinary enable final writer admission refuses a terminal reentry", function()
		with_owner(function(world)
			local engine, preferences = world.load_engine()
			local write = preferences.set_many
			local guarded, attempts = false, 0
			preferences.set_many = function(values, source, admission)
				attempts = attempts + 1
				guarded = type(admission) == "function"
				local shutdown = engine.shutdown_runtime or engine.stop_runtime
				world.shutdown_ack = shutdown()
				-- Controlled final boundary; physical writer has independent disk cases.
				if guarded and admission() ~= true then return false end
				return write(values, source)
			end
			helpers.assert_true(engine.enable())
			world.answer(world.good)
			helpers.assert_eq(attempts, 1)
			helpers.assert_true(guarded, "actual Profiles.enable forwards the final admission")
			helpers.assert_true(world.shutdown_ack)
			helpers.assert_eq(preferences.get("llm.enabled"), false)
			helpers.assert_eq(package.loaded["modules.llm.profiles"].is_enabled(), false)
			helpers.assert_eq(engine.is_enabled(), false)
		end)
	end)

	test("backend final writer admission refuses shutdown after caller admission", function()
		with_owner(function(world)
			local engine, preferences = world.load_engine()
			local write_many, write_one = preferences.set_many, preferences.set
			local guarded, attempts = false, 0
			preferences.set_many = function(values, source, admission)
				attempts = attempts + 1
				guarded = type(admission) == "function"
				local shutdown = engine.shutdown_runtime or engine.stop_runtime
				world.shutdown_ack = shutdown()
				if guarded and admission() ~= true then return false end
				return write_many(values, source)
			end
			preferences.set = function(path, value)
				attempts = attempts + 1
				local shutdown = engine.shutdown_runtime or engine.stop_runtime
				world.shutdown_ack = shutdown()
				return write_one(path, value)
			end
			helpers.assert_eq(engine.set_backend("api"), false)
			helpers.assert_eq(attempts, 1)
			helpers.assert_true(guarded, "backend publication reaches the existing guarded writer")
			helpers.assert_true(world.shutdown_ack)
			helpers.assert_eq(preferences.get("llm.models.selected"), "ollama")
		end)
	end)

	test("terminal model and download entries refuse before native dispatch", function()
		local name = "modules.llm.model_download"
		local previous, starts = package.loaded[name], 0
		package.loaded[name] = {
			shutdown = function() return true end,
			start = function() starts = starts + 1; return true end,
		}
		local ok, err = xpcall(function()
			with_owner(function(world)
				local engine, preferences = world.load_engine()
				local shutdown = engine.shutdown_runtime or engine.stop_runtime
				helpers.assert_true(shutdown())
				helpers.assert_eq(engine.set_model("new:tag"), false)
				helpers.assert_eq(engine.download_model("new:tag", "Model"), false)
				helpers.assert_eq(starts, 0)
				helpers.assert_eq(preferences.get("llm.models.ollama"), "model:2b")
			end)
		end, debug.traceback)
		package.loaded[name] = previous
		if not ok then error(err, 0) end
	end)


	test("actual model selection forwards a final native terminal admission", function()
		with_owner(function(world)
			local engine, preferences = world.load_engine()
			local write_many, write_one = preferences.set_many, preferences.set
			local guarded, attempts = false, 0
			preferences.set_many = function(values, source, admission)
				attempts = attempts + 1
				guarded = type(admission) == "function"
				local shutdown = engine.shutdown_runtime or engine.stop_runtime
				world.shutdown_ack = shutdown()
				if guarded and admission() ~= true then return false end
				return write_many(values, source)
			end
			preferences.set = function(path, value)
				attempts = attempts + 1
				local shutdown = engine.shutdown_runtime or engine.stop_runtime
				world.shutdown_ack = shutdown()
				return write_one(path, value)
			end
			helpers.assert_eq(engine.set_model("new:tag"), false)
			helpers.assert_eq(attempts, 1)
			helpers.assert_true(guarded, "actual Profiles.set_model forwards exact source and final admission")
			helpers.assert_true(world.shutdown_ack)
			helpers.assert_eq(preferences.get("llm.models.ollama"), "model:2b")
			helpers.assert_eq(engine.get_current_model(), "model:2b")
		end)
	end)

	test("terminal shutdown retains ordinary probe cancellation refusal until exact ACK", function()
		with_owner(function(world)
			local engine = world.load_engine()
			helpers.assert_true(engine.enable())
			world.cancel_ok = false
			local shutdown = engine.shutdown_runtime or engine.stop_runtime
			helpers.assert_eq(shutdown(), false)
			helpers.assert_eq(engine.enable(), false)
			helpers.assert_eq(engine.is_enabled(), false)
			world.cancel_ok = true
			helpers.assert_true(shutdown())
			world.answer(world.good)
			helpers.assert_eq(engine.is_enabled(), false)
		end)
	end)
end)

--- Runs the real repair, engine, profiles, probe and chat graph over owned OS ports.
--- @param body function Receives actual producers and the retained service capability.
local function with_managed_responses(body)
	local names = { "modules.llm.api_ollama", "modules.llm.local_model_probe", "llm.runtime_repair" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local popen = io.popen
	local ok, failure = xpcall(function()
		with_owner(function(world)
			local engine = world.load_engine()
			local profiles = require("modules.llm.profiles")
			local Repair = require("llm.runtime_repair")
			world.responses, world.posts, world.observations = {}, {}, 0
			world.runtime_valid, world.service_current = true, true
			local engine_port, proof, app_source, app_epoch
			local runtime = { current = function() world.observations = world.observations + 1; return world.runtime_valid end,
				executable = function() return "/private/owned-ollama/bin/ollama" end }
			local function operation(kind, done, authorized)
				local op = { started = kind == "service" or kind == "timer", closed = false, listeners = {} }
				function op:is_settled() return self.closed end
				function op:on_settled(fn) if self.closed then fn() else self.listeners[#self.listeners + 1] = fn end; return true end
				function op:close()
					self.closed = true
					local listeners = self.listeners; self.listeners = {}
					for _, fn in ipairs(listeners) do fn() end
				end
				function op:cancel()
					world.native_cancels = (world.native_cancels or 0) + 1
					self.cancelled = true
					if kind ~= "service" or not world.hold_service then self:close() end
					return self.closed
				end
				function op:is_current() world.observations = world.observations + 1; return world.service_current and not self.closed and not self.cancelled and authorized() end
				function op:is_running()
					world.observations = world.observations + 1
					local admitted = kind == "service" and not self.exited and self:is_current()
					if world.observe_running then world.returned_running = true end
					return admitted and not self.exited and not self.closed and not self.cancelled
				end
				function op:answer(value) done(value); self:close() end
				return op
			end
			local ports = {
				current = function() return engine_port.state().enabled == false end,
				resolve = function() return { status = "installed", runtime = runtime } end,
				install = function() error("this graph never installs a binary") end,
				after = function(_, done) return operation("timer", done, function() return true end) end,
				now_ms = function() return 0 end,
				start_service = function(_, _, options, done)
					world.service = operation("service", done, options.authorized); return world.service
				end,
				probe = function(_, _, _, done) world.ready = operation("probe", done, function() return true end); return world.ready end,
				publish = function(_, acknowledge)
					local state = engine_port.state()
					if profiles.enable() ~= true or engine_port.publish_enabled(state.revision, state.app_epoch) ~= true then return false end
					proof = {}; return acknowledge(proof)
				end,
				app_capture = function(candidate)
					if candidate ~= proof then return nil end
					app_source, app_epoch = {}, engine_port.state().app_epoch; return app_source
				end,
				app_current = function(source)
					if world.on_observe then world.on_observe() end
					world.observations = world.observations + 1
					return source == app_source and engine_port.state().app_epoch == app_epoch
				end,
				compensate = function() return false end,
			}
			world.controller = Repair.new(ports, { bootstrap_timeout_ms = 100, poll_ms = 10 })
			package.loaded["modules.llm.runtime_factory"] = { new = function(captured)
				engine_port = captured
				return { controller = world.controller, resolve = function() return { status = "installed" } end,
					source = { capture = function() return { origin = engine.get_base_url() } end, diagnostic_current = function() return false end } }
			end }
			world.choice_index = 1
			helpers.assert_true(engine.enable()); world.answer({ ok = false, status = 503, body = "" })
			assert(world.ready, "the actual explicit repair acquired its version probe")
			world.ready:answer({ ok = true, status = 200, body = '{"version":"0.24.0"}' })
			helpers.assert_true(engine.is_enabled()); helpers.assert_eq(world.controller:app_status(), "running")
			local Http = package.loaded["adapters.http_client"]
			Http.postStream = function(url, _, _, _, chunk, done)
				world.posts[#world.posts + 1] = { url = url, chunk = chunk, done = done }; return true
			end
			world.api = helpers.load_module("modules.llm.api_ollama")
			world.profiles = profiles
			function world:chat(verify)
				return self.api.chat(engine.get_base_url(), "model:2b", {}, { verify_local_model = verify == true },
					function(text) self.responses[#self.responses + 1] = "chunk:" .. text end,
					function(text, err) self.responses[#self.responses + 1] = err or "done:" .. text end)
			end
			function world:respond()
				local post = assert(self.posts[#self.posts]); post.chunk('{"message":{"content":"stale"}}\n'); post.done({ ok = true, status = 200 })
			end
			function world:begin_app()
				local state = engine_port.state()
				assert(self.controller:stop_app())
				assert(profiles.disable()); assert(engine_port.restore_disabled(state.revision, state.app_epoch))
				return self.controller:start({ origin = engine.get_base_url() }, "start", true)
			end
			function world:replace_app()
				local request = self:begin_app()
				self.ready:answer({ ok = true, status = 200, body = '{"version":"0.24.0"}' })
				assert(request.result and request.result.ok == true)
				assert(self.controller:app_status() == "running")
			end
			body(world, engine)
			engine.stop_runtime(); world.api.cancel()
		end)
	end, debug.traceback)
	io.popen = popen
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(failure, 0) end
end

helpers.describe("managed response preserves the originating application", function()
	for _, unsettled in ipairs({ false, true }) do
		test("(linux-managed-response) stopped app cannot publish late stream, debt=" .. tostring(unsettled), function()
			with_managed_responses(function(world, engine)
				world:chat(); helpers.assert_eq(#world.posts, 1)
				world.hold_service = unsettled
				helpers.assert_eq(engine.stop_runtime(), not unsettled)
				world:respond(); helpers.assert_eq(#world.responses, 0, "same URL and unchanged chat epoch cannot revive the retired app")
			end)
		end)
	end
	test("(linux-managed-response) retained service exit cannot publish late stream or retire resources", function()
		with_managed_responses(function(world)
			world:chat(); world.service.exited = true
			local cancellations = world.native_cancels
			world:respond(); helpers.assert_eq(#world.responses, 0)
			helpers.assert_eq(world.native_cancels, cancellations, "response observations never stop or retire a service")
		end)
	end)
	test("(linux-managed-response) retired binary source cannot turn a tags response into chat", function()
		with_managed_responses(function(world)
			world:chat(true); local tags = world.calls[#world.calls]
			world.runtime_valid = false
			tags.callback({ ok = true, status = 200, body = '{"models":[{"name":"model:2b"}]}' })
			helpers.assert_eq(#world.posts, 0); helpers.assert_eq(#world.responses, 0)
		end)
	end)
	test("(linux-managed-response) origin construction cannot capture a successor after retiring the producer", function()
		with_managed_responses(function(world, engine)
			local Bridge = require("infra.llm_bridge"); local endpoint = Bridge.ollama_endpoint
			Bridge.ollama_endpoint = function(...) engine.stop_runtime(); return endpoint(...) end
			local called, failure = pcall(world.chat, world)
			Bridge.ollama_endpoint = endpoint
			helpers.assert_true(called, failure); helpers.assert_eq(#world.posts, 0); helpers.assert_eq(#world.responses, 0)
		end)
	end)
	test("(linux-managed-response) same app permits the original stream", function()
		with_managed_responses(function(world)
			world:chat(); world:respond()
			helpers.assert_eq(world.responses, { "chunk:stale", "done:stale" })
		end)
	end)
end)

helpers.describe("managed response private identities and inventory", function()
	test("(linux-managed-response) same-origin app replacement cannot borrow the unchanged engine epoch", function()
		with_managed_responses(function(world)
			world:chat(); world:replace_app(); world:respond()
			helpers.assert_eq(#world.responses, 0, "the original private app differs even at the same origin and engine epoch")
		end)
	end)
	test("(linux-managed-response) capture invokes no observer and forged handles cannot authenticate", function()
		with_managed_responses(function(world, engine)
			local before = world.observations
			local receipt = engine.capture_runtime_response()
			helpers.assert_eq(world.observations, before, "capture is lexical only")
			helpers.assert_eq(engine.runtime_response_current({}, engine.get_base_url()), false)
			receipt.app, receipt.epoch = {}, -1
			helpers.assert_true(engine.runtime_response_current(receipt, engine.get_base_url()), "caller fields have no authority")
			helpers.assert_eq(world.api.chat(engine.get_base_url(), "model:2b", {}, { runtime_response = {} }), false)
			helpers.assert_eq(#world.posts, 0)
		end)
	end)
	test("(linux-managed-response) endpoint reader retires the producer before model inventory dispatch", function()
		with_managed_responses(function(world, engine)
			local Bridge = require("infra.llm_bridge"); local endpoint = Bridge.ollama_endpoint
			local opens = 0
			io.popen = function() opens = opens + 1; return { read = function() return '{"models":[{"name":"stale"}]}' end, close = function() return true end } end
			Bridge.ollama_endpoint = function(...) engine.stop_runtime(); return endpoint(...) end
			local called, models = pcall(world.profiles.refresh_models)
			Bridge.ollama_endpoint = endpoint
			helpers.assert_true(called, models); helpers.assert_eq(models, {}); helpers.assert_eq(opens, 0)
		end)
	end)
	test("(linux-managed-response) same-origin service replacement during inventory read cannot publish models", function()
		with_managed_responses(function(world)
			io.popen = function() return { read = function() world:replace_app(); return '{"models":[{"name":"stale"}]}' end, close = function() return true end } end
			helpers.assert_eq(world.profiles.refresh_models(), {})
			helpers.assert_eq(world.profiles.get_current_model(), "model:2b")
		end)
	end)
	test("(linux-managed-response) inventory cache belongs to its original private app", function()
		with_managed_responses(function(world)
			local opens = 0
			io.popen = function() opens = opens + 1; return { read = function() return '{"models":[{"name":"model:2b"}]}' end, close = function() return true end } end
			helpers.assert_eq(world.profiles.refresh_models(), { "model:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "model:2b" }); helpers.assert_eq(opens, 1)
			world:replace_app()
			helpers.assert_eq(world.profiles.get_models(), { "model:2b" }); helpers.assert_eq(opens, 2, "a fresh app requires its own inventory response")
		end)
	end)
	test("(linux-managed-response) origin resolution refuses before borrowing a newer managed owner", function()
		with_managed_responses(function(world, engine)
			local getter = world.profiles.get_base_url
			world.profiles.get_base_url = function() world.profiles.get_base_url = getter; engine.stop_runtime(); return getter() end
			helpers.assert_nil(engine.resolve_backend())
			world.profiles.get_base_url = getter
		end)
	end)
end)

helpers.describe("managed response reentrancy and closed authority", function()
	test("(linux-managed-response) source observer cannot deliver an old chunk after installing a successor request", function()
		with_managed_responses(function(world)
			local chunks = {}
			world.api.chat(world.profiles.get_base_url(), "model:2b", {}, {}, function(text) chunks[#chunks + 1] = text end)
			local original = world.posts[1]
			world.on_observe = function()
				world.on_observe = nil
				world.api.chat(world.profiles.get_base_url(), "model:2b", {}, {}, function() end)
			end
			original.chunk('{"message":{"content":"old"}}\n')
			helpers.assert_eq(#world.posts, 2); helpers.assert_eq(chunks, {})
		end)
	end)
	test("(linux-managed-response) a chunk callback retiring the app fences later lines in that same native chunk", function()
		with_managed_responses(function(world, engine)
			local chunks = {}
			world.api.chat(engine.get_base_url(), "model:2b", {}, {}, function(text)
				chunks[#chunks + 1] = text; engine.stop_runtime()
			end)
			world.posts[1].chunk('{"message":{"content":"first"}}\n{"message":{"content":"second"}}\n')
			helpers.assert_eq(chunks, { "first" })
		end)
	end)
	for _, member in ipairs({ "capture_response", "response_current" }) do
		test("(linux-managed-response) replaced compatible controller port cannot grant custody: " .. member, function()
			with_managed_responses(function(world)
				local original = world.controller[member]
				world.controller[member] = function() return member == "response_current" and true or {} end
				local dispatched = world:chat()
				world.controller[member] = original
				helpers.assert_eq(dispatched, false); helpers.assert_eq(#world.posts, 0)
			end)
		end)
	end
	test("(linux-managed-response) stale response retains refused HTTP cancellation until actual acknowledgement", function()
		with_managed_responses(function(world, engine)
			world:chat(); engine.stop_runtime(); world:respond()
			world.cancel_ok = false
			helpers.assert_eq(world.api.cancel(), false); helpers.assert_true(world.api.is_active())
			helpers.assert_eq(world:chat(), false); helpers.assert_eq(#world.posts, 1)
			world.cancel_ok = true
			helpers.assert_true(world.api.cancel()); helpers.assert_eq(world.api.is_active(), false)
			helpers.assert_eq(world.responses, {}, "stale logical/cancel callbacks cannot claim replacement authority")
		end)
	end)
	test("(linux-managed-response) fresh unowned same-origin query is observable only through its actual response", function()
		with_managed_responses(function(world, engine)
			local before = engine.capture_runtime_response()
			helpers.assert_true(engine.stop_runtime())
			helpers.assert_eq(world.api.chat(engine.get_base_url(), "model:2b", {}, { runtime_response = before }), false)
			helpers.assert_eq(#world.posts, 0)
			world:chat(); world:respond()
			helpers.assert_eq(world.responses, { "chunk:stale", "done:stale" }, "a new explicit external query remains allowed, without a managed-identity claim")
		end)
	end)
end)

helpers.describe("managed response observer and cache publication order", function()
	test("(linux-managed-response) superseded synchronous inventory cannot overwrite a newer cache", function()
		with_managed_responses(function(world)
			local reads = 0
			io.popen = function() return { read = function()
				reads = reads + 1
				if reads == 1 then
					helpers.assert_eq(world.profiles.refresh_models(), { "new" })
					return '{"models":[{"name":"old"}]}'
				end
				return '{"models":[{"name":"new"}]}'
			end, close = function() return true end } end
			helpers.assert_eq(world.profiles.refresh_models(), {})
			helpers.assert_eq(world.profiles.get_models(), { "new" }); helpers.assert_eq(reads, 2)
		end)
	end)
	test("(linux-managed-response) final running proof has no later source observer", function()
		with_managed_responses(function(world, engine)
			local receipt = engine.capture_runtime_response()
			world.returned_running, world.observe_running = false, true
			world.on_observe = function() if world.returned_running then world.service.exited = true end end
			helpers.assert_true(engine.runtime_response_current(receipt, world.profiles.get_base_url()))
			helpers.assert_eq(world.service.exited, nil, "source callbacks cannot invalidate the final physical running observation")
			world.on_observe, world.observe_running = nil, false
		end)
	end)
	test("(linux-managed-response) reentrant controller-port replacement is refused by the originating wrapper", function()
		with_managed_responses(function(world, engine)
			local receipt = engine.capture_runtime_response()
			local original = world.controller.response_current
			world.on_observe = function() world.on_observe = nil; world.controller.response_current = function() return true end end
			local current = engine.runtime_response_current(receipt, world.profiles.get_base_url())
			world.controller.response_current = original
			helpers.assert_eq(current, false)
		end)
	end)
end)

helpers.describe("managed provisional source has no response authority", function()
	test("(linux-managed-response) provisional serve cannot borrow an absent app receipt", function()
		with_managed_responses(function(world, engine)
			local pending = world:begin_app()
			helpers.assert_eq(pending:is_settled(), false)
			local before = world.observations
			local receipt = engine.capture_runtime_response()
			helpers.assert_eq(world.observations, before)
			helpers.assert_eq(engine.runtime_response_current(receipt, world.profiles.get_base_url()), false)
			helpers.assert_eq(world:chat(), false); helpers.assert_eq(#world.posts, 0)
		end)
	end)
end)

helpers.describe("managed response reaches original transport admission", function()
	test("(linux-managed-response) repeated app stop revokes an already unowned request epoch", function()
		with_managed_responses(function(world, engine)
			assert(engine.stop_runtime()); world:chat(); assert(engine.stop_runtime()); world:respond()
			helpers.assert_eq(world.responses, {})
		end)
	end)
	test("(linux-managed-response) standalone tags response cannot borrow a replacement app", function()
		with_managed_responses(function(world, engine)
			local delivered = 0
			helpers.assert_true(require("modules.llm.local_model_probe").verify(engine.get_base_url(), "model:2b", nil,
				function() delivered = delivered + 1 end))
			local probe = world.calls[#world.calls]
			world:replace_app()
			probe.callback({ ok = true, status = 200, body = '{"models":[{"name":"model:2b"}]}' })
			helpers.assert_eq(delivered, 0)
		end)
	end)
	test("(linux-managed-response) native transport constructor receives the original final admission predicate", function()
		with_managed_responses(function(world, engine)
			local dispatched = 0
			package.loaded["adapters.http_client"].postStream = function(_, _, _, options)
				assert(engine.stop_runtime())
				if options.authorized and options.authorized() ~= true then return false end
				dispatched = dispatched + 1; return true
			end
			helpers.assert_eq(world:chat(), false)
			helpers.assert_eq(dispatched, 0, "the existing actual HTTP admission contract must reject after reentrant teardown")
		end)
	end)
end)

helpers.describe("managed response closes per-line observer currency", function()
	test("(linux-managed-response) per-line source observer cannot publish into a superseded request", function()
		with_managed_responses(function(world)
			local chunks = {}
			world.api.chat(world.profiles.get_base_url(), "model:2b", {}, {}, function(text) chunks[#chunks + 1] = text end)
			local original = world.posts[1]
			local Bridge = require("infra.llm_bridge"); local parse = Bridge.parse_stream_line
			Bridge.parse_stream_line = function(line)
				Bridge.parse_stream_line = parse
				world.on_observe = function()
					world.on_observe = nil
					world.api.chat(world.profiles.get_base_url(), "model:2b", {}, {}, function() end)
				end
				return parse(line)
			end
			local called, failure = pcall(original.chunk, '{"message":{"content":"old"}}\n')
			Bridge.parse_stream_line = parse
			helpers.assert_true(called, failure); helpers.assert_eq(#world.posts, 2); helpers.assert_eq(chunks, {})
		end)
	end)
end)

helpers.describe("managed response consumers retain constructor-bound engine ports", function()
	for _, consumer in ipairs({ "chat", "probe", "inventory" }) do
		test("(linux-managed-response) compatible latest engine exports cannot authorize " .. consumer, function()
			with_managed_responses(function(world, engine)
				local probe = helpers.load_module("modules.llm.local_model_probe")
				local capture, current = engine.capture_runtime_response, engine.runtime_response_current
				local opens, delivered = 0, 0
				io.popen = function() opens = opens + 1; return { read = function() return '{"models":[{"name":"forged"}]}' end, close = function() return true end } end
				engine.capture_runtime_response, engine.runtime_response_current = function() return {} end, function() return true end
				local probes = #world.calls
				local called, result = pcall(function()
					if consumer == "chat" then return world:chat() end
					if consumer == "probe" then return probe.verify(world.profiles.get_base_url(), "model:2b", nil, function() delivered = delivered + 1 end) end
					return world.profiles.refresh_models()
				end)
				engine.capture_runtime_response, engine.runtime_response_current = capture, current
				helpers.assert_true(called, result)
				if consumer == "inventory" then helpers.assert_eq(result, {}) else helpers.assert_eq(result, false) end
				helpers.assert_eq(#world.posts, 0); helpers.assert_eq(#world.calls, probes)
				helpers.assert_eq(opens, 0); helpers.assert_eq(delivered, 0)
			end)
		end)
	end
end)

helpers.describe("managed inventory getter retains its original invocation", function()
	local function install_inventory_pipe(world, names)
		world.inventory_opens = 0
		io.popen = function()
			world.inventory_opens = world.inventory_opens + 1
			return {
				read = function()
					if world.inventory_read then world.inventory_read() end
					local model = names[world.inventory_opens] or names[#names]
					return '{"models":[{"name":"' .. model .. '"}]}'
				end,
				close = function() return true end,
			}
		end
	end

	test("(linux-inventory-getter) shutdown refuses retained cache without touching personal selection", function()
		with_managed_responses(function(world, engine)
			install_inventory_pipe(world, { "original:2b" })
			helpers.assert_eq(world.profiles.refresh_models(), { "original:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "original:2b" })
			helpers.assert_eq(world.inventory_opens, 1)
			helpers.assert_true(engine.shutdown_runtime())
			helpers.assert_eq(world.profiles.get_models(), {}, "Refused refresh cannot expose the old cached inventory.")
			helpers.assert_eq(world.inventory_opens, 1)
			helpers.assert_eq(world.profiles.get_current_model(), "model:2b", "Configured selection remains personal state.")
		end)
	end)

	test("(linux-inventory-getter) exited retained service refuses stale cache without cleanup or transport", function()
		with_managed_responses(function(world)
			install_inventory_pipe(world, { "original:2b" })
			helpers.assert_eq(world.profiles.refresh_models(), { "original:2b" })
			local cancellations = world.native_cancels or 0
			world.service.exited = true
			helpers.assert_eq(world.profiles.get_models(), {})
			helpers.assert_eq(world.inventory_opens, 1)
			helpers.assert_eq(world.native_cancels or 0, cancellations, "Currency is read-only and grants no retirement.")
		end)
	end)

	test("(linux-inventory-getter) cached native observer cannot recapture a same-origin successor", function()
		with_managed_responses(function(world)
			install_inventory_pipe(world, { "original:2b", "successor:2b" })
			helpers.assert_eq(world.profiles.refresh_models(), { "original:2b" })
			world.on_observe = function()
				world.on_observe = nil
				world:replace_app()
			end
			helpers.assert_eq(world.profiles.get_models(), {}, "This getter belongs to the app captured before its observer.")
			helpers.assert_eq(world.inventory_opens, 1, "Only a fresh getter may dispatch to the successor app.")
			helpers.assert_eq(world.profiles.get_models(), { "successor:2b" })
			helpers.assert_eq(world.inventory_opens, 2)
		end)
	end)

	test("(linux-inventory-getter) reentrant newer inventory is preserved for its own fresh getter", function()
		with_managed_responses(function(world)
			install_inventory_pipe(world, { "original:2b", "newer:2b", "unexpected-third:2b" })
			helpers.assert_eq(world.profiles.refresh_models(), { "original:2b" })
			world.on_observe = function()
				world.on_observe = nil
				helpers.assert_eq(world.profiles.refresh_models(), { "newer:2b" })
			end
			helpers.assert_eq(world.profiles.get_models(), {}, "A superseded getter cannot publish a newer operation's cache.")
			helpers.assert_eq(world.inventory_opens, 2)
			helpers.assert_eq(world.profiles.get_models(), { "newer:2b" })
			helpers.assert_eq(world.inventory_opens, 2, "The original getter must not erase or refetch its successor's cache.")
		end)
	end)

	test("(linux-inventory-getter) fresh external response after app retirement retains ordinary caching", function()
		with_managed_responses(function(world, engine)
			install_inventory_pipe(world, { "original:2b", "external:2b" })
			helpers.assert_eq(world.profiles.refresh_models(), { "original:2b" })
			helpers.assert_true(engine.stop_runtime())
			helpers.assert_eq(world.profiles.get_models(), { "external:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "external:2b" })
			helpers.assert_eq(world.inventory_opens, 2, "Absence observes the transport response without authenticating an external PID.")
		end)
	end)

	test("(linux-inventory-getter) original empty-cache getter rejects delayed native read after service replacement", function()
		with_managed_responses(function(world)
			install_inventory_pipe(world, { "late:2b", "successor:2b" })
			world.inventory_read = function()
				world.inventory_read = nil
				world:replace_app()
			end
			helpers.assert_eq(world.profiles.get_models(), {})
			helpers.assert_eq(world.inventory_opens, 1)
			helpers.assert_eq(world.profiles.get_models(), { "successor:2b" })
			helpers.assert_eq(world.inventory_opens, 2)
		end)
	end)
	test("(linux-inventory-getter) delayed getter refresh returns refusal while preserving newer inventory", function()
		with_managed_responses(function(world)
			install_inventory_pipe(world, { "old-read:2b", "newer:2b" })
			world.inventory_read = function()
				world.inventory_read = nil
				helpers.assert_eq(world.profiles.refresh_models(), { "newer:2b" })
			end
			helpers.assert_eq(world.profiles.get_models(), {}, "The getter must return its refresh refusal, not the newer global cache.")
			helpers.assert_eq(world.inventory_opens, 2)
			helpers.assert_eq(world.profiles.get_models(), { "newer:2b" })
			helpers.assert_eq(world.inventory_opens, 2)
		end)
	end)

end)
