--- tests/unit/modules/llm/runtime/test_runtime_engine_acquisition_reserves_actual_teardown.lua

--- ==============================================================================
--- MODULE: Concrete Linux Runtime Construction Admission
--- DESCRIPTION:
--- Exercises the actual engine around explicit runtime UI and reentrant start
--- constructors. Controlled capabilities do not prove native resource cleanup.
--- ==============================================================================

package.loaded["tests.support.modules.llm.runtime.runtime_engine_acquisition_fixture"] = nil
local Fixture = require("tests.support.modules.llm.runtime.runtime_engine_acquisition_fixture")
local helpers, test, with_owner, runtime_fixture, with_managed_responses =
	Fixture.helpers, Fixture.test, Fixture.with_owner, Fixture.runtime_fixture, Fixture.with_managed_responses




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
			original.chunk('{"message":{"content":"old"},"done":true}\n')
			helpers.assert_eq(#world.posts, 2); helpers.assert_eq(chunks, {})
		end)
	end)
	test("(linux-managed-response) a chunk callback retiring the app fences later lines in that same native chunk", function()
		with_managed_responses(function(world, engine)
			local chunks = {}
			world.api.chat(engine.get_base_url(), "model:2b", {}, {}, function(text)
				chunks[#chunks + 1] = text; engine.stop_runtime()
			end)
			world.posts[1].chunk('{"message":{"content":"first"},"done":false}\n{"message":{"content":"second"},"done":true}\n')
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
			local called, failure = pcall(original.chunk, '{"message":{"content":"old"},"done":true}\n')
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

