--- tests/unit/modules/llm/test_runtime_engine_acquisition.lua

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
