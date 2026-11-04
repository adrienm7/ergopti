--- tests/support/modules/llm/runtime/runtime_engine_acquisition_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_runtime_engine_acquisition
--- DESCRIPTION:
--- Prelude shared by the test_runtime_engine_acquisition_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local function test(name, body) helpers.it(name .. " (ollama-runtime-engine)", body) end

local PreferencesFixture = require("tests.support.llm_preferences_fixture")

local function with_owner(body, options)
	options = options or {}
	local names = { "adapters.http_client", "modules.llm.enable_admission", "ui.llm_enable_refusal",
		"modules.llm.prediction_engine", "modules.llm.profiles", "modules.llm.model_inventory", "infra.llm_preferences",
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
		package.loaded["modules.llm.model_inventory"] = nil
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

--- Runs the real repair, engine, profiles, probe and chat graph over owned OS ports.
--- @param body function Receives actual producers and the retained service capability.
local function with_managed_responses(body)
	local names = { "modules.llm.api_ollama", "modules.llm.local_model_probe", "llm.runtime_repair",
		"modules.llm.model_inventory", "infra.managed_http_deadline" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local popen = io.popen
	local ok, failure = xpcall(function()
		with_owner(function(world)
			require("tests.support.modules.llm.runtime.inventory_fixture").install(world)
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
				local post = assert(self.posts[#self.posts]); post.chunk('{"message":{"content":"stale"},"done":true}\n'); post.done({ ok = true, status = 200 })
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

return {
	helpers = helpers,
	test = test,
	PreferencesFixture = PreferencesFixture,
	with_owner = with_owner,
	runtime_fixture = runtime_fixture,
	with_managed_responses = with_managed_responses,
}
