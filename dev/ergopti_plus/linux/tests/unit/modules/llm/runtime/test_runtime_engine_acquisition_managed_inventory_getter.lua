--- tests/unit/modules/llm/runtime/test_runtime_engine_acquisition_managed_inventory_getter.lua

--- ==============================================================================
--- MODULE: Concrete Linux Inventory Acquisition
--- DESCRIPTION:
--- Drives the actual Engine runtime response authority and Profiles inventory
--- through controlled defer, HTTP and physical settlement boundaries.
--- ==============================================================================

package.loaded["tests.support.modules.llm.runtime.runtime_engine_acquisition_fixture"] = nil
local Fixture = require("tests.support.modules.llm.runtime.runtime_engine_acquisition_fixture")
local helpers, test, with_managed_responses = Fixture.helpers, Fixture.test, Fixture.with_managed_responses

local function fetch(world, models)
	helpers.assert_eq(world.profiles.refresh_models(), {})
	world:inventory_defer()
	world:inventory_answer(models)
end

--- Keeps failed initialization assertions separate from physical cleanup acknowledgement.
--- @param body function Exercises the original Profiles and Engine constructors.
local function with_initialization(body)
	with_managed_responses(function(world, engine)
		local ok, failure = pcall(body, world, engine, world.profiles)
		helpers.assert_true(world.profiles.cancel_model_inventory())
		helpers.assert_eq(world.profiles.model_inventory_pending(), false)
		helpers.assert_true(engine.shutdown_runtime())
		helpers.assert_eq(world.controller:has_debt(), false)
		for _, operations in ipairs({ world.inventory_defers, world.inventory_requests }) do
			for _, operation in ipairs(operations) do helpers.assert_true(operation:is_settled()) end
		end
		if not ok then error(failure, 0) end
	end)
end

--- Uses the actual Engine and downloader with controlled owned HTTP/window ports.
--- @param body function Receives the runtime world, Engine and captured pull.
local function with_model_pull(body)
	with_initialization(function(world, engine)
		local previous_download, previous_window = package.loaded["modules.llm.model_download"], package.loaded["ui.download_window.bridge"]
		local Http = package.loaded["adapters.http_client"]
		local previous_post, pulls, completions = Http.post_stream_owned, {}, {}
		local controlled = require("tests.support.owned_http_fixture").attach({
			postStream = function(url, _, _, options, chunk, done)
				pulls[#pulls + 1] = { url = url, options = options, chunk = chunk, done = done }
				return true
			end,
			cancel = function() return true end,
		})
		Http.post_stream_owned = controlled.post_stream_owned
		package.loaded["ui.download_window.bridge"] = {
			show = function() return 1 end, session_id = function() return 1 end,
			update = function() return true end, focus = function(id) return id == 1 end,
			complete = function(_, succeeded) completions[#completions + 1] = succeeded; return true end,
			retire = function(id) return id == 1 end,
		}
		package.loaded["modules.llm.model_download"] = nil
		local Download = require("modules.llm.model_download")
		local ok, failure = xpcall(function() body(world, engine, pulls, completions) end, debug.traceback)
		local closed = Download.shutdown()
		Http.post_stream_owned = previous_post
		package.loaded["modules.llm.model_download"], package.loaded["ui.download_window.bridge"] = previous_download, previous_window
		helpers.assert_true(closed)
		if not ok then error(failure, 0) end
	end)
end

helpers.describe("post-install inventory observation", function()
	test("(linux-inventory-mutation) actual pull success waits old HTTP ACK then observes installed models afresh", function()
		with_model_pull(function(world, engine, pulls, completions)
			local notifications = 0
			helpers.assert_true(world.profiles.init({ on_models_changed = function() notifications = notifications + 1 end }))
			engine.get_models(); world:inventory_defer()
			world.inventory_hold_settlement = "http"
			world:inventory_answer({ "old:2b" })
			local selected = 0
			helpers.assert_true(engine.download_model("new:2b", "New model", function(success, tag)
				helpers.assert_true(success); helpers.assert_eq(tag, "new:2b"); selected = selected + 1
			end))
			helpers.assert_eq(pulls[1].url, engine.get_base_url() .. "/api/pull")
			helpers.assert_true(pulls[1].options.authorized())
			pulls[1].chunk('{"status":"success"}\n'); pulls[1].done({ ok = true, status = 200 })
			helpers.assert_eq({ selected, engine.get_current_model(), #completions }, { 1, "new:2b", 1 })
			helpers.assert_eq(#world.inventory_defers, 1, "logical tags result cannot release native debt")
			helpers.assert_eq(engine.get_cached_models(), {})
			helpers.assert_eq(notifications, 0, "obsolete tags cannot notify menu or browser")
			world.inventory_requests[1]:close()
			helpers.assert_eq(#world.inventory_defers, 2)
			helpers.assert_eq(#world.inventory_requests, 1, "the fresh request remains deferred")
			world.inventory_hold_settlement = nil
			world:inventory_defer(); world:inventory_answer({ "old:2b", "new:2b", "Case:Latest" })
			helpers.assert_eq(engine.get_models(), { "old:2b", "new:2b", "Case:Latest" })
			helpers.assert_eq(notifications, 1)
			helpers.assert_eq(world.profiles.model_inventory_pending(), false)
		end)
	end)

	test("(linux-inventory-mutation) failed pull leaves the ordinary pending inventory unchanged", function()
		with_model_pull(function(world, engine, pulls, completions)
			engine.get_models(); world:inventory_defer()
			local callbacks = 0
			helpers.assert_true(engine.download_model("new:2b", "New model", function(success)
				helpers.assert_eq(success, false); callbacks = callbacks + 1
			end))
			pulls[1].done({ ok = false, status = 503 })
			helpers.assert_eq({ callbacks, #completions, engine.get_current_model() }, { 1, 1, "model:2b" })
			world:inventory_answer({ "old:2b" })
			helpers.assert_eq(engine.get_models(), { "old:2b" })
			helpers.assert_eq(#world.inventory_defers, 1)
		end)
	end)

	test("(linux-inventory-mutation) real pull completion cannot select after mutation-defer runtime withdrawal", function()
		with_model_pull(function(world, engine, pulls)
			local callbacks = 0
			helpers.assert_true(engine.download_model("new:2b", "New model", function() callbacks = callbacks + 1 end))
			world.inventory_during_defer = function()
				world.inventory_during_defer = nil
				engine.stop_runtime()
			end
			pulls[1].chunk('{"status":"success"}\n'); pulls[1].done({ ok = true, status = 200 })
			helpers.assert_eq(engine.get_current_model(), "model:2b")
			helpers.assert_eq(callbacks, 0)
			helpers.assert_eq(#world.inventory_requests, 0)
		end)
	end)

	test("(linux-inventory-mutation) multiple mutations reserve one follow-up while ordinary refresh still coalesces", function()
		with_initialization(function(world, engine, profiles)
			engine.get_models(); world:inventory_defer()
			for _ = 1, 5 do profiles.refresh_models_after_mutation(); engine.refresh_models() end
			helpers.assert_eq(#world.inventory_defers, 1)
			world:inventory_answer({ "obsolete:2b" })
			helpers.assert_eq(engine.get_cached_models(), {})
			helpers.assert_eq(#world.inventory_defers, 2)
			world:inventory_defer(); world:inventory_answer({ "installed:2b" })
			for _ = 1, 5 do helpers.assert_eq(engine.get_models(), { "installed:2b" }) end
			helpers.assert_eq(#world.inventory_defers, 2)
		end)
	end)

	test("(linux-inventory-mutation) mutation without pending work invalidates the previous cache", function()
		with_initialization(function(world, engine, profiles)
			fetch(world, { "old:2b" })
			profiles.refresh_models_after_mutation()
			helpers.assert_eq(engine.get_cached_models(), {})
			helpers.assert_eq(#world.inventory_defers, 2)
			world:inventory_defer(); world:inventory_answer({ "old:2b", "new:2b" })
			helpers.assert_eq(engine.get_models(), { "old:2b", "new:2b" })
		end)
	end)

	test("(linux-inventory-mutation) obsolete failure permits one explicit follow-up but fresh failure never auto-retries", function()
		with_initialization(function(world, engine, profiles)
			engine.get_models(); world:inventory_defer(); profiles.refresh_models_after_mutation()
			world.inventory_requests[1]:answer({ ok = false, status = 503, body = "" })
			helpers.assert_eq(#world.inventory_defers, 2)
			world:inventory_defer()
			world.inventory_requests[2]:answer({ ok = false, status = 503, body = "" })
			for _ = 1, 5 do helpers.assert_eq(engine.get_models(), {}) end
			helpers.assert_eq(#world.inventory_defers, 2)
			helpers.assert_eq(profiles.model_inventory_pending(), false)
			profiles.refresh_models(); world:inventory_defer(); world:inventory_answer({ "recovered:2b" })
			helpers.assert_eq(engine.get_models(), { "recovered:2b" })
		end)
	end)

	for _, action in ipairs({ "cancel", "stop", "shutdown" }) do
		test("(linux-inventory-mutation) " .. action .. " revokes the follow-up before old cancellation ACK", function()
			with_initialization(function(world, engine, profiles)
				engine.get_models(); world:inventory_defer(); profiles.refresh_models_after_mutation()
				world.inventory_hold_cancel = "http"
				local cancel = action == "cancel" and profiles.cancel_model_inventory
					or (action == "stop" and engine.stop_runtime or engine.shutdown_runtime)
				helpers.assert_eq(cancel(), false)
				helpers.assert_eq(#world.inventory_defers, 1)
				helpers.assert_eq(world.inventory_requests[1]:is_settled(), false)
				world.inventory_requests[1]:close()
				helpers.assert_eq(#world.inventory_defers, 1, "late close cannot resurrect the revoked mutation")
				world.inventory_hold_cancel = nil
				helpers.assert_true(cancel())
				helpers.assert_eq(profiles.get_cached_models(), {})
			end)
		end)
	end

	test("(linux-inventory-mutation) same-origin app successor cannot inherit an old mutation intent", function()
		with_initialization(function(world, engine, profiles)
			engine.get_models(); world:inventory_defer(); profiles.refresh_models_after_mutation()
			world:replace_app()
			world:inventory_answer({ "stale:2b" })
			helpers.assert_eq(#world.inventory_defers, 1)
			helpers.assert_eq(engine.get_cached_models(), {})
			engine.get_models(); world:inventory_defer(); world:inventory_answer({ "successor:2b" })
			helpers.assert_eq(engine.get_models(), { "successor:2b" })
			helpers.assert_eq(#world.inventory_defers, 2)
		end)
	end)

	test("(linux-inventory-mutation) replacement Profiles refuses an old callback and its retained follow-up", function()
		with_initialization(function(world, engine, profiles)
			engine.get_models(); world:inventory_defer(); profiles.refresh_models_after_mutation()
			local original = package.loaded["modules.llm.profiles"]
			package.loaded["modules.llm.profiles"] = {}
			local ok, failure = pcall(function()
				world:inventory_answer({ "stale:2b" })
				helpers.assert_eq(#world.inventory_defers, 1)
				helpers.assert_eq(profiles.get_cached_models(), {})
			end)
			package.loaded["modules.llm.profiles"] = original
			if not ok then error(failure, 0) end
			helpers.assert_eq(profiles.get_cached_models(), {})
			helpers.assert_eq(#world.inventory_defers, 1, "module replacement is a lifecycle fixture, not runtime hot reload")
		end)
	end)

	test("(linux-inventory-mutation) source withdrawal during fresh capture cannot lend the successor lease", function()
		with_initialization(function(world, engine, profiles)
			engine.get_models(); world:inventory_defer(); profiles.refresh_models_after_mutation()
			world.inventory_hold_settlement = "http"
			world:inventory_answer({ "obsolete:2b" })
			world.on_observe = function() world.on_observe = nil; world:replace_app() end
			world.inventory_requests[1]:close()
			helpers.assert_eq(#world.inventory_defers, 1)
			helpers.assert_eq(engine.get_cached_models(), {})
		end)
	end)

	test("(linux-inventory-mutation) delayed deferred close ACK cannot start either HTTP acquisition early", function()
		with_initialization(function(world, engine, profiles)
			engine.get_models()
			world.inventory_hold_settlement = "defer"
			world:inventory_defer(); profiles.refresh_models_after_mutation()
			helpers.assert_eq(#world.inventory_requests, 0)
			helpers.assert_eq(#world.inventory_defers, 1)
			world.inventory_defers[1]:close()
			helpers.assert_eq(#world.inventory_requests, 1)
			helpers.assert_eq(#world.inventory_defers, 1)
			world.inventory_hold_settlement = nil
			world:inventory_answer({ "obsolete:2b" })
			helpers.assert_eq(#world.inventory_defers, 2)
			world:inventory_defer(); world:inventory_answer({ "installed:2b" })
			helpers.assert_eq(engine.get_models(), { "installed:2b" })
		end)
	end)

	for _, mutation in ipairs({ false, true }) do
		test("(linux-inventory-mutation) cancellation inside idle-source observation revokes " .. (mutation and "mutation" or "cold") .. " acquisition", function()
			with_initialization(function(world, engine, profiles)
				local acknowledged
				world.on_observe = function()
					world.on_observe = nil
					acknowledged = profiles.cancel_model_inventory()
				end
				if mutation then profiles.refresh_models_after_mutation() else engine.get_models() end
				helpers.assert_true(acknowledged, "same-origin cancellation needs no Engine epoch change")
				helpers.assert_eq(#world.inventory_defers, 0, "an interrupted reader cannot acquire after cancellation ACK")
				helpers.assert_eq(profiles.model_inventory_pending(), false)
			end)
		end)
	end

	test("(linux-inventory-mutation) cancellation during old settlement observation revokes the entire handoff", function()
		with_initialization(function(world, engine, profiles)
			engine.get_models(); world:inventory_defer(); profiles.refresh_models_after_mutation()
			world.inventory_hold_settlement = "http"
			world:inventory_answer({ "obsolete:2b" })
			local acknowledged
			world.on_observe = function()
				world.on_observe = nil
				acknowledged = profiles.cancel_model_inventory()
			end
			world.inventory_requests[1]:close()
			helpers.assert_true(acknowledged)
			helpers.assert_eq(#world.inventory_defers, 1)
			helpers.assert_eq(profiles.model_inventory_pending(), false)
			helpers.assert_eq(engine.get_cached_models(), {})
		end)
	end)

	test("(linux-inventory-mutation) intent during defer construction cannot acquire before returned capability ACK", function()
		with_initialization(function(world, engine, profiles)
			world.inventory_during_defer = function()
				world.inventory_during_defer = nil
				profiles.refresh_models_after_mutation()
				helpers.assert_eq(#world.inventory_requests, 0)
			end
			engine.get_models()
			helpers.assert_eq(#world.inventory_defers, 1)
			world:inventory_defer(); world:inventory_answer({ "obsolete:2b" })
			helpers.assert_eq(#world.inventory_defers, 2)
			world:inventory_defer(); world:inventory_answer({ "installed:2b" })
			helpers.assert_eq(engine.get_models(), { "installed:2b" })
		end)
	end)
end)

helpers.describe("profile initialization recovery", function()
	test("(linux-inventory-init-recovery) invalid explicit model preserves publication and permits a valid successor", function()
		with_initialization(function(_, engine, profiles)
			local origin, model, enabled = profiles.get_base_url(), profiles.get_current_model(), profiles.is_enabled()
			local ok, failure = pcall(profiles.init, { port = 12543, model = "" })
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(failure):find("the configured Ollama model must be nonempty", 1, true) ~= nil)
			helpers.assert_eq({ profiles.get_base_url(), profiles.get_current_model(), profiles.is_enabled() }, { origin, model, enabled })
			helpers.assert_true(profiles.init({ model = "recovered:2b" }))
			helpers.assert_eq(profiles.get_current_model(), "recovered:2b")
			helpers.assert_true(engine.init({}) ~= false)
		end)
	end)

	test("(linux-inventory-init-recovery) real malformed preferences can be repaired before Engine retries", function()
		with_initialization(function(_, engine, profiles)
			local Sandbox = require("test.config_unused_keys_contract").sandbox
			Sandbox.with_config("[llm\n", function(path)
				local previous_paths, previous_preferences = package.loaded["infra.config_paths"], package.loaded["infra.llm_preferences"]
				package.loaded["infra.config_paths"] = { config = function() return path end }
				package.loaded["infra.llm_preferences"] = nil
				local ok, failure = pcall(function()
					local preferences = require("infra.llm_preferences")
					local called, detail = pcall(engine.init, {})
					helpers.assert_eq(called, false)
					helpers.assert_true(tostring(detail):find("AI configuration contains malformed TOML", 1, true) ~= nil)
					Sandbox.write_bytes(path, '[llm]\nenabled = false\n[llm.models]\nollama = "repaired:2b"\n')
					helpers.assert_eq(preferences.get_many({ "llm.models.ollama" })["llm.models.ollama"], "repaired:2b")
					helpers.assert_true(engine.init({}) ~= false)
					helpers.assert_eq(profiles.get_current_model(), "repaired:2b")
				end)
				package.loaded["infra.config_paths"], package.loaded["infra.llm_preferences"] = previous_paths, previous_preferences
				if not ok then error(failure, 0) end
			end)
		end)
	end)

	for _, kind in ipairs({ "defer", "http" }) do
		test("(linux-inventory-init-recovery) retained " .. kind .. " cancellation blocks until the original physical ACK", function()
			with_initialization(function(world, engine, profiles)
				profiles.get_models()
				if kind == "http" then world:inventory_defer() end
				local operation = kind == "http" and world.inventory_requests[1] or world.inventory_defers[1]
				world.inventory_hold_cancel = kind
				helpers.assert_eq(profiles.init({ model = "" }), false)
				helpers.assert_true(operation.cancelled)
				helpers.assert_true(profiles.model_inventory_pending())
				helpers.assert_eq(operation:is_settled(), false)
				helpers.assert_eq(profiles.init({ model = "recovered:2b" }), false)
				helpers.assert_eq(profiles.get_current_model(), "model:2b")
				operation:close()
				helpers.assert_true(operation:is_settled())
				helpers.assert_true(profiles.init({ model = "recovered:2b" }))
				helpers.assert_eq(profiles.get_current_model(), "recovered:2b")
				helpers.assert_true(engine.init({}) ~= false)
			end)
		end)
	end

	test("(linux-inventory-init-recovery) inventory construction rejects reentry before publishing any staged value", function()
		with_initialization(function(_, _, profiles)
			local Inventory = require("modules.llm.model_inventory")
			local original, captured, nested = Inventory.new, nil, nil
			local origin, model, enabled = profiles.get_base_url(), profiles.get_current_model(), profiles.is_enabled()
			Inventory.new = function(context)
				captured = context
				nested = profiles.init({ model = "reentrant:2b" })
				helpers.assert_eq(context.retained(), false)
				helpers.assert_eq({ profiles.get_base_url(), profiles.get_current_model(), profiles.is_enabled() }, { origin, model, enabled })
				return original(context)
			end
			local called, result = pcall(profiles.init, { port = 12543, model = "outer:2b" })
			Inventory.new = original
			if not called then error(result, 0) end
			helpers.assert_true(result)
			helpers.assert_eq(nested, false)
			helpers.assert_true(captured.retained())
			helpers.assert_eq(profiles.get_current_model(), "outer:2b")
			helpers.assert_true(profiles.get_base_url():find(":12543", 1, true) ~= nil)
		end)
	end)

	test("(linux-inventory-init-recovery) inventory constructor error is rethrown unchanged and releases the initializer", function()
		with_initialization(function(_, _, profiles)
			local Inventory = require("modules.llm.model_inventory")
			local original, sentinel = Inventory.new, {}
			local origin, model, enabled = profiles.get_base_url(), profiles.get_current_model(), profiles.is_enabled()
			Inventory.new = function() error(sentinel, 0) end
			local called, failure = pcall(profiles.init, { port = 12543, model = "unpublished:2b" })
			Inventory.new = original
			helpers.assert_eq(called, false)
			helpers.assert_true(rawequal(failure, sentinel))
			helpers.assert_eq({ profiles.get_base_url(), profiles.get_current_model(), profiles.is_enabled() }, { origin, model, enabled })
			helpers.assert_true(profiles.init({ model = "recovered:2b" }))
			helpers.assert_eq(profiles.get_current_model(), "recovered:2b")
		end)
	end)
end)

helpers.describe("managed inventory getter retains its original invocation", function()
	test("(linux-inventory-getter) shutdown refuses retained cache without touching personal selection", function()
		with_managed_responses(function(world, engine)
			fetch(world, { "original:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "original:2b" })
			helpers.assert_true(engine.shutdown_runtime())
			helpers.assert_eq(world.profiles.get_models(), {})
			helpers.assert_eq(#world.inventory_requests, 1)
			helpers.assert_eq(world.profiles.get_current_model(), "model:2b")
		end)
	end)

	test("(linux-inventory-getter) exited retained service refuses stale cache without cleanup or transport", function()
		with_managed_responses(function(world)
			fetch(world, { "original:2b" })
			local cancellations = world.inventory_cancels or 0
			world.service.exited = true
			helpers.assert_eq(world.profiles.get_models(), {})
			helpers.assert_eq(#world.inventory_requests, 1)
			helpers.assert_eq(world.inventory_cancels or 0, cancellations)
		end)
	end)

	test("(linux-inventory-getter) cached native observer cannot recapture a same-origin successor", function()
		with_managed_responses(function(world)
			fetch(world, { "original:2b" })
			world.on_observe = function() world.on_observe = nil; world:replace_app() end
			helpers.assert_eq(world.profiles.get_models(), {})
			helpers.assert_eq(#world.inventory_requests, 1)
			helpers.assert_eq(world.profiles.get_models(), {})
			world:inventory_defer(); world:inventory_answer({ "successor:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "successor:2b" })
			helpers.assert_eq(#world.inventory_requests, 2)
		end)
	end)

	test("(linux-inventory-getter) reentrant newer inventory is preserved for its own fresh getter", function()
		with_managed_responses(function(world)
			fetch(world, { "original:2b" })
			world.on_observe = function()
				world.on_observe = nil
				helpers.assert_eq(world.profiles.refresh_models(), {})
			end
			helpers.assert_eq(world.profiles.get_models(), {})
			world:inventory_defer(); world:inventory_answer({ "newer:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "newer:2b" })
			helpers.assert_eq(#world.inventory_requests, 2)
		end)
	end)

	test("(linux-inventory-getter) fresh external response after app retirement retains ordinary caching", function()
		with_managed_responses(function(world, engine)
			fetch(world, { "original:2b" })
			helpers.assert_true(engine.stop_runtime())
			helpers.assert_eq(world.profiles.get_models(), {})
			world:inventory_defer(); world:inventory_answer({ "external:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "external:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "external:2b" })
			helpers.assert_eq(#world.inventory_requests, 2)
		end)
	end)

	test("(linux-inventory-getter) delayed native answer cannot publish after service replacement", function()
		with_managed_responses(function(world)
			helpers.assert_eq(world.profiles.get_models(), {})
			world:inventory_defer()
			world:replace_app()
			world:inventory_answer({ "late:2b" })
			helpers.assert_eq(world.profiles.get_models(), {})
			world:inventory_defer(); world:inventory_answer({ "successor:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "successor:2b" })
			helpers.assert_eq(#world.inventory_requests, 2)
		end)
	end)

	test("(linux-inventory-getter) delayed refresh coalesces without replacing the originating acquisition", function()
		with_managed_responses(function(world)
			helpers.assert_eq(world.profiles.get_models(), {})
			world:inventory_defer()
			for _ = 1, 5 do helpers.assert_eq(world.profiles.refresh_models(), {}) end
			helpers.assert_eq(#world.inventory_requests, 1)
			world:inventory_answer({ "original:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "original:2b" })
		end)
	end)
end)

helpers.describe("owned deferred inventory", function()
	test("(linux-inventory-async) cold and explicit projections return before HTTP and coalesce", function()
		with_managed_responses(function(world, engine)
			local popen = io.popen
			io.popen = function() error("inventory must never execute synchronous shell IO") end
			local ok, failure = pcall(function()
				for _ = 1, 5 do helpers.assert_eq(engine.get_models(), {}); helpers.assert_eq(engine.refresh_models(), {}) end
				helpers.assert_eq(#world.inventory_defers, 1)
				helpers.assert_eq(#world.inventory_requests, 0)
				helpers.assert_true(engine.runtime_pending())
				world:inventory_defer()
				local request = world.inventory_requests[1]
				helpers.assert_eq(request.options.owner, "ollama_model_inventory")
				helpers.assert_eq(request.options.timeout_ms, 5000)
				helpers.assert_eq(request.options.follow_redirects, false)
				helpers.assert_true(request.options.authorized())
				world:inventory_answer({ "Qwen:2B", "alpha:latest" })
				helpers.assert_eq(engine.get_models(), { "Qwen:2B", "alpha:latest" })
				helpers.assert_eq(engine.get_cached_models(), { "Qwen:2B", "alpha:latest" })
				helpers.assert_eq(engine.runtime_pending(), false)
			end)
			io.popen = popen
			assert(ok, failure)
		end)
	end)

	test("(linux-inventory-async) successful empty cache remains valid across repeated getters", function()
		with_managed_responses(function(world)
			fetch(world, {})
			for _ = 1, 5 do helpers.assert_eq(world.profiles.get_models(), {}) end
			helpers.assert_eq(#world.inventory_defers, 1)
			helpers.assert_eq(#world.inventory_requests, 1)
		end)
	end)

	for _, result in ipairs({
		{ ok = false, status = 0, body = "" },
		{ ok = true, status = 503, body = '{"models":[{"name":"error-envelope:2b"}]}' },
		{ ok = true, status = 200, body = '{"models":{}}' },
		{ ok = true, status = 200, body = '{"models":[{}]}' },
	}) do
		test("(linux-inventory-async) unknown result consumes cold attempt until explicit refresh " .. result.body, function()
			with_managed_responses(function(world)
				helpers.assert_eq(world.profiles.get_models(), {})
				world:inventory_defer(); world.inventory_requests[1]:answer(result)
				for _ = 1, 3 do helpers.assert_eq(world.profiles.get_models(), {}) end
				helpers.assert_eq(#world.inventory_defers, 1)
				helpers.assert_eq(world.profiles.refresh_models(), {})
				world:inventory_defer(); world:inventory_answer({ "retry:2b" })
				helpers.assert_eq(world.profiles.get_models(), { "retry:2b" })
			end)
		end)
	end

	test("(linux-inventory-async) cache-only projection never starts a cold request", function()
		with_managed_responses(function(world, engine)
			for _ = 1, 5 do helpers.assert_eq(engine.get_cached_models(), {}) end
			helpers.assert_eq(#world.inventory_defers, 0)
		end)
	end)

	test("(linux-inventory-async) native defer must physically close before HTTP starts", function()
		with_managed_responses(function(world)
			world.inventory_hold_settlement = "defer"
			world.profiles.get_models(); local deferred = world:inventory_defer()
			helpers.assert_eq(#world.inventory_requests, 0)
			deferred:close()
			helpers.assert_eq(#world.inventory_requests, 1)
			world.inventory_hold_settlement = nil; world:inventory_answer({ "after-ack:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "after-ack:2b" })
		end)
	end)

	test("(linux-inventory-async) logical HTTP success waits for physical result and close ACK", function()
		with_managed_responses(function(world)
			world.inventory_hold_settlement = "http"
			world.profiles.get_models(); world:inventory_defer()
			local request = world:inventory_answer({ "staged:2b" })
			helpers.assert_eq(world.profiles.get_cached_models(), {})
			helpers.assert_true(world.profiles.model_inventory_pending())
			request:close()
			helpers.assert_eq(world.profiles.get_cached_models(), { "staged:2b" })
			helpers.assert_eq(world.profiles.model_inventory_pending(), false)
		end)
	end)

	for _, kind in ipairs({ "defer", "http" }) do
		test("(linux-inventory-async) stop retains exact " .. kind .. " cancellation debt until physical ACK", function()
			with_managed_responses(function(world, engine)
				world.profiles.get_models()
				if kind == "http" then world:inventory_defer() end
				local operation = kind == "http" and world.inventory_requests[1] or world.inventory_defers[1]
				world.inventory_hold_cancel = kind
				helpers.assert_eq(engine.stop_runtime(), false)
				helpers.assert_true(engine.runtime_pending())
				helpers.assert_eq(world.profiles.init({ model = "changed:2b" }), false)
				helpers.assert_eq(world.profiles.get_current_model(), "model:2b")
				helpers.assert_eq(world.profiles.refresh_models(), {})
				helpers.assert_eq(#world.inventory_defers, 1)
				operation:close()
				helpers.assert_true(engine.stop_runtime())
				helpers.assert_eq(engine.runtime_pending(), false)
				helpers.assert_eq(world.profiles.get_cached_models(), {})
			end)
		end)
	end

	test("(linux-inventory-async) inline constructors cannot outrun cancellation or borrow successor source", function()
		with_managed_responses(function(world, engine)
			world.inventory_during_defer = function(op)
				helpers.assert_eq(engine.stop_runtime(), false)
				op:answer()
			end
			world.profiles.get_models()
			helpers.assert_eq(#world.inventory_requests, 0)
			helpers.assert_true(engine.stop_runtime())
			helpers.assert_eq(world.profiles.model_inventory_pending(), false)
		end)
	end)

	test("(linux-inventory-async) inline HTTP completion is staged until constructor returns", function()
		with_managed_responses(function(world)
			world.inventory_during_http = function(op)
				op:answer({ ok = true, status = 200, body = '{"models":[{"name":"inline:2b"}]}' })
				helpers.assert_eq(world.profiles.get_cached_models(), {})
			end
			world.profiles.get_models(); world:inventory_defer()
			helpers.assert_eq(world.profiles.get_models(), { "inline:2b" })
		end)
	end)

	test("(linux-inventory-async) captured notification projects cache without another acquisition", function()
		with_managed_responses(function(world, engine)
			local changes, projected = 0
			local options = { on_models_changed = function()
				changes = changes + 1
				projected = engine.get_cached_models()
			end }
			helpers.assert_true(engine.init(options) ~= false)
			options.on_models_changed = function() error("later options mutation cannot replace callback") end
			fetch(world, { "notification:2b" })
			helpers.assert_eq(changes, 1)
			helpers.assert_eq(projected, { "notification:2b" })
			helpers.assert_eq(#world.inventory_requests, 1)
		end)
	end)

	test("(linux-inventory-async) reinitialization revokes delayed original inventory publication", function()
		with_managed_responses(function(world)
			world.profiles.get_models(); world:inventory_defer()
			local old = world.inventory_requests[1]
			helpers.assert_true(world.profiles.init({ model = "configured:2b" }))
			old:answer({ ok = true, status = 200, body = '{"models":[{"name":"late:2b"}]}' })
			helpers.assert_eq(world.profiles.get_cached_models(), {})
			world.profiles.get_models(); world:inventory_defer(); world:inventory_answer({ "fresh:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "fresh:2b" })
			helpers.assert_eq(world.profiles.get_current_model(), "configured:2b")
		end)
	end)

	test("(linux-inventory-async) lifecycle fixture module replacement revokes old notification and cache", function()
		with_managed_responses(function(world, engine)
			local original, old_notices, new_notices = world.profiles, 0, 0
			helpers.assert_true(original.init({ model = "model:2b", on_models_changed = function()
				old_notices = old_notices + 1
			end }))
			original.get_models(); world:inventory_defer()
			local old = world.inventory_requests[1]
			-- Production file watchers do not reload Profiles. This deliberately
			-- replaces the real module only to exercise its lifetime identity fence.
			package.loaded["modules.llm.profiles"] = nil
			local ok, failure = xpcall(function()
				local successor = require("modules.llm.profiles")
				helpers.assert_true(successor ~= original)
				helpers.assert_true(successor.init({ model = "successor:2b", on_models_changed = function()
					new_notices = new_notices + 1
				end }))
				old:answer({ ok = true, status = 200, body = '{"models":[{"name":"stale:2b"}]}' })
				helpers.assert_eq(old_notices, 0, "The retired module cannot request a tray/page rebuild.")
				helpers.assert_eq(original.get_cached_models(), {})
				helpers.assert_eq(engine.get_cached_models(), {})
				helpers.assert_eq(successor.get_cached_models(), {})
				helpers.assert_eq(engine.get_models(), {})
				world:inventory_defer(); world:inventory_answer({ "successor-inventory:2b" })
				old:answer({ ok = true, status = 200, body = '{"models":[{"name":"late-again:2b"}]}' })
				helpers.assert_eq(old_notices, 0)
				helpers.assert_eq(new_notices, 1)
				helpers.assert_eq(original.get_cached_models(), {}, "The old getter cannot adopt successor cache.")
				helpers.assert_eq(engine.get_cached_models(), { "successor-inventory:2b" })
				helpers.assert_eq(#world.inventory_requests, 2)
			end, debug.traceback)
			package.loaded["modules.llm.profiles"] = original
			assert(ok, failure)
		end)
	end)

	test("(linux-inventory-async) later external origin receives only its own response", function()
		with_managed_responses(function(world, engine)
			world.profiles.get_models(); world:inventory_defer()
			local old = world.inventory_requests[1]
			helpers.assert_true(engine.stop_runtime())
			helpers.assert_true(world.profiles.init({ port = 12543, model = "model:2b" }))
			world.profiles.get_models(); world:inventory_defer(); world:inventory_answer({ "new-origin:2b" })
			old:answer({ ok = true, status = 200, body = '{"models":[{"name":"old-origin:2b"}]}' })
			helpers.assert_eq(world.inventory_requests[2].url, "http://127.0.0.1:12543/api/tags")
			helpers.assert_eq(world.profiles.get_models(), { "new-origin:2b" })
		end)
	end)

	test("(linux-inventory-async) replacement HTTP capability cannot acquire the reserved request", function()
		with_managed_responses(function(world)
			world.profiles.get_models()
			local Http = package.loaded["adapters.http_client"]
			local get = Http.get_owned
			Http.get_owned = function() error("replacement capability must not execute") end
			world:inventory_defer()
			Http.get_owned = get
			helpers.assert_eq(#world.inventory_requests, 0)
			helpers.assert_eq(world.profiles.model_inventory_pending(), false)
		end)
	end)

	test("(linux-inventory-async) constructor unwind retains unknown ownership instead of acknowledging stop", function()
		with_managed_responses(function(world, engine)
			world.inventory_during_http = function() error("native constructor unwind") end
			world.profiles.get_models(); world:inventory_defer()
			helpers.assert_eq(engine.stop_runtime(), false)
			helpers.assert_true(engine.runtime_pending())
			helpers.assert_eq(world.profiles.init({ model = "replacement:2b" }), false)
			helpers.assert_eq(#world.inventory_requests, 1)
		end)
	end)

	test("(linux-inventory-async) cold stop does not import inventory or Profiles", function()
		Fixture.with_owner(function()
			package.loaded["modules.llm.prediction_engine"] = nil
			package.loaded["modules.llm.profiles"] = nil
			package.loaded["modules.llm.model_inventory"] = nil
			package.loaded["modules.llm.runtime_factory"] = nil
			local engine = require("modules.llm.prediction_engine")
			helpers.assert_true(engine.stop_runtime())
			helpers.assert_eq(engine.runtime_pending(), false)
			helpers.assert_eq(package.loaded["modules.llm.profiles"], nil)
			helpers.assert_eq(package.loaded["modules.llm.model_inventory"], nil)
			helpers.assert_eq(package.loaded["modules.llm.runtime_factory"], nil)
		end)
	end)
end)
